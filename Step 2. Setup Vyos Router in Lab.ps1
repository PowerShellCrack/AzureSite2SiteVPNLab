#https://systemspecialist.net/2014/11/26/create-mini-router-with-hyper-v-for-vm-labs/
#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#start transcript
$LogfileName = "$RegionAName-HyperVSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

$VM = Get-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
#region Create VyOS VM
If($null -eq $VM){
    Try{
        New-VHD -Path ($HyperVConfig.VirtualHardDiskLocation + '\'+ $VyOSConfig.VMName +'.vhdx') -SizeBytes 2GB -Dynamic
        New-VM -Name $VyOSConfig.VMName -VHDPath ($HyperVConfig.VirtualHardDiskLocation + '\'+ $VyOSConfig.VMName +'.vhdx') -SwitchName $VyOSConfig.ExternalInterface -MemoryStartupBytes 256MB -Generation 1 -ErrorAction Stop
        
        #Connect ISO
        Set-VMDvdDrive -VMName $VyOSConfig.VMName -Path $VyOSConfig.ISOLocation
    }
    Catch{
        Write-Host ("Unable to build the VM: [{0}]. Error {1}" -f $VyOSConfig.VMName,$_.Exception.Message) -ForegroundColor Red
        Break
    }
}
Else{   
    Write-Host ("VM Already created named [{0}]." -f $VM.Name) -ForegroundColor Green
}

#Start-VM
If($VM.State -ne "Running"){Start-VM -Name $VyOSConfig.VMName -ErrorAction Stop}
Write-Host "Configuring router for inital configurations..." -ForegroundColor Gray

#Trunk HyperV Network for internal networks
Get-VMNetworkAdapter -VMName $VyOSConfig.VMName | Where-Object {$_.SwitchName -ne $VyOSConfig.ExternalInterface} | Set-VMNetworkAdapterVlan -Trunk -NativeVlanId 10 -AllowedVlanIdList 1-100
#Get-VMNetworkAdapter -VMName $VyOSConfig.VMName | Where-Object {$_.SwitchName -ne $VyOSConfig.ExternalInterface} |  Set-VMNetworkAdapterVlan -Untagged
Get-VMNetworkAdapterVlan -VMName $VyOSConfig.VMName


Start-Sleep 10
#endregion

#region INSTALL VyOS
$VyOSSteps = @"
`n
You will be Loading an image onto the Virtual Machine router
Connect to router and answer the questions below on the VM
=======================================
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
 Enter password for user 'VyOS': [Choose a password]
 Retype password for user 'VyOS': [New password]
 Which drive should GRUB modify the boot partition on? [sda]: [Enter]
"@

do {
    #cls
    Write-Host $VyOSSteps -ForegroundColor Gray
    $response1 = Read-host "Did you complete the steps above? [Y or N]"
} until ($response1 -eq 'Y')

Write-Host "Configuring router for next configurations..." -ForegroundColor Gray
Stop-VM $VyOSConfig.VMName -ErrorAction SilentlyContinue
Get-VMDvdDrive -VMName $VyOSConfig.VMName | Remove-VMDvdDrive
Start-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue

#endregion

#region Setup VyOS SSH
$VyOSSteps = @"
`n
You will be enabling SSH on the Virtual Machine router
Connect to router and answer the questions below on the VM
=======================================
VyOS Base Configuration
VyOS login: VyOS
Password: [New password]
VyOS@VyOS:~$ configure
VyOS@VyOS# set interfaces ethernet eth0 address dhcp
VyOS@VyOS# set service ssh port '22'
VyOS@VyOS# commit
VyOS@VyOS# save
VyOS@VyOS# exit
VyOS@VyOS:~$ show int
"@
write-host "TAKE NOTE OF IP" -BackgroundColor Yellow -ForegroundColor Black
do {
    #cls
    Write-Host $VyOSSteps -ForegroundColor Gray
    $response1 = Read-host "Did you complete the steps above? [Y or N]"
} until ($response1 -eq 'Y')
Write-Host "If steps completed successfully, You can now ssh into the router instead of connecting via VM" -ForegroundColor Yellow
#endregion

#region Prompt for external interface for router
do {
    Remove-Item "$env:temp\VyOSextip.txt" -Force -ErrorAction SilentlyContinue | Out-Null
    $VyOSExternalIP = Read-host "What is your $($VM.VMName) router's eth0 IP Address? [eg. 192.168.1.2]"
    Write-Host "Testing connection to [$VyOSExternalIP]..." -ForegroundColor Yellow -NoNewline
    Start-Sleep 5
    $TestIP = Test-Connection $VyOSExternalIP -Count 1 -Quiet
    If (!($TestIP)){
        Write-Host "Failed! Check IP [run command in router: show int ethernet eth0 brief]" -ForegroundColor Red
    } Else {
        Write-Host ("IP [{0}] was pingable" -f $VyOSExternalIP) -ForegroundColor Green
        $VyOSConfig.Add('ExternalInterfaceIP',$VyOSExtInterfaceIP)
        $VyOSExternalIP | Out-File "$env:temp\VyOSextip.txt" -Force
    }
} until ($VyOSExternalIP -as [System.Net.IPAddress] -and $TestIP)
#endregion

#region Add all internal networks to router
Stop-VM $VyOSConfig.VMName -ErrorAction SilentlyContinue

start-sleep 10
$VM = Get-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
$VyOSNetworks = Get-VMSwitch -Name "$($VyOSConfig.NetPrefix)*"
ForEach($net in $VyOSNetworks) {
    If($net.Name -in $VM.NetworkAdapters.switchname){
        Write-Host ("Network [{0}] is already attached to [{1}]" -f $net.Name,$VM.VMName) -ForegroundColor Yellow
    }
    Else{
        Add-VMNetworkAdapter -VMName $VM.VMName -SwitchName $net.Name -ErrorAction Stop
        Write-Host ("Attached network [{0}] is to [{1}]" -f $net.Name,$VM.VMName) -ForegroundColor Green
    }
} 

Start-VM -Name $VyOSConfig.VMName -ErrorAction SilentlyContinue
Start-Sleep 10
#endregion


#NOT WORKING
# Add NATS for each Network
# Create External conenction (Not default switch)
# Fix network switch
# create UI



#region Build VyOS Final Configuration Commands
$VyOSFinal = @"
#VyOS Extended Configuration Script
configure

#Host Configuration
set system host-name $(($VyOSConfig.HostName).ToLower())
set system domain-name $domain
set system time-zone $($VyOSConfig.TimeZone)

#External Interface Configuration
set interfaces ethernet eth0 description 'Switch_External'

#DNS Configuration
set service dns forwarding cache-size '0'
"@
$i=1
foreach ($SubnetCIDR in $VyOSConfig.LocalSubnetPrefix){
    $subnet = $SubnetCIDR.Split("/")[0]
    $mask = $SubnetCIDR.Split("/")[1]
    $IPInfo = Get-NetworkStartEndAddress $Subnet -Prefix $mask
    $GatewayInfo = Get-TypicalIPRange -StartIP $IPInfo.StartingIP -EndIP $IPInfo.EndingIP -Gateway Last
    $VyOSFinal += @"
`n
#Interface $i Configuration
set interfaces ethernet eth$i address $($IPInfo.EndingIP)/$mask
set interfaces ethernet eth$i description '$($LabPrefix.ToUpper())-$i'
set service dns forwarding listen-on 'eth$i'
"@

    If($VyOSConfig.EnableDHCP){
        $VyOSFinal += @"

# Enable DHCP Configuration for eth$i

set service dhcp-server disabled 'false'
set service dhcp-server shared-network-name ETH$($i)_Pool subnet $SubnetCIDR start $($GatewayInfo.StartIP) stop $($GatewayInfo.EndIP)
set service dhcp-server shared-network-name ETH1_Pool subnet $SubnetCIDR dns-server $NextHop
set service dhcp-server shared-network-name ETH1_Pool subnet $SubnetCIDR dns-server $($GatewayInfo.GatewayIP)
set service dhcp-server shared-network-name ETH1_Pool subnet $SubnetCIDR default-router $($GatewayInfo.GatewayIP)
set service dhcp-server shared-network-name ETH1_Pool subnet $SubnetCIDR lease '86400'
"@

    }

$i++
}

switch($VyOSConfig.UseDNSOption){
'External' {$VyOSFinal += @"
`n
#forward home network dhcp`n
set service dns forwarding dhcp eth0
"@
}

'Internal' {$VyOSFinal += @" 
`n
#Set internal dns

"@
    foreach ($IP in $VyOSConfig.InternalDNSIP){
        $VyOSFinal += @"
set service dns forwarding name-server '$IP'
"@
                    
                    }
}
'Internet' {$VyOSFinal += @"

#Set internet dns
`n
set service dns forwarding name-server '8.8.8.8'
set service dns forwarding name-server '$NextHop'
"@    
    }
}

If($VyOSConfig.EnablePXEPRelay){
    $i=1
    ForEach($net in $VyOSNetworks){
        
        $VyOSFinal += @"
`n
#Enable DHCP relay (PXE boot) for eth($i):
set service dhcp-relay interface eth$i
"@
    $i=$i+1
    }

$VyOSFinal += @"
`n
#If DHCP Disabled, Set the IP address of the other DHCP server:
set service dhcp-relay server '$($VyOSConfig.PXERelayIP)'

#Discard DHCP packages already containing relay agent
set service dhcp-relay relay-options relay-agents-packets discard
"@
}

If($VyOSConfig.EnableNAT){
    $VyOSFinal += @"

#Enable NAT Configuration
set nat source rule 100 outbound-interface eth0
set nat source rule 100 source address '$($VyOSConfig.LocalCIDRPrefix)'
set nat source rule 100 translation address masquerade
"@
}

$VyOSFinal += @"
`n
commit
save
"@


Write-Host "`nCopy and Paste below in ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
Write-Host $VyOSFinal -ForegroundColor Gray

Write-Host "`nA reboot may be required on $($VyOSConfig.VMName). Run this command in ssh session:`n" -ForegroundColor Yellow
Write-Host "reboot now" -ForegroundColor Gray
#endregion

Stop-Transcript