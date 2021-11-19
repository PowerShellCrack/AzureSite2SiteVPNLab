#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#install hyper-V feature
If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -ne 'Enabled'){
    $HyperVResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
    If($HyperVResult.RestartNeeded -eq $true){
        Write-Host ("Hyper-V does require a reboot...") -ForegroundColor Yellow
    }
}
Else{
    Write-Host ("Hyper-V is already installed.") -ForegroundColor Green
}


#Grab physical network
$FastestPhysicalAdapter = (Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch "Xbox"} | Sort-Object $_.LinkSpeed | Select-Object -First 1).Name

#region Configure Hyper-V settings
If( ($HyperVConfig.ChangeLocation) -and ((Get-VMHost).VirtualMachinePath -ne $HyperVConfig.VirtualMachineLocation) -or ((Get-VMHost).VirtualHardDiskPath -ne $HyperVConfig.VirtualHardDiskLocation) ){
    New-Item $HyperVConfig.VirtualMachineLocation -ItemType Directory -ErrorAction SilentlyContinue
    New-Item $HyperVConfig.VirtualHardDiskLocation -ItemType Directory -ErrorAction SilentlyContinue
    Set-VMHost -VirtualMachinePath $HyperVConfig.VirtualMachineLocation -VirtualHardDiskPath $HyperVConfig.VirtualHardDiskLocation -EnableEnhancedSessionMode:$HyperVConfig.EnableSessionMode
}
Else{
    Set-VMHost -EnableEnhancedSessionMode:$HyperVConfig.EnableSessionMode
}
#endregion

#Private Switches
$HyperVSwitches = Get-VMSwitch

#region Create External Switch
If ($null -eq ($HyperVSwitches | Where SwitchType -eq 'External') ) {
    New-VMSwitch -Name 'External' -NetAdapterName $FastestPhysicalAdapter -AllowManagementOS $true -Notes 'External Switch'
}
$VmSwitchExternal = (Get-VMSwitch -SwitchType External).Name
#endregion

$i = 1
#TEST $Subnet = $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name |Select -first 1

Foreach($Subnet in $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name){
    $NetworkName = ($vYosConfig.NetPrefix +' ' + $i + ' - ' + $Subnet.Name)
    $Description = ("{2} for {1}: {0}" -f $Subnet.Name,$VyOSConfig.LocalSubnetPrefix[$Subnet.Name],$vYosConfig.NetPrefix)
    If($NetworkName -notin ($HyperVSwitches | Where SwitchType -eq 'Private') ){
        New-VMSwitch -Name $NetworkName -SwitchType Private -Notes $Description
    }
    Else{
        Write-Host ("{0} Network already exists. Skipping creation." -f $NetworkName) -ForegroundColor Yellow
    }
    $i++
}