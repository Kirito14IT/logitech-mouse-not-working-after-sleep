# 罗技鼠标「待机后失灵」诊断与修复

> Logitech mouse stops working after sleep/wake — diagnosis & fix
> Affected: Logitech G304 LIGHTSPEED (`VID_046D&PID_C53F`) on Windows 11 (Modern Standby / S0)

**一句话结论（TL;DR）**

不是硬件故障，也**不是驱动 bug**。真凶是：**待机时 USB 集线器进入选择性挂起，接收器端口被断电**，LIGHTSPEED 接收器固件随之掉电，唤醒后**不再监听已配对的鼠标**。Windows 侧一切正常（设备管理器显示 `Status=OK`、无任何错误码），所以表现为「鼠标完全没反应，但看起来一切正常」。

**解法**：
1. **根治** —— 让接收器所在的 USB 集线器不再被关闭，接收器不掉电就不会失联；
2. **兜底** —— 常驻守护进程，检测到 Windows 重新枚举过接收器就自动复位一次（用户还没回到电脑时就已经修好）。

复位接收器 = 软件层面的 USB 复位 = 物理拔插一次，**实测 4~5 秒恢复**。

---

## ⚠️ 关于一个被证伪的结论（本文最有价值的部分）

第一次遇到这个问题时，我认定元凶是罗技官方驱动 `logi_lamparray_usb.inf` 挂在接收器上的 **USB 下层过滤驱动**：

```
HKLM\...\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters = { vhf, logi_lamparray }
```

推理是自洽的（G304 是单色 DPI 指示灯机型，根本用不到 RGB 灯光驱动），而且有旁证：

- **微软官方支持文档**在教用户**禁用 `Logitech_Lamparray_Service`**，并说明 G 系列键鼠用户大量反馈该服务导致「异常行为」
- **AprilNEA/OpenLogi#1129** 报告同一服务持续覆盖 HID++ 写入
- **ValveSoftware/Dota2-Gameplay#35162** 里，另一台机器、另一款鼠标（G Pro Wireless）、**同一套过滤器栈**，拔插接收器时游戏主线程冻结数秒

于是我卸掉驱动包、摘掉过滤器、停用服务。**鼠标当时确实恢复了。**

但症状复发时我第一件事就是查过滤器：

```
LowerFilters = []            ← 过滤器早就不在了
logi_lamparray 驱动包         ← 不存在
logi_lamparray 内核驱动       ← 已停用
```

**症状照样发生。** 也就是说：上次"修好"并不是因为摘掉了过滤器，而是因为**那次操作顺带重新枚举了接收器**（和拔插 USB 是同一件事）。

> **教训：当一个修复"生效"时，先确认它到底修掉了什么。**
> 我验证了"摘过滤器后鼠标好了"，却没验证对照组——"不摘过滤器、只重新枚举，是不是也一样好"。后者才是区分**真因**与**巧合**的实验。

（过滤器本身仍是值得上报的真实缺陷——把 RGB 驱动绑到无 RGB 的机型上、且与 Dynamic Lighting 冲突——但它不是"鼠标待机后失灵"的原因。给罗技的 issue 已同步更正。）

---

## 目录

