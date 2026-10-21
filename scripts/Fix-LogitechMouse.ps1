# Fix-LogitechMouse.ps1
# 罗技 G304 无线鼠标"待机后失联"永久修复（需管理员）
#
# 背景（基于本机实测诊断）：
#   * 鼠标设备树完全健康（Status=OK, CM_PROB_NONE），Windows 从未在 USB 层断开它
#   * 真正的故障点：接收器 USB 节点上挂着罗技的 logi_lamparray 内核下层过滤驱动
#       HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F\<inst>\LowerFilters
#       = {vhf, logi_lamparray}
#     该过滤器一旦在 Modern Standby 后卡死，就会吞掉接收器的全部 HID 报告，
#     而设备管理器仍显示一切正常 —— 这正是"拔插 USB / 重启电脑能好"的根因。
#   * 加剧因素：USB 选择性暂停 = 启用（AC+DC）、快速启动 = 启用、
#     Device Parameters\DeviceSelectiveSuspended = 1（设备确实处于被挂起状态）
#
# 本脚本会：
#   A. 备份所有将被修改的注册表值
#   B. 分阶段修复，每阶段用 raw input 客观验证 G304 是否真的恢复上报
#   C. 移除 logi_lamparray 下层过滤器（并停用该内核驱动，防止复发）
#   D. 关闭 USB 选择性暂停 / 快速启动 / 设备电源管理（预防）
#   E. 落桌面一键恢复脚本 + 注册开机与"唤醒后自动修复"计划任务

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $NoPrompt
)

$ErrorActionPreference = 'Continue'
$Base   = 'E:\LogitechMouseFix'
$Backup = "$Base\backup"
$Log    = "$Base\fix.log"
$stamp  = (Get-Date -Format 'yyyyMMdd-HHmmss')

New-Item -ItemType Directory -Path $Base   -Force | Out-Null
New-Item -ItemType Directory -Path $Backup -Force | Out-Null

function Write-Log {
    param([string] $Text, [string] $Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

Set-Content -Path $Log -Value "" -Encoding UTF8
Write-Log "===== 罗技 G304 永久修复开始 ====="
Write-Log "用户: $env:USERNAME  管理员: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

. "$Base\RawInput.ps1"

# ============================================================
# 0. 备份
# ============================================================
Write-Log "--- 阶段 0：备份 ---" 'STEP'
$regBackup = "$Backup\registry-$stamp.txt"
"=== Enum\\USB\\VID_046D&PID_C53F LowerFilters ===" | Out-File -FilePath $regBackup -Encoding UTF8
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    "{0}`tLowerFilters={1}`tUpperFilters={2}" -f $_.PSChildName, ($p.LowerFilters -join ','), ($p.UpperFilters -join ',') |
        Out-File -FilePath $regBackup -Append -Encoding UTF8
}
$powerBackup = "$Backup\power-$stamp.txt"
powercfg /list                                       | Out-File -FilePath $powerBackup -Encoding UTF8
powercfg /query SCHEME_CURRENT                        | Out-File -FilePath $powerBackup -Append -Encoding UTF8
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled |
    Out-File -FilePath $powerBackup -Append -Encoding UTF8
Write-Log "备份完成 -> $regBackup / $powerBackup"

# ============================================================
# 设备定位辅助
# ============================================================
function Get-ReceiverNode {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_' -and $_.InstanceId -notmatch 'LAMPARRAY' } |
        Select-Object -First 1
}
function Get-MouseHidNode {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } |
        Select-Object -First 1
}

$recv = Get-ReceiverNode
if (-not $recv) { Write-Log "找不到 LIGHTSPEED 接收器，终止。" 'FATAL'; exit 2 }
Write-Log "接收器节点: $($recv.InstanceId)  Status=$($recv.Status)"

$recvKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)"
$lfNow   = (Get-ItemProperty $recvKey -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
Write-Log "当前 LowerFilters: $($lfNow -join ', ')"

# ============================================================
# 1. 基线检测
# ============================================================
Write-Log "--- 阶段 1：基线检测（修复前）---" 'STEP'
$baseline = Measure-G304 -Milliseconds 8000
Write-Log "基线 G304 移动事件数 = $($baseline.Count)  => 修复前 $(if($baseline.Ok){'正常'}else{'失效'})"
$alreadyOk = $baseline.Ok

# ============================================================
# 2. 阶段 A：温和恢复（不卸载任何东西）
# ============================================================
if (-not $alreadyOk) {
    Write-Log "--- 阶段 A：温和恢复（重启服务 + 重新枚举设备树）---" 'STEP'
    try { Stop-Service -Name 'logi_lamparray_service' -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 600
    try { Start-Service -Name 'logi_lamparray_service' -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1

    try { Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop; Write-Log "  接收器已禁用" } catch { Write-Log "  禁用接收器失败: $($_.Exception.Message)" 'WARN' }
    Start-Sleep -Seconds 2
    try { Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction Stop; Write-Log "  接收器已启用" } catch { Write-Log "  启用接收器失败: $($_.Exception.Message)" 'WARN' }
    Start-Sleep -Seconds 3
    pnputil /restart-device "$($recv.InstanceId)" 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $mouse = Get-MouseHidNode
    if ($mouse) {
        try { Disable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 1
        try { Enable-PnpDevice  -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
    $rA = Measure-G304 -Milliseconds 8000
    Write-Log "阶段 A 结果: G304 移动事件 = $($rA.Count)"
    if ($rA.Ok) { $alreadyOk = $true }
}

# ============================================================
# 3. 阶段 B：移除 logi_lamparray 下层过滤器（核心修复）
# ============================================================
if (-not $alreadyOk) {
    Write-Log "--- 阶段 B：移除 logi_lamparray 下层过滤器 ---" 'STEP'

    # Enum 键默认 SYSTEM 独占，管理员需要先夺取所有权
    function Grant-AdminFullControl([string] $PsPath) {
        try {
            $sub = $PsPath -replace '^HKEY_LOCAL_MACHINE\\', ''
            $reg = [Microsoft.Win32.Registry]::LocalMachine
            $k = $reg.OpenSubKey($sub, [Microsoft.Win32.RegistryRights]::TakeOwnership)
            if ($k) {
                $acl = $k.GetAccessControl([Microsoft.Win32.RegistryRights]::None)
                $acl.SetOwner((New-Object System.Security.Principal.NTAccount('BUILTIN','Administrators')))
                $k.SetAccessControl($acl); $k.Close()
                $k2 = $reg.OpenSubKey($sub, [Microsoft.Win32.RegistryRights]::ChangePermissions)
                $acl2 = $k2.GetAccessControl([Microsoft.Win32.RegistryRights]::None)
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                    'BUILTIN\Administrators','FullControl','ContainerInherit,ObjectInherit','None','Allow')
                $acl2.ResetAccessRule($rule)
                $k2.SetAccessControl($acl2); $k2.Close()
                return $true
            }
        } catch { return $false }
        return $false
    }

    $targets = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F' -ErrorAction SilentlyContinue
    foreach ($t in $targets) {
        $p = Get-ItemProperty $t.PSPath -ErrorAction SilentlyContinue
        $lf = @($p.LowerFilters)
        if ($lf -contains 'logi_lamparray') {
            $new = $lf | Where-Object { $_ -ne 'logi_lamparray' }
            if ($new.Count -eq 0) { $new = @() }
            $okWrite = $false
            try {
                Set-ItemProperty -Path $t.PSPath -Name LowerFilters -Value $new -Type MultiString -ErrorAction Stop
                $okWrite = $true
            } catch {
                Write-Log "  直接写入被拒，尝试夺取所有权: $($t.PSChildName)" 'WARN'
                if (Grant-AdminFullControl $t.PSPath) {
                    try {
                        Set-ItemProperty -Path $t.PSPath -Name LowerFilters -Value $new -Type MultiString -ErrorAction Stop
                        $okWrite = $true
                    } catch { Write-Log "  夺取所有权后仍失败: $($_.Exception.Message)" 'ERR' }
                }
            }
            if ($okWrite) { Write-Log "  已从 $($t.PSChildName) 移除 logi_lamparray -> [$($new -join ',')]" }
        }
    }

    # 重新枚举，让新过滤器生效
    $recv = Get-ReceiverNode
    try { Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    try { Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 3
    pnputil /restart-device "$($recv.InstanceId)" 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $rB = Measure-G304 -Milliseconds 8000
    Write-Log "阶段 B 结果: G304 移动事件 = $($rB.Count)"
    if ($rB.Ok) { $alreadyOk = $true }
}

# ============================================================
# 4. 阶段 C：卸载 logi_lamparray USB 驱动包（兜底）
# ============================================================
if (-not $alreadyOk) {
    Write-Log "--- 阶段 C：卸载 logi_lamparray_usb.inf 驱动包（兜底）---" 'STEP'
    $recv = Get-ReceiverNode
    $infName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name Driver -ErrorAction SilentlyContinue).Driver
    Write-Log "  接收器当前驱动槽: $infName"
    $raw = pnputil /enum-drivers 2>&1 | Out-String
    $blocks = $raw -split "`r?`n\s*`r?`n"
    foreach ($b in $blocks) {
        if ($b -match '(?i)logi_lamparray_usb\.inf') {
            $pub = ([regex]::Match($b, 'Published Name:\s*(\S+)')).Groups[1].Value
            if ($pub) {
                Write-Log "  删除驱动包 $pub"
                pnputil /delete-driver $pub /uninstall /force 2>&1 | ForEach-Object { Write-Log "    $_" }
            }
        }
    }
    $recv = Get-ReceiverNode
    try { Disable-PnpDevice -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    try { Enable-PnpDevice  -InstanceId $recv.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 3
    pnputil /scan-devices 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $rC = Measure-G304 -Milliseconds 8000
    Write-Log "阶段 C 结果: G304 移动事件 = $($rC.Count)"
    if ($rC.Ok) { $alreadyOk = $true }
}

# ============================================================
# 5. 预防性配置
# ============================================================
Write-Log "--- 阶段 D：预防性配置 ---" 'STEP'

# D1. 关闭所有电源方案的 USB 选择性暂停（AC + DC）
$USBSS_SUB  = '2a737441-1930-4402-8d77-b2bebba308a3'
$USBSS_SET  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$schemes = (powercfg /list | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches.Value | Sort-Object -Unique
foreach ($s in $schemes) {
    powercfg /setacvalueindex $s $USBSS_SUB $USBSS_SET 0 2>&1 | Out-Null
    powercfg /setdcvalueindex $s $USBSS_SUB $USBSS_SET 0 2>&1 | Out-Null
}
powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
$check = powercfg /query SCHEME_CURRENT $USBSS_SUB $USBSS_SET 2>&1 | Out-String
if ($check -match '0x00000000') { Write-Log "  USB 选择性暂停 -> 已禁用 (AC+DC, 全部电源方案)" } else { Write-Log "  USB 选择性暂停设置未能确认" 'WARN' }

# D2. 禁止 Windows 关闭罗技接收器接口的电源
try {
    $pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
          Where-Object { $_.InstanceName -match 'VID_046D' }
    foreach ($d in $pm) {
        Set-CimInstance -Namespace root\wmi -Property @{ Enable = $false } -Filter "InstanceName='$($d.InstanceName)'" -ErrorAction Stop | Out-Null
        Write-Log "  电源管理关闭: $($d.InstanceName)"
    }
} catch { Write-Log "  设置设备电源管理失败: $($_.Exception.Message)" 'WARN' }

# D3. 关闭接收器的选择性挂起 / 增强电源管理
$recv = Get-ReceiverNode
$dp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)\Device Parameters"
foreach ($n in @('SelectiveSuspendEnabled', 'EnhancedPowerManagementEnabled')) {
    try { Set-ItemProperty -Path $dp -Name $n -Value 0 -Type DWord -ErrorAction Stop; Write-Log "  DeviceParameters.$n = 0" }
    catch { Write-Log "  设置 $n 失败: $($_.Exception.Message)" 'WARN' }
}

# D4. 关闭快速启动（否则"关机再开机"其实是休眠恢复，USB 设备常处于半死状态）
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
    Write-Log "  快速启动 -> 已关闭"
} catch { Write-Log "  关闭快速启动失败: $($_.Exception.Message)" 'WARN' }

# D5. 停用 logi_lamparray 内核驱动（过滤器已移除后，它对 G304 毫无用处）
$otherUsers = @()
foreach ($root in @('HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_046D&PID_C53F',
                    'HKLM:\SYSTEM\CurrentControlSet\Enum\HID')) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (@($p.LowerFilters) -contains 'logi_lamparray') { $otherUsers += $_.PSPath }
    }
}
if ($otherUsers.Count -eq 0) {
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\logi_lamparray' -Name Start -Value 4 -Type DWord -ErrorAction Stop
        Write-Log "  logi_lamparray 内核驱动 -> 已停用（Start=4），不会再被加载"
    } catch { Write-Log "  停用 logi_lamparray 失败: $($_.Exception.Message)" 'WARN' }
    try {
        Stop-Service -Name 'logi_lamparray_service' -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\logi_lamparray_service' -Name Start -Value 4 -Type DWord -ErrorAction SilentlyContinue
        Write-Log "  logi_lamparray_service -> 已停用"
    } catch { }
} else {
    Write-Log "  仍有其他设备引用 logi_lamparray，保留驱动: $($otherUsers -join '; ')" 'WARN'
}

# D6. 关闭空闲自动睡眠（Modern Standby 下 USB 接收器最容易掉线）
$STANDBY_SUB  = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$STANDBY_SET  = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
foreach ($s in $schemes) {
    powercfg /setacvalueindex $s $STANDBY_SUB $STANDBY_SET 0 2>&1 | Out-Null
    powercfg /setdcvalueindex $s $STANDBY_SUB $STANDBY_SET 0 2>&1 | Out-Null
}
powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
Write-Log "  空闲自动睡眠 -> 已关闭"

# ============================================================
# 6. 落桌面一键恢复 + 计划任务
# ============================================================
Write-Log "--- 阶段 E：部署一键恢复与自动修复 ---" 'STEP'
$bat = "$Base\一键恢复鼠标.bat"
if (-not (Test-Path $bat)) {
@'
@echo off
chcp 65001 >nul
title Logitech G304 Mouse Recovery
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\LogitechMouseFix\Recover-Mouse.ps1" -Measure
echo.
echo Done. If the mouse still does not respond, run:
echo   E:\LogitechMouseFix\Fix-LogitechMouse.ps1
pause
'@ | Set-Content -Path $bat -Encoding ASCII
    Write-Log "  已生成 $bat"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop '一键恢复鼠标.lnk'
try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $bat
    $lnk.WorkingDirectory = $Base
    $lnk.Description      = 'Logitech G304 mouse recovery (requires admin)'
    $lnk.Save()
    Write-Log "  桌面快捷方式: $lnkPath"
} catch { Write-Log "  创建桌面快捷方式失败: $($_.Exception.Message)" 'WARN' }

# 开机自动修复
try {
    $pwshPath = (Get-Process -Id $PID).Path
    $act = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Base\Recover-Mouse.ps1`" -Silent" `
        -WorkingDirectory $Base
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $reg = New-ScheduledTask -Action $act -Trigger $trg -Description 'Auto-recover Logitech G304 after logon' `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5))
    Register-ScheduledTask -TaskName 'LogitechG304AutoRecover' -InputObject $reg -Force | Out-Null
    Write-Log "  计划任务 LogitechG304AutoRecover (登录时) 已注册"
} catch { Write-Log "  注册登录计划任务失败: $($_.Exception.Message)" 'WARN' }

# 从现代待机恢复后自动修复（需先为任务计划程序启用该通道）
try {
    wevtutil sl 'Microsoft-Windows-Kernel-Power' /e:true 2>&1 | Out-Null
    $out = schtasks /create /tn 'LogitechG304RecoverOnResume' /tr "`"$pwshPath`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Base\Recover-Mouse.ps1`" -Silent" `
        /sc ONEVENT /ec 'Microsoft-Windows-Kernel-Power' /mo "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507)]]" /ru SYSTEM /rl HIGHEST /f 2>&1
    Write-Log "  恢复后自动修复任务: $out"
} catch { Write-Log "  注册恢复计划任务失败: $($_.Exception.Message)" 'WARN' }

# 看门狗：每 2 分钟检查一次，鼠标死了就自愈（最可靠的一层保险）
try {
    $actW = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Base\Watchdog.ps1`"" `
        -WorkingDirectory $Base
    $trgW = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $regW = New-ScheduledTask -Action $actW -Trigger $trgW -Description 'Logitech G304 watchdog: auto-heal if mouse stops reporting' `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3))
    Register-ScheduledTask -TaskName 'LogitechG304Watchdog' -InputObject $regW -Force | Out-Null
    Write-Log "  看门狗任务 LogitechG304Watchdog (每 2 分钟) 已注册"
} catch { Write-Log "  注册看门狗任务失败: $($_.Exception.Message)" 'WARN' }

# ============================================================
# 7. 最终验证
# ============================================================
Write-Log "--- 阶段 F：最终验证 ---" 'STEP'
$recvF = Get-ReceiverNode
$mouseF = Get-MouseHidNode
Write-Log "接收器: $($recvF.Status)  $($recvF.InstanceId)"
Write-Log "鼠标HID: $($mouseF.Status)  $($mouseF.InstanceId)"
$lfF = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recvF.InstanceId)" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
Write-Log "最终 LowerFilters: [$($lfF -join ', ')]"
$final = Measure-G304 -Milliseconds 10000
Write-Log "最终 G304 移动事件 = $($final.Count)"

$summary = @"
==== 罗技 G304 修复报告 ====
时间            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
G304 恢复上报    : $(if ($final.Count -gt 0) { '是 ✔  （收到 ' + $final.Count + ' 个移动事件）' } else { '否 ✘  （仍未收到移动事件）' })
接收器状态      : $($recvF.Status)
鼠标 HID 状态   : $($mouseF.Status)
下层过滤器      : $($lfF -join ', ')
USB 选择性暂停  : 已禁用
设备电源管理    : 已禁止关闭
快速启动        : 已关闭
空闲自动睡眠    : 已关闭
logi_lamparray  : $(if (@($lfF) -contains 'logi_lamparray') { '仍在（需进一步处理）' } else { '已移除' })
一键恢复脚本    : $bat
桌面快捷方式    : $lnkPath
注册表备份      : $regBackup
电源备份        : $powerBackup
================================
"@
$summary | Out-File -FilePath "$Base\report-$stamp.txt" -Encoding UTF8
Write-Log $summary
Write-Log "===SCRIPT-END==="

if (-not $NoPrompt) {
    $msg = if ($final.Count -gt 0) { "G304 鼠标已恢复 ✔`n`nG304 已重新开始上报数据。`n桌面已生成『一键恢复鼠标』快捷方式。" }
           else { "G304 仍未恢复 ✘`n`n设备树健康但没有输入报告。`n请把报告发给我，我继续排查。" }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg, 'Logitech G304 修复结果', 'OK', 'Information') | Out-Null
}
