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

$lastArrival  = $null
$lastInstance = $null
$recvId       = $null
$prevIdle     = 0L
$lastRepair   = 0L
# 从长空闲回来时，留 4 秒给指针移动（鼠标活着的话指针会动，就不会误触发）
$RETURN_IDLE_MS = 180000
$COOLDOWN_MS    = 120000
$POLL_MS        = 5000      # 便宜路径的轮询间隔
$RESCAN_EVERY   = 6         # 每 6 次做一次全量枚举（约 30 秒），太频繁太费 CPU

$tick = 0
try {
    while ($true) {
        $tick++
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        # ── 便宜路径：只查已缓存实例的 LastArrivalDate ──
        if ($recvId) {
            $v = (Get-PnpDeviceProperty -InstanceId $recvId -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue).Data
            if ($v) {
                $v = [string]$v
                # ── T1：接收器刚刚被重新枚举过（Windows 在待机后做过端口复位）──
                #     这正是接收器固件掉电、鼠标随之失联的那一刻。
                #     用户这时通常还没回到电脑，所以这次复位对他完全无感。
                if ($lastArrival -and $v -ne $lastArrival) {
                    if ($now - $lastRepair -gt $COOLDOWN_MS) {
                        Repair "T1 接收器刚被重新枚举（LastArrival 变化）"
                        $lastRepair = $now
                    }
                }
                $lastArrival = $v
            }
        }

        # ── 昂贵路径：偶尔全量枚举，刷新实例 ID、发现接收器被换到别的口 ──
        if (-not $recvId -or ($tick % $RESCAN_EVERY) -eq 0) {
            $recv = Get-Receiver
            if ($recv) {
                # ── T1b：设备实例 ID 变了 ──
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

        # ── T2：用户从长空闲回来，但指针没动 ──
        if ($prevIdle -gt $RETURN_IDLE_MS -and $idle -lt 500) {
            if ($now - $lastRepair -gt $COOLDOWN_MS) {
                $before = [IdleProbe]::Cursor()
                Start-Sleep -Seconds 4
                $after = [IdleProbe]::Cursor()
                if ($before[0] -eq $after[0] -and $before[1] -eq $after[1]) {
                    Repair "T2 从长空闲回来后指针未动（鼠标疑似失联）"
                    $lastRepair = $now
                }
            }
        }

        # ── 注意：这里刻意没有"指针冻结但系统有输入"这一条。
        #    用户打字时指针本来就不动，那条会每 4 秒误触发一次，纯属添乱。

        $prevIdle = $idle
        Start-Sleep -Milliseconds $POLL_MS
    }
} catch {
    W "守护进程异常退出: $($_.Exception.Message)"
    exit 1
}
