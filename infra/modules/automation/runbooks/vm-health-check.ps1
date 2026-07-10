param(
    [Parameter(Mandatory = $true)]
    [string]$vmname,

    [Parameter(Mandatory = $true)]
    [string]$resourcegroupname
)

Write-Output "Starting health check for VM: $vmname in RG: $resourcegroupname"

Connect-AzAccount -Identity | Out-Null

$vm = Get-AzVM -ResourceGroupName $resourcegroupname -Name $vmname
$vmId = $vm.Id

# --- Outside-the-box view: CPU metric via Azure Monitor ---
$endTime = Get-Date
$startTime = $endTime.AddMinutes(-30)

$cpu = Get-AzMetric -ResourceId $vmId -MetricName "Percentage CPU" `
    -TimeGrain 00:05:00 -StartTime $startTime -EndTime $endTime `
    -AggregationType Average -WarningAction SilentlyContinue

$avgCpu = ($cpu.Data | Where-Object { $_.Average -ne $null } |
    Measure-Object -Property Average -Average).Average
Write-Output "Average CPU (last 30 min): $([math]::Round($avgCpu, 2))%"

# --- Inside-the-box view: disk + nginx via run command ---
$script = @'
echo "=== Disk usage ==="
df -h / | tail -n 1
echo "=== nginx status ==="
systemctl is-active nginx
'@

$result = Invoke-AzVMRunCommand -ResourceGroupName $resourcegroupname `
    -VMName $vmname -CommandId "RunShellScript" -ScriptString $script

Write-Output "In-guest check result:"
Write-Output $result.Value[0].Message

Write-Output "Health check completed."