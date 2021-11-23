$ErrorActionPreference = "Stop"

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading configuration file first...") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoAzureCheck
    Write-Host "Done" -ForegroundColor Green
}
#endregion

#region start transcript
$LogfileName = "$RegionBName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#grab external interface for VyOS router
If($null -ne $VyOSConfig.ExternalInterfaceIP){
    $VyOSExternalIP = $VyOSConfig.ExternalInterfaceIP
}
ElseIf(Test-Path "$env:temp\VyOSextip.txt"){
    $VyOSExternalIP = Get-Content "$env:temp\VyOSextip.txt"
}
Else{
    $VyOSExternalIP = Read-host "Whats the VyOS interface '$($VyOSConfig.ExternalInterface)' IP (eg. '192.168.1.36')"
}
$VyOSConfig.Add('ExternalInterfaceIP',$VyOSExternalIP)

#region BGP checks
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

# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
#region 1. Create a virtual network and a gateway subnet

# create a resource group
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureAdvConfigSiteB.ResourceGroupName) -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureAdvConfigSiteB.ResourceGroupName) -ForegroundColor Green
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
Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VnetSpokeSubnetName -VirtualNetwork $vNetB -AddressPrefix $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix | Out-Null
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
New-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -AllocationMethod Dynamic
$gwpip = Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureAdvConfigSiteB.PublicIpName
#endregion

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigSiteB.VnetGatewayIpConfigName -SubnetId $gwsubnet.id -PublicIpAddressId $gwpip.Id

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
$azpip = (Get-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name ($AzureAdvConfigSiteB.PublicIpName)).IpAddress
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



$VyOSFinal = @"
# Enter configuration mode.
configure
`n
"@

If($VyOSConfig.ResetVPNConfigs){
    $VyOSFinal += @"
#delete current configurations
delete vpn ipsec
delete protocols bgp
`n
"@
#set to false so the next gateway setup does not delete this setup
$VyOSConfig['ResetVPNConfigs']=$false
}

$VyOSFinal += @"
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
    $VyOSFinal += @"
#BGP for Azure East
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) ebgp-multihop '8'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) remote-as '$($bgpsettings.Asn)'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) soft-reconfiguration 'inbound'
"@
}

$VyOSFinal += @"

commit
save

"@

If($RouterAutomationMode){
    #region Automation Mode
    $VyOSFinalScript = New-VyattaScript -Value $VyOSFinal -AsObject -SetReboot

    #temporary set auto logon ssh keys
    New-SSHSharedKey -DestinationIP $VyOSExternalIP -User 'vyos'

    $Result = Initialize-VyattaScript -IP $VyOSExternalIP -Path $VyOSFinalScript.Path -Execute -Verbose
    If(!$Result){
        Write-Host "Failed to run automation script for vyos router; use manual process" -ForegroundColor Red
        $RunManualSteps = $true
    }
}
Else{
    $RunManualSteps = $true
}

If($RunManualSteps){
    $VyOSFinal -split '\n' | %{$_ | Add-Content "$PSScriptRoot\Logs\vyoss2sregion2setup.txt"}
    #region Copy Paste Mode
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
    Write-Host "Copy script below line or from $PSScriptRoot\Logs\vyoss2sregion2setup.txt" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Stop copying above line this and paste in ssh session" -ForegroundColor Yellow
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "Run this command last in ssh session: " -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow
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
