$ErrorActionPreference = "Stop"
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell

#dot source configuration file
. "$PSScriptRoot\Configs.ps1"

#start transcript
$LogfileName = "$RegionBName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

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

#if using BGP; ask some questions
If($UseBGP){
    #grab last address in subnets (for BGP)
    $Lastsubnet = $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name | select -Last 1
    $subnet = $Lastsubnet.name.Split("/")[0]
    $mask = $Lastsubnet.name.Split("/")[1]
    $AddressesSpace = Get-NetworkStartEndAddress $subnet -Prefix $mask

    $LocalNetworkASN = Read-host "What will be your local BGP ASN Number (range 64512 - 65534) [$($VyOSConfig.BgpAsn)]"
    If($LocalNetworkASN){$VyOSConfig['BGPAsn']=$LocalNetworkASN}
    
    #Determin last address base don VyOS subnets
    $LocalPeerIP = Read-host "Whats is your last IP address in your VyOS routers subnet (Usually for the Bgp Peering Address) ['$($AddressesSpace.EndingIP)']"
    If($LocalPeerIP){$VyOSConfig['BgpPeeringAddress']=$LocalPeerIP}Else{$VyOSConfig['BgpPeeringAddress']=$AddressesSpace.EndingIP}
}
#endregion

# create a resource group
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
{
    New-AzResourceGroup -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName
}

#region 1. Create virtual network A
$vNetA = New-AzVirtualNetwork -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureAdvConfigSiteB.VnetHubName `
                     -Location $AzureAdvConfigSiteB.LocationName -AddressPrefix $AzureAdvConfigSiteB.VnetHubCIDRPrefix
#Create a subnet configuration for the hub network or gateway subnet (Vnet A)
Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VnetHubSubnetName -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteB.VnetHubSubnetAddressPrefix
Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteB.VnetHubSubnetGatewayAddressPrefix
Set-AzVirtualNetwork -VirtualNetwork $vNetA

# Create virtual network B
$vNetB = New-AzVirtualNetwork -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureAdvConfigSiteB.VnetSpokeName `
                     -Location $AzureAdvConfigSiteB.LocationName -AddressPrefix $AzureAdvConfigSiteB.VnetSpokeCIDRPrefix
#Create a subnet configuration for first VM subnet (vnet B)
Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VnetSpokeSubnetName -VirtualNetwork $vNetB -AddressPrefix $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix
Set-AzVirtualNetwork -VirtualNetwork $vNetB
#endregion

#region 2. Build Peering between vnets
$vNetA = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
$vNetB = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetSpokeName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameAB -VirtualNetwork $vNetA -RemoteVirtualNetworkId $vNetB.Id
Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameBA -VirtualNetwork $vNetB -RemoteVirtualNetworkId $vNetA.Id

#get vnet and gateway subnet
$vNet = Get-AzVirtualNetwork -Name $vNetA.Name -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
$gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet
#endregion

#region 3. Create Public IP
New-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpAddressName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -AllocationMethod Dynamic
$gwpip = Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureAdvConfigSiteB.PublicIpAddressName
#endregion

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig2 -SubnetId $gwsubnet.id -PublicIpAddressId $gwpip.Id

#region 4. make the gateway
$VNGBGPParams=@{}
If($UseBGP){
    $VNGBGPParams.add('Asn',$AzureAdvConfigSiteB.VnetASN)
    $VNGBGPParams.add('EnableBgp',$true)
}Else{
    $VNGBGPParams.add('EnableBgp',$false)
}
# This will take a while; typically about 30 minutes
New-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteB.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Standard @VNGBGPParams

#fetch virtual network gateway
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteB.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
#endregion

#region 5. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSBGPConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSBGPConfig.BgpPeeringAddress)
}
New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix @LNGBGPParams
#endregion

#region 6. get local gateway and on-prem local info
$Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
# connect the two
New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey -enablebgp $UseBGP
#endregion

$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
# get the BGP ip for local gw
$azpip = (Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name ($AzureAdvConfigSiteB.PublicIpAddressName)).IpAddress
If($UseBGP){$bgpsettings = $gateway1.BgpSettingsText | ConvertFrom-Json}

#Ouput information need for local router
Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
Write-Host ("Azure Location:       {0}" -f $AzureAdvConfigSiteB.LocationName)
Write-Host ("Azure Peer Public IP: {0}" -f $azpip)
Write-Host ("Remote Subnet Prefix: {0}" -f $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix)
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
set vpn ipsec site-to-site peer $azpip description '$($AzureAdvConfigSiteB.TunnelDescription)'
set vpn ipsec site-to-site peer $azpip ike-group 'azure-ike'
set vpn ipsec site-to-site peer $azpip ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $azpip local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $azpip tunnel 1 remote prefix '$($AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix)'

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

"@
If($RouterAutomationMode){
    #region Automation Mode
    #build script for router
    #https://docs.vyos.io/en/crux/automation/command-scripting.html
    '#!/bin/vbash' | Set-Content $env:temp\vyos.script
    'source /opt/vyatta/etc/functions/script-template' | Add-Content $env:temp\vyos.script
    '' | Add-Content $env:temp\vyos.script
    $VyOSFinal -split '\n' | %{$_ | Add-Content $env:temp\vyos.script}
    'exit' | Add-Content $env:temp\vyos.script
    'run restart vpn' | Add-Content $env:temp\vyos.script
    'run show vpn ipsec sa' | Add-Content $env:temp\vyos.script
    '' | Add-Content $env:temp\vyos.script
    If($UseBGP){
        'run show ip bgp' | Add-Content $env:temp\vyos.script
    }
    #'' | Add-Content $env:temp\vyos.script
    #'run reboot now' | Add-Content $env:temp\vyos.script
    #get-content $env:temp\vyos.script

    #copy script to vyos router
    $remoteSSHServerLogin = "vyos@$VyOSExternalIP"
    scp -o 'StrictHostKeyChecking no' "$env:temp\vyos.script" "${remoteSSHServerLogin}:~/tmp.sh"

    $scriptfile = 'sitebs2svpn.sh'
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
    #endregion

}
Else{
    $VyOSFinal -split '\n' | %{$_ | Add-Content "$PSScriptRoot\Logs\vyoss2sregion2setup.txt"}
    #region Copy Paste Mode
    Write-Host "`nCopy and Paste below in ssh session for $($VyOSConfig.VMName):`n or" -ForegroundColor Yellow
    Write-Host "`nCopy code from $PSScriptRoot\Logs\vyoss2sregion2setup.txt" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray

    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName). Run this command in console or ssh session:`n" -ForegroundColor Yellow
    Write-Host "reboot now" -ForegroundColor Gray
    #endregion
}

#make a connection the VPN health probe
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

$VPNGateway = Invoke-RestMethod "https://$($VyOSExternalIP):8081/healthprobe"
$VPNGateway.string."#Text"


Stop-Transcript