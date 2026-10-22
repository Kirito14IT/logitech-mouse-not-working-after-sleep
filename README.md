# 罗技鼠标「待机后失灵」诊断与修复

> Logitech mouse stops working after sleep/wake — diagnosis & fix
> Affected: Logitech G304 LIGHTSPEED (`VID_046D&PID_C53F`) on Windows 11 (Modern Standby / S0)

**一句话结论（TL;DR）**

接收器在待机期间**掉电**，唤醒后固件**不再监听已配对的鼠标** → 鼠标一个 HID 报告都发不出来，而 Windows 侧一切正常。

关键在于：**这次掉电发生在 Windows 电源管理管不到的那一层**（Modern Standby 的端口电源门控 / D3cold，由 EC/BIOS 决定）。所以：

- Windows **观测不到**它（`ConfigFlags=0`、无错误码、`DeviceSelectiveSuspended` 属性根本不存在）
- Windows **拦不住**它（`MSPower_DeviceEnable`、选择性挂起开关、设备参数全部设成"不许省电"也无效）
- 只能**事后补救**：检测到用户回来时把接收器复位一次（软件层面的 USB 复位 = 物理拔插，实测 4~5 秒恢复）

**真正的根治在硬件层**：给接收器接一个**带独立供电的 USB Hub**，或换个 USB 口（换根集线器），或在 BIOS 里把 Modern Standby 换成 S3。

---

## ⚠️ 两次被证伪的结论（本文最有价值的部分）

### 第一次：`logi_lamparray` 过滤驱动

接收器上挂着罗技的 USB 下层过滤驱动：

```
HKLM\...\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters = { vhf, logi_lamparray }
```

推理是自洽的（G304 是单色 DPI 指示灯机型，用不到 RGB 灯光驱动；它插在接收器的 USB I/O 路径上，卡死就会吞掉 HID 报告），旁证也有（微软官方文档教用户禁用 `Logitech_Lamparray_Service`；OpenLogi#1129 报告同一服务覆盖 HID++ 写入；Valve 的 Dota2#35162 里另一台机器、另一款鼠标带着同一套过滤器栈出现主线程冻结）。

于是卸驱动包、摘过滤器、停用服务 —— **鼠标当时确实恢复了**。

但症状复发时第一件事就是查过滤器：

```
LowerFilters = []          ← 过滤器早就不在了
logi_lamparray 驱动包       ← 不存在
logi_lamparray 内核驱动     ← 已停用
```

**症状照样发生。** 上次"修好"只是因为**那次操作顺带重新枚举了接收器**。

> **当一个修复"生效"时，先确认它到底修掉了什么。** 验证了"A 之后好了"还不够，要补对照组"不 A、只做 B 是不是也一样好"。

（过滤器本身仍是真实缺陷，已向罗技提 issue 并更正归因：<https://github.com/Logitech/cpg-docs/issues/25>）

### 第二次：「让集线器不许被关闭 = 根治」

第二次转向电源，逻辑链是：待机时集线器选择性挂起 → 端口断电 → 接收器固件掉电 → 唤醒后不重新监听。于是设了四层加固（全局 USB 选择性挂起关闭、集线器 `MSPower_DeviceEnable=False`、设备各接口 `Enable=False`、设备参数 `SelectiveSuspendEnabled=0` / `EnhancedPowerManagementEnabled=0`）。

**下一次待机，症状照旧。** 而趁鼠标还死着做的取证，才是真正的转折点：

```
DEVPKEY_Device_ConfigFlags             = 0        ← 无 SUSPENDED 标志
DEVPKEY_Device_ProblemCode             = 0
DEVPKEY_Device_LastArrivalDate         = 23:48:18 ← 待机期间没有新的"到达"
DEVPKEY_Device_DeviceSelectiveSuspended = (属性不存在)
Device Parameters\SelectiveSuspendEnabled        = 0   ← 我设的，在
Device Parameters\EnhancedPowerManagementEnabled = 0   ← 我设的，在
```

**待机期间 Windows 根本没有重新枚举接收器**（实例 ID 和 `LastArrivalDate` 都没变）。这同时废掉了守护进程的第一版触发器——它靠 `LastArrivalDate` 变化来检测，而这个信号**永远不来**。