- [1. 症状与迷惑性](#1-症状与迷惑性)
- [2. 真正的因果链](#2-真正的因果链)
- [3. 修复：根治](#3-修复根治)
- [4. 修复：常驻守护](#4-修复常驻守护)
- [5. 踩过的坑](#5-踩过的坑)
- [6. 给遇到同样问题的人：最快路径](#6-给遇到同样问题的人最快路径)
- [7. 目录结构](#7-目录结构)
- [English summary](#english-summary)

---

## 1. 症状与迷惑性

| 你看到的 | 实际情况 |
|---|---|
| 设备管理器里鼠标是 `OK`，没有黄色感叹号 | 设备**从未**在 USB 层断开，只是**一个 HID 报告都发不出来** |
| 触控板能用，系统其他部分正常 | USB 控制器和系统都是好的 |
| 拔插接收器就好 | 重新枚举 = 给接收器做了一次 USB 复位 = 接收器固件重启 |
| 重启电脑就好 | 同上，且顺带清掉了休眠状态 |
| 事件日志里没有任何错误 | 驱动没报错，它只是**不再上报** |

```
Status  Class   FriendlyName          InstanceId
OK      Mouse   HID-compliant mouse  HID\VID_046D&PID_C53F&MI_01&COL01\8&2C2C0656&0&0000
```

`Problem = CM_PROB_NONE` —— **系统认为它完全正常**。

---

## 2. 真正的因果链

```
鼠标（电池供电）──(LIGHTSPEED 无线)──> 接收器（USB 供电）──(USB 中断)──> USB 集线器 ──> 系统
```

1. 待机时 Windows 让 **USB 集线器进入选择性挂起** → **切断端口供电**；
2. 接收器固件**随之掉电**；
3. 唤醒后固件**不会自动重新监听已配对的鼠标**（需要一次 USB 复位才会重启无线栈）；
4. 鼠标有电、一直在发信号，但接收器"聋了"，于是**一个 HID 报告都到不了系统**；
5. Windows 侧设备树完全健康 → 设备管理器 `Status=OK` → **看起来像硬件坏了**。

日志证据：待机前后接收器枚举号从 `&3&` 变成 `&4&` —— Windows 确实在待机时对接收器做了端口复位，而那次复位后鼠标依然死着。

### 判定「是掉电」而不是「驱动坏了」的最硬证据

让接收器所在的集线器不许被关闭，症状就不再出现：

```powershell
$hub = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent').Data
$obj = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable |
       Where-Object { $_.InstanceName -eq "$hub`_0" }
$obj.Enable = $false
Set-CimInstance -InputObject $obj
```

---

## 3. 修复：根治

四层一起上，缺一层都可能复发。

```powershell
# (1) 全局：关闭所有电源方案的 USB 选择性暂停（AC + DC）
$SUB = '2a737441-1930-4402-8d77-b2bebba308a3'   # USB 设置
$SET = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB 选择性暂停
foreach ($s in (powercfg /list | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches.Value) {
    powercfg /setacvalueindex $s $SUB $SET 0
    powercfg /setdcvalueindex $s $SUB $SET 0
}
powercfg /setactive SCHEME_CURRENT

# (2) 接收器所在的 USB 集线器：不允许被关闭   ← 第一版修复漏掉的就是这层
$hub = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent').Data
$obj = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable |
       Where-Object { $_.InstanceName -eq "$hub`_0" }
$obj.Enable = $false
Set-CimInstance -InputObject $obj

# (3) 接收器自身及所有接口：禁止被关闭
#     每个节点的 root\wmi 实例名 = 设备实例 ID + "_0"
Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable |
    Where-Object { $_.InstanceName -match 'VID_046D' } | ForEach-Object {
        $_.Enable = $false; Set-CimInstance -InputObject $_
    }

# (4) 每个设备节点：关掉设备自身的选择性挂起与增强电源管理
$dp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)\Device Parameters"
Set-ItemProperty $dp -Name SelectiveSuspendEnabled        -Value 0 -Type DWord
Set-ItemProperty $dp -Name EnhancedPowerManagementEnabled -Value 0 -Type DWord
```

> ⚠️ `Set-CimInstance` 在 PowerShell 7 里**只有 `-InputObject` 和 `-Query`**，没有 `-Filter`、没有 `-ClassName`（后者是 `New-CimInstance` 的）。必须取出对象、改属性、再传回去。

---

## 4. 修复：常驻守护

端口断电这类问题靠设置"根除"并不总是可靠（笔记本 EC/BIOS、驱动栈更新都可能改回去）。所以加一个常驻守护，**在用户还没回到电脑时就把接收器复位好**。

### 关键信号：`DEVPKEY_Device_LastArrivalDate`

**Windows 每次重新枚举设备都会刷新它，而设备实例 ID 不变** —— 这是最可靠的"接收器刚刚被复位过"的信号：

```powershell
$before = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
           -KeyName 'DEVPKEY_Device_LastArrivalDate').Data
# ... 重新枚举 ...
$after  = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
           -KeyName 'DEVPKEY_Device_LastArrivalDate').Data
"$before -> $after   changed = $($before -ne $after)"
```

### 三个触发器

| 触发器 | 含义 | 何时发生 |
|---|---|---|
| **T1** | `LastArrivalDate` 变了 | Windows 重新枚举了接收器 —— **通常发生在用户回来之前** |
| **T1b** | 设备实例 ID 变了 | 接收器被换到别的 USB 口 |
| **T2** | 用户从长空闲回来，但**指针没跟着动** | 鼠标死了（鼠标活着的话，用户一动鼠标指针就动） |

**T2 的设计是重点**：鼠标正常时用户一动鼠标指针就动，这个触发器根本不会响，所以**不给正常使用添乱**。

### 为什么不用 Raw Input 做按设备判定

T2 原本需要区分"鼠标死了"和"用户改用触控板"，这要用 Raw Input 按设备路径过滤。**实测这台机器上 Raw Input 不可用**：

```
GetRawInputDeviceList 返回码: 0   (无设备)
光标: 起=(1640,766)  止=(1416,1040)  移动过=True
WatchBoth 结果: G304=0  其它=0
判定: 光标动了但 raw input 无事件 -> RAW INPUT 不可用
```

探针跑在**交互式计划任务**里（`SessionId=2`、`UserInteractive=True`），不是权限问题。

所以最终方案**完全不依赖 raw input**。

### 修复动作

```powershell
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false
Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

实测 **4~5 秒**。这是用户能感觉到的中断，所以时机很重要 —— **T1 发生在用户回来之前，这一下他完全无感**。

### 装法

`scripts/install-guard.ps1` 会：

- 撤掉无效的旧任务；
- 注册 `LogitechG304Guard`（登录即启动，交互式 + 最高权限，崩溃自动重启）；
- 立刻启动一次。

常驻开销约 **1% 单核**（轮询间隔 5 秒；`GetPnpDeviceProperty` 单次约 450 ms，是主要成本）。

---

## 5. 踩过的坑

### `pnputil` 的输出是本地化的

提权进程里输出中文 `发布名称:`，交互式会话里是英文 `Published Name:`。用英文正则解析提权进程的输出 → **全部匹配失败，且静默地"什么都没找到"**。我第一次就是这么把"已清除"写进了日志，复查才发现根本没删。

```powershell
$pub = ([regex]::Match($b, '(?i)oem\d+\.inf')).Value   # 与语言无关
```

### 删驱动包可能让设备直接起不来

只摘过滤器、却留着驱动包 → 换 USB 口时 Windows 新建实例、INF **把过滤器写回来** → 而内核驱动已被停用 → **设备直接「无法启动」**，比原问题更糟。**两者必须一起做。**

### 卸载第三方驱动后 WinUSB 可能抢走整个复合设备

摘掉罗技驱动包后，Windows 重新匹配时选中了第三方 `LIGHTSPEED_Receiver.inf`（libwdi / WinUSB），它匹配**整个** `VID_046D&PID_C53F`（无 `&MI_` 限定）。**WinUSB 不暴露 HID 接口**，鼠标 HID 节点整个消失。

判断哪些该卸、哪些该留，读 DriverStore 里 INF 声明的硬件 ID：

```
LIGHTSPEED_Receiver.inf        -> VID_046D&PID_C53F          <- 抢整个复合设备，要卸
usb_receiver_(interface_0).inf -> VID_046D&PID_C53F&MI_00    <- 只管 HID++ 接口，保留
```

### 不要用"指针冻结 + 系统有输入"当触发器

用户打字时指针本来就不动，那条判据会每几秒误触发一次，纯属添乱。宁可少一条触发器，也不要制造误伤。

---

## 6. 给遇到同样问题的人：最快路径

```powershell
# 1. 确认是软件层问题（设备在位、状态正常）
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' } |
    Select-Object Status, Problem, Class, InstanceId

# 2. 找到接收器，以及它挂在哪个集线器上
$recv = Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
                   $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
$hub  = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
         -KeyName 'DEVPKEY_Device_Parent').Data

# 3. 让集线器不许被关闭（关键一步）
$obj = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable |
       Where-Object { $_.InstanceName -eq "$hub`_0" }
$obj.Enable = $false; Set-CimInstance -InputObject $obj

# 4. 顺手关掉全局 USB 选择性暂停
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT

# 5. 应急：复位接收器（= 拔插一次，约 4~5 秒）
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false; Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

**第 5 步永远能立刻救回来** —— 下次再遇到，先做这步，别急着重启。

---

## 7. 目录结构

```
.
├── README.md                     ← 本文件
├── LICENSE
├── scripts/
│   ├── Recover-Mouse.ps1         ← 复位接收器（软拔插），4~5 秒
│   ├── MouseGuard.ps1            ← 常驻守护（T1 / T1b / T2 三个触发器）
│   ├── install-guard.ps1         ← 注册并启动守护计划任务
│   ├── harden-power.ps1          ← 电源管理加固（集线器 / 设备 / 设备参数）
│   ├── RawInput.ps1              ← Raw Input 设备级事件过滤（本机不可用，仅作参考）
│   ├── Watchdog.ps1              ← 旧版按设备检测看门狗（已弃用）
│   ├── Fix-LogitechMouse.ps1     ← 一次性主修复脚本
│   ├── Cleanup-Drivers.ps1       ← 卸载 logi_lamparray 驱动包
│   ├── Restore-HID.ps1           ← 兜底：把接收器从 WinUSB 拉回 usbccgp
│   └── 一键恢复鼠标.bat            ← 日常入口（双击即用）
├── docs/
│   ├── root-cause.md             ← 根因深度分析
│   └── diagnostics.md            ← 完整诊断实录
└── evidence/                     ← 执行日志（已脱敏）
```

---

## English summary

**Not a hardware fault, and not a driver bug.** The real cause: while the machine is
idle, the **USB hub enters selective suspend and cuts power to the port**. The
LIGHTSPEED receiver's firmware loses power with it and does not go back to
listening for its paired mouse after the resume. The device tree stays perfectly
healthy — Device Manager reports `Status=OK` and nothing lands in the event log —
so it looks like a dead mouse with a healthy system.

**Fix**: stop the hub the receiver is on from being powered down
(`MSPower_DeviceEnable=False` on the hub, USB selective suspend off globally,
`SelectiveSuspendEnabled=0` / `EnhancedPowerManagementEnabled=0` on every node of
the receiver's stack), plus a resident guard that resets the receiver whenever
Windows re-enumerates it — detected through `DEVPKEY_Device_LastArrivalDate`,
which is refreshed on every re-enumeration while the device instance id stays
the same. That repair runs **before the user is back**, so it is invisible.

Resetting the receiver is a software-level USB reset (one replug) and takes
4–5 seconds.

**A correction worth reading**: the first version of this document blamed
Logitech's `logi_lamparray` USB lower filter driver. That was wrong — the filter
was already gone when the symptom recurred. The earlier "fix" worked only
because it re-enumerated the receiver. The filter is still a genuine defect
worth reporting (an RGB driver bound to hardware with no RGB, conflicting with
Dynamic Lighting), but it is not the cause of the input loss.

---

## License

MIT
