#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#install hyper-V feature
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All


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

#region Create External Switch
If (((Get-VMSwitch -SwitchType External).Name) -eq $null) {New-VMSwitch -Name 'External' -NetAdapterName $FastestPhysicalAdapter -AllowManagementOS $true -Notes 'External Switch'}
$VmSwitchExternal = (Get-VMSwitch -SwitchType External).Name
#endregion

#Private Switches
#$VmSwitchPrivate = (Get-VMSwitch -SwitchType Private).Name

#region loop through hashtable and create networks
Foreach($Key in $HyperVConfig.InternalNetworks.Keys){
    $NetworkName = $HyperVConfig.InternalNetworks[$Key]
    If($NetworkName -notin (Get-VMSwitch -SwitchType Private).Name){
        New-VMSwitch -Name $NetworkName -SwitchType Private -Notes ("{0} VLAN: {1} for [{2}]" -f $Key,$NetworkName,$vYosConfig.NetPrefix)
    }
    Else{
        Write-Host ("{0} Network already exists [{1}]. Skipping creation." -f $NetworkName,$Key) -ForegroundColor Yellow
    }
}
#endregion