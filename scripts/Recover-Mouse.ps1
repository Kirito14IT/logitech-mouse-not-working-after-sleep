# Recover-Mouse.ps1 — 重新枚举罗技 LIGHTSPEED 接收器（软件层面的 USB 复位）。
#
# 为什么能修：接收器在待机时所在的 USB 端口被下电，接收器固件随之掉电；
# 唤醒后它不会自动重新监听已配对的鼠标，于是鼠标完全不上报，而设备管理器里
# 一切显示正常。给接收器做一次 USB 复位（禁用→启用）等于物理上拔插一次，
# 固件重启后就会重新监听，鼠标立即恢复。
#
# 两种模式：
#   -Fast（默认）只复位接收器本体，约 4~6 秒。这是用户能感觉到的中断时长。
#   -Full 额外重建鼠标 HID 集合并重启 pnputil，用于接收器复位后仍未恢复的场合。
#
# 需要管理员权限。

[CmdletBinding()]
param(
    [switch] $Full,
    [switch] $Silent
)

$ErrorActionPreference = 'Continue'
if (-not $Silent) { Write-Host "`n=== 罗技接收器复位 ===" -ForegroundColor Cyan }

$recv = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } |
        Select-Object -First 1

if (-not $recv) {
    if (-not $Silent) { Write-Host "[!] 找不到 LIGHTSPEED 接收器。" -ForegroundColor Red }
    exit 2
}
if (-not $Silent) { Write-Host "接收器: $($recv.InstanceId)" }

$sw = [Diagnostics.Stopwatch]::StartNew()

# ── 复位接收器本体 ──
try {
    Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop
} catch {
    if (-not $Silent) { Write-Host "  禁用失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
Start-Sleep -Milliseconds 700
try {
    Enable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop
} catch {
    if (-not $Silent) { Write-Host "  启用失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
Start-Sleep -Seconds 2

if ($Full) {
    # ── 重建鼠标 HID 集合 ──
    $mouse = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } |
             Select-Object -First 1
    if ($mouse) {
        try { Disable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 700
        try { Enable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    # ── 再补一次 pnputil 级别的重启 ──
    $recv2 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } |
             Select-Object -First 1
    if ($recv2) { pnputil /restart-device "$($recv2.InstanceId)" 2>&1 | Out-Null }
    Start-Sleep -Seconds 2
}

$sw.Stop()
if (-not $Silent) {
    Write-Host ("  完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host "  如果鼠标仍然没反应，请重试一次（接收器可能需要两次复位）。`n"
}
exit 0
