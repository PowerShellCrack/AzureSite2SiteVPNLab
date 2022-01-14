<#
    .SYNOPSIS
        Set vyos router

    .DESCRIPTION
        Set VyOS router in Hyper-V

    .NOTES
        1. Creates New VHD file
        2. Create new General 1 VM and attached the VHD
        3. Mounts vyOS IOS to VM
        4. Configures Hyper-V networks for VLANID
        5. Boots VM and requires manual input for install
        6. Unmounts ISO, Reboots VM and requires lan setup
        7. Setup external network and SSH
        8. Adds LAN networks to router and sets up LAN configuration

#>
#Requires -RunAsAdministrator

Param(
    [switch]$SkipInitialSetup
)

#https://systemspecialist.net/2014/11/26/create-mini-router-with-hyper-v-for-vm-labs/
#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\configs.ps1") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoAzureCheck
}
#endregion


#start transcript
$LogfileName = "$LabPrefix-VYOSRouterSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

If(-Not(Test-Path $VyOSConfig.ISOLocation)){Write-Host ("Unable to find VyOS ISO: [{0}]. Please update config and rerun setup" -f $VyOSConfig.ISOLocation) -ForegroundColor Red;Break}

#check drive space availability
$DriveLetter = (Get-Item $HyperVConfig.VirtualHardDiskLocation).PSDrive.Name
$disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($DriveLetter):'" | Select-Object *
If($disk.FreeSpace/1GB -le 2){
    Write-Host ("Unable to create VHD: [{0}]. Not enough drive space [{1}GB]" -f $VHDxFilePath,[int]($disk.FreeSpace/1GB).ToString()) -ForegroundColor Black -BackgroundColor Red
    Break
}

