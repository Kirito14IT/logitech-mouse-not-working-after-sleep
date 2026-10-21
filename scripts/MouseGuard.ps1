# MouseGuard.ps1 — 常驻守护：G304 失联时自动复位接收器。
#
# 为什么不用 Raw Input 做检测：
#   实测本机（Session 2，Interactive=True 的计划任务内）GetRawInputDeviceList 恒返回 0，
#   光标明显在动（1640,766 -> 1416,1040）而 raw input 收到 0 个事件——
#   这台机器上 raw input 不可用，任何基于它的按设备判定都是瞎的。
#
# 改用两个不依赖 raw input 的触发器：
#   T1 接收器刚被重新枚举过（LastArrivalDate 变化，实例 ID 不变）
#      = Windows 在待机后给接收器做过一次端口复位/重新枚举。
#      这恰恰是接收器固件掉电、鼠标随之失联的那一刻。
#      关键是它发生在用户回来之前，所以这次复位用户完全无感。
#   T2 用户从长时间空闲回来，但指针没有跟着动
#      = 鼠标死了（活着的话，用户一动鼠标指针就动）。
#      鼠标活着时这个触发器不会响，所以不会给正常使用添乱。
#
# 修复动作 = 重新枚举接收器（软件层面的 USB 复位，等价于拔插一次）。
#
# 需要管理员权限。以交互式计划任务在用户会话中常驻。

$ErrorActionPreference = 'Continue'
$Base     = 'E:\LogitechMouseFix'
$stateDir = "$Base\state"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$logFile  = "$stateDir\guard.log"

# 手工复位请求：桌面入口写这个文件，守护（SYSTEM 权限）看到后执行复位
$requestFile = "$stateDir\repair.request"
$requestDone = "$stateDir\repair.done"

function W([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IdleProbe {
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
  public static long IdleMs() {
    LASTINPUTINFO l = new LASTINPUTINFO();
    l.cbSize = (uint)Marshal.SizeOf(l);
    GetLastInputInfo(ref l);
    return (long)((uint)Environment.TickCount - l.dwTime);
  }
  public static int[] Cursor() { PT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }
}
'@ -ErrorAction SilentlyContinue

function Get-Receiver {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } |
        Select-Object -First 1
}

# 接收器最近一次被枚举/接上的时刻。Windows 每次重新枚举设备都会刷新它，
# 而设备实例 ID 不变——所以它是"接收器刚刚被复位过"最可靠的信号。
function Get-ArrivalStamp($recv) {
    $v = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue).Data
    if ($v) { return [string]$v }
    return $null
}

function Repair([string]$why) {
    W "触发修复：$why"
    try {
        & "$Base\Recover-Mouse.ps1" -Silent
        W "修复完成"
    } catch { W "修复异常: $($_.Exception.Message)" }
    Start-Sleep -Seconds 5
}

W "=== MouseGuard 启动 (PID=$PID, Session=$((Get-Process -Id $PID).SessionId)) ==="

# 触发器设计（2026-10-22 修正）
#
# 上一版有两个触发器，实测在真实待机后一次都没触发，原因有两个：
#   T1  LastArrivalDate 变化 —— 待机期间 Windows 根本没有重新枚举接收器
#       （实例 ID 和 LastArrivalDate 都没变），所以这个信号永远不来。
#   T2  指针不动 —— 用户回来后改用触控板，指针动了，判据被自己抑制掉。
#
# 而 Windows 侧完全查不到掉电迹象：ConfigFlags=0（无 SUSPENDED 标志）、
# ProblemCode=0、DeviceSelectiveSuspended 属性都不存在。也就是说掉电发生在
# Windows 电源管理管不到的那一层（Modern Standby 的端口电源门控 / D3cold，
# 由 EC/BIOS 决定），**软件既拦不住，也观测不到**。
#
# 于是判据改成"不判断鼠标死没死，只判断用户回来了没有"：
#   T1  接收器被重新枚举（换 USB 口 / 驱动更新）-> 复位
#   T2  系统空闲从长变短 = 用户回来了        -> 复位（主力，不看指针）
#   T5  长时间空闲时的低频兜底复位（保证最坏 20 分钟内一定恢复）
#
# 代价：用户从长空闲回来时，鼠标会有 4~5 秒空窗。但那正是鼠标本来就会死的
# 时刻，所以感知是"本来就不动，4 秒后突然好了"，远好于"一直坏着要拔插"。

