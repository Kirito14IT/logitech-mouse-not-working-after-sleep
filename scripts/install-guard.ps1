$ErrorActionPreference = 'Continue'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$Base = 'E:\LogitechMouseFix'
$out  = "$Base\state\install-guard.txt"
New-Item -ItemType Directory -Path "$Base\state" -Force | Out-Null

$lines = @()

# 1. 撤掉两个没用的旧任务
foreach ($t in @('LogitechG304Watchdog', 'LogitechG304AutoRecover')) {
    try {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
        $lines += "removed task: $t"
    } catch { $lines += "could not remove $t : $($_.Exception.Message)" }
}

# 2. 注册常驻守护（交互式 + 最高权限 + 登录即启动）
try {
    $act = New-ScheduledTaskAction -Execute $pwsh `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Base\MouseGuard.ps1`"" `
        -WorkingDirectory $Base
    $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'LogitechG304Guard' -Action $act `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME") `
        -Principal $prin -Settings $set -Description 'Logitech G304 guard: auto-reset the receiver when the mouse stops reporting' -Force | Out-Null
    $lines += 'registered task: LogitechG304Guard'
} catch { $lines += "register failed: $($_.Exception.Message)" }

# 3. 立即启动
try {
    Start-ScheduledTask -TaskName 'LogitechG304Guard'
    $lines += 'started LogitechG304Guard'
} catch { $lines += "start failed: $($_.Exception.Message)" }

# 4. 测一次恢复耗时（用户可见的"闪断"时长）
$sw = [Diagnostics.Stopwatch]::StartNew()
& "$Base\Recover-Mouse.ps1" -Silent
$sw.Stop()
$lines += ("recovery duration: {0:N1}s" -f $sw.Elapsed.TotalSeconds)

$lines | Out-File -FilePath $out -Encoding utf8