而"我设的值全都在、却一点用都没有"说明：**掉电在 Windows 电源管理管不到的那一层**。

---

## 真正的软件方案：判断「用户回来了」而不是「鼠标死了」

既然观测不到、拦不住，只剩一条路：**用户回来时复位接收器一次**。

### 关键信号：系统空闲时间

`GetLastInputInfo` 的空闲时间在待机期间持续增长，用户一回来就归零。**这是唯一可靠、且成本几乎为零的"用户回来了"信号。**

### 四个触发器

| 触发器 | 条件 | 说明 |
|---|---|---|
| **T1** | 接收器 `LastArrivalDate` 变化 | 换 USB 口 / 驱动更新时触发（待机时不会触发，但换口会） |
| **T1b** | 设备实例 ID 变化 | 接收器被换到别的 USB 口 |
| **T2** | **系统空闲从 >4 分钟掉到 <1 秒** | 用户回来了（碰到键盘/触控板）→ 立即复位接收器 |
| **T5** | **空闲 >5 分钟后，每 2 分钟主动复位一次** | **主动式**：趁用户不在时把接收器复位好，回来直接就能用 |
| **T6** | 手工请求文件 | 桌面「一键恢复鼠标」写请求文件，守护代为执行，**不弹 UAC** |

**T2 不看指针动不动** —— 这是第一版守护最大的教训：第一版要求"回来后 4 秒内指针没动"才修复，于是用户**改用触控板移动指针** → 判据被自己抑制 → 一次都没触发。

### 为什么必须有 T5 主动式

死掉的鼠标**不产生任何输入**——滑动和点击都不会到达 Windows，空闲计时因此不会归零，守护也就不知道用户回来了。T5 反过来做：**在用户离开期间就周期性复位接收器**。

Modern Standby 下用户态程序仍在运行，而 USB 复位会重新给端口供电、重启接收器固件——于是用户回来时接收器就是新鲜的，**直接滑鼠标即可，连键盘都不用碰**。T2 保留为兜底（万一待机期间的复位无效）。

实测：空闲 307s / 427s / 547s 时各自动触发一次，间隔稳定在 2 分钟。

### T6：不需要管理员权限的手工复位

复位接收器**确实需要管理员权限**——实测非提权进程执行 `Disable-PnpDevice` / `Enable-PnpDevice` 直接报「常规故障」。但守护进程本身就是以 SYSTEM 权限运行的，所以桌面入口改成**只写一个请求文件**：

```bat
>"E:\LogitechMouseFix\state\repair.request" echo request
```

守护看到就执行复位。**实测端到端 11 秒，全程不弹 UAC。** 守护没在运行时，批处理会自动退回提权方式。

### 代价与体感

用户从长空闲回来时鼠标有 **4~5 秒空窗**。但那正是鼠标本来就会死的时刻，感知是"本来就不动，4 秒后突然好了"，而不是"一直坏着必须拔插"。

而且 T2 触发在用户**碰到触控板或键盘的那一刻**——也就是他刚发现鼠标坏了、正在找别的办法的时候。恢复延迟几乎零感知。

### 修复动作

