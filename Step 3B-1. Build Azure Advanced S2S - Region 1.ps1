$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Compute,Az.Compute,Az.Resources,Az.Storage
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading configuration file first...") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoVyosISOCheck
}
#endregion

#region start transcript
$LogfileName = "$RegionAName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#Make it a global variable so it used for the entire session
#TEST $Global:RegionAPssKey='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'
If(!$Global:RegionAPssKey){$Global:RegionAPssKey = New-SharedPSKey}

#grab external interface for VyOS router
If($null -ne $VyOSConfig.ExternalInterfaceIP){
    $VyOSExternalIP = $VyOSConfig.ExternalInterfaceIP
}
ElseIf(Test-Path "$env:temp\$($LabPrefix)-VyOSextip.txt"){
    $VyOSExternalIP = Get-Content "$env:temp\$($LabPrefix)-VyOSextip.txt"
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
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureAdvConfigSiteA.ResourceGroupName) -ForegroundColor White -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureAdvConfigSiteA.ResourceGroupName) -ForegroundColor Green
}
#endregion

#region 2. Create virtual network A
If(-Not($vNetA = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure hub virtual network [{0}]..." -f $AzureAdvConfigSiteA.VnetHubName) -ForegroundColor White -NoNewline
    Try{
        $vNetA = New-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                            -Location $AzureAdvConfigSiteA.LocationName -AddressPrefix $AzureAdvConfigSiteA.VnetHubCIDRPrefix
        #Create a subnet configuration for the hub network or gateway subnet (Vnet A)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteA.VnetHubSubnetName -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteA.VnetHubSubnetAddressPrefix | Out-Null
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNetA -AddressPrefix $AzureAdvConfigSiteA.VnetHubSubnetGatewayAddressPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $vNetA | Out-Null
    }
}
Else{
    Write-Host ("Using Azure hub virtual network [{0}]" -f $AzureAdvConfigSiteA.VnetHubName) -ForegroundColor Green
}
#endregion


#region 3. Create virtual network B
If(-Not($vNetB = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetSpokeName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke virtual network [{0}]..." -f $AzureAdvConfigSiteA.VnetSpokeName) -ForegroundColor White -NoNewline
    Try{
        $vNetB = New-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetSpokeName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                            -Location $AzureAdvConfigSiteA.LocationName -AddressPrefix $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix
        #Create a subnet configuration for first VM subnet (vnet B)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteA.VnetSpokeSubnetName -VirtualNetwork $vNetB `
                -AddressPrefix $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $vNetB | Out-Null
    }
}
Else{
    Write-Host ("Using Azure spoke virtual network [{0}]" -f $AzureAdvConfigSiteA.VnetSpokeName) -ForegroundColor Green
}
#endregion


#region 4. Build Peering between vnets
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
If( -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameAB -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VirtualNetwork $vNetA.Name) -or `
    -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameBA -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VirtualNetwork $vNetB.Name) )
{
    Write-Host ("Creating peering between vnets [{0}] and [{1}]..." -f $AzureAdvConfigSiteA.VnetPeerNameAB,$AzureAdvConfigSiteA.VnetPeerNameBA) -ForegroundColor White -NoNewline
    Try{
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameAB -VirtualNetwork $vNetA -RemoteVirtualNetworkId $vNetB.Id | Out-Null
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigSiteA.VnetPeerNameBA -VirtualNetwork $vNetB -RemoteVirtualNetworkId $vNetA.Id | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Peering between Hub [{0}] and spoke [{1}] is already setup" -f $AzureAdvConfigSiteA.VnetPeerNameAB,$AzureAdvConfigSiteA.VnetPeerNameBA) -ForegroundColor Green
}
#endregion


#get vnet and gateway subnet
$vNet = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
$gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet


#region 5. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteA.PublicIpName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureAdvConfigSiteA.PublicIPName) -ForegroundColor White -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureAdvConfigSiteA.PublicIpName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                -Location $AzureAdvConfigSiteA.LocationName -AllocationMethod Dynamic | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteA.PublicIpName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureAdvConfigSiteA.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion


#region 6. attach public ip to gateway
Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureAdvConfigSiteA.PublicIPName, 'GatewaySubnet') -ForegroundColor White -NoNewline
Try{
    #$vnet = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
    $gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigSiteA.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigSiteA.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
#endregion


#region 7. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteA.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureAdvConfigSiteA.VnetGatewayName) -ForegroundColor White -NoNewline
    Try{
        $VNGBGPParams=@{}
        If($UseBGP){
            $VNGBGPParams.add('Asn',$AzureAdvConfigSiteA.VnetASN)
            $VNGBGPParams.add('EnableBgp',$true)
        }
        Else{
            $VNGBGPParams.add('EnableBgp',$false)
        }

        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteA.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
            -Location $AzureAdvConfigSiteA.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku Standard @VNGBGPParams | Out-Null
        $stopwatch.Stop()
        $totalSecs = [timespan]::fromseconds($stopwatch.Elapsed.TotalSeconds)
        Write-Host ("Completed [{0:hh\:mm\:ss}]" -f $totalSecs) -ForegroundColor Green
    }
    Catch{
        $stopwatch.Stop()
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureAdvConfigSiteA.VnetGatewayName) -ForegroundColor Green
}
#endregion


#region 8. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSConfig.BgpPeeringAddress)
}

If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureAdvConfigSiteA.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                -Location $AzureAdvConfigSiteA.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalSubnetPrefix.keys @LNGBGPParams | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
ElseIf($Local.GatewayIpAddress -ne $HomePublicIP)
{
    Try{
        Write-Host ("Updating the local network gateway with ip [{0}]" -f $HomePublicIP) -ForegroundColor Yellow -NoNewline
        #Update Local network gratway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                -Location $AzureAdvConfigSiteA.LocationName -GatewayIpAddress $HomePublicIP `
                -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) @LNGBGPParams -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureAdvConfigSiteA.LocalGatewayName) -ForegroundColor Green
}
#endregion


#region 9. Create the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.ConnectionName `
            -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue

If( ($currentGwConnection).ConnectionStatus -eq "Connected")
{
    Write-Host ("VPN Gateway is connected to ip [{0}]. No further action needed!" -f $azpip.IpAddress) -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Break
}
ElseIf( ($currentGwConnection).ConnectionStatus -eq "Unknown")
{
    Write-Host ("VPN Gateway status is unknown. It can take up to three minutes for the status to change!") -ForegroundColor Yellow
    Write-Host ("Re-run this script at that time to get a fresh status message.") -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Break
}
Elseif( $null -eq $currentGwConnection)
{
    #create the Site-to-Site VPN connection between your virtual network gateway and your VPN device.
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteA.VnetGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigSiteA.LocalGatewayName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureAdvConfigSiteA.ConnectionName) -ForegroundColor White -NoNewline
    Try{
        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.ConnectionName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
            -Location $AzureAdvConfigSiteA.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $Global:RegionAPssKey -EnableBgp $UseBGP | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Gateway is not connected! ") -ForegroundColor Red -NoNewline
    If($VyOSConfig['ResetVPNConfigs'] -eq $false){
        do {
            #cls
            $ReconfigureVpn = Read-host "Would you like to re-run the router configurations? [Y or N]"
        } until ($ReconfigureVpn -eq 'Y')
    }
    If( ($ReconfigureVpn -eq 'Y') -or ($VyOSConfig['ResetVPNConfigs'] -eq $true) )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:RegionAPssKey = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigSiteA.ConnectionName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $RouterAutomationMode = $false
    }
}
#endregion


# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigSiteA.PublicIpName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
If($azpip.IpAddress -eq 'Not Assigned'){
    Write-Host ("Public IP is not assigned. Please wait 10 mins to rerun script!") -ForegroundColor Black -BackgroundColor Yellow
    Break
}

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
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication pre-shared-secret '$($Global:RegionAPssKey)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec site-to-site peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureAdvConfigSiteA.TunnelDescription)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$($VyOSExternalIP)'
"@

#combine cidr address.
$AzureCIDRSubnets = @()
$AzureCIDRSubnets += $AzureAdvConfigSiteA.VnetHubCIDRPrefix
$AzureCIDRSubnets += $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix
$i = 1
foreach ($AzureCIDR in $AzureCIDRSubnets){
    $VyOSFinal += @"
`n
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel $($i) allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel $($i) allow-public-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel $($i) local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel $($i) remote prefix '$($AzureCIDR)'
"@
    $i++
}

@"
`n
#Default route and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'
"@

foreach ($SubnetCIDR in $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name){
    $VyOSFinal += @"
`n
set protocols static route '$($SubnetCIDR.Name)' next-hop '$($azpip.IpAddress)'
"@
}

If($UseBGP){
    $VyOSFinal += @"
`n
#BGP for Azure East
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) ebgp-multihop '8'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) remote-as '$($bgpsettings.Asn)'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) soft-reconfiguration 'inbound'
"@
}

foreach ($vNetAPrefix in $vNetA.AddressSpace.AddressPrefixes){
    #use the last octet of network id as the rule id (keeps it unique)
    $RuleID = ((Get-NetworkDetails -CidrAddress $vNetAPrefix).NetworkID -replace '\.0','').split('.')[-1]
    If( ($RuleID -eq 10) -or ($RuleID -eq 100) ){$RuleID++}
    $VyOSFinal += @"
`n
set nat source rule $($RuleID) destination address '$($vNetAPrefix)'
set nat source rule $($RuleID) exclude
set nat source rule $($RuleID) outbound-interface 'eth0'
set nat source rule $($RuleID) source address '$($VyOSConfig.LocalCIDRPrefix)'
"@
}


foreach ($vNetBPrefix in $vNetB.AddressSpace.AddressPrefixes){
    #use the last octet of network id as the rule id (keeps it unique)
    $RuleID = ((Get-NetworkDetails -CidrAddress $vNetBPrefix).NetworkID -replace '\.0','').split('.')[-1]
    $VyOSFinal += @"
`n
set nat source rule $($RuleID) destination address '$($vNetBPrefix)'
set nat source rule $($RuleID) exclude
set nat source rule $($RuleID) outbound-interface 'eth0'
set nat source rule $($RuleID) source address '$($VyOSConfig.LocalCIDRPrefix)'
"@
}

