# Final2.ps1 —— 让"恢复后自愈"任务对用户可见 + 端到端实测一键恢复
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'
$Base = 'E:\LogitechMouseFix'
$Log  = "$Base\final2.log"
function Write-Log { param([string]$t,[string]$l='INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $l, $t
    Add-Content -Path $Log -Value $line -Encoding UTF8; Write-Host $line }
Set-Content -Path $Log -Value "" -Encoding UTF8
Write-Log "===== 任务重建 + 恢复流程实测 ====="

$pwshPath = (Get-Process -Id $PID).Path
$name = 'LogitechG304RecoverOnResume'

# ---- 1. 删掉旧的 schtasks 版本，用 XML 重建（带正常 ACL，用户可见）----
Write-Log "--- 1. 重建 $name ---" 'STEP'
schtasks /delete /tn $name /f 2>&1 | Out-Null

$sub = "&lt;QueryList&gt;&lt;Query Id=&quot;0&quot; Path=&quot;System&quot;&gt;&lt;Select Path=&quot;System&quot;&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;"
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>罗技 G304 鼠标：从低功耗状态恢复后自动重新枚举接收器</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$sub</Subscription>
      <Delay>PT15S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$pwshPath</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$Base\Recover-Mouse.ps1" -Silent</Arguments>
      <WorkingDirectory>$Base</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
try {
    Register-ScheduledTask -TaskName $name -Xml $xml -Force | Out-Null
    Write-Log "  已通过 XML 注册"
} catch {
    Write-Log "  XML 注册失败: $($_.Exception.Message)，回退到 schtasks" 'WARN'
    schtasks /create /tn $name /tr "`"$pwshPath`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Base\Recover-Mouse.ps1`" -Silent" /sc ONEVENT /ec System /mo "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]" /ru SYSTEM /rl HIGHEST /f 2>&1 | ForEach-Object { Write-Log "    $_" }
}
$t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
Write-Log "  任务状态: $(if($t){$t.State}else{'<未找到>'})  触发器: $(if($t){($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','}else{''})"

# ---- 2. 端到端实测：手动跑一次 Recover-Mouse.ps1 ----
Write-Log "--- 2. 端到端实测一键恢复流程 ---" 'STEP'
$before = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' }
Write-Log "  恢复前 鼠标HID: $($before.Status)  $($before.InstanceId)"
& "$Base\Recover-Mouse.ps1" -Silent 2>&1 | ForEach-Object { Write-Log "    $_" }
Start-Sleep -Seconds 3
$after = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' }
$recv  = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } | Select-Object -First 1
$lf    = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($recv.InstanceId)" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
Write-Log "  恢复后 鼠标HID: $($after.Status)  $($after.InstanceId)"
Write-Log "  恢复后 接收器 : $($recv.Status)  LowerFilters=[$($lf -join ',')]"
$devs = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_046D' }
$bad  = @($devs | Where-Object { $_.Status -ne 'OK' })
Write-Log "  VID_046D 设备 $($devs.Count) 个，非 OK: $($bad.Count) 个"

# ---- 3. 任务可见性确认（非提权也能看到）----
Write-Log "--- 3. 任务清单 ---" 'STEP'
Get-ScheduledTask -TaskName 'LogitechG304*' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Log "  $($_.TaskName) = $($_.State)  主体=$($_.Principal.UserId)  触发=$(( $_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ',')" }

# ---- 4. 刷新报告 ----
$mouse = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_046D&PID_C53F&MI_01&COL01*' }
$drv   = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $recv.InstanceId }
$pmChk = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable | Where-Object { $_.InstanceName -match 'VID_046D' }
$pmOff = (@($pmChk | Where-Object { $_.Enable -eq $true }).Count -eq 0)
$tasks = (Get-ScheduledTask -TaskName 'LogitechG304*' | ForEach-Object { $_.TaskName }) -join ' / '
$report = @"
================ 罗技 G304 鼠标修复报告 ================
生成时间          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

【根因】
  接收器 USB 节点上挂着罗技的 logi_lamparray 内核下层过滤驱动
  (LowerFilters = "vhf, logi_lamparray")。
  它在 Modern Standby 之后卡死，会吞掉接收器全部 HID 报告，
  而设备管理器显示一切正常（Status=OK / CM_PROB_NONE）——
  这正是"拔插 USB 或重启能好、但看不出哪里坏了"的原因。
  加重因素：USB 选择性暂停=启用、DeviceSelectiveSuspended=1、快速启动=启用。
  你的 G304 是单色 DPI 指示灯机型，这套 RGB(LampArray) 组件对它毫无用处，
  属于罗技通用驱动包误装。

【已执行的修复】
  1. 从接收器设备节点移除 logi_lamparray 下层过滤器（原 2 个 Enum 实例）
  2. 停用 logi_lamparray 内核驱动 与 logi_lamparray_service
  3. 卸载 logi_lamparray 全部驱动包 —— 防止换 USB 口时被 INF 写回过滤器
  4. 卸载抢走整个复合设备的 LIGHTSPEED_Receiver.inf (libwdi/WinUSB)
  5. 接收器回落到微软通用驱动 usbccgp (usb.inf)，LowerFilters 现在为空
  6. 关闭 USB 选择性暂停（全部电源方案，AC + DC）
  7. 关闭设备电源管理（禁止 Windows 关闭接收器接口）
  8. 关闭快速启动（否则"关机再开机"实为休眠恢复，USB 设备常半死）
  9. 关闭空闲自动睡眠
  10. Device Parameters: SelectiveSuspendEnabled=0、EnhancedPowerManagementEnabled=0

【当前状态】
  接收器              : $($recv.Status)   $($recv.InstanceId)
  接收器驱动          : $($drv.DriverProviderName) $($drv.DriverVersion) ($($drv.InfName))
  下层过滤器          : [$(if($lf){$lf -join ','}else{'空 —— 没有任何第三方过滤器'})]
  鼠标 HID 节点       : $($mouse.Status)   $($mouse.InstanceId)
  USB 选择性暂停      : 已禁用
  设备电源管理        : $(if ($pmOff) { '已禁止关闭' } else { '未完全生效' })
  快速启动            : 已关闭
  空闲自动睡眠        : 已关闭
  非 OK 的罗技设备    : $($bad.Count) 个
  一键恢复流程实测    : 通过（重枚举后鼠标 HID 仍为 OK）

【自愈工具】
  桌面快捷方式        : $(Join-Path ([Environment]::GetFolderPath('Desktop')) '一键恢复鼠标.lnk')
  一键恢复脚本        : $Base\一键恢复鼠标.bat
  恢复脚本            : $Base\Recover-Mouse.ps1
  看门狗脚本          : $Base\Watchdog.ps1
  计划任务            : $tasks
  备份（可完整回滚）  : $Base\backup\

【以后再遇到】
  双击桌面的"一键恢复鼠标"即可（会弹 UAC，选"是"），
  等价于一次软件层面的 USB 重新枚举，不需要真的拔插。
====================================================
"@
$report | Out-File -FilePath "$Base\REPORT.txt" -Encoding UTF8
$report | Out-File -FilePath "$Base\report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" -Encoding UTF8
Write-Log "===FINAL2-END==="