```powershell
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false
Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

实测 **4~5 秒**。

---

## ✅ 现场实测验证（2026-10-22 整日）

修复上线后的**第一个完整工作日**，用户反馈：「**今天一整体都没有出现鼠标动不了的情况**」。

守护进程当天的遥测（原始日志：`evidence/field-test-20261022.log`）：

```
T2  用户从长空闲回来（真实待机回机）  :   6 次   ← 每一次都自动恢复
T5  空闲期间主动复位接收器            : 314 次   （间隔稳定 ~2 分钟）
T6  手工请求                          :   8 次
守护异常                             :   0 次
当天结束时接收器状态                   : OK / CM_PROB_NONE
```

**关键在 T2 那 6 次**：每一次都对应一次真实的「待机 → 回机」，而每一次回机时鼠标**直接就能用**——没有手动拔插、没有 UAC、没有用户干预。

这正好验证了方案的两个关键设计：

1. **T5 主动式确实生效**。如果只有 T2 兜底，用户回来时第一次动鼠标应该是"没反应"（T2 要等到他碰到键盘/触控板才触发）。现在回机即用，说明**待机期间的周期性复位已经把接收器保持在健康状态**。
2. **T2 判据「空闲从长变短」不依赖指针**。314 次 T5 复位期间接收器被反复禁用/启用，`LastArrivalDate` 等信号会变化，但守护没有误触发、也没有漏触发——零异常、零误报。

---

## 硬件层：真正的根治

| 方案 | 说明 |
|---|---|
| **带独立供电的 USB Hub** | Hub 有自己的电源，笔记本端口下电不影响它 → 接收器不掉电 → **鼠标永不失联**。最省事、最有效 |
| **换 USB 口** | AMD 平台有多个 USB 控制器（本机 3 个根集线器），**各控制器的 Modern Standby 端口门控行为可能不同**。零成本试一次 |
| **BIOS 切 S3** | 很多 AMD 笔记本在 BIOS 里提供 "S3 Sleep" 与 "Modern Standby" 切换。S3 是真正的 ACPI 睡眠，行为可能完全不同 |
| BIOS 里其它项 | "USB 待机供电" / "USB Selective Suspend" / "Modern Standby" |

---

## 给遇到同样问题的人：最快路径

```powershell
# 1. 确认是软件层问题
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' } |
    Select-Object Status, Problem, Class, InstanceId

# 2. 找到接收器
$recv = Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
                   $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1

# 3. 应急：复位接收器（= 拔插一次，约 4~5 秒，永远有效）
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false; Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

**第 3 步永远能立刻救回来** —— 下次再遇到，先做这步，别急着重启。

---

## 踩过的坑

### `pnputil` 的输出是本地化的

提权进程里输出中文 `发布名称:`，交互式会话里是英文 `Published Name:`。用英文正则解析提权进程的输出 → **全部匹配失败，且静默地"什么都没找到"**。我第一次就是这么把"已清除"写进了日志，复查才发现根本没删。

```powershell
$pub = ([regex]::Match($b, '(?i)oem\d+\.inf')).Value   # 与语言无关
```

### `Set-CimInstance` 没有 `-Filter` / `-ClassName`

PowerShell 7 里只有 `-InputObject` 和 `-Query`：

```powershell
$obj.Enable = $false
Set-CimInstance -InputObject $obj
```

### 删驱动包可能让设备直接起不来

只摘过滤器、留着驱动包 → 换 USB 口时 INF 把过滤器写回来 → 而内核驱动已停用 → **设备直接「无法启动」**。两者必须一起做。

### 卸载第三方驱动后 WinUSB 可能抢走整个复合设备

摘掉罗技驱动包后，Windows 重新匹配时选中第三方 `LIGHTSPEED_Receiver.inf`（libwdi / WinUSB），它匹配**整个** `VID_046D&PID_C53F`（无 `&MI_` 限定）。**WinUSB 不暴露 HID 接口** → 鼠标 HID 节点整个消失。

```
LIGHTSPEED_Receiver.inf        -> VID_046D&PID_C53F          <- 抢整个复合设备，要卸
usb_receiver_(interface_0).inf -> VID_046D&PID_C53F&MI_00    <- 只管 HID++ 接口，保留
```

### Raw Input 不一定可用

本机实测（交互式计划任务内，`SessionId=2`、`UserInteractive=True`）：

```
GetRawInputDeviceList 返回码: 0   (无设备)
光标: 起=(1640,766)  止=(1416,1040)  移动过=True
WatchBoth: G304=0 其它=0
→ 光标动了但 raw input 无事件，RAW INPUT 不可用
```

任何"按设备区分输入来源"的检测方案在这台机器上都是瞎的。**别把方案建立在它之上**，除非先验证过。

### `powershell.exe`（5.1）读无 BOM 的 UTF-8 脚本会炸

Windows PowerShell 5.1 读**没有 BOM 的 UTF-8** `.ps1` 时按 ANSI（中文系统是 GBK）解码。后果是双重的：

