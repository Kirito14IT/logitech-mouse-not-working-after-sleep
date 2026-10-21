# Recover-Mouse.ps1
# 罗技 G304 无线鼠标"软拔插"恢复。
# 原理：罗技 LIGHTSPEED 接收器上挂了 logi_lamparray 这个 USB 下层过滤驱动，
#       它卡死时会把鼠标的 HID 报告全部吞掉（设备管理器却显示一切正常）。
#       重新枚举设备树 = 软件层面模拟一次拔插 USB。
#
# 参数：
#   -Elevate  若当前不是管理员，则自动以管理员身份重新启动自己
#   -Silent   不显示 UAC 提示窗口
#   -Measure  修复后自动检测 G304 是否恢复上报

[CmdletBinding()]
param(
    [switch] $Elevate,
    [switch] $Silent,
    [switch] $Measure
)

$ErrorActionPreference = 'Continue'
$Base = 'E:\LogitechMouseFix'

if (-not $Silent) { Write-Host "`n=== 罗技 G304 恢复工具 ===" -ForegroundColor Cyan }

# ---------- 提权 ----------
if ($Elevate) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $psExe = (Get-Process -Id $PID).Path
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSCommandPath")
        $p = Start-Process -FilePath $psExe -ArgumentList $args -Verb RunAs -PassThru
        if (-not $Silent) { Write-Host "已请求管理员权限，请在 UAC 弹窗点『是』…" -ForegroundColor Yellow }
        $p.WaitForExit()
        exit $p.ExitCode
    }
}

# ---------- 定位设备 ----------
function Get-ReceiverNode {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and
            $_.InstanceId -notmatch '&MI_' -and
            $_.InstanceId -notmatch 'LAMPARRAY'
        } | Select-Object -First 1
}

function Get-MouseHidNode {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } |
        Select-Object -First 1
}

function Get-ReceiverHidNodes {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F*' }
}

$recv = Get-ReceiverNode
$recvHid = Get-ReceiverHidNodes
$mouse = Get-MouseHidNode

if (-not $recv) {
    if (-not $Silent) { Write-Host "[!] 没有找到 LIGHTSPEED 接收器（VID_046D&PID_C53F）。" -ForegroundColor Red }
    exit 2
}
if (-not $Silent) {
    Write-Host "接收器 : $($recv.InstanceId)"
    Write-Host "鼠标HID: $($mouse.InstanceId)"
}

# ---------- 步骤 1：重启罗技 LampArray 用户态服务 ----------
if (-not $Silent) { Write-Host "`n[1/4] 重启 Logitech LampArray 服务…" -ForegroundColor Cyan }
try {
    Stop-Service -Name 'logi_lamparray_service' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Service -Name 'logi_lamparray_service' -ErrorAction SilentlyContinue
} catch { }
Start-Sleep -Milliseconds 800

# ---------- 步骤 2：禁用/启用接收器（软拔插） ----------
if (-not $Silent) { Write-Host "[2/4] 重新枚举接收器设备树（软件模拟拔插 USB）…" -ForegroundColor Cyan }
try {
    Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop
} catch {
    if (-not $Silent) { Write-Host "     禁用失败，改用 pnputil: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
Start-Sleep -Seconds 2
try {
    Enable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop
} catch {
    if (-not $Silent) { Write-Host "     启用失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
Start-Sleep -Seconds 3

# ---------- 步骤 3：pnputil 重启设备（第二道保险） ----------
if (-not $Silent) { Write-Host "[3/4] pnputil /restart-device 接收器…" -ForegroundColor Cyan }
pnputil /restart-device "$($recv.InstanceId)" 2>&1 | Out-Null
Start-Sleep -Seconds 3

# ---------- 步骤 4：重建鼠标 HID 集合 ----------
if (-not $Silent) { Write-Host "[4/4] 重建鼠标 HID 集合…" -ForegroundColor Cyan }
$mouse = Get-MouseHidNode
if ($mouse) {
    try {
        Disable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Enable-PnpDevice  -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    } catch { }
}
Start-Sleep -Seconds 2

# ---------- 结果 ----------
$recv2 = Get-ReceiverNode
$mouse2 = Get-MouseHidNode
if (-not $Silent) {
    Write-Host "`n--- 设备状态 ---" -ForegroundColor Cyan
    if ($recv2)  { Write-Host "接收器 : $($recv2.Status)  $($recv2.InstanceId)" }
    if ($mouse2) { Write-Host "鼠标HID: $($mouse2.Status)  $($mouse2.InstanceId)" }
    $lf = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv2.InstanceId)" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    Write-Host "下层过滤器: $($lf -join ', ')"
}

$ok = $true
if ($Measure) {
    . "$Base\RawInput.ps1"
    $r = Measure-G304 -Milliseconds 8000
    $ok = $r.Ok
    if (-not $Silent) {
        if ($ok) { Write-Host "`n[GOK] G304 已恢复上报数据。" -ForegroundColor Green }
        else     { Write-Host "`n[WARN] 仍未检测到 G304 的移动事件 —— 可能需要执行 Fix-LogitechMouse.ps1 移除 logi_lamparray 过滤器。" -ForegroundColor Red }
    }
}

if (-not $Silent) {
    Write-Host ""
    Write-Host "如果鼠标仍然没反应：请运行  E:\LogitechMouseFix\Fix-LogitechMouse.ps1（需管理员）" -ForegroundColor Yellow
    Read-Host "按回车关闭"
}
exit $(if ($ok) { 0 } else { 1 })
