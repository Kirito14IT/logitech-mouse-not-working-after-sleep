# Restore-HID.ps1 —— 紧急恢复：让接收器回到微软 usbccgp，HID 接口复活
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'
$Base = 'E:\LogitechMouseFix'
$Log  = "$Base\restore.log"
function Write-Log { param([string]$t,[string]$l='INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $l, $t
    Add-Content -Path $Log -Value $line -Encoding UTF8; Write-Host $line }
Set-Content -Path $Log -Value "" -Encoding UTF8
Write-Log "===== 紧急恢复开始 ====="

# ---- 1. 找到并卸载抢走整个复合设备的 LIGHTSPEED_Receiver.inf ----
Write-Log "--- 1. 卸载 LIGHTSPEED_Receiver.inf（WinUSB，会杀掉 HID 接口）---" 'STEP'
$raw = pnputil /enum-drivers 2>&1 | Out-String
$lines = $raw -split "`r?`n"; $blocks = @(); $cur = @()
foreach ($l in $lines) { if ($l.Trim() -eq '') { if ($cur.Count) { $blocks += ($cur -join "`n"); $cur = @() } } else { $cur += $l } }
if ($cur.Count) { $blocks += ($cur -join "`n") }
$kill = @()
foreach ($b in $blocks) {
    if ($b -match '(?i)lightspeed_receiver\.inf') {
        $pub = ([regex]::Match($b, '(?i)oem\d+\.inf')).Value
        if ($pub) { $kill += $pub }
    }
}
$kill = @($kill | Sort-Object -Unique)
Write-Log "  待卸载: $($kill -join ', ')"
foreach ($k in $kill) {
    $o = pnputil /delete-driver $k /uninstall /force 2>&1 | Out-String
    $o = (($o -split "`r?`n") | Where-Object { $_ -match '\S' }) -join ' | '
    Write-Log "  删除 $k -> $o"
}

# ---- 2. 摘掉旧设备实例，强制重新安装 ----
Write-Log "--- 2. 移除接收器设备实例并重新枚举 ---" 'STEP'
$recv = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
if ($recv) {
    Write-Log "  移除: $($recv.InstanceId)"
    pnputil /remove-device "$($recv.InstanceId)" 2>&1 | ForEach-Object { Write-Log "    $_" }
} else { Write-Log "  没有找到当前接收器实例" 'WARN' }
Start-Sleep -Seconds 2
pnputil /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 6

# ---- 3. 复查 ----
Write-Log "--- 3. 复查 ---" 'STEP'
for ($i = 0; $i -lt 4; $i++) {
    $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_046D' }
    $mouse = $devs | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } | Select-Object -First 1
    Write-Log "  第 $($i+1) 次: VID_046D 设备 $($devs.Count) 个, 鼠标HID = $(if($mouse){$mouse.Status}else{'<缺失>'})"
    if ($mouse -and $mouse.Status -eq 'OK') { break }
    Start-Sleep -Seconds 4
}

$devs  = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_046D' }
$recv  = $devs | Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
$mouse = $devs | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } | Select-Object -First 1
$drv   = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $recv.InstanceId }
$lf    = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
Write-Log "  接收器: $($recv.Status)  驱动=$($drv.DriverProviderName) $($drv.DriverVersion) ($($drv.InfName))  LowerFilters=[$($lf -join ',')]"
Write-Log "  鼠标HID: $($mouse.Status)  $($mouse.InstanceId)"
$devs | ForEach-Object { Write-Log "    - $($_.Status)  $($_.Class)  $($_.InstanceId)" }

# ---- 4. 兜底：如果还没回来，用备份里的原厂驱动装回去 ----
if (-not $mouse -or $mouse.Status -ne 'OK') {
    Write-Log "--- 4. 兜底：从备份恢复原厂 logi_lamparray 驱动 ---" 'WARN'
    $bak = Get-ChildItem "$Base\backup" -Directory -Filter 'drvstore-logi_lamparray_usb*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bak) {
        $inf = Get-ChildItem $bak.FullName -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
        Write-Log "  安装 $($inf.FullName)"
        pnputil /add-driver "$($inf.FullName)" /install 2>&1 | ForEach-Object { Write-Log "    $_" }
        Start-Sleep -Seconds 3
        pnputil /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        # 装回去后立刻摘掉过滤器 + 停用驱动
        $r2 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
        if ($r2) {
            try { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$($r2.InstanceId)" -Name LowerFilters -Value @('vhf') -Type MultiString -ErrorAction Stop
                  Write-Log "  已重新摘除 logi_lamparray 过滤器" } catch { Write-Log "  摘过滤器失败: $($_.Exception.Message)" 'ERR' }
        }
        $m2 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } | Select-Object -First 1
        Write-Log "  兜底后 鼠标HID: $(if($m2){$m2.Status}else{'<缺失>'})"
    } else { Write-Log "  !! 备份里没找到驱动目录" 'ERR' }
}

$final = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' } | Select-Object -First 1
Write-Log "最终 鼠标HID: $(if($final){$final.Status}else{'<缺失>'})"
Write-Log "===RESTORE-END==="
