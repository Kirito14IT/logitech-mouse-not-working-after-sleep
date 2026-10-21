# 诊断实录：5 分钟确认是不是这个病

> 现场：Windows 11 build 26100（24H2），AMD 平台笔记本，Modern Standby (S0)，罗技 G304 LIGHTSPEED。
> 目标：在不拔插、不重启的前提下，判断「鼠标不响应」是硬件问题还是软件问题，并在 5 分钟内定位到具体元凶。

---

## Step 0 — 先证明硬件是好的

```powershell
Get-PnpDevice -Class Mouse | Select-Object Status, Problem, FriendlyName, InstanceId
```

```
Status  Problem         FriendlyName          InstanceId
OK      CM_PROB_NONE    HID-compliant mouse    HID\VID_046D&PID_C53F&MI_01&COL01\8&1293EAEC&0&0000
OK      CM_PROB_NONE    HID-compliant mouse    HID\VID_046D&PID_C53F&MI_01&COL01\9&2E1727E0&0&0000
OK      CM_PROB_NONE    HID-compliant mouse    HID\TENCENTMYAPPSHIDBUS&COL01\...
OK      CM_PROB_NONE    HID-compliant mouse    HID\HTIX5288&COL01\...          ← 触控板
```

`CM_PROB_NONE` + `Present=True` ⇒ **鼠标在位、驱动在位、链路通**。

> 注意这里有**两个** `PID_C53F` 实例：`8&1293EAEC` 是当前 `Present=True` 的，`9&2E1727E0` 是历史残留。后续所有操作都必须先按 `Present` 过滤，否则会改到陈旧实例。

进一步确认「鼠标其实没在动」：

```powershell
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class CurPos {
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
}
'@
1..8 | ForEach-Object {
  $p = New-Object CurPos+PT; [void][CurPos]::GetCursorPos([ref]$p)
  "$($p.X),$($p.Y)"; Start-Sleep -Milliseconds 350
}
```

输出 8 行**完全相同**的坐标 ⇒ 用户在晃鼠标，但光标纹丝不动。

---

## Step 1 — 找接收器节点

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' } |
  Select-Object Status, Class, FriendlyName, InstanceId
```

```
OK  USB  LIGHTSPEED Receiver  USB\VID_046D&PID_C53F\6&18811D57&0&1
```

`DEVPKEY_Device_LocationInfo` = `Port_#0001.Hub_#0002`。

---

## Step 2 — ⭐ 看过滤器（决定性一步）

```powershell
$recv = Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
                 $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1

Get-PnpDeviceProperty -InstanceId $recv.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters'
```

```
DEVPKEY_Device_LowerFilters : vhf, logi_lamparray
```

注册表同源：

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\6&18811D57&0&1
    LowerFilters    = {vhf, logi_lamparray}
    DeviceDesc      = @oem103.inf,%ls2recvname%;LIGHTSPEED Receiver
    Driver          = {36fc9e60-c465-11cf-8056-444553540000}\0023
```

`oem103.inf` → `logi_lamparray_usb.inf`，Provider `Logitech`，版本 `1.1.84.7627`（2026-02-27）。

**→ 找到元凶。**

---

## Step 3 — 确认选择性挂起状态

```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)\Device Parameters" |
  Select-Object DeviceSelectiveSuspended
```

```
DeviceSelectiveSuspended : 1     ← 设备当时确实处于被选择性挂起的状态
```

---

## Step 4 — 确认罗技驱动栈

```powershell
Get-CimInstance Win32_SystemDriver | Where-Object Name -match 'logi'
Get-Service logi_lamparray*
```

```
Running Manual  logi_lamparray          ...\logi_lamparray.AMD64.sys
Running Automatic logi_lamparray_service Logitech LampArray Service
```

`pnputil /enum-drivers` 里相关包：

| Published | Original | Class |
|---|---|---|
| oem103.inf | logi_lamparray_usb.inf | USB |
| oem78.inf | logi_lamparray_usb.inf | USB |
| oem18.inf | logi_lamparray_usb.inf | USB |
| oem6.inf | logi_lamparray_hid.inf | HIDClass |

另有 `usb_receiver_(interface_0).inf`（libwdi，5 个包）匹配 `&MI_00`；`LIGHTSPEED_Receiver.inf`（libwdi，2 个包）匹配**整个**复合设备——后者是 §7.2 那个坑的元凶。

---

## Step 5 — 确认电源策略

```powershell
powercfg /a
powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
```

```
睡眠状态        : 待机(S0 低电量待机) / 休眠 / 快速启动
USB 选择性暂停  : AC=0x1(启用)  DC=0x1(启用)      ← 应为 0
HiberbootEnabled: 1                                ← 应为 0
```

设备电源管理（`root\wmi`）：

```
InstanceName                                          Enable
USB\VID_046D&PID_C53F&MI_01\7&335346df&3&0001_0      True   ← 应为 False
USB\VID_046D&PID_C53F&MI_02\7&335346df&3&0002_0      True   ← 应为 False
```

---

## Step 6 — 排除事件日志

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-3); Level=1,2,3} |
  Where-Object { $_.ProviderName -match 'Kernel-PnP|UserPnp|USB|HID|DriverFrameworks' }
```

**无任何输出。** 驱动没有报错，也没有设备移除/重新枚举事件——进一步印证「设备没断，只是不上报」。

---

## Step 7 — 验证修复（关键对照实验）

| 阶段 | 动作 | 结果 |
|---|---|---|
| 基线 | — | 光标 12 秒零移动 |
| A | 重启 `logi_lamparray_service` + 禁用/启用接收器 + `pnputil /restart-device` | 仍无输入 |
| B | 从 `LowerFilters` 移除 `logi_lamparray` + 重新枚举 | ✅ **鼠标立刻恢复**（用户实测确认，未拔插、未重启） |
| C | 卸载 `logi_lamparray*` 驱动包 | 完成 |
| D | 卸载 `LIGHTSPEED_Receiver.inf`（WinUSB） | 完成 → 接收器回落 `usbccgp` |
| E | 预防配置 + 部署自愈任务 | 完成 |
| F | 端到端实测一键恢复流程 | 通过，11 个设备全 OK |

---

## 附：让脚本自动判定「鼠标到底有没有在上报」

`scripts/RawInput.ps1` 用 **Raw Input + 设备路径过滤**，只统计 `VID_046D&PID_C53F` 的移动事件，从而把 G304 和触控板区分开：

```powershell
. .\scripts\RawInput.ps1
Measure-G304 -Milliseconds 10000
```

```
>>> 请用 G304 鼠标晃动一下（触控板不算），监听 10000 毫秒…
>>> 收到 G304 移动事件: 0
```

> ⚠️ 两个实现陷阱见 README §7.4：`RegisterRawInputDevices` 用 `RIDEV_INPUTSINK` + `NULL` hwnd 会返回 `ERROR_INVALID_PARAMETER (87)`，必须先建 message-only 窗口。
>
> ⚠️ 另外，部分宿主进程（例如非交互式 agent 进程）根本拿不到 raw input 设备列表，此时该工具会返回 0——**这不代表鼠标坏了**，以人工实测为准。
