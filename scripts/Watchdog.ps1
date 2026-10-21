# Watchdog.ps1 —— 罗技 G304 看门狗（由计划任务每 2 分钟调用）
#
# 安全判据（三重约束，任一不满足就不动手）：
#   1. 曾经见过 G304 上报（即它平时确实在用），且在最近 30 分钟内活跃过
#   2. 当前这一轮 G304 零事件，而触控板等其它鼠标有活动
#   3. 连续 2 轮都是"只有触控板在动"（约 4 分钟），排除用户只是暂时没用它
#   4. raw input 拿不到 -> 无法判定 -> 不动手
#   5. 距上次自愈 5 分钟内不再重复自愈
#
# 需要管理员权限（Disable-PnpDevice 等）。

[CmdletBinding()]
param(
    [int] $WindowMs = 6000,
    [switch] $Force
)

$ErrorActionPreference = 'Continue'
$Base     = 'E:\LogitechMouseFix'
$stateDir = "$Base\state"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$stateFile = "$stateDir\watchdog.json"

try { . "$Base\RawInput.ps1" } catch { exit 0 }
if (-not ('MouseWatch' -as [type])) { exit 0 }

# ---- 读取状态 ----
$st = @{ lastSeenG304 = 0; silentRuns = 0; lastHeal = 0 }
if (Test-Path $stateFile) {
    try {
        $j = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $st.lastSeenG304 = [int64]$j.lastSeenG304
        $st.silentRuns   = [int]$j.silentRuns
        $st.lastHeal     = [int64]$j.lastHeal
    } catch { }
}
function Save-State { $st | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---- 频率限制：距上次自愈不足 5 分钟则跳过 ----
if ($st.lastHeal -gt 0 -and ($now - $st.lastHeal) -lt 300) { exit 0 }

# ---- 采样 ----
$counts = $null
try { $counts = [MouseWatch]::WatchBoth($WindowMs, 'VID_046D&PID_C53F') } catch { exit 0 }
if ($null -eq $counts) { exit 0 }          # 拿不到 raw input -> 不判定

$g = [int]$counts[0]   # G304 事件
$o = [int]$counts[1]   # 其它鼠标事件

if ($g -gt 0) {
    $st.lastSeenG304 = $now
    $st.silentRuns   = 0
    Save-State
    exit 0
}

if ($o -eq 0) {                          # 整个系统都没鼠标活动 -> 用户不在用
    $st.silentRuns = 0
    Save-State
    exit 0
}

# G304 静默 + 触控板在动
$st.silentRuns++
$seenRecently = ($st.lastSeenG304 -gt 0) -and (($now - $st.lastSeenG304) -lt 1800)
Save-State

if (-not $seenRecently) { exit 0 }        # G304 平时就没在用 -> 可能是用户只用触控板
if ($st.silentRuns -lt 2)  { exit 0 }    # 只持续一轮 -> 可能只是用户暂时没动它

# 判定：G304 确实卡死了
$st.lastHeal = $now
$st.silentRuns = 0
Save-State
try {
    & "$Base\Recover-Mouse.ps1" -Silent | Out-Null
} catch { }

exit 0
