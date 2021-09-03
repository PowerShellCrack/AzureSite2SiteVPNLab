$ErrorActionPreference = "Stop"

#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#region start transcript
$LogfileName = "$RegionName-BasicSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#grab external interface for VyOS router
If($null -ne $VyOSConfig.ExternalInterfaceIP){
    $VyOSExternalIP = $VyOSConfig.ExternalInterfaceIP
}
ElseIf(Test-Path "$env:temp\VyOSextipw.txt"){
    $VyOSExternalIP = Get-Content "$env:temp\VyOSextip.txt"
}
Else{
    $VyOSExternalIP = Read-host "Whats the VyOS interface '$($VyOSConfig.ExternalInterface)' IP (eg. '192.168.1.36')"
}
$VyOSConfig.Add('ExternalInterfaceIP',$VyOSExternalIP)

#temporary set auto logon ssh keys
New-SSHSharedKey -DestinationIP $VyOSExternalIP -User 'vyos' -Force

#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell
#region 1. Create a virtual network and a gateway subnet

#Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    New-AResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName
}

#Set the vnet subnets
$subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix
$subnet2 = New-AzVirtualNetworkSubnetConfig -Name 'DefaultSubnet' -AddressPrefix $AzureSimpleConfig.VnetSubnetPrefix

#Create the VNet
New-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -AddressPrefix $AzureSimpleConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2

#add a gateway subnet to a virtual network you have already created
$vnet = Get-AzVirtualNetwork -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleConfig.VnetName
Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix -VirtualNetwork $vnet
Set-AzVirtualNetwork -VirtualNetwork $vnet
#endregion

#region 2. Create the local network gateway
#add a local network gateway with a single address prefix:
New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $AzureSimpleConfig.LocalSubnetPrefix 
#endregion

#region 3. Request a Public IP address
$gwpip= New-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIPName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -AllocationMethod Dynamic
#endregion

#region 4. Create the gateway IP addressing configuration
$vnet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
$subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig1 -SubnetId $subnet.Id -PublicIpAddressId $gwpip.Id
#endregion

#region 5. Create the VPN gateway
#this can take up to 40 minutes (eg: started at 4:15; ended at 4:39)
New-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1
#endregion

#region 6 & 7. Create the VPN connection
Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIPName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
#create the Site-to-Site VPN connection between your virtual network gateway and your VPN device.
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
$Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName

#Create the connection
New-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey
#endregion

#region 8. Verify the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
#endregion

#get the Public IP
$azpip = (Get-AzPublicIpAddress -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleConfig.PublicIPName).IpAddress

#Ouput information need for local router
Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
Write-Host ("Azure Location:      {0}" -f $AzureSimpleConfig.LocationName)
Write-Host ("Azure Public IP:     {0}" -f $azpip)
Write-Host ("Azure Subnet Prefix: {0}" -f $AzureSimpleConfig.VnetSubnetPrefix)
Write-host ("Shared Key (PSK):    {0}" -f $Global:sharedPSKKey)
Write-host ("Home Public IP:      {0}" -f $HomePublicIP)
Write-Host ("Router CIDR Prefix:  {0}" -f $VyOSConfig.LocalCIDRPrefix)
Write-Host "Be sure to follow a the configruation file 'VyOS_vpn_basic.md' in the VyOS_setup folder" -ForegroundColor Yellow

#region Build VyOS VPN Configuration Commands
$VyOScomand = @"
# Enter configuration mode.
configure
`n
"@

If($VyOSConfig.ResetVPNConfigs){
    $VyOScomand += @"
#delete current configurations
delete vpn ipsec
delete protocols bgp
`n
"@
#set to false so the next gateway setup does not delete this setup
$VyOSConfig['ResetVPNConfigs']=$false
}

$VyOScomand += @"
# Set up the IPsec preamble for link Azures gateway
set vpn ipsec esp-group azure compression 'disable'
set vpn ipsec esp-group azure lifetime '3600'
set vpn ipsec esp-group azure mode 'tunnel'
set vpn ipsec esp-group azure pfs 'disable'
set vpn ipsec esp-group azure proposal 1 encryption 'aes256'
set vpn ipsec esp-group azure proposal 1 hash 'sha1'
set vpn ipsec ike-group azure-ike ikev2-reauth 'no'
set vpn ipsec ike-group azure-ike key-exchange 'ikev2'
set vpn ipsec ike-group azure-ike lifetime '10800'
set vpn ipsec ike-group azure-ike proposal 1 dh-group '2'
set vpn ipsec ike-group azure-ike proposal 1 encryption 'aes256'
set vpn ipsec ike-group azure-ike proposal 1 hash 'sha1'

set vpn ipsec ipsec-interfaces interface 'eth0'
set vpn ipsec nat-traversal 'enable'
set vpn ipsec site-to-site peer $azpip authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer $azpip authentication pre-shared-secret '$Global:sharedPSKKey'
set vpn ipsec site-to-site peer $azpip connection-type 'initiate'
set vpn ipsec site-to-site peer $azpip default-esp-group 'azure'
set vpn ipsec site-to-site peer $azpip description '$($AzureSimpleConfig.TunnelDescription)'
set vpn ipsec site-to-site peer $azpip ike-group 'azure-ike'
set vpn ipsec site-to-site peer $azpip ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $azpip local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $azpip tunnel 1 remote prefix '$($AzureSimpleConfig.VnetSubnetPrefix)'

#Default route and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'

"@

$VyOScomand += @"

commit
save
"@

#build script for router
#https://docs.vyos.io/en/crux/automation/command-scripting.html
'#!/bin/vbash' | Set-Content $env:temp\vyos.script
'source /opt/vyatta/etc/functions/script-template' | Add-Content $env:temp\vyos.script
'' | Add-Content $env:temp\vyos.script
$VyOSFinal -split '\n' | %{$_ | Add-Content $env:temp\vyos.script}
'exit' | Add-Content $env:temp\vyos.script
'run restart vpn' | Add-Content $env:temp\vyos.script
'run show vpn ipsec sa' | Add-Content $env:temp\vyos.script
#'' | Add-Content $env:temp\vyos.script
#'run reboot now' | Add-Content $env:temp\vyos.script
#get-content $env:temp\vyos.script

#copy script to vyos router
$remoteSSHServerLogin = "vyos@$VyOSExternalIP"
scp -o 'StrictHostKeyChecking no' "$env:temp\vyos.script" "${remoteSSHServerLogin}:~/tmp.sh"


$scriptfile = 'basics2svpn.sh'
#build bash command
$bashCommands = @(
    'mkdir -p ~/.scripts'
    'chmod 700 ~/.scripts'
    "rm -f ~/.scripts/$scriptfile"
    "cat ~/tmp.sh >> ~/.scripts/$scriptfile"
    'rm -f ~/tmp.sh'
    "sed -i -e 's/\r$//' ~/.scripts/$scriptfile"
    "chmod u+x ~/.scripts/$scriptfile"
    "sg vyattacfg -c ~/.scripts/$scriptfile"
)
#jooin all commands as single line separated with &&
$bashCommand = $bashCommands -join ' && '
ssh "vyos@$VyOSExternalIP" $bashCommand

write-Host 
Write-Host "vyos is rebooting...." -ForegroundColor Gray

Stop-Transcript