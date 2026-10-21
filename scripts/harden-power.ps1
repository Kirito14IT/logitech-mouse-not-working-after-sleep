$ErrorActionPreference = 'Continue'
$log = 'E:\LogitechMouseFix\power-hardening.log'
function W($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }
Set-Content -Path $log -Value "" -Encoding UTF8

# root\wmi 的 MSPower_DeviceEnable 实例名 = 设备实例 ID + "_0"（保留 USB\ 前缀）
$all = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -EA SilentlyContinue
$recv = Get-PnpDevice -PresentOnly -EA SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F\*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } |
        Select-Object -First 1
$hub = (Get-PnpDeviceProperty -InstanceId $recv.InstanceId -KeyName 'DEVPKEY_Device_Parent' -EA SilentlyContinue).Data
W "接收器: $($recv.InstanceId)"
W "集线器: $hub"

$want = @($hub, $recv.InstanceId)
Get-PnpDevice -PresentOnly -EA SilentlyContinue |
    Where-Object { $_.InstanceId -like 'USB\VID_046D&PID_C53F&MI_*' } |
    ForEach-Object { $want += $_.InstanceId }
$wantNames = $want | Sort-Object -Unique | ForEach-Object { "$_`_0" }

foreach ($name in $wantNames) {
    $obj = $all | Where-Object { $_.InstanceName -eq $name } | Select-Object -First 1
    if (-not $obj) { W "  (无此条目，跳过) $name"; continue }
    try {
        $obj.Enable = $false
        Set-CimInstance -InputObject $obj -ErrorAction Stop | Out-Null
        W "  Enable=False -> $name"
    } catch { W "  失败 $name :: $($_.Exception.Message)" }
}

# 接收器所在集线器若没有 root\wmi 条目，则直接用 WMI 创建一条
$hubName = "$hub`_0"
if (-not ($all | Where-Object { $_.InstanceName -eq $hubName })) {
    W "  集线器无 root\wmi 条目，尝试创建"
    try {
        $new = New-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -Property @{ InstanceName = $hubName; Enable = $false } -ErrorAction Stop
        W "  已创建条目 Enable=False -> $hubName"
    } catch { W "  创建失败: $($_.Exception.Message)" }
}

W "--- 复查 ---"
Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -EA SilentlyContinue |
    Where-Object { $_.InstanceName -match 'VID_046D|ROOT_HUB30' } |
    ForEach-Object { W ("  {0,-70} Enable={1}" -f $_.InstanceName, $_.Enable) }
W "=== HARDEN3-END ==="
