# 根因深度分析：USB 端口掉电如何让罗技鼠标"静音"

> 本文是 [logitech-mouse-not-working-after-sleep](https://github.com/Kirito14IT/logitech-mouse-not-working-after-sleep) 的技术附录。
> 所有数据来自一次真实的现场诊断与复现（Windows 11 build 26100，AMD 平台笔记本，Modern Standby S0，罗技 G304 LIGHTSPEED）。

---

## 0. 一句话

> 待机 → USB 集线器选择性挂起 → **接收器端口断电** → 接收器固件掉电 → 唤醒后固件**不再监听已配对的鼠标** → 鼠标的报告一个都到不了系统，而 Windows 侧一切正常。

---

## 1. 先排除硬件

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' } |
    Select-Object Status, Problem, Class, InstanceId
```

```
Status  Problem         Class      InstanceId
OK      CM_PROB_NONE    Mouse      HID\VID_046D&PID_C53F&MI_01&COL01\8&2C2C0656&0&0000
OK      CM_PROB_NONE    USBDevice  USB\VID_046D&PID_C53F&MI_00\7&335346DF&4&0000
OK      CM_PROB_NONE    USB        USB\VID_046D&PID_C53F\6&18811D57&0&1
```

`CM_PROB_NONE` + `Present=True` ⇒ **设备从未在 USB 层断开**。System 日志里也没有任何 `Kernel-PnP` / `UserPnp` / `DriverFrameworks` / `USBHUB3` 告警。

同时**触控板完全正常** ⇒ USB 控制器、系统、输入栈都是好的。

于是故障范围被压缩成一句话：**设备在位、驱动在位，但报告流断了。**

---

## 2. 完整的因果链

### 2.1 供电拓扑

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

**鼠标是电池供电的，接收器是 USB 供电的。** 这个不对称是问题的关键。

### 2.2 待机时发生了什么

Windows 让闲置的 USB 集线器进入**选择性挂起（Selective Suspend）**，从而**切断端口供电**。接收器固件掉电。

日志里的直接证据：待机前后接收器的枚举号从 `&3&` 变成 `&4&` —— **Windows 确实在待机时对接收器做了一次端口复位 / 重新枚举**。而那次复位之后，鼠标依然是死的。

### 2.3 为什么唤醒后鼠标不会自己恢复

接收器固件在掉电重启后不会自动重新扫描并锁定已配对的鼠标（它需要一次 USB 复位才会重启无线栈并重新配对）。

于是形成这个死锁：

- 鼠标有电，一直在发信号
- 接收器"聋了"，收不到也转发不了
- Windows 侧设备树完全健康 → 设备管理器显示 `OK`
- **鼠标就是不发任何报告**

### 2.4 为什么"拔插 USB"能修

拔插 = 给接收器一次 USB 复位 = 固件重启 = 重新监听鼠标 = 恢复。

**这就是为什么"拔插一下就好"这个现象本身就是最强的线索**：它说明问题在**已加载的设备/固件状态**，而不是硬件。

---

## 3. 定位过程中的分岔：一个被证伪的结论

### 3.1 最初的假设

接收器上挂着罗技的 USB 下层过滤驱动：

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters
    = { vhf, logi_lamparray }
```

`logi_lamparray` 是罗技 `logi_lamparray_usb.inf`（WHCP 签名）安装的内核态 USB 过滤驱动，作用是把罗技设备的 RGB 灯光接入 Windows 11 Dynamic Lighting。

推理链：

> G304 是单色 DPI 指示灯机型，没有任何 LampArray 能力 → 这套驱动是误装的 → 它插在接收器的 USB I/O 路径上 → 一旦卡死就会吞掉全部 HID 报告。

旁证：

| 来源 | 内容 |
|---|---|
| 微软官方支持文档 | 教用户**禁用 `Logitech_Lamparray_Service`**，并说明 G 系列键鼠用户大量反馈该服务导致「异常行为」 |
| [AprilNEA/OpenLogi#1129](https://github.com/AprilNEA/OpenLogi/issues/1129) | 同一服务持续往鼠标灯光区推 Windows 强调色，覆盖其他工具的 HID++ 写入 |
| [ValveSoftware/Dota2-Gameplay#35162](https://github.com/ValveSoftware/Dota2-Gameplay/issues/35162) | 另一台机器、另一款鼠标（G Pro Wireless）、**同一套过滤器栈**，拔插时游戏主线程冻结数秒 |

### 3.2 处理与"成功"

卸载驱动包 → 摘除过滤器 → 停用内核驱动与用户服务 → 重新枚举设备。

**鼠标恢复了。** 至此看起来一切自洽。

### 3.3 复发时的反证

症状原样复发。第一件事是查过滤器：

```
LowerFilters        = []        ← 过滤器根本不在了
logi_lamparray 驱动包            ← 不存在
logi_lamparray 内核驱动          ← 已停用（Start=4）
```

**症状照样发生。**

结论只有一个：**上次"修好"不是因为摘了过滤器，而是因为那次操作顺带重新枚举了接收器。** 过滤器从来不是这个症状的原因。

### 3.4 方法论

> **当一个修复"生效"时，先确认它到底修掉了什么。**
> 验证了"A 之后好了"还不够，要补上对照组"不 A、只做 B 是否也一样好"。

这一步如果早做，能省下"卸载驱动包 → 引入 WinUSB 抢占 → 鼠标 HID 整个消失 → 再花一轮拉回来"这一整串弯路。

---

## 4. 真正的修复

### 4.1 根治：不让端口掉电

关键在于**接收器所在的集线器**：

```powershell
$hub = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent').Data
# -> USB\ROOT_HUB30\5&187d60f0&0&0
```

第一版修复只禁用了接收器的**两个 HID 子接口**（MI_01 / MI_02）的电源管理，
**没有动真正会断电的集线器** —— 这就是"修好了又复发"的技术原因。

四层一起上：

| 层 | 作用 |
|---|---|
| 全局 `USB 选择性暂停 = 禁用`（AC+DC，所有电源方案） | 不让 USB 子系统整体挂起端口 |
| 集线器 `MSPower_DeviceEnable = False` | **端口不再断电**（接收器固件不掉电） |
| 接收器及所有接口 `MSPower_DeviceEnable = False` | 设备本身不被关闭 |
| 每个节点 `SelectiveSuspendEnabled=0`、`EnhancedPowerManagementEnabled=0` | 关掉设备自身的挂起与链路电源管理 |

> `Set-CimInstance`（PowerShell 7）**没有 `-Filter`、没有 `-ClassName`**。
> 正确写法：取出对象 → 改属性 → `Set-CimInstance -InputObject $obj`。

### 4.2 兜底：常驻守护

设置不是万能的（EC/BIOS、驱动栈更新都可能改回去），所以加一个守护。

**关键信号**：`DEVPKEY_Device_LastArrivalDate` 在**每次重新枚举**时刷新，而设备实例 ID 不变。

```
LastArrival before : 2026/10/21 23:04:13
LastArrival after  : 2026/10/21 23:04:46
LastArrival 变化   : True
instance before/after: 相同
```

三个触发器：

| | 条件 | 说明 |
|---|---|---|
| **T1** | `LastArrivalDate` 变化 | Windows 重新枚举过接收器 —— **通常发生在用户回来之前** |
| **T1b** | 实例 ID 变化 | 接收器被换到别的 USB 口 |
| **T2** | 从长空闲(>3min)回来后 4 秒内指针没动 | 鼠标死了（活着的话指针会跟着动，**不会误触发**） |

**为什么 T2 不会误伤**：鼠标正常时，用户一动鼠标指针就动，触发器根本不响。

**为什么放弃 Raw Input**：T2 原本要区分"鼠标死了"和"用户改用触控板"，需要 Raw Input 按设备路径过滤。实测本机（交互式计划任务内，`SessionId=2`、`UserInteractive=True`）：

```
GetRawInputDeviceList 返回码: 0
光标: 起=(1640,766) 止=(1416,1040) 移动过=True
WatchBoth: G304=0 其它=0
→ 光标动了但 raw input 无事件，RAW INPUT 不可用
```

于是**改成完全不依赖 raw input** 的三个触发器。

### 4.3 修复动作与体感

```powershell
Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false
Start-Sleep -Milliseconds 700
Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false
```

实测 **4~5 秒**。因为 T1 发生在用户回来之前，这次中断**完全无感**。

---

## 5. 其他一并查清的问题

| 问题 | 结论 |
|---|---|
| `logi_lamparray` 过滤器 | 与 Dynamic Lighting 确有冲突（微软文档佐证），但**不是**输入失灵的原因；已向罗技提 issue 并更正 |
| 卸载罗技驱动包后 | 第三方 `LIGHTSPEED_Receiver.inf`（libwdi/WinUSB）会抢占**整个**复合设备，**WinUSB 不暴露 HID** → 鼠标 HID 节点整个消失。必须一并卸掉它，让接收器回落到微软 `usbccgp` |
| `usb_receiver_(interface_0).inf` | 只匹配 `&MI_00`（HID++ 接口），原本正常，**保留** |
| 计划任务触发器 | `Microsoft-Windows-Kernel-Power` / `Power-Troubleshooter` **不是**独立 wevtutil 通道，事件在 **System** 日志里；用 `/ec System` + Provider 过滤 |
| 事件触发不可靠 | 实测 6 小时内 System 日志里 0 条 Kernel-Power/Power-Troubleshooter 事件 → **不能靠事件驱动**，改为主动轮询 |
| `Set-CimInstance` 参数 | PS7 只有 `-InputObject` / `-Query` |
| `pnputil` 输出本地化 | 提权进程是中文标签，用 `oem\d+\.inf` 解析 |

---

## 6. 结论

罗技 G304 的"待机后失灵"**不是硬件故障，也不是罗技驱动的 bug**，而是
**USB 端口被选择性挂起切断供电 + 接收器固件掉电后不重新监听鼠标** 共同造成的。

它的迷惑性在于**系统侧完全看不出异常** —— 设备管理器一切正常、事件日志一片干净。
真正有用的判据是：**"拔插一下就好"这个现象本身**，它直接指向"设备/固件状态"而非硬件。

而定位它的过程中最有价值的一课是：**修复生效之后，要补一个对照组来确认它到底修掉了什么。**
