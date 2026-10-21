# 根因深度分析：接收器掉电，而 Windows 看不见

> 本文是 [logitech-mouse-not-working-after-sleep](https://github.com/Kirito14IT/logitech-mouse-not-working-after-sleep) 的技术附录。
> 所有数据来自同一台机器上的两次真实复现与一次"趁故障取证"。

---

## 0. 结论

> 接收器在待机期间掉电 → 唤醒后固件不再监听已配对的鼠标 → 鼠标一个 HID 报告都发不出来。
> 而这次掉电在 **Windows 电源管理管不到的那一层**（Modern Standby 的端口电源门控 / D3cold，由 EC/BIOS 决定），
> 因此 Windows **既观测不到、也拦不住**。

---

## 1. 先排除硬件

```
Status  Problem         Class      InstanceId
OK      CM_PROB_NONE    Mouse      HID\VID_046D&PID_C53F&MI_01&COL01\8&2C2C0656&0&0000
OK      CM_PROB_NONE    USBDevice  USB\VID_046D&PID_C53F&MI_00\7&335346DF&4&0000
OK      CM_PROB_NONE    USB        USB\VID_046D&PID_C53F\6&18811D57&0&1
```

`CM_PROB_NONE` + `Present=True` ⇒ **设备从未在 USB 层断开**。System 日志无 `Kernel-PnP` / `UserPnp` / `DriverFrameworks` / `USBHUB3` 告警。触控板完全正常 ⇒ USB 控制器与系统健康。

故障范围：**设备在位、驱动在位，但报告流断了。**

---

## 2. 供电拓扑

```
鼠标（AA 电池供电）
   │  LIGHTSPEED 无线（2.4GHz）
   ▼
接收器固件（由 USB 供电）
   │  USB 中断
   ▼
USB 集线器（笔记本内置根集线器）
   │  USBHUB3
   ▼
Windows USB 栈 → hidusb → mouhid → 系统
```

**鼠标是电池供电的，接收器是 USB 供电的。** 这个不对称是问题的关键：鼠标一直在喊，接收器聋了。

---

## 3. 两次被证伪的结论

### 3.1 第一次：`logi_lamparray` 过滤器

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters
    = { vhf, logi_lamparray }
```

`logi_lamparray` 是罗技 `logi_lamparray_usb.inf`（WHCP 签名）安装的内核态 USB 过滤驱动，把罗技设备的 RGB 接入 Windows 11 Dynamic Lighting。

推理链（自洽）：

> G304 是单色 DPI 指示灯机型，没有 LampArray 能力 → 这套驱动是误装的 → 它插在接收器的 USB I/O 路径上 → 卡死就会吞掉全部 HID 报告。

旁证：

| 来源 | 内容 |
|---|---|
| 微软官方支持文档 | 教用户**禁用 `Logitech_Lamparray_Service`**，说明 G 系列键鼠用户大量反馈该服务导致「异常行为」 |
| [AprilNEA/OpenLogi#1129](https://github.com/AprilNEA/OpenLogi/issues/1129) | 同一服务持续往鼠标灯光区推强调色，覆盖其他工具的 HID++ 写入 |
| [ValveSoftware/Dota2-Gameplay#35162](https://github.com/ValveSoftware/Dota2-Gameplay/issues/35162) | 另一台机器、另一款鼠标（G Pro Wireless）、**同一套过滤器栈**，拔插时游戏主线程冻结数秒 |

处理：卸驱动包 → 摘过滤器 → 停用内核驱动与用户服务 → 重新枚举。**鼠标当时确实恢复了。**

复发时复查过滤器：

```
LowerFilters = []          ← 过滤器早就不在了
logi_lamparray 驱动包       ← 不存在
logi_lamparray 内核驱动     ← 已停用
```

**症状照样发生。** 唯一解释：**上次"修好"是因为那次操作顺带重新枚举了接收器。**

### 3.2 第二次：电源管理「根治」

第二版转向电源，主张"待机时集线器选择性挂起切断端口供电"，并设了四层加固：

1. 全局 `USB 选择性暂停 = 禁用`（全部电源方案，AC + DC）
2. 接收器所在根集线器 `MSPower_DeviceEnable = False`
3. 接收器及各接口 `MSPower_DeviceEnable = False`
4. 设备节点 `SelectiveSuspendEnabled = 0`、`EnhancedPowerManagementEnabled = 0`

**下一次待机，症状照旧。**

而真正有价值的取证是**趁鼠标还死着**查设备状态属性：

```
DEVPKEY_Device_ConfigFlags             = 0        ← 无 SUSPENDED 标志
DEVPKEY_Device_ProblemCode             = 0
DEVPKEY_Device_LastArrivalDate         = 23:48:18 ← 待机期间没有新的"到达"
DEVPKEY_Device_DeviceSelectiveSuspended = (属性不存在)
Device Parameters\SelectiveSuspendEnabled        = 0   ← 我设的，在
Device Parameters\EnhancedPowerManagementEnabled = 0   ← 我设的，在
```

三个推论：

1. **待机期间 Windows 根本没有重新枚举接收器**（设备实例 ID 未变、`LastArrivalDate` 停在 23:48）。→ 第一版守护靠 `LastArrivalDate` 变化检测，**这个信号永远不来**。
2. **Windows 完全不知道接收器掉过电**。无挂起标志、无错误码、无问题状态，连 `DeviceSelectiveSuspended` 属性都不存在。
3. **我做的每一项都确实生效了**（值都是 0 / False），**却毫无作用**。

⇒ **掉电在 Windows 电源管理管不到的那一层**：Modern Standby 里 USB **端口**的电源门控（port power gating / D3cold）由 **EC/BIOS** 决定。

---

## 4. 守卫的触发器：从「鼠标死没死」改成「用户回来了没」

### 4.1 为什么不能判断「鼠标死没死」

要区分"G304 没动"和"触控板在动"，需要按设备区分输入来源 → Raw Input。本机实测**不可用**：

```
GetRawInputDeviceList 返回码: 0
光标: 起=(1640,766) 止=(1416,1040) 移动过=True
WatchBoth: G304=0 其它=0
→ 光标动了但 raw input 无事件
```

（探针跑在交互式计划任务内，`SessionId=2`、`UserInteractive=True`，不是权限问题。）

### 4.2 第一版守卫的两个触发器为什么都不触发

| 触发器 | 为什么失效 |
|---|---|
| T1：`LastArrivalDate` 变化 | 待机期间接收器**没被重新枚举**，这个信号从不来 |
| T2：回来后指针 4 秒不动 | 用户**改用触控板**移动指针 → 判据被自己抑制 |

### 4.3 最终的三个触发器

| | 条件 | 说明 |
|---|---|---|
| **T1** | `LastArrivalDate` 变化 | 换口 / 驱动更新时触发 |
| **T1b** | 设备实例 ID 变化 | 换口了 |
| **T2** | **系统空闲从 >4 分钟掉到 <1 秒** | **主力**：用户回来了 → 立即复位接收器 |
| **T5** | 空闲 > 10 分钟时每 20 分钟兜底 | 保证最坏情况也会恢复 |

**T2 不看指针动不动。** 信号来自 `GetLastInputInfo`：待机期间空闲时间持续增长，用户一回来就归零。

代价：回来时鼠标有 4~5 秒空窗——但那正是它本来就会死的时刻，感知是"本来就不动，4 秒后突然好了"。

### 4.4 修复动作

```powershell
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false
Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

实测 4~5 秒。

---

## 5. 硬件层：真正的根治

| 方案 | 理由 |
|---|---|
| **带独立供电的 USB Hub** | Hub 自带电源，笔记本端口下电不影响它 → 接收器不掉电 → 鼠标永不失联 |
| **换 USB 口 / 换根集线器** | AMD 平台多个 USB 控制器（本机 3 个根集线器），Modern Standby 的端口门控行为可能不同 |
| **BIOS 切 S3** | S3 是真正的 ACPI 睡眠，与"系统还醒着只关屏"的 Modern Standby 行为不同 |

---

## 6. 其它一并查清的问题

| 问题 | 结论 |
|---|---|
| `logi_lamparray` 过滤器 | 与 Dynamic Lighting 确有冲突（微软文档佐证），但**不是**输入失灵的原因；已向罗技提 issue 并两次更正归因 |
| 卸载罗技驱动包后 | 第三方 `LIGHTSPEED_Receiver.inf`（libwdi/WinUSB）会抢占**整个**复合设备，**WinUSB 不暴露 HID** → 鼠标 HID 节点整个消失。必须一并卸掉，让接收器回落到微软 `usbccgp` |
| `usb_receiver_(interface_0).inf` | 只匹配 `&MI_00`（HID++ 接口），原本正常，**保留** |
| 计划任务触发器 | `Microsoft-Windows-Kernel-Power` / `Power-Troubleshooter` **不是**独立 wevtutil 通道，事件在 **System** 日志里；且实测待机不产生可用事件 → **不能靠事件驱动自愈**，改为主动轮询 |
| `Set-CimInstance` 参数 | PS7 只有 `-InputObject` / `-Query` |
| `pnputil` 输出本地化 | 提权进程是中文标签，用 `oem\d+\.inf` 解析 |

---

## 7. 方法论

两次都栽在同一件事上：**修复"生效"之后，没有补对照组来确认它到底修掉了什么。**

- 第一次：验证了"摘过滤器后好了"，没验证"只重新枚举是不是也一样好"；
- 第二次：验证了"设了电源管理参数"，没验证"这参数是否真的能到达掉电的那一层"。

> 正确的顺序是：先做**能区分假设的对照实验**，再宣称修复。做不到时，宁可承认"症状消失"而不要断言"原因找到"。

而真正让问题水落石出的，是**在故障仍然存在时去查状态**——故障现场本身就是最好的取证窗口。