```
字符层面：中文注释和字符串全变乱码
语法层面：GBK 把某些 UTF-8 尾字节当成双字节字符的后半段，
          于是紧跟其后的 ASCII 引号 " 被"吃掉" —— 直接变成 ParserError
```

真实报错长这样（脚本里明明只有中文注释和正常字符串）：

```
SystemCleanup.ps1:84 字符: 1
+         if ($sz -lt 1MB) { L ("  跳过 {0}（仅 {1:N0} 字节? -f $sid, $sz
+                                                                 ~
表达式或语句中包含意外的标记"）"。
```

而且它是**静默失败**的：`Start-Process` 拉起子进程，子进程解析失败立刻退出，父进程只看到"进程起来了又没了"，没有任何报错。

**两条规避办法**（本仓库的守护脚本请用 **PowerShell 7 / `pwsh`**，安装脚本已经这样注册了任务）：

```powershell
# 方案 A：用 pwsh（推荐）—— UTF-8 是默认编码
'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File .\MouseGuard.ps1

# 方案 B：脚本内容全部用纯 ASCII —— 5.1 和 7 下行为一致
```

> 判断依据很简单：**只要脚本里有中文，就必须用 `pwsh` 跑**；要兼容 5.1，就把脚本写成纯 ASCII。

### `Start-Process -WindowStyle` 在计划任务里会静默失败

在计划任务上下文里用 `Start-Process ... -WindowStyle Hidden` 拉后台子进程，进程**可能压根不启动**，而且没有报错。

改用 .NET API，并记得把 stderr 重定向出来，否则失败时同样什么都看不到：

```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = 'cmd.exe'
$psi.Arguments = '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\script.ps1" > "C:\path\out.txt" 2>&1'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[System.Diagnostics.Process]::Start($psi) | Out-Null
```

---

## 目录结构

```
.
├── README.md                     ← 本文件
├── LICENSE
├── scripts/
│   ├── Recover-Mouse.ps1         ← 复位接收器（软拔插），4~5 秒
│   ├── MouseGuard.ps1            ← 常驻守护（T1 / T1b / T2 / T5）
│   ├── install-guard.ps1         ← 注册并启动守护计划任务
│   ├── harden-power.ps1          ← 电源管理加固（对本次故障无效，但值得保留）
│   ├── RawInput.ps1              ← Raw Input 设备级事件过滤（本机不可用，仅作参考）
│   ├── Fix-LogitechMouse.ps1     ← 第一轮的一次性主修复脚本，保留作为历史记录
│   ├── Cleanup-Drivers.ps1       ← 卸载 logi_lamparray 驱动包
│   ├── Restore-HID.ps1           ← 兜底：把接收器从 WinUSB 拉回 usbccgp
│   └── 一键恢复鼠标.bat            ← 日常入口（双击即用）
├── docs/
│   ├── root-cause.md             ← 根因深度分析（含两次被证伪的结论）
│   └── diagnostics.md            ← 完整诊断实录
└── evidence/                     ← 执行日志（已脱敏）
    └── field-test-20261022.log   ← 整日实测遥测（6 次待机回机全部自动恢复）
```

---

## English summary

**Not a hardware fault.** The receiver loses power during standby and its firmware stops listening for its paired mouse — so no HID report reaches the system, while the device tree stays perfectly healthy.

Crucially, **this drop happens below the layer Windows power management controls**: in Modern Standby, port power gating is decided by the EC/BIOS. Windows can neither observe it (`ConfigFlags=0`, no error code, `DeviceSelectiveSuspended` does not exist as a property) nor prevent it (every `MSPower_DeviceEnable` / selective-suspend setting was verified in place and changed nothing).

So the software answer is: **stop asking "is the mouse dead?" — you cannot observe that — and ask "is the user back?"**, via the idle timer. Resetting the receiver is a software-level USB reset (one replug) and restores the mouse in 4–5 s. The real fix is at the hardware layer: a self-powered USB hub, a different root hub, or switching the BIOS from Modern Standby to S3.

**Two corrections worth reading**: the first version blamed Logitech's `logi_lamparray` filter driver, and the second claimed that letting the USB hub sleep was the cause. Both were refuted by the evidence above. The earlier fixes only worked because they happened to re-enumerate the receiver.

---

## License

MIT
