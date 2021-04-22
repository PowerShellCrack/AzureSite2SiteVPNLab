
$ErrorActionPreference = "Stop"
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell

#dot source configuration file
. "$PSScriptRoot\Configs.ps1"

$LogfileName = "$RegionAName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#grab last address in subnets (for BGP)
$Lastsubnet = $VyOSConfig.LocalSubnetPrefix | select -Last 1
$subnet = $Lastsubnet.Split("/")[0]
$mask = $Lastsubnet.Split("/")[1]
$AddressesSpace = Get-NetworkStartEndAddress $subnet -Prefix $mask

#grab external interface for VyOS router
If($null -ne $VyOSConfig.ExternalInterfaceIP){
    $VyOSExtInterfaceIP = $VyOSConfig.ExternalInterfaceIP
}
Else{
    $VyOSExtInterfaceIP = Read-host "Whats the VyOS interface '$($VyOSConfig.ExternalInterface)' IP (eg. '192.168.1.36')"
    #$VyOSExtInterfaceIP | Out-File "$env:temp\VyOSextip.txt" -Force
    $VyOSConfig.Add('ExternalInterfaceIP',$VyOSExtInterfaceIP)
}

#if using BGP; ask some questions
If($UseBGP){
    $LocalNetworkASN = Read-host "What will be your local BGP ASN Number (range 64512 - 65534) [$($VyOSConfig.BgpAsn)]"
    If($LocalNetworkASN){$VyOSConfig['BGPAsn']=$LocalNetworkASN}
    
    #Determin last address base don VyOS subnets
    $LocalPeerIP = Read-host "Whats is your last IP address in your VyOS routers subnet (Usually for the Bgp Peering Address) ['$($AddressesSpace.EndingIP)']"
    If($LocalPeerIP){$VyOSConfig['BgpPeeringAddress']=$LocalPeerIP}Else{$VyOSConfig['BgpPeeringAddress']=$AddressesSpace.EndingIP}
}
#endregion

# create a resource group
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    New-AzResourceGroup -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName
}

#region 1. Create virtual network A
$vNetA = New-AzVirtualNetwork -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $AzureAdvConfigSiteA.VnetHubName -AddressPrefix $AzureAdvConfigSiteA.VnetHubCIDRPrefix -Location $AzureAdvConfigSiteA.LocationName
#Create a subnet configuration for the hub network or gateway subnet (Vnet A)
Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteA.VnetHubSubnetName -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteA.VnetHubSubnetAddressPrefix
Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteA.VnetHubSubnetGatewayAddressPrefix
Set-AzVirtualNetwork -VirtualNetwork $vNetA

# Create virtual network B
$vNetB = New-AzVirtualNetwork -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $AzureAdvConfigSiteA.VnetSpokeName -AddressPrefix $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix -Location $AzureAdvConfigSiteA.LocationName
#Create a subnet configuration for first VM subnet (vnet B)
Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteA.VnetSpokeSubnetName -VirtualNetwork $vNetB -AddressPrefix $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix
Set-AzVirtualNetwork -VirtualNetwork $vNetB
#endregion


#region 2. Build Peering between vnets
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameAB -VirtualNetwork $vNetA -RemoteVirtualNetworkId $vNetB.Id -ErrorAction SilentlyContinue
Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameBA -VirtualNetwork $vNetB -RemoteVirtualNetworkId $vNetA.Id -ErrorAction SilentlyContinue


#get vnet and gateway subnet
$vNet = Get-AzVirtualNetwork -Name $vNetA.Name -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
$gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet
#endregion

#region 3. Create Public IP
New-AzPublicIpAddress -Name $AzureAdvConfigSiteA.PublicIpAddressName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -AllocationMethod Dynamic
$gwpip = Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $AzureAdvConfigSiteA.PublicIpAddressName

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig1 -SubnetId $gwsubnet.Id -PublicIpAddressId $gwpip.Id
#endregion

#region 4. make the gateway
$VNGBGPParams=@{}
If($UseBGP){
    $VNGBGPParams.add('Asn',$AzureAdvConfigSiteA.VnetASN)
    $VNGBGPParams.add('EnableBgp',$true)
}
Else{
    $VNGBGPParams.add('EnableBgp',$false)
}
# This will take a while; typically about 30 minutes
New-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteA.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Standard @VNGBGPParams

#fetch virtual network gateway
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteA.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
#endregion


#region 5. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSConfig.BgpPeeringAddress)
}

New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix @LNGBGPParams
#endregion

#region 6. get local gateway and on-prem local info
$Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
#connect the two
New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey -enablebgp $UseBGP
#endregion

$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
# get the BGP ip for local gw
$azpip = (Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name ($AzureAdvConfigSiteA.PublicIpAddressName)).IpAddress
If($UseBGP){$bgpsettings = $gateway1.BgpSettingsText | ConvertFrom-Json}

#Ouput information need for local router
Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
Write-Host ("Azure Location:       {0}" -f $AzureAdvConfigSiteA.LocationName)
Write-Host ("Azure Peer Public IP: {0}" -f $azpip)
Write-Host ("Remote Subnet Prefix: {0}" -f $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix)
Write-host ("Shared Key (PSK):     {0}" -f $Global:sharedPSKKey)
Write-Host ("BGP Enabled:          {0}" -f $UseBGP.ToString())
If($UseBGP){
    Write-Host ("BGP ASN:              {0}" -f $bgpsettings.Asn)
    Write-Host ("BGP Peering Address:  {0}" -f $bgpsettings.BgpPeeringAddress)
}
Write-Host ("Local Router Prefix:   {0}" -f $VyOSConfig.LocalCIDRPrefix)
Write-Host ("Local Router External:   {0}" -f $VyOSConfig.LocalCIDRPrefix)
Write-host ("Home Public IP:        {0}" -f $HomePublicIP)
Write-Host "Be sure to follow a the configuration file 'VyOS_vpn_2site_bgp.md' in the VyOS_setup folder`n" -ForegroundColor Yellow

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
set vpn ipsec site-to-site peer $azpip description '$($AzureAdvConfigSiteA.TunnelDescription)'
set vpn ipsec site-to-site peer $azpip ike-group 'azure-ike'
set vpn ipsec site-to-site peer $azpip ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $azpip local-address '$($VyOSConfig.ExternalInterfaceIP)'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $azpip tunnel 1 remote prefix '$($AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix)'

#Default route and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'

"@

If($UseBGP){
    $VyOScomand += @"
#BGP for Azure East
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) ebgp-multihop '8'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) remote-as '$($bgpsettings.Asn)'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) soft-reconfiguration 'inbound'
"@
}

$VyOScomand += @"

commit
save
exit

#check the IPsec tunnels are up:
show vpn ipsec sa

"@

If($UseBGP){
    $VyOScomand += @"
# Test if BGP is functioning, run the command:
show ip bgp
"@
}

Write-Host "Copy and Paste below in ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
Write-Host $VyOScomand -ForegroundColor Gray

Write-Host "`nA reboot may be required on $($VyOSConfig.VMName). Run this command in ssh session:`n" -ForegroundColor Yellow
Write-Host "reboot now" -ForegroundColor Gray


#make a conenction the VPN healthprobe
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$VPNGateway = Invoke-RestMethod "https://$($VyOSConfig.ExternalInterfaceIP):8081/healthprobe"
$VPNGateway.string."#Text"

Stop-Transcript