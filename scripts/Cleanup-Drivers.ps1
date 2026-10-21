# Cleanup-Drivers.ps1 —— 卸载 logi_lamparray 驱动包（语言无关解析 + 完整备份）
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'
$Base   = 'E:\LogitechMouseFix'
$Backup = "$Base\backup"
$Log    = "$Base\cleanup.log"
$stamp  = (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
function Write-Log { param([string]$t,[string]$l='INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $l, $t
    Add-Content -Path $Log -Value $line -Encoding UTF8; Write-Host $line }
Set-Content -Path $Log -Value "" -Encoding UTF8
Write-Log "===== 驱动包清理开始 ====="

$drvStore = "$env:SystemRoot\System32\DriverStore\FileRepository"

# ---- 语言无关地枚举 logi_lamparray 驱动包 ----
function Get-LampArrayPackages {
    $raw = pnputil /enum-drivers 2>&1 | Out-String
    $lines = $raw -split "`r?`n"
    $blocks = @(); $cur = @()
    foreach ($l in $lines) {
        if ($l.Trim() -eq '') { if ($cur.Count) { $blocks += ($cur -join "`n"); $cur = @() } }
        else { $cur += $l }
    }
    if ($cur.Count) { $blocks += ($cur -join "`n") }
    $res = @()
    foreach ($b in $blocks) {
        if ($b -match '(?i)logi_lamparray') {
            # "发布名称: oem103.inf" / "Published Name: oem103.inf" —— 直接抓 oemNNN.inf
            $pub  = ([regex]::Match($b, '(?i)oem\d+\.inf')).Value
            $orig = ([regex]::Match($b, '(?i)logi_lamparray_[a-z]+\.inf')).Value
            if ($pub) { $res += [pscustomobject]@{ Published = $pub; Original = $orig } }
        }
    }
    $res
}

$pkgs = @(Get-LampArrayPackages)
Write-Log "枚举到 $($pkgs.Count) 个 logi_lamparray 驱动包: $(($pkgs | ForEach-Object { "$($_.Published)[$($_.Original)]" }) -join ', ')"

# ---- 先完整备份 DriverStore 目录 + inf ----
if ($pkgs.Count) {
    $dirs = Get-ChildItem $drvStore -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)logi_lamparray' }
    foreach ($d in $dirs) {
        $dest = Join-Path $Backup "drvstore-$($d.Name)"
        Copy-Item $d.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "  已备份驱动目录: $($d.Name)"
    }
    $pkgs | ForEach-Object { "$($_.Published)  <=  $($_.Original)" } | Out-File -FilePath "$Backup\driver-map-$stamp.txt" -Encoding UTF8
}

# ---- 卸载 ----
foreach ($p in $pkgs) {
    $o = pnputil /delete-driver $p.Published /uninstall /force 2>&1 | Out-String
    $o = (($o -split "`r?`n") | Where-Object { $_ -match '\S' }) -join ' | '
    Write-Log "  删除 $($p.Published) ($($p.Original)) -> $o"
}
Start-Sleep -Seconds 3
pnputil /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 5

# ---- 复查 ----
$left = @(Get-LampArrayPackages)
if ($left.Count) { Write-Log "  !! 仍残留: $(($left | ForEach-Object { $_.Published }) -join ', ')" 'ERR' }
else { Write-Log "  logi_lamparray 驱动包已全部卸载" }

$recv = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
$mouse = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } | Select-Object -First 1
$drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $recv.InstanceId }
$lf  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
Write-Log "  接收器: $($recv.Status)  LowerFilters=[$($lf -join ',')]"
Write-Log "  接收器驱动: $($drv.DriverProviderName) $($drv.DriverVersion) ($($drv.InfName))"
Write-Log "  鼠标HID: $($mouse.Status)  $($mouse.InstanceId)"

$devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_046D' }
$bad  = @($devs | Where-Object { $_.Status -ne 'OK' })
Write-Log "  VID_046D 设备 $($devs.Count) 个，非 OK: $($bad.Count) 个"
foreach ($b in $bad) { Write-Log "    !! $($b.Status)  $($b.InstanceId)" 'WARN' }

# ---- 刷新报告 ----
$usbss = powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>&1 | Out-String
$hib   = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
$pmChk = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match 'VID_046D' }
$pmOff = (@($pmChk | Where-Object { $_.Enable -eq $true }).Count -eq 0)
$leftTxt = if ($left.Count) { "仍残留 $($left.Count) 个" } else { '已全部卸载' }

$report = @"
================ 罗技 G304 鼠标修复报告 ================
时间              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

【根因】
  接收器 USB 节点上挂着罗技的 logi_lamparray 内核下层过滤驱动。
  它在 Modern Standby 之后卡死，会吞掉接收器全部 HID 报告，
  而设备管理器显示一切正常（Status=OK / CM_PROB_NONE）——
  这正是"拔插 USB 或重启能好、但看不出哪里坏了"的原因。
  加重因素：USB 选择性暂停=启用、DeviceSelectiveSuspended=1、快速启动=启用。
  G304 是单色 DPI 指示灯机型，这套 RGB 组件对它毫无用处，属误装。

【已执行的修复】
  1. 从接收器设备节点移除 logi_lamparray 下层过滤器（2 个 Enum 实例）
  2. 停用 logi_lamparray 内核驱动 (Start=4) 与 logi_lamparray_service
  3. 备份并卸载 logi_lamparray 驱动包（$leftTxt）
     —— 必须清掉，否则换 USB 口时 INF 会把过滤器写回来，
        而内核驱动已被停用，设备会直接"无法启动"(Code 10/39)
  4. 关闭 USB 选择性暂停（全部电源方案，AC + DC）
  5. 关闭设备电源管理（禁止 Windows 关闭接收器接口）
  6. 关闭快速启动
  7. 关闭空闲自动睡眠
  8. Device Parameters: SelectiveSuspendEnabled=0, EnhancedPowerManagementEnabled=0

【当前状态】
  接收器              : $($recv.Status)   $($recv.InstanceId)
  鼠标 HID 节点       : $($mouse.Status)   $($mouse.InstanceId)
  接收器当前驱动      : $($drv.DriverProviderName) $($drv.DriverVersion) ($($drv.InfName))
  下层过滤器           : $($lf -join ', ')
  USB 选择性暂停       : $(if ($usbss -match '0x00000000') { '已禁用' } else { '未确认' })
  设备电源管理         : $(if ($pmOff) { '已禁止关闭' } else { '未完全生效' })
  快速启动             : $(if ($hib -eq 0) { '已关闭' } else { '仍开启' })
  非 OK 的罗技设备     : $($bad.Count) 个

【自愈工具】
  一键恢复（桌面）     : $(Join-Path ([Environment]::GetFolderPath('Desktop')) '一键恢复鼠标.lnk')
  一键恢复（脚本）     : $Base\一键恢复鼠标.bat
  恢复脚本             : $Base\Recover-Mouse.ps1
  看门狗脚本           : $Base\Watchdog.ps1
  计划任务             : LogitechG304AutoRecover / LogitechG304RecoverOnResume / LogitechG304Watchdog
  备份（可完整回滚）   : $Base\backup\
====================================================
"@
$report | Out-File -FilePath "$Base\REPORT.txt" -Encoding UTF8
$report | Out-File -FilePath "$Base\report-$stamp.txt" -Encoding UTF8
Write-Log $report
Write-Log "===CLEANUP-END==="
