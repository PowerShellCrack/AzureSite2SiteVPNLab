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
$LogfileName = "$RegionAName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
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

    #Determine last address base don VyOS subnets
    $LocalPeerIP = Read-host "Whats is your last IP address in your VyOS routers subnet (Usually for the Bgp Peering Address) ['$($AddressesSpace.EndingIP)']"
    If($LocalPeerIP){$VyOSConfig['BgpPeeringAddress']=$LocalPeerIP}Else{$VyOSConfig['BgpPeeringAddress']=$AddressesSpace.EndingIP}
}
#endregion


# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
#region 1. create a resource group
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
#endregion

#region 2. Create virtual network A
If(-Not($vNetA = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure hub virtual network [{0}]..." -f $AzureAdvConfigSiteB.VnetHubName) -NoNewline
    Try{
        $vNetA = New-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                            -Location $AzureAdvConfigSiteB.LocationName -AddressPrefix $AzureAdvConfigSiteB.VnetHubCIDRPrefix
        #Create a subnet configuration for the hub network or gateway subnet (Vnet A)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VnetHubSubnetName -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteB.VnetHubSubnetAddressPrefix | Out-Null
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteB.VnetHubSubnetGatewayAddressPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $vNetA | Out-Null
    }
}
Else{
    Write-Host ("Using Azure hub virtual network [{0}]" -f $AzureAdvConfigSiteB.VnetHubName) -ForegroundColor Green
}
#endregion


#region 3. Create virtual network B
If(-Not($vNetB = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetSpokeName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke virtual network [{0}]..." -f $AzureAdvConfigSiteB.VnetSpokeName) -NoNewline
    Try{
        $vNetB = New-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetSpokeName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                            -Location $AzureAdvConfigSiteB.LocationName -AddressPrefix $AzureAdvConfigSiteB.VnetSpokeCIDRPrefix
        #Create a subnet configuration for first VM subnet (vnet B)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VnetSpokeSubnetName -VirtualNetwork $vNetB `
                -AddressPrefix $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $vNetB | Out-Null
    }
}
Else{
    Write-Host ("Using Azure spoke virtual network [{0}]" -f $AzureAdvConfigSiteB.VnetSpokeName) -ForegroundColor Green
}
#endregion


#region 4. Build Peering between vnets
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
If( -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameAB -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VirtualNetwork $vNetA.Name) -or `
    -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameBA -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VirtualNetwork $vNetB.Name) )
{
    Write-Host ("Creating peering between vnets [{0}] and [{1}]..." -f $AzureAdvConfigSiteB.VnetPeerNameAB,$AzureAdvConfigSiteB.VnetPeerNameBA) -NoNewline
    Try{
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameAB -VirtualNetwork $vNetA -RemoteVirtualNetworkId $vNetB.Id | Out-Null
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteB.VnetPeerNameBA -VirtualNetwork $vNetB -RemoteVirtualNetworkId $vNetA.Id | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Peering between Hub [{0}] and spoke [{1}] is already setup" -f $AzureAdvConfigSiteB.VnetPeerNameAB,$AzureAdvConfigSiteB.VnetPeerNameBA) -ForegroundColor Green
}
#endregion


#get vnet and gateway subnet
$vNet = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
$gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet


#region 5. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureAdvConfigSiteB.PublicIPName) -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                -Location $AzureAdvConfigSiteB.LocationName -AllocationMethod Dynamic | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureAdvConfigSiteB.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion


#region 6. attach public ip to gateway
Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureAdvConfigSiteB.PublicIPName, 'GatewaySubnet') -NoNewline
Try{
    #$vnet = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
    $gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigSiteB.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigSiteB.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
#endregion


#region 7. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteB.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureAdvConfigSiteB.VnetGatewayName) -NoNewline
    Try{
        $VNGBGPParams=@{}
        If($UseBGP){
            $VNGBGPParams.add('Asn',$AzureAdvConfigSiteB.VnetASN)
            $VNGBGPParams.add('EnableBgp',$true)
        }
        Else{
            $VNGBGPParams.add('EnableBgp',$false)
        }

        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteB.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Standard @VNGBGPParams | Out-Null
        $stopwatch.Stop()
        $totalSecs =  [math]::Round($stopwatch.Elapsed.TotalSeconds,0)
        Write-Host ("Completed in [{0}] seconds" -f $totalSecs) -ForegroundColor Green
    }
    Catch{
        $stopwatch.Stop()
        $totalSecs =  [math]::Round($stopwatch.Elapsed.TotalSeconds,0)
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureAdvConfigSiteB.VnetGatewayName) -ForegroundColor Green
}
#endregion


#region 8. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSConfig.BgpPeeringAddress)
}

If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureAdvConfigSiteB.LocalGatewayName) -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                -Location $AzureAdvConfigSiteB.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix @LNGBGPParams | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
ElseIf($Local.GatewayIpAddress -ne $HomePublicIP)
{
    Try{
        Write-Host ("Updating the local network gateway with ip [{0}]" -f $HomePublicIP) -ForegroundColor Yellow -NoNewline
        #Update Local network gratway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                -Location $AzureAdvConfigSiteB.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix @LNGBGPParams -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureAdvConfigSiteB.LocalGatewayName) -ForegroundColor Green
}
#endregion


#region 9. Create the VPN connection
If( ($currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue).ConnectionStatus -eq "Connected")
{
    Write-Host ("Gateway is connected to ip [{0}]. Completed!" -f $azpip.IpAddress) -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Green
    Break
}
Elseif( $null -eq $currentGwConnection)
{
    #create the Site-to-Site VPN connection between your virtual network gateway and your VPN device.
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteB.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteB.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureAdvConfigSiteB.VnetConnectionName) -NoNewline
    Try{
        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -Location $AzureAdvConfigSiteB.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey -enablebgp $UseBGP | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Gateway is not connected. Attempting to update vyos router vpn settings to Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
    $Global:sharedPSKKey = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
    $VyOSConfig['ResetVPNConfigs'] = $true
}
#endregion


# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteB.PublicIpName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName

# Grab BGP settings form JSON
If($UseBGP){$bgpsettings = $gateway1.BgpSettingsText | ConvertFrom-Json}


#region 10. Build VyOS VPN Configuration Commands
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
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication pre-shared-secret '$Global:sharedPSKKey'
set vpn ipsec site-to-site peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec site-to-site peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureAdvConfigSiteB.TunnelDescription)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 remote prefix '$($AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix)'

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
#endregion



If($RouterAutomationMode)
{
    $RunManualSteps = $false
    Write-Host "Attempting to automatically configure router's site-2-site vpn settings for region 2..." -ForegroundColor Yellow
    #region Automation Mode
    $VyOSFinalScript = New-VyattaScript -Value $VyOSFinal -AsObject -SetReboot

    #temporary set auto logon ssh keys
    New-SSHSharedKey -DestinationIP $VyOSExternalIP -User 'vyos'

    $Result = Initialize-VyattaScript -IP $VyOSExternalIP -Path $VyOSFinalScript.Path -Execute -Verbose

    $Result

    If(!$Result){
        Write-Host "Failed to run automation script for vyos router; use manual process" -ForegroundColor Red
        $RunManualSteps = $true
    }
    Else{
        #wait for VM to boot completely
        Write-Host "VM is rebooting" -ForegroundColor Yellow -NoNewline
        do {
            Write-Host "." -NoNewline
            Start-Sleep 3
        } until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)

        Write-Host "Booted" -ForegroundColor Green
        Write-Host "--------------------------------------------"
        Write-Host "Login to router and run [" -ForegroundColor Gray -NoNewline
        Write-Host "show vpn ipsec sa" -ForegroundColor Yellow -NoNewline
        Write-Host "]" -ForegroundColor Gray
        Write-Host "---------------------------------------------"
        $response1 = Read-host "Is the VPN tunnel up? ? [Y or N]"
        If($response1 -eq 'Y'){
            Write-Host ("Done configuring router advanced site-2-site vpn for region 2") -ForegroundColor Green
            Write-Host "==============================================================" -ForegroundColor Green
        }Else{
            Write-Host "Automation may have failed try running the commands manually" -ForegroundColor Red
            $RunManualSteps = $true
        }

        $ErrorActionPreference = 'SilentlyContinue'
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

        $VPNGateway = Invoke-RestMethod "https://$($azpip.IpAddress):8081/healthprobe" -ErrorAction SilentlyContinue
        $VPNGateway.string."#Text"

        #check current connection
        Write-Host ("Checking Site-2-Site VPN tunnel connection status...") -ForegroundColor Yellow -NoNewline

        If($VyOSConfig['ResetVPNConfigs']){Reset-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName}
        Start-sleep 10
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteB.VnetConnectionName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
        If($currentGwConnection.ConnectionStatus -eq "Connected")
        {
            Write-Host ("{0}!" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Green
            #set to false so the next gateway setup does not delete this setup
            $VyOSConfig['ResetVPNConfigs'] = $false
        }
        Else{
            Write-Host ("{0}" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Red
            $RunManualSteps = $true
        }
    }
    #endregion
}
Else{
    $RunManualSteps = $true
}

If($RunManualSteps){
    #Ouput information need for local router
    Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
    Write-Host ("Azure Location:           {0}" -f $AzureAdvConfigSiteB.LocationName)
    Write-Host ("Azure Peer Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Remote Subnet Prefix:     {0}" -f $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix)
    Write-host ("Shared Key (PSK):         {0}" -f $Global:sharedPSKKey)
    Write-Host ("BGP Enabled:              {0}" -f $UseBGP.ToString())
    If($UseBGP){
        Write-Host ("BGP ASN:              {0}" -f $bgpsettings.Asn)
        Write-Host ("BGP Peering Address:  {0}" -f $bgpsettings.BgpPeeringAddress)
    }
    Write-Host ("Local Router Prefix:      {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-Host ("Local Router External:    {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-host ("Home Public IP:           {0}" -f $HomePublicIP)
    Write-Host "Be sure to follow a the configuration file 'VyOS_vpn_2site_bgp.md' in the VyOS_setup folder`n" -ForegroundColor Yellow

    $VyOSFinal -split '\n' | %{$_ | Add-Content "$PSScriptRoot\Logs\vyoss2sregion1setup.txt"}
    #region Copy Paste Mode
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
    Write-Host "Copy script below line or from $PSScriptRoot\Logs\vyoss2sregion1setup.txt" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Stop copying above line this and paste in ssh session" -ForegroundColor Yellow
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "Run this command last in ssh session: " -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow
    #endregion
}

Stop-Transcript
