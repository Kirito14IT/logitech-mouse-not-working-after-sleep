# 罗技鼠标「待机后失灵」诊断与修复

> Logitech mouse stops working after sleep/wake — diagnosis & fix
> Affected: Logitech G304 LIGHTSPEED (`VID_046D&PID_C53F`) on Windows 11 (Modern Standby / S0)

**一句话结论（TL;DR）**

不是硬件故障，也不需要换鼠标。根因是罗技官方驱动 `logi_lamparray_usb.inf` 会给 LIGHTSPEED 接收器挂一个 **USB 下层过滤驱动 `logi_lamparray`**；该过滤器在 Modern Standby 唤醒后可能卡死，**把鼠标的全部 HID 报告吞掉**，而设备管理器里一切显示正常（`Status=OK`、`CM_PROB_NONE`）。所以「拔插 USB / 重启电脑」能好——那只是重新枚举了设备树，绕过了卡死的过滤器。

**解法**：把 `logi_lamparray` 从接收器设备节点上摘掉 + 卸掉它的驱动包；再关掉 USB 选择性暂停 / 快速启动 / 设备电源管理，从源头断掉复现条件。**全程不需要拔插、不需要重启。**

---

## 目录

- [1. 为什么难查](#1-为什么难查)
- [2. 根因](#2-根因)
- [3. 诊断流程（可复现）](#3-诊断流程可复现)
- [4. 修复方案](#4-修复方案)
- [5. 预防性配置](#5-预防性配置)
- [6. 一键自愈](#6-一键自愈)
- [7. 踩过的坑（重要）](#7-踩过的坑重要)
- [8. 上游报告与相关资料](#8-上游报告与相关资料)
- [9. 目录结构](#9-目录结构)
- [English summary](#english-summary)

---

## 1. 为什么难查

故障现象极具迷惑性：

| 你看到的 | 实际情况 |
|---|---|
| 设备管理器里鼠标是 `OK`，没有黄色感叹号 | 设备**从未**在 USB 层断开，只是**报告不出来了** |
| 触控板能用、系统其他部分正常 | 只有 HID 报告流死了，不是 USB 控制器或系统挂了 |
| 拔插接收器就好 | 重新枚举 = 重新加载过滤器驱动 = 绕过卡死状态 |
| 重启电脑就好 | 同上，而且顺带清掉了休眠状态 |
| 事件日志里没有任何错误 | 驱动没报错，它只是**不再上报** |

关键证据（`Get-PnpDevice`）：

```
Status  Class   FriendlyName             InstanceId
OK      Mouse   HID-compliant mouse     HID\VID_046D&PID_C53F&MI_01&COL01\...
```

`Problem = CM_PROB_NONE`。**系统认为它完全正常**——这正是为什么网上所有「重启/换 USB 口」的建议都「有效」但没人找到真正原因。

---

## 2. 根因

### 2.1 罪魁祸首

罗技 LIGHTSPEED 接收器是一个 USB 复合设备。驱动 `logi_lamparray_usb.inf`（WHCP 签名，Logitech 出品）给它的**设备实例**写入了一个下层过滤器：

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\<instance>\LowerFilters
    = { vhf, logi_lamparray }
```

`logi_lamparray.AMD64.sys` 是**内核态 USB 过滤驱动**，负责把 Logitech 设备的 RGB 灯光接入 Windows 11 的 Dynamic Lighting（LampArray）API。`logi_lamparray_service`（用户态服务）是它的同伴。

### 2.2 为什么 G304 根本不需要它

G304 是**单色 DPI 指示灯**机型，没有 RGB、没有 LampArray 能力。但罗技的通用驱动包会**无条件**把灯光驱动挂到 LIGHTSPEED 接收器上——包括对 G304 完全无用的灯光栈。这是罗技驱动打包/绑定的设计问题。

### 2.3 怎么触发的

过滤器驱动在 Modern Standby（你这台机器是 `S0 低电量待机`）之后挂起/恢复时，若状态机没有正确处理 S0 电源转换，就会卡住。卡住后它拦截的 USB 中断不再上行，鼠标的 HID 报告全部消失。

**加剧因素**（Windows 默认值，正好构成完整复现条件）：

- USB 选择性暂停 = **启用**（AC + DC）
- `Device Parameters\DeviceSelectiveSuspended = 1`（设备确实处于被挂起状态）
- 快速启动 = **启用**（于是「关机再开机」其实是休眠恢复，USB 设备常处于半死状态）

### 2.4 这不是孤例

同样的驱动栈在别人机器上也出事：

- **ValveSoftware/Dota2-Gameplay#35162** —— 另一台机器、另一款鼠标（G Pro Wireless）、同一个过滤器：

  ```
  Logitech USB driver: logi_lamparray_usb.inf / oem218.inf
  Driver version: 1.1.91.2790
  Receiver lower filters: vhf, logi_lamparray
  ```

  症状是拔插接收器时 Dota 主线程冻结数秒（DirectInput 同步枚举被拖死）。

- **AprilNEA/OpenLogi#1129** —— `logi_lamparray_service`（经 Windows Update 装的 `logi_lamparray_usb.inf`）持续抢占鼠标的灯光区，导致 HID++ 写入被覆盖。

- **微软官方支持文档**（"Dynamic lighting not working in Windows"）直接教用户**禁用 `Logitech_Lamparray_Service`**，并说明 G 系列键鼠用户大量反馈该服务导致「异常行为」。

> **判定：罗技官方驱动缺陷**，Windows 默认电源策略是放大器。已向罗技官方 GitHub 提 issue（见 §8）。

---

## 3. 诊断流程（可复现）

下面每条都可以直接复制到 **管理员 PowerShell** 执行。

### 3.1 确认设备被正常枚举（排除硬件问题）

```powershell
Get-PnpDevice -Class Mouse | Select-Object Status, Problem, FriendlyName, InstanceId, Present
```

只要 `Present=True` 且 `Status=OK`，**硬件和 USB 链路就是好的**，问题在软件层。

### 3.2 找到接收器节点

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' } |
  Select-Object Status, Class, FriendlyName, InstanceId
```

### 3.3 ⭐ 关键一步：检查下层过滤器

```powershell
$recv = Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
                 $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1

Get-PnpProperty -InstanceId $recv.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters'
# 或者直接读注册表（更可靠）
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name LowerFilters
```

**看到 `logi_lamparray` 出现在这里，就找到根因了。**

### 3.4 检查选择性挂起状态

```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)\Device Parameters" `
  -Name DeviceSelectiveSuspended
# 1 = 设备正处在被选择性挂起的状态
```

### 3.5 确认罗技驱动与服务的存在

```powershell
Get-CimInstance Win32_SystemDriver | Where-Object Name -match 'logi'
Get-Service logi_lamparray*
pnputil /enum-drivers | Select-String -Pattern 'logi_lamparray' -Context 1,3
```

### 3.6 确认「鼠标没在上报」而不是「系统没收到任何鼠标」

触控板正常但鼠标不动 → 精确指向 G304 的 HID 报告流。

想用代码客观区分「G304 的报告」和「触控板的报告」，用 **Raw Input 按设备路径过滤**（见 `scripts/RawInput.ps1`）：

```powershell
. .\scripts\RawInput.ps1
Measure-G304 -Milliseconds 10000
# Count = 0 说明 G304 一个移动事件都没上报
```

---

## 4. 修复方案

完整自动化脚本：`scripts/Fix-LogitechMouse.ps1`（需管理员）。

### 阶段 A：温和恢复（不卸载任何东西）

软件层面模拟一次「拔插 USB」——重建设备树，过滤器驱动会随之重新加载：

```powershell
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false   # 禁用
Start-Sleep -Seconds 2
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false   # 启用
pnputil /restart-device "$($recv.InstanceId)"                    # 再补一刀

# 然后重建鼠标 HID 集合
$mouse = Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' }
Disable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false
Start-Sleep -Seconds 1
Enable-PnpDevice  -InstanceId $mouse.InstanceId -Confirm:$false
```

> ⚠️ Windows PowerShell 5.1 里 `Disable-PnpDevice` 需要 `Import-Module PnpDevice`。

### 阶段 B：摘除 `logi_lamparray` 下层过滤器（核心修复）

```powershell
# Enum 键默认 SYSTEM 独占，管理员需要先夺取所有权
$key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)"
Set-ItemProperty -Path $key -Name LowerFilters -Value @('vhf') -Type MultiString
```

如果报 `拒绝访问`，先夺取所有权：

```powershell
$reg = [Microsoft.Win32.Registry]::LocalMachine
$sub = "SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)"
$k = $reg.OpenSubKey($sub, [Microsoft.Win32.RegistryRights]::TakeOwnership)
$acl = $k.GetAccessControl([Microsoft.Win32.RegistryRights]::None)
$acl.SetOwner((New-Object System.Security.Principal.NTAccount('BUILTIN','Administrators')))
$k.SetAccessControl($acl); $k.Close()

$k2 = $reg.OpenSubKey($sub, [Microsoft.Win32.RegistryRights]::ChangePermissions)
$acl2 = $k2.GetAccessControl([Microsoft.Win32.RegistryRights]::None)
$rule = New-Object System.Security.AccessControl.RegistryAccessRule(
  'BUILTIN\Administrators','FullControl','ContainerInherit,ObjectInherit','None','Allow')
$acl2.ResetAccessRule($rule)
$k2.SetAccessControl($acl2); $k2.Close()

# 然后再写
Set-ItemProperty -Path $key -Name LowerFilters -Value @('vhf') -Type MultiString
```

改完**必须重新枚举设备**才生效（禁用 → 启用接收器）。

### 阶段 C：卸载 `logi_lamparray` 驱动包（必须做，否则会复发）

```powershell
pnputil /delete-driver oem103.inf /uninstall /force   # logi_lamparray_usb.inf
pnputil /delete-driver oem78.inf  /uninstall /force
pnputil /delete-driver oem18.inf  /uninstall /force
pnputil /delete-driver oem6.inf   /uninstall /force   # logi_lamparray_hid.inf
```

**为什么必须卸？** 如果只摘过滤器、却留着驱动包：

- 换 USB 口 → Windows 新建 Enum 实例 → INF 重新把 `logi_lamparray` 写回 `LowerFilters`
- 而内核驱动已被我们停用 → **设备直接「无法启动」（Code 10 / 39）**，比原问题更糟

同时停用残留服务：

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\logi_lamparray' -Name Start -Value 4
Stop-Service logi_lamparray_service -Force
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\logi_lamparray_service' -Name Start -Value 4
```

### 阶段 D：收尾校验

```powershell
$recv = Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
                 $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1

"接收器状态 : $($recv.Status)"
"下层过滤器 : [$(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name LowerFilters)]"
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' } |
  Where-Object Status -ne 'OK'      # 应该没有输出
```

**理想终态**：接收器走微软通用驱动 `usbccgp`（`usb.inf`），`LowerFilters` 为空。

### 回滚

```powershell
pnputil /add-driver ".\backup\drvstore-logi_lamparray_usb.inf_amd64_*/\*.inf" /install
```

装回后请立刻再执行一次阶段 B 的过滤器摘除，否则老问题会回来。

---

## 5. 预防性配置

```powershell
# (a) 关闭所有电源方案的 USB 选择性暂停（AC + DC）
$SUB = '2a737441-1930-4402-8d77-b2bebba308a3'   # USB 设置
$SET = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB 选择性暂停
$schemes = (powercfg /list | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches.Value | Sort-Object -Unique
foreach ($s in $schemes) {
  powercfg /setacvalueindex $s $SUB $SET 0
  powercfg /setdcvalueindex $s $SUB $SET 0
}
powercfg /setactive SCHEME_CURRENT

# (b) 禁止 Windows 关闭罗技接收器接口的电源
Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable |
  Where-Object { $_.InstanceName -match 'VID_046D' } | ForEach-Object {
    $_.Enable = $false
    Set-CimInstance -InputObject $_
  }

# (c) 关闭快速启动（否则「关机再开机」= 休眠恢复，USB 设备常半死）
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0

# (d) 关闭空闲自动睡眠
$SUB = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # 睡眠
$SET = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'   # 在此时间后睡眠
foreach ($s in $schemes) {
  powercfg /setacvalueindex $s $SUB $SET 0
  powercfg /setdcvalueindex $s $SUB $SET 0
}
powercfg /setactive SCHEME_CURRENT

# (e) 关闭接收器自身的选择性挂起 / 增强电源管理
$dp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)\Device Parameters"
Set-ItemProperty $dp -Name SelectiveSuspendEnabled -Value 0 -Type DWord
Set-ItemProperty $dp -Name EnhancedPowerManagementEnabled -Value 0 -Type DWord
```

> 关掉快速启动后，「关机再开机」会走完整关机流程，开机稍慢，但换来 USB 设备不会再「半死」。

---

## 6. 一键自愈

### 手动

双击 `scripts/一键恢复鼠标.bat`（会弹 UAC，选「是」）→ 等价于一次软件层面的 USB 重新枚举。

### 自动（计划任务）

| 任务名 | 触发时机 | 作用 |
|---|---|---|
| `LogitechG304AutoRecover` | 用户登录时 | 重新枚举接收器 |
| `LogitechG304RecoverOnResume` | 从低功耗状态恢复 / 退出新型待机 | **最关键**——故障几乎都发生在唤醒后 |
| `LogitechG304Watchdog` | 每 2 分钟 | 精判「G304 真的死了」才自愈 |

「恢复后自愈」任务用 XML 注册（`schtasks /create /sc ONEVENT` 建的任务 ACL 会让普通用户看不见）：

```powershell
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT15S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\Recover-Mouse.ps1" -Silent</Arguments>
    </Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskName 'LogitechG304RecoverOnResume' -Xml $xml -Force
```

> 事件在 **System** 日志里。`Microsoft-Windows-Kernel-Power` / `Microsoft-Windows-Power-Troubleshooter` **不是**独立的 wevtutil 通道，所以要用 `/ec System` + Provider 过滤，不能用 `/ec Microsoft-Windows-Kernel-Power`（会报「找不到指定的信道」）。

### 看门狗的「不误伤」设计

`scripts/Watchdog.ps1` 不是「定时重启接收器」，而是**三重约束**才动手：

1. 曾经见过 G304 上报（它平时确实在用），且最近 30 分钟内活跃过
2. 当前这一轮 G304 零事件，**而触控板等其它鼠标有活动**
3. 连续 2 轮都是这样（约 4 分钟）

否则不动。理由：如果你平时只用触控板，G304 静默是**正常的**，不能当成故障。判断「别的鼠标在动」靠 Raw Input 的设备路径过滤（`VID_046D&PID_C53F` vs 其它）。

---

## 7. 踩过的坑（重要）

这几条都是实际踩到的，写下来能省下别人半天时间。

### 7.1 `pnputil /enum-drivers` 的输出是**本地化**的

| 进程环境 | 标签 |
|---|---|
| 交互式用户会话 | `Published Name:` / `Original Name:` |
| 提权（UAC）进程 | `发布名称:` / `原始名称:` |

用英文正则解析提权进程的输出 → **全部匹配失败**，而且会静默地「什么都没找到」。

**解法**：用与语言无关的模式，直接抓 `oem\d+\.inf`：

```powershell
$pub = ([regex]::Match($b, '(?i)oem\d+\.inf')).Value
```

并按行切块（空行分隔），不要用带 `\r?\n` 的正则切块（PowerShell 双引号里 `` "`r?`n" `` 的 `?` 会被当成字面量，行为和预期不同）。

### 7.2 卸载罗技驱动包后，**WinUSB 会抢走整个复合设备** → 鼠标 HID 整个消失

`logi_lamparray_usb.inf` 被删掉后，Windows 重新匹配驱动，选中了第三方 `LIGHTSPEED_Receiver.inf`（`libwdi` / WinUSB）——它匹配的是**整个** `VID_046D&PID_C53F`（无 `&MI_` 限定）。

**WinUSB 不暴露 HID 接口**，于是：

```
接收器 : OK   驱动=libwdi 6.1.7600.16385 (oem13.inf)
鼠标HID: <缺失>          ← 鼠标整个不见了
```

**解法**：把这几个 WinUSB 包也卸掉，让接收器回落到微软通用驱动 `usbccgp`：

```powershell
# 只删 LIGHTSPEED_Receiver.inf（匹配整个复合设备的那些）
# 保留 usb_receiver_(interface_0).inf（只匹配 &MI_00 HID++ 接口，原本就正常）
pnputil /delete-driver oem13.inf /uninstall /force
pnputil /delete-driver oem91.inf /uninstall /force

# 然后摘掉旧实例，强制重新安装
pnputil /remove-device "USB\VID_046D&PID_C53F\6&18811D57&0&1"
pnputil /scan-devices
```

**判定方法**：直接读 DriverStore 里 INF 声明的硬件 ID：

```powershell
$fs = "$env:SystemRoot\System32\DriverStore\FileRepository"
Get-ChildItem $fs -Directory | Where-Object Name -match 'lightspeed_receiver|usb_receiver' | ForEach-Object {
  $inf = Get-ChildItem $_.FullName -Filter '*.inf' | Select-Object -First 1
  $ids = [regex]::Matches((Get-Content $inf.FullName -Raw), '(?i)VID_046D&PID_[0-9A-F]{4}(?:&MI_\d+)?') |
         ForEach-Object { $_.Value.ToUpper() } | Sort-Object -Unique
  "$($_.Name)  ->  $($ids -join ', ')"
}
```

### 7.3 `Set-CimInstance` 没有 `-Filter` / `-ClassName`

PowerShell 7 的 `Set-CimInstance` 只有 `-InputObject` / `-Query`：

```powershell
# ❌ 报错：找不到与参数名称 'Filter' 匹配的参数
Set-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -Property @{Enable=$false} -Filter "..."

# ✅
$obj.Enable = $false
Set-CimInstance -InputObject $obj
```

### 7.4 `RegisterRawInputDevices` 返回 `ERROR_INVALID_PARAMETER (87)`

`RIDEV_INPUTSINK` + `hwndTarget = NULL` 在本机不合法。必须先建一个真实窗口（message-only）再注册：

```csharp
IntPtr hwnd = CreateWindowEx(0, "STATIC", "sink", 0, 0,0,0,0,
                              new IntPtr(-3), IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
RegisterRawInputDevices(dev, 1, size);   // dev.hwndTarget = hwnd; dev.dwFlags = RIDEV_INPUTSINK
```

`hwndTarget = NULL` + `dwFlags = 0` 在本机反而能成功注册（前台接收模式）。

### 7.5 PowerShell 变量名**大小写不敏感** → `$base` 覆盖了 `$Base`

```powershell
$Base   = 'E:\LogitechMouseFix'
$base   = Measure-G304 -Milliseconds 8000   # ← 这行把 $Base 覆盖成了一个对象！
...
$bat = "$Base\一键恢复鼠标.bat"              # → 路径变成 "@{Count=-1; Ok=False; ...}\一键恢复鼠标.bat"
```

症状：日志里出现莫名其妙的对象字符串，文件写到错误路径。**给路径变量起个不会撞的名字**（`$ToolRoot` / `$sample`）。

### 7.6 别忘了 `-PresentOnly`

`Get-PnpDevice` 默认会列出所有**历史**设备实例（包括插过的其它接收器、不同 USB 口）。判断「当前在不在」必须加 `-PresentOnly`，否则会对着陈旧实例改注册表。

---

## 8. 上游报告与相关资料

| 链接 | 说明 |
|---|---|
| `logitech/cpg-docs` issue（本文作者提交） | 向罗技官方报告 `logi_lamparray` 过滤器在 S0 恢复后吞掉 HID 报告的缺陷 |
| [ValveSoftware/Dota2-Gameplay#35162](https://github.com/ValveSoftware/Dota2-Gameplay/issues/35162) | 另一台机器、另一款鼠标、同一过滤器栈 |
| [AprilNEA/OpenLogi#1129](https://github.com/AprilNEA/OpenLogi/issues/1129) | `logi_lamparray_service` 抢占鼠标灯光区 |
| 微软支持文档「Dynamic lighting not working in Windows」 | 官方教用户禁用 `Logitech_Lamparray_Service` |
| [openai/codex#33780](https://github.com/openai/codex/issues/33780) | 同类症状：单个 HID 设备不响应导致 HID 枚举卡死 |

---

## 9. 目录结构

```
.
├── README.md                     ← 本文件
├── LICENSE
├── scripts/
│   ├── Fix-LogitechMouse.ps1     ← 一次性主修复（诊断→分阶段修复→预防→部署）
│   ├── Recover-Mouse.ps1         ← 一键恢复（软拔插）
│   ├── Watchdog.ps1              ← 看门狗（不误伤版）
│   ├── RawInput.ps1              ← Raw Input 设备级事件过滤
│   ├── Cleanup-Drivers.ps1       ← 卸载 logi_lamparray 驱动包
│   ├── Restore-HID.ps1           ← 兜底：把接收器从 WinUSB 拉回 usbccgp
│   ├── Final2.ps1                ← 任务重建 + 端到端实测
│   └── 一键恢复鼠标.bat            ← 日常入口
├── docs/
│   ├── root-cause.md             ← 根因深度分析
│   └── diagnostics.md            ← 完整诊断实录
└── evidence/
    ├── REPORT.txt                ← 修复后最终状态报告
    └── *.log                     ← 各阶段执行日志（已脱敏）
```

---

## English summary

**Not a hardware fault.** Logitech's own `logi_lamparray_usb.inf` driver attaches a USB **lower filter driver** (`logi_lamparray`) to LIGHTSPEED receivers. After Modern Standby (S0) resume that filter can wedge, silently swallowing every HID report from the mouse — while Device Manager still shows `Status=OK` / `CM_PROB_NONE`. That is exactly why "unplug the receiver" or "reboot" always worked: they re-enumerate the device tree and reload the filter.

The G304 has no RGB at all, so the LampArray stack is useless to it — the driver package attaches it unconditionally.

**Fix**: remove `logi_lamparray` from the receiver's `LowerFilters` (device-instance key, under `HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\<inst>`), delete the `logi_lamparray*` driver packages, and disable the kernel driver + service. Then disable USB selective suspend, fast startup, per-device power management and idle sleep so the trigger conditions cannot come back. No unplugging, no reboot required.

**Gotcha**: after deleting the Logitech package, a third-party `LIGHTSPEED_Receiver.inf` (libwdi/WinUSB) claims the *whole* composite device and HID interfaces vanish entirely — remove those packages too so the receiver falls back to Microsoft's `usbccgp`.

See `scripts/` for the automated PowerShell implementation, and `docs/` for the full diagnostic transcript.

---

## License

MIT
