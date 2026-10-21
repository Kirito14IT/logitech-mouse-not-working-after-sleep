# 根因深度分析：`logi_lamparray` 过滤器如何吃掉鼠标的 HID 报告

> 本文是 [logitech-mouse-not-working-after-sleep](https://github.com/Kirito14IT/logitech-mouse-not-working-after-sleep) 的技术附录。
> 所有数据来自一次真实的现场诊断（Windows 11 26100 / AMD 平台 / Modern Standby S0）。

---

## 0. 现象层

用户的 G304 无线鼠标在电脑待机一段时间后失灵：

- 鼠标有电、接收器 USB 正常插着
- 触控板完全正常
- 鼠标**移动无反应、点击无反应**
- 重新插拔接收器 → 恢复
- 重启电脑 → 恢复

用户自己的判断是「老毛病了，肯定是软件问题」，并明确说「之前知道让鼠标重新动起来的方法就是重新插拔 USB 或重启」。

**这个判断完全正确，而且「拔插/重启能好」这个事实本身就是最强的线索**——它说明设备树重建即可修复，说明问题出在**已加载的驱动/过滤器状态**，而不是硬件。

---

## 1. 排除硬件：设备树完全健康

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' }
```

```
Status  Class      FriendlyName
OK      Mouse      HID-compliant mouse
OK      HIDClass   HID-compliant vendor-defined device
OK      USB        LIGHTSPEED Receiver
...
```

逐个查 `DEVPKEY_Device_ProblemCode`：

```
DEVPKEY_Device_ProblemCode   : 0        (CM_PROB_NONE)
DEVPKEY_Device_Service       : mouhid
DEVPKEY_Device_DriverVersion : 10.0.26100.1150
DEVPKEY_Device_DriverProvider: Microsoft
```

结论：**Windows 从未在 USB 层断开过这个设备**。鼠标 HID 集合（`MI_01&COL01`）存在、状态 OK、由微软标准 `mouhid` 驱动承载。所以「USB 接触不良」「鼠标坏了」「接收器坏了」全部排除。

同时，**系统层面没有任何 USB / PnP / HID 错误事件**（近 3 小时 System 日志中 `Kernel-PnP`、`UserPnp`、`DriverFrameworks`、`USBHUB3` 全部无告警）。

> 至此，故障范围被压缩到：**设备在位、驱动在位、但报告流断了**。

---

## 2. 锁定过滤器

对接收器的**设备实例**枚举过滤器：

```powershell
Get-PnpDeviceProperty -InstanceId 'USB\VID_046D&PID_C53F\6&18811D57&0&1' \
  -KeyName 'DEVPKEY_Device_LowerFilters'
```

```
DEVPKEY_Device_LowerFilters : vhf, logi_lamparray
```

同一个值也直接存在于注册表：

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\6&18811D57&0&1
    LowerFilters = { vhf, logi_lamparray }
```

含义：

| 过滤器 | 是什么 | 归属 |
|---|---|---|
| `vhf` | Virtual HID Framework | Windows 系统组件（正常） |
| `logi_lamparray` | **Logitech 灯光驱动包安装的 USB 下层过滤驱动** | 罗技，随 `logi_lamparray_usb.inf` 到达 |

对应到已加载的内核驱动：

```
State  StartMode  Name             PathName
Running Manual    logi_lamparray    ...\logi_lamparray_usb.inf_amd64_...\logi_lamparray.AMD64.sys
```

以及伴随的用户态服务：

```
Status  StartType  Name                    DisplayName
Running Automatic  logi_lamparray_service   Logitech LampArray Service
```

### 2.1 这个过滤器是干什么的

`logi_lamparray` 存在的唯一目的，是把罗技设备的 RGB 灯光接入 **Windows 11 Dynamic Lighting（LampArray API）**。`logi_lamparray_service` 负责周期性把 Windows 的强调色推给设备。

### 2.2 它为什么会出现在这��鼠标上

驱动包 `logi_lamparray_usb.inf`（Logitech 出品，Microsoft WHCP 签名）在安装时对 **LIGHTSPEED 接收器复合设备**无条件声明 `AddFilter`：

```
HKLM\...\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters = { vhf, logi_lamparray }
```

而 **G304 是单色 DPI 指示灯机型，没有任何 RGB 灯区**，根本不存在 LampArray 能力。`logi_lamparray_hid.inf` 还在系统里注册了一个虚拟 HID 设备（`VID_02046D&PID_B35B`，"Logitech Download Assistant"）——同样是给灯光功能用的。

**结论：这套组件对 G304 完全无用，却实实在在插在了它的 USB I/O 路径上。** 这是罗技驱动打包/绑定策略的问题。

### 2.3 失效机制

USB 下层过滤驱动位于 `URB` 与 HID 类驱动之间。正常路径：

```
鼠标固件 ──(LIGHTSPEED 无线)──> 接收器固件 ──(USB 中断)──> USBHUB3 ──> logi_lamparray ──> hidusb ──> mouhid ──> 系统
```

`logi_lamparray` 插在 USB 栈和 HID 栈之间。**它一旦在电源状态转换中卡死（不返回、不再上行），后面整条链路就断了**，而：
- 设备树不会变（设备还在）
- 驱动不报错（它没「出错」，只是不再传）
- 事件日志没有错误（没有异常码，只是没数据）

这完美解释了「设备管理器一切正常但鼠标不动」。

---

## 3. 触发条件：Windows 默认电源策略

```powershell
powercfg /a
```

```
此系统上有以下睡眠状态:
    待机 (S0 低电量待机) 连接的网络
    休眠
    快速启动
```

**Modern Standby（S0）**——不是传统 S3。在 S0 下，Windows 会在系统空闲时把设备逐个下电（选择性暂停），用户一动又逐个上电。**过滤器驱动如果没正确处理 S0 的挂起/恢复序列，就会卡在中间态。**

配合另外两个默认值，构成完整复现条件：

| 设置 | 值 | 影响 |
|---|---|---|
| USB 选择性暂停 | **启用**（AC + DC） | 接收器 USB 端口被下电，恢复时过滤器状态机最容易出错 |
| `DeviceSelectiveSuspended` | **1** | 证实设备当时确实处于被选择性挂起的状态 |
| 快速启动 | **启用** | 「关机再开机」实为休眠恢复，USB 设备常以半死状态起来 |

事件日志佐证 Modern Standby 转换：

```
Kernel-Power 506  系统正在进入新型待机状态
Kernel-Power 507  系统正在退出新型待机状态
Kernel-Power 42   系统正在进入睡眠状态
Kernel-Power 107  系统已从睡眠状态恢复
Power-Troubleshooter 1  系统已从低功耗状态中恢复
```

---

## 4. 证据闭环

| 证据 | 说明 |
|---|---|
| 设备树 `CM_PROB_NONE`，11 个 VID_046D 设备全 OK | 不是断连，是不上报 |
| `LowerFilters` 含 `logi_lamparray` | 故障点已定位到具体驱动 |
| 摘除过滤器 + 重枚举后**立即恢复**（未拔插、未重启） | 因果关系闭合 |
| 另一台机器、另一款鼠标、同过滤器栈也出问题（Valve issue #35162） | 非单机偶发 |
| 微软官方文档教禁用 `Logitech_Lamparray_Service` | 官方已知冲突 |
| G304 无 RGB 能力 | 该组件对本机完全无用，属误装 |

---

## 5. 修复的因果链

```
1. 移除 LowerFilters 中的 logi_lamparray
        ↓
2. 重新枚举设备树（Disable/Enable + pnputil /restart-device）
        ↓
3. 过滤器不再拦截 HID 报告 → 鼠标恢复上报
        ↓
4. 卸载 logi_lamparray* 驱动包
   （否则换 USB 口时 INF 会把过滤器写回，
     而内核驱动已被停用 → 设备 Code 10/39 无法启动）
        ↓
5. 卸载 LIGHTSPEED_Receiver.inf（libwdi/WinUSB）
   （否则它会抢占整个复合设备，HID 接口全部消失）
        ↓
6. 接收器回落到微软通用驱动 usbccgp，LowerFilters 为空
        ↓
7. 关闭 USB 选择性暂停 / 快速启动 / 设备电源管理 / 空闲睡眠
        ↓
   触发条件不再存在 → 不复发
```

---

## 6. 为什么会「拔插一下就好」

禁用 → 启用接收器设备节点时，Windows 会：

1. 卸载设备栈（`logi_lamparray` 这一层随之从内核卸载）
2. 重新枚举 → 重新加载驱动栈

过滤器驱动被**重新加载** = 状态机回到初始态 = 卡死解除。

所以「拔插 USB」不是修复了硬件，而是**重新加载了一个卡死的内核过滤器**。搞清楚这一点，才能解释为什么它每次都能「自愈」却始终查不出原因。

---

## 7. 残留问题

- **`usb_receiver_(interface_0).inf`（libwdi，5 个包）被保留**：它只匹配 `VID_046D&PID_C53F&MI_00`（HID++ 厂商接口），原本就正常工作，不影响 HID 输入，保留可让依赖 HID++ 的第三方工具继续用。
- **罗技官方软件未安装**：本机没有 G HUB / Logi Options+（无卸载注册表项、无对应服务），只有 `C:\Program Files\Logi\{Trueforce,wheel_sdk}` 与 `C:\Program Files\Logitech\Direct Input Force Feedback` 这类组件目录，以及 `mx_keys.inf`（MX Keys 键盘驱动）。说明 `logi_lamparray` 驱动包是**被其它罗技软件/驱动连带拉进来的**。
- **罗技官方渠道仍应被告知**：这套驱动会绑定到不具备 LampArray 能力的机型上，并且能影响非罗技软件（Valve 的 Dota 案例就是 SDL DirectInput 枚举被拖死）。