If($VyOSConfig.ResetVPNConfigs){
    $VyOSFinal += @"
`n
reset vpn ipsec-peer $($azpip.IpAddress) tunnel 1
"@
}

$VyOSFinal += @"

commit
save
"@
#endregion


#region 11: Build reset vpn config
$VyOSReset = @"
restart vpn
run show ipsec vpn sa
`n
"@
#endregion

#Always output script
$ScriptName = $LogfileName.replace('.log','.script')
Remove-Item "$PSScriptRoot\Logs\$ScriptName" -Force -ErrorAction SilentlyContinue | Out-Null
$VyOSFinal | Add-Content "$PSScriptRoot\Logs\$ScriptName"
$VyOSConfig['ResetVPNConfigs'] = $False

If($RouterAutomationMode)
{
    $RunManualSteps = $false
    Write-Host "Attempting to automatically configure router's site-2-site vpn settings for region 1..." -ForegroundColor Yellow
    #region Automation Mode
    $VyOSFinalScript = New-VyattaScript -Value $VyOSFinal -AsObject -SetReboot

    #temporary set auto logon ssh keys
    New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos'

    $Result = Invoke-VyattaScript -IP $VyOSExternalIP -Path $VyOSFinalScript.Path -Verbose

    $Result

    If(!$Result){
        Write-Host "Failed to run automation script for vyos router; use manual process" -ForegroundColor Red
        $RunManualSteps = $true
    }
    Else{
        #wait for VM to boot completely
        Write-Host "Completed..." -ForegroundColor Green -NoNewline
        Write-Host "VM is rebooting" -ForegroundColor Yellow -NoNewline
        do {
            Write-Host "." -ForegroundColor Yellow -NoNewline
            Start-Sleep 3
        } until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)

        Write-Host "Ready" -ForegroundColor Green
        Write-Host "--------------------------------------------"
        Write-Host "Log into router and run [" -ForegroundColor Gray -NoNewline
        Write-Host "show vpn ipsec sa" -ForegroundColor Yellow -NoNewline
        Write-Host "]" -ForegroundColor Gray
        Write-Host "---------------------------------------------"
        $IsVpnUp = Read-host "Is the VPN tunnel up? [Y or N]"
        If($IsVpnUp -eq 'Y'){
            Write-Host "==============================================================="  -ForegroundColor Black -BackgroundColor Green
            Write-Host (" Done configuring router advanced site-2-site vpn for region 1 ")  -ForegroundColor Black -BackgroundColor Green
            Write-Host "==============================================================="  -ForegroundColor Black -BackgroundColor Green
        }Else{
            Write-Host "Automation may have failed, will attempt to fix..." -ForegroundColor Red
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

        Start-sleep 30
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.ConnectionName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
        If($currentGwConnection.ConnectionStatus -eq "Connected")
        {
            Write-Host ("{0}!" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Green
            #set to false so the next gateway setup does not delete this setup
            $VyOSConfig['ResetVPNConfigs'] = $false
        }
        Else{
            Write-Host ("{0}" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Red
            $ResetVpn = Read-host "Would you like to attempt to reset the VPN connection? [Y or N]"
            If($ResetVpn -eq 'Y'){
                Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigSiteA.ConnectionName `
                        -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Value $Global:RegionAPssKey -Force | Out-Null

                Reset-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteA.ConnectionName `
                        -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Force | Out-Null
                Start-Sleep 10
                $VyOSResetScript = New-VyattaScript -Value $VyOSReset -AsObject
                #TEST $VyOSFinalScript.value
                New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Verbose

                $Result = Invoke-VyattaScript -IP $VyOSExternalIP -Path $VyOSResetScript.Path -Verbose
                If(!$Result){
                    Write-Host "The reset may have failed on vyos router; check vpn status and use manual process if necessary" -ForegroundColor Black -BackgroundColor Red
                }
            }
            $RunManualSteps = $true
        }
    }
    #endregion
}
Else{
    $RunManualSteps = $true
}




If($RunManualSteps){
    #Output information need for local router
    Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
    Write-Host ("Azure Location:           {0}" -f $AzureAdvConfigSiteA.LocationName)
    Write-Host ("Azure Peer Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Remote Subnet Prefix:     {0}" -f $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix)
    Write-host ("Shared Key (PSK):         {0}" -f $Global:RegionAPssKey)
    Write-Host ("BGP Enabled:              {0}" -f $UseBGP.ToString())
    If($UseBGP){
        Write-Host ("BGP ASN:              {0}" -f $bgpsettings.Asn)
        Write-Host ("BGP Peering Address:  {0}" -f $bgpsettings.BgpPeeringAddress)
    }
    Write-Host ("Local Router Prefix:      {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-Host ("Local Router External:    {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-host ("Home Public IP:           {0}" -f $HomePublicIP)

    #region Copy Paste Mode
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
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
