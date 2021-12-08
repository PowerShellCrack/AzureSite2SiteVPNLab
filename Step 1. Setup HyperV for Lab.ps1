#Requires -RunAsAdministrator

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\configs.ps1") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoAzureCheck -NoVyosISOCheck
}
#endregion

#start transcript
$LogfileName = "$LabPrefix-HyperVSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}


#install hyper-V feature
Write-Host ("Enabling Hyper-V role...") -ForegroundColor White -NoNewline
If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -ne 'Enabled'){
    $HyperVResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
    If($HyperVResult.RestartNeeded -eq $true){
        Write-Host ("Hyper-V does require a reboot...") -ForegroundColor Yellow
    }
}
Else{
    Write-Host ("Hyper-V is already installed.") -ForegroundColor Green
}

#region Configure Hyper-V settings
Write-Host ("Setting up Hyper-V...") -ForegroundColor White -NoNewline
If( ($HyperVConfig.ChangeLocation) -and ((Get-VMHost).VirtualMachinePath -ne $HyperVConfig.VirtualMachineLocation) -or ((Get-VMHost).VirtualHardDiskPath -ne $HyperVConfig.VirtualHardDiskLocation) ){
    New-Item $HyperVConfig.VirtualMachineLocation -ItemType Directory -ErrorAction SilentlyContinue
    New-Item $HyperVConfig.VirtualHardDiskLocation -ItemType Directory -ErrorAction SilentlyContinue
    Set-VMHost -VirtualMachinePath $HyperVConfig.VirtualMachineLocation -VirtualHardDiskPath $HyperVConfig.VirtualHardDiskLocation -EnableEnhancedSessionMode:$HyperVConfig.EnableSessionMode
}
Else{
    Set-VMHost -EnableEnhancedSessionMode:$HyperVConfig.EnableSessionMode
}
Write-Host "Done" -ForegroundColor Green
#endregion

#region Create External Switch
Write-Host ("Configuring Hyper-V External switch...") -ForegroundColor White -NoNewline
#Grab physical network that is connected to the internet
$InternetConnectedAdapter = Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch "Xbox"} | Sort-Object $_.LinkSpeed | Select-Object -First 1
If($null -eq $InternetConnectedAdapter){ Write-Host ("There is no known physical adapter connect to the internet. Unable to continue! ") -ForegroundColor Black -BackgroundColor Red;Break}

#check if there are any external switches; if not create one
$HyperVSwitches = Get-VMSwitch
If ($null -eq ($HyperVSwitches | Where SwitchType -eq 'External') )
{
    New-VMSwitch -Name 'External' -NetAdapterName $InternetConnectedAdapter.Name -AllowManagementOS $true -Notes 'External Switch' | Out-Null
}
ElseIf( ($InternetConnectedAdapter.InterfaceGuid -replace '^{|}$','') -notin ($HyperVSwitches | Where SwitchType -eq 'External').NetAdapterInterfaceGuid.Guid){
    #Check If external is connect to a internet connected adapter
    Try{
        Set-VMSwitch -VMSwitch ($HyperVSwitches | Where SwitchType -eq 'External') -NetAdapterName $InternetConnectedAdapter.Name -AllowManagementOS $true -ErrorAction Stop | Out-Null
        Write-Host ("Changed to [{0}]" -f $InternetConnectedAdapter.Name) -ForegroundColor Yellow
    }
    Catch{
        Write-Host ("{0}" -f $_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host "Done" -ForegroundColor Green
}

#endregion

$i = 1
#TEST $Subnet = $HyperVConfig.VirtualSwitchNetworks.GetEnumerator() | Sort Name |Select -first 1
Foreach($Subnet in $HyperVConfig.VirtualSwitchNetworks.GetEnumerator() | Sort Name)
{
    $NetworkName = $Subnet.Name
    Write-Host ("Configuring Hyper-V internal switch [{0}]..." -f $NetworkName) -ForegroundColor White -NoNewline
    $Description = $HyperVConfig.VirtualSwitchNetworks[$Subnet.Name]
    #$Description = ("{2} for {1}: {0}" -f $Subnet.Name,$VyOSConfig.LocalSubnetPrefix[$Subnet.Name],$vYosConfig.NetPrefix)
    If( $HyperVSwitches | Where Name -eq $NetworkName ){
        Write-Host ("Network already exists. Skipping creation.") -ForegroundColor Green
    }
    Else{
        New-VMSwitch -Name $NetworkName -SwitchType Private -Notes $Description | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    $i++
}

Write-Host ("Done configuring Hyper-V") -ForegroundColor Green
Write-Host "--------------------------------------------------" -ForegroundColor Green
Stop-Transcript