#region Create VyOS VM
$VM = Get-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
If(!$SkipInitialSetup -or !$VM){
    If($null -eq $VM)
    {
        Write-Host ("Creating a VM [{0}]..." -f $VyOSConfig.VMName) -ForegroundColor White -NoNewline
        $VHDxFilePath = ($HyperVConfig.VirtualHardDiskLocation + '\'+ $VyOSConfig.VMName +'.vhdx')
        Try{
            If(Get-VHD -Path $VHDxFilePath -ErrorAction SilentlyContinue ){
                Remove-Item $VHDxFilePath -Confirm -Force -ErrorAction Stop
            }
            New-VHD -Path $VHDxFilePath -SizeBytes 2GB -Dynamic -ErrorAction stop | Out-Null
        }
        Catch{
            Write-Host ("Unable to manage VHD: [{0}]. {1}" -f $VHDxFilePath ,$_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
            Break
        }

        Try{
            $VmSwitchExternal = Get-VMSwitch -SwitchType External | Select -ExpandProperty Name -First 1

            New-VM -Name $VyOSConfig.VMName -VHDPath $VHDxFilePath  `
                -SwitchName $VmSwitchExternal -MemoryStartupBytes 256MB -Generation 1 -ErrorAction Stop | Out-Null
            Set-VM -Name $VyOSConfig.VMName -AutomaticCheckpointsEnabled $false -Notes 'StartupOrder: 1' `
                -AutomaticStartAction Start -AutomaticStopAction ShutDown -CheckpointType Disabled `
                -DynamicMemory -ErrorAction Stop | Out-Null
            #Remove-VMCheckpoint -VMName $VyOSConfig.VMName -ErrorAction SilentlyContinue
            #Connect ISO
            Set-VMDvdDrive -VMName $VyOSConfig.VMName -Path $VyOSConfig.ISOLocation -ErrorAction Stop

            #$VmSwitchExternal = Get-VMSwitch -SwitchType External | Select -ExpandProperty Name -First 1
            #Get-VMNetworkAdapter -VMName $VyOSConfig.VMName | Connect-VMNetworkAdapter -SwitchName $VmSwitchExternal -ErrorAction Stop
        }
        Catch{
            Write-Host ("Unable to build the VM: [{0}]. {1}" -f $VyOSConfig.VMName,$_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
            Break
        }
        Write-Host "Done" -ForegroundColor Green
    }
    Else{
        Write-Host ("VM Already created named [{0}]..." -f $VM.Name) -ForegroundColor Green -NoNewline
        #always stop VM before attaching iso
        If($VM.State -eq 'Running'){
            Write-Host ("in [{0}] State...stopping" -f $VM.State) -ForegroundColor Red
            Stop-VM $VyOSConfig.VMName -ErrorAction SilentlyContinue -Force
        }
        Else{
            Write-Host ("in [{0}] State" -f $VM.State) -ForegroundColor Green
        }
        #always remount ISO if found mounted already
        If( ($MountedIsoPath = Get-VMDvdDrive -VMName $VyOSConfig.VMName).Path -ne $VyOSConfig.ISOLocation)
        {
            Set-VMDvdDrive -VMName $VyOSConfig.VMName -Path $VyOSConfig.ISOLocation -ErrorAction Stop
        }
    }
    #endregion


    #Trunk HyperV Network for internal networks; determine if VLAN needs to be used.
    #https://docs.microsoft.com/en-us/powershell/module/hyper-v/set-vmnetworkadaptervlan?view=windowsserver2019-ps
    If($HyperVConfig.ConfigureForVLAN)
    {
        Get-VMNetworkAdapter -VMName $VyOSConfig.VMName | Where-Object {$_.SwitchName -ne $VmSwitchExternal} |
            Set-VMNetworkAdapterVlan -Trunk -NativeVlanId $HyperVConfig.VLANID -AllowedVlanIdList $VyOSConfig.AllowedvLanIdRange
    }
    Else{
        Get-VMNetworkAdapter -VMName $VyOSConfig.VMName | Where-Object {$_.SwitchName -ne $VmSwitchExternal} |
            Set-VMNetworkAdapterVlan -Untagged
    }

    #start VM
    Write-Host "Starting router for initial settings, please wait..." -ForegroundColor Yellow
    If($VM.State -ne "Running"){Start-VM -Name $VyOSConfig.VMName -ErrorAction Stop
        Start-Sleep 45
    }

    #region INSTALL VyOS
    Write-Host "↓↓↓ PLEASE FOLLOW THE STEPS BELOW ↓↓↓"  -ForegroundColor Black -BackgroundColor Cyan
    $VyOSSteps = @"
`n
Installing an image onto the virtual router
Connect to router and answer the questions below:
=================================================
  VyOS login: vyos
  Password: vyos
  VyOS@VyOS:~$ install image
  Would you like to continue? (Yes/No) [Yes]: [Enter]
  Partition (Auto/Parted/Skip) [Auto]: [Enter]
  Install the image on? [sda]: [Enter]
  Continue? (Yes/No) [No]: Yes
  How big of a root partition should I create? (1000MB - 2147MB) [2147]MB: [Enter]
  What would you like to name this image? [1.1.8]: [Enter]
  Which one should I copy to sda? [/config/config.boot]: [Enter]
  Enter password for user 'vyos': [Type in a password]
  Retype password for user 'vyos': [Confirm password]
  Which drive should GRUB modify the boot partition on? [sda]: [Enter]
"@

    do {
        #cls
        Write-Host $VyOSSteps -ForegroundColor Gray
        Write-Host "`nNOTE: To get out of console, hit [CTRL+ALT+LEFT ARROW]" -ForegroundColor Yellow
        $CompleteFirstStep = Read-host "Did you complete the steps above? [Y or N]"
    } until ($CompleteFirstStep -eq 'Y')

    Write-Host "`nPreparing router for next configurations, please wait..." -ForegroundColor Yellow
    Stop-VM $VyOSConfig.VMName -ErrorAction SilentlyContinue
    #always dismount ISO
    Get-VMDvdDrive -VMName $VyOSConfig.VMName | Remove-VMDvdDrive

    Start-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
    Start-Sleep 45
    #endregion

    #region Setup VyOS SSH
    Write-Host "↓↓↓ PLEASE FOLLOW THE STEPS BELOW ↓↓↓"  -ForegroundColor Black -BackgroundColor Cyan
    $VyOSSteps = @"
`n
Enable network and SSH on the virtual router
Connect to router and answer the questions below:
=================================================
  vyos login: vyos
  Password: [Your new password]
  vyos@vyos:~$ configure
  vyos@vyos# set interfaces ethernet eth0 address dhcp
  vyos@vyos# set service ssh port 22
  vyos@vyos# commit
  vyos@vyos# save
  vyos@vyos# exit
  vyos@vyos:~$ show int
"@

    do {
        #cls
        Write-Host $VyOSSteps -ForegroundColor Gray
        Write-Host "`nMake sure there is an IP address for interface eth0" -ForegroundColor Yellow
        Write-Host "TAKE NOTE OF IP" -BackgroundColor Yellow -ForegroundColor Black
        $CompleteSecondStep = Read-host "Did you complete the steps above? [Y or N]"
    } until ($CompleteSecondStep -eq 'Y')
    Write-Host "If steps completed successfully, You will be able to ssh into the router instead of connecting VM console" -ForegroundColor White

    #endregion
}
Else{
    Write-Host "Check IP by running command in router [" -ForegroundColor Red -NoNewline
    Write-Host "show int" -ForegroundColor Yellow -NoNewline
    Write-Host "]" -ForegroundColor Red
}

#region Prompt for external interface for router
$ping = 0
do {
    If(Test-Path "$env:temp\$($LabPrefix)-VyOSextip.txt"){
        $VyOSExistingIP = Get-Content "$env:temp\$($LabPrefix)-VyOSextip.txt"
        $IsRightIP = Read-host "Is your $($VM.Name) eth0 IP Address [$VyOSExistingIP]? [Y or N]"
    }
    If($IsRightIP -eq 'Y'){
        $VyOSExternalIP = $VyOSExistingIP
    }Else{
        $VyOSExternalIP = Read-host "What is your $($VM.Name)'s eth0 IP Address? [eg. 192.168.1.2]"
    }
    #remove old recorded IP and CIDR from address (if found)
    Remove-Item "$env:temp\$($LabPrefix)-VyOSextip.txt" -Force -ErrorAction SilentlyContinue | Out-Null
    If($VyOSExternalIP -match '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(3[0-2]|[1-2][0-9]|[0-9]))$'){
        $VyOSExternalIP = $VyOSExternalIP.replace($Matches[4],'')
    }

    Write-Host "Testing connection to [$VyOSExternalIP]..." -ForegroundColor Yellow -NoNewline
    Start-Sleep 5
    $ping++
    $TestIP = Test-Connection $VyOSExternalIP -Count 1 -Quiet
    If (!($TestIP)){
        Write-Host "Failed! Check IP and run command in router [" -ForegroundColor Red -NoNewline
        Write-Host "show int ethernet eth0 brief" -ForegroundColor white -NoNewline
        Write-Host "]" -ForegroundColor Red
    }
    Else {
        Write-Host ("interface is pingable") -ForegroundColor Green
        $VyOSConfig.Add('ExternalInterfaceIP',$VyOSExternalIP)
        $VyOSExternalIP | Out-File "$env:temp\$($LabPrefix)-VyOSextip.txt" -Force
    }
} until ( ($VyOSExternalIP -as [System.Net.IPAddress] -and $TestIP) -or ($ping -eq 10) )
#endregion

#region Add all internal networks to router
Stop-VM $VyOSConfig.VMName -ErrorAction SilentlyContinue
start-sleep 10

$VM = Get-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
$VyOSNetworks = $HyperVConfig.VirtualSwitchNetworks.GetEnumerator() | Sort Name

#TEST $Network = $VyOSNetworks[0]
ForEach($Network in $VyOSNetworks)
{
    If($Network.Name -in $VM.NetworkAdapters.switchname){
        Write-Host ("Network [{0}] is already attached to [{1}]" -f $Network.Name,$VM.VMName) -ForegroundColor Green
    }
    Else{
        Try{
            Write-Host ("Attaching network [{0}] to [{1}]..." -f $Network.Name,$VM.VMName) -ForegroundColor White -NoNewline
            Add-VMNetworkAdapter -VMName $VM.VMName -SwitchName $Network.Name -ErrorAction Stop
            Write-Host ("Done") -ForegroundColor Green
        }
        Catch{
            Write-Host ("{0}" -f $_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
            Break
        }
    }
}

Start-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
#wait for VM to boot completely
Write-Host "Router is rebooting" -ForegroundColor Yellow -NoNewline
do {
    Write-Host "." -ForegroundColor White -NoNewline
    Start-Sleep 3
} until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)
#endregion
Write-Host "Booted" -ForegroundColor Green


#region Build VyOS Lan Configuration Commands
$VyOSLanCmd = @"
#VyOS Extended Configuration Script
configure

#Host Configuration
set system host-name $(($VyOSConfig.HostName).ToLower())
set system domain-name $domain
set system time-zone $($VyOSConfig.TimeZone)

#External Interface Configuration
set interfaces ethernet eth0 description 'External'

#DNS Configuration
set service dns forwarding cache-size '0'
"@
$i=1
#TEST $SubnetCIDR = ($VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name)[0]
foreach ($SubnetCIDR in $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name){
    $Description = ("LAN Subnet for {0}" -f $VyOSConfig.LocalSubnetPrefix[$SubnetCIDR.Name])
    $IPInfo = Get-NetworkDetails -CidrAddress $SubnetCIDR.Name
    $GatewayInfo = Get-TypicalRouterRange -StartIP $IPInfo.StartingIP -EndIP $IPInfo.EndingIP -Gateway $IPInfo.SubnetMask -Position Last
    $VyOSLanCmd += @"
`n
#Interface $i Configuration
set interfaces ethernet eth$i address $($IPInfo.EndingIP)/$($IPInfo.Prefix)
set interfaces ethernet eth$i description '$($Description)'
set service dns forwarding listen-on 'eth$($i)'
"@

    If($VyOSConfig.EnableDHCP){
        $VyOSLanCmd += @"

# Enable DHCP Configuration for eth$i

set service dhcp-server disabled 'false'
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $($SubnetCIDR.Name) start $($GatewayInfo.StartIP) stop $($GatewayInfo.EndIP)
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $($SubnetCIDR.Name) dns-server $NextHop
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $($SubnetCIDR.Name) dns-server $($GatewayInfo.GatewayIP)
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $($SubnetCIDR.Name) default-router $($GatewayInfo.GatewayIP)
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $($SubnetCIDR.Name) lease '86400'
"@

    }

$i++
}

switch($VyOSConfig.UseDNSOption){
'External' {$VyOSLanCmd += @"
`n
#forward home network dhcp`n
set service dns forwarding dhcp eth0
"@
}

'Internal' {$VyOSLanCmd += @"
`n
#Set internal dns
"@
    foreach ($IP in $VyOSConfig.InternalDNSIP){
        $VyOSLanCmd += @"
`n
set service dns forwarding name-server '$($IP)'
"@
                    }
}
'Internet' {$VyOSLanCmd += @"

#Set internet dns
`n
set service dns forwarding name-server '8.8.8.8'
set service dns forwarding name-server '$($NextHop)'
"@
    }
}

If($VyOSConfig.EnablePXERelay){
    $i=1
    ForEach($Network in $VyOSNetworks){
        $VyOSLanCmd += @"
`n
#Enable DHCP relay (PXE boot) for eth$($i):
set service dhcp-relay interface eth$($i)
"@
    $i=$i+1
    }

If(!$VyOSConfig.EnableDHCP){
    $VyOSLanCmd += @"
`n
#If DHCP disabled, Set the IP address of the other DHCP server:
set service dhcp-relay server '$($VyOSConfig.DhcpRelayIP)'

#Discard DHCP packages already containing relay agent
set service dhcp-relay relay-options relay-agents-packets discard
"@
}
}

If($VyOSConfig.EnableNAT){
    $VyOSLanCmd += @"

#Enable NAT Configuration
set nat source rule 100 outbound-interface eth0
set nat source rule 100 source address '$($VyOSConfig.LocalCIDRPrefix)'
set nat source rule 100 translation address masquerade
"@
}

$VyOSLanCmd += @"

commit
save

"@
#endregion

#Always output script
$ScriptName = $LogfileName.replace('.log','.script')
$VyOSLanCmd -split '\n' | %{$_ | Set-Content "$PSScriptRoot\Logs\$ScriptName"}

If($RouterAutomationMode){
    Write-Host "Attempting to automatically configure router's lan settings..." -ForegroundColor Yellow
    #region Automation Mode
    $VyOSLanScript = New-VyattaScript -Value $VyOSLanCmd -AsObject -SetReboot

    #temporary set auto logon ssh keys
    New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Force -Persistent -Verbose

    $Result = Invoke-VyattaScript -IP $VyOSExternalIP -Path $VyOSLanScript.Path -Verbose

    $Result

    If(!$Result){
        Write-Host "Failed to run automation script for vyos router; please use manual process instead" -ForegroundColor Red
        $RunManualSteps = $true
    }
    Else{
        #wait for VM to boot completely
        Write-Host "Router is rebooting" -ForegroundColor Yellow -NoNewline
        do {
            Write-Host "." -ForegroundColor Yellow -NoNewline
            Start-Sleep 3
        } until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)

        Write-Host "Booted" -ForegroundColor Green
        Write-Host "------------------------------------------" -ForegroundColor Gray
        Write-Host "Log into router and run command [" -ForegroundColor Gray -NoNewline
        Write-Host "show int" -ForegroundColor Yellow -NoNewline
        Write-Host "]" -ForegroundColor Gray
        Write-Host "------------------------------------------" -ForegroundColor Gray
        $LanInterfaces = Read-host "Are all interfaces configured with an ip address? [Y or N]"
        If($LanInterfaces -eq 'Y'){
            Write-Host "====================================" -ForegroundColor Black -BackgroundColor Green
            Write-Host " Done configuring router interfaces " -ForegroundColor Black -BackgroundColor Green
            Write-Host "====================================" -ForegroundColor Black -BackgroundColor Green
            $RunManualSteps = $false
        }
        Else{
            Write-Host "Automation may have failed, try running the commands manually" -ForegroundColor Black -BackgroundColor Red
            $RunManualSteps = $true
        }
    }
    #endregion
}
Else{
    $RunManualSteps = $true
}


If($RunManualSteps){
    #region Copy Paste Mode
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host  $VyOSLanCmd -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName) by running command [" -ForegroundColor White -NoNewline
    Write-Host ("ssh vyos@{0}" -f $VyOSExternalIP) -ForegroundColor Yellow -NoNewline
    Write-Host "]" -ForegroundColor White
    Write-Host "Then copy the script between the lines or `n from $PSScriptRoot\Logs\$ScriptName" -ForegroundColor White
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "In router's ssh session, run command [" -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow -NoNewline
    Write-Host "] to reboot" -ForegroundColor Gray
    #endregion
}

Stop-Transcript