$lastArrival  = $null
$lastInstance = $null
$recvId       = $null
$prevIdle     = 0L
$lastRepair   = 0L
# 超过这个空闲时长，认为"可能已经进入掉电状态"
$RETURN_IDLE_MS = 240000          # 4 分钟
$COOLDOWN_MS    = 60000           # 两次复位之间的最小间隔
$IDLE_REPAIR_MS = 120000          # T5 兜底：2 分钟一次
$IDLE_TRIGGER_MS = 300000         # 空闲超过 5 分钟才进入 T5
$POLL_MS        = 3000
$RESCAN_EVERY   = 5               # 每 5 次（约 15 秒）全量枚举一次

$tick = 0
try {
    while ($true) {
        $tick++
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        # ── T6：手工请求（桌面的「一键恢复鼠标」写这个文件）──
        #     守护本身以 SYSTEM 权限运行，所以由它来复位就不需要弹 UAC。
        #     放在循环最前面，响应最快。
        if (Test-Path -LiteralPath $requestFile) {
            try { Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue } catch { }
            Repair "T6 收到手工复位请求"
            $lastRepair = $now
            Set-Content -LiteralPath $requestDone -Value (Get-Date -Format 'o') -Encoding UTF8
        }

        # ── 便宜路径：查已缓存实例的 LastArrivalDate ──
        if ($recvId) {
            $v = (Get-PnpDeviceProperty -InstanceId $recvId -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue).Data
            if ($v) {
                $v = [string]$v
                if ($lastArrival -and $v -ne $lastArrival) {
                    if ($now - $lastRepair -gt $COOLDOWN_MS) {
                        Repair "T1 接收器刚被重新枚举（LastArrival 变化）"
                        $lastRepair = $now
                    }
                }
                $lastArrival = $v
            }
        }

        # ── 昂贵路径：偶尔全量枚举，刷新实例 ID、发现接收器换口 ──
        if (-not $recvId -or ($tick % $RESCAN_EVERY) -eq 0) {
            $recv = Get-Receiver
            if ($recv) {
                if ($lastInstance -and $recv.InstanceId -ne $lastInstance) {
                    if ($now - $lastRepair -gt $COOLDOWN_MS) {
                        Repair "T1b 接收器实例变化: $lastInstance -> $($recv.InstanceId)"
                        $lastRepair = $now
                    }
                }
                $lastInstance = $recv.InstanceId
                $recvId = $recv.InstanceId
            } else {
                $recvId = $null
            }
        }

        $idle = [IdleProbe]::IdleMs()

        # ── T2：系统空闲从长变短 = 用户回来了（不看指针动不动）──
        if ($prevIdle -gt $RETURN_IDLE_MS -and $idle -lt 1000) {
            if ($now - $lastRepair -gt $COOLDOWN_MS) {
                Repair "T2 用户从长空闲回来了（待机后接收器可能已掉电）"
                $lastRepair = $now
            }
        }

        # ── T5：用户离开期间周期性复位接收器（主动式）──
        #     关键：Modern Standby 下用户态程序仍在运行，USB 复位会重新给端口
        #     供电并重启接收器固件。如果待机期间的复位也生效，那么用户回来时
        #     接收器就是新鲜的 —— 直接滑鼠标即可，不必碰键盘。
        #     即便待机期间复位无效，T2 依然会在用户碰到键盘/触控板时兜底。
        if ($idle -gt $IDLE_TRIGGER_MS -and ($now - $lastRepair) -gt $IDLE_REPAIR_MS) {
            Repair "T5 空闲期间主动复位接收器（让用户回来时鼠标已经是好的）"
            $lastRepair = $now
        }

        $prevIdle = $idle
        Start-Sleep -Milliseconds $POLL_MS
    }
} catch {
    W "守护进程异常退出: $($_.Exception.Message)"
    exit 1
}
