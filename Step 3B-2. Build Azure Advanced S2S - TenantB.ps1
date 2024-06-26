<#
    .SYNOPSIS
        Sets up Tenant 2 Tenant VPN in Azure in Region 2

    .DESCRIPTION
        Sets up Tenant 2 Tenant VPN in Azure Region 2 using hub and spoke design

    .NOTES
        1. Gets new share key
        2. Retrieves VyOS external IP
        3. Create a resource group
        3. Create virtual network A (Hub) with gateway
        4. Create virtual network B (Spoke)
        5. Build Peering between vnets
        6. Create a Public IP address
        7. attach public ip to gateway
        8. Create the VPN gateway
        9. Create the local network gateway
        10. Update gateway transit in peering
        11. Create the VPN connection
        12. Build VyOS VPN Configuration
        13. Applies VyOS configurations
        14. Check VPN connection

        TODO:
        - Build Policy based tunneling: https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-connect-multiple-policybased-rm-ps
        - Clean routes in vyos before adding
        - Add Routetable in azure back to onprem

    .PARAMETER ConfigurationFile
    STRING

    .PARAMETER SkipVYOSSetup
    switch

    .EXAMPLE
    & '.\Step 3B-2. Build Azure Advanced S2S - Region 2.ps1 -ConfigurationFile configs-gov.ps1
#>
param(

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )

        $Configs = Get-Childitem $_ -Filter configs* | Where Extension -eq '.ps1' | Select -ExpandProperty Name

        $Configs | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("config")]
    [string]$ConfigurationFile = "configs.ps1",

    [switch]$SkipVYOSSetup
)

$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Resources,Az.Network
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
[string]$ResourcePath = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\$ConfigurationFile)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$ResourcePath\$ConfigurationFile") -ForegroundColor Yellow -NoNewline
    . "$ResourcePath\$ConfigurationFile" -NoVyosISOCheck
}
#endregion

#region start transcript
$LogfileName = "$SiteBName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$ResourcePath\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$ResourcePath\$LogfileName"}
#endregion

#Make it a global variable so it used for the entire session
#TEST $Global:RegionBSharedPSK='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'
If(!$Global:RegionBSharedPSK){$Global:RegionBSharedPSK = New-SharedPSKey}

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


# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-Tenant-to-Tenant-rm-powershell
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
#region 1. create a resource group
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureAdvConfigTenantB.ResourceGroupName) -ForegroundColor White -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureAdvConfigTenantB.ResourceGroupName -Location $AzureAdvConfigTenantB.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureAdvConfigTenantB.ResourceGroupName) -ForegroundColor Green
}
#endregion

#region 2. Create virtual network A
If(-Not($HubVnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetHubName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure hub virtual network [{0}]..." -f $AzureAdvConfigTenantB.VnetHubName) -ForegroundColor White -NoNewline
    Try{
        $HubVnet = New-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetHubName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                            -Location $AzureAdvConfigTenantB.LocationName -AddressPrefix $AzureAdvConfigTenantB.VnetHubCIDRPrefix
        #Create a subnet configuration for the hub network or gateway subnet (Vnet A)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantB.VnetHubSubnetName -VirtualNetwork $HubVnet -AddressPrefix $AzureAdvConfigTenantB.VnetHubSubnetAddressPrefix | Out-Null
        <#
        If($AddAzFirewall){
            $SubnetConfigSplat = @{
                Name='GatewaySubnet'
                VirtualNetwork=$HubVnet
                AddressPrefix=$AzureAdvConfigTenantB.VnetHubSubnetGatewayAddressPrefix
                RouteTable=$GatewayRouteTable
            }
        }
        Else{
            $SubnetConfigSplat = @{
                Name='GatewaySubnet'
                VirtualNetwork=$HubVnet
                AddressPrefix=$AzureAdvConfigTenantB.VnetHubSubnetGatewayAddressPrefix
            }
        }
        #>
        #Add-AzVirtualNetworkSubnetConfig @SubnetConfigSplat | Out-Null
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $HubVnet -AddressPrefix $AzureAdvConfigTenantB.VnetHubSubnetGatewayAddressPrefix | Out-Null

        #Add DNS Server to Vnet
        If($VyOSConfig['InternalDNSIP'].count -gt 0){
            $HubVnet.DhcpOptions.DnsServers += $VyOSConfig['InternalDNSIP']
        }

        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $HubVnet | Out-Null
    }
}
Else{
    Write-Host ("Using Azure hub virtual network [{0}]" -f $AzureAdvConfigTenantB.VnetHubName) -ForegroundColor Green
}
#endregion


#region 3. Create virtual network B
If(-Not($SpokeVnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetSpokeName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke virtual network [{0}]..." -f $AzureAdvConfigTenantB.VnetSpokeName) -ForegroundColor White -NoNewline
    Try{
        $SpokeVnet = New-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetSpokeName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                            -Location $AzureAdvConfigTenantB.LocationName -AddressPrefix $AzureAdvConfigTenantB.VnetSpokeCIDRPrefix
        #Create a subnet configuration for first VM subnet (vnet B)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantB.VnetSpokeSubnetName -VirtualNetwork $SpokeVnet `
                -AddressPrefix $AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix | Out-Null

        #Add DNS Server to Vnet
        If($VyOSConfig['InternalDNSIP'].count -gt 0){
            $SpokeVnet.DhcpOptions.DnsServers += $VyOSConfig['InternalDNSIP']
        }

        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        Set-AzVirtualNetwork -VirtualNetwork $SpokeVnet | Out-Null
    }
}
Else{
    Write-Host ("Using Azure spoke virtual network [{0}]" -f $AzureAdvConfigTenantB.VnetSpokeName) -ForegroundColor Green
}
#endregion

If(-Not($SpokeVnetNsg = Get-AzNetworkSecurityGroup -Name $AzureAdvConfigTenantB.NSGSpokeName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke network security group [{0}]..." -f $AzureAdvConfigTenantB.NSGSpokeName) -ForegroundColor White -NoNewline
    Try{
        $rule1 = New-AzNetworkSecurityRuleConfig -Name 'AllowAllOnpremTraffic' -Description "Allow all On-Premise traffic" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 4000 
                        -SourceAddressPrefix $OnPremSubnetCIDR -SourcePortRange * `
                        -DestinationAddressPrefix * -DestinationPortRange *
        <#
        $rule2 = New-AzNetworkSecurityRuleConfig -Name web-rule -Description "Allow HTTP" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 4001 `
                        -SourceAddressPrefix $OnPremSubnetCIDR -SourcePortRange * `
                        -DestinationAddressPrefix * -DestinationPortRange 80, 443
        #>
        $SpokeVnetNsg = New-AzNetworkSecurityGroup -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                        -Location $AzureAdvConfigTenantB.LocationName `
                        -Name $AzureAdvConfigTenantB.NSGSpokeName -SecurityRules $rule1 #,$rule2

        #We associate the nsg to the subnet
        Set-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantB.VnetSpokeSubnetName `
                        -VirtualNetwork $SpokeVnet -AddressPrefix $AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix `
                        -NetworkSecurityGroup $SpokeVnetNsg

        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        #Update our virtual network 
        #$SpokeVnet | Set-AzVirtualNetwork
        Set-AzVirtualNetwork -VirtualNetwork $SpokeVnet | Out-Null
    }
}
Else{
    Write-Host ("Using Azure network security group [{0}]" -f $AzureAdvConfigTenantB.NSGSpokeName) -ForegroundColor Green
}
#endregion

#region 3. Create Storage account for network troubleshooting
If(-Not($StorageAccount = Get-AzStorageAccount -Name $AzureAdvConfigTenantB.StorageAccountName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){

    Write-Host ("Creating Azure storage account [{0}]..." -f $AzureAdvConfigTenantB.StorageAccountName) -ForegroundColor White -NoNewline
    Try{
        $StorageAccount = New-AzStorageAccount -Name $AzureAdvConfigTenantB.StorageAccountName `
                            -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                            -SkuName $AzureAdvConfigTenantB.StorageSku `
                            -Location $AzureAdvConfigTenantB.LocationName -Kind Storage | Out-Null

        #create container
        [System.Object[]]$currentStorageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -Name $AzureAdvConfigTenantB.StorageAccountName
        $ctx = New-AzStorageContext -StorageAccountName $AzureAdvConfigTenantB.StorageAccountName -StorageAccountKey $currentStorageAccountKeys.value[0]
        New-AzStorageContainer -Name 'connection-network-logs' -Context $ctx | Out-Null
        
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure storage account [{0}]" -f $StorageAccount.StorageAccountName) -ForegroundColor Green
}
#endregion


#region 4. Build Peering between vnets
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
If( -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantB.VnetPeerNameAB -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -VirtualNetwork $HubVnet.Name -ErrorAction SilentlyContinue) -and `
    -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantB.VnetPeerNameBA -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -VirtualNetwork $SpokeVnet.Name -ErrorAction SilentlyContinue) )
{
    Write-Host ("Creating Peering between vents [{0}] and [{1}]..." -f $HubVnet.Name,$SpokeVnet.Name) -ForegroundColor White -NoNewline
    Try{
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantB.VnetPeerNameAB -VirtualNetwork $HubVnet -RemoteVirtualNetworkId $SpokeVnet.Id | Out-Null
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantB.VnetPeerNameBA -VirtualNetwork $SpokeVnet -RemoteVirtualNetworkId $HubVnet.Id | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Peering between Hub [{0}] and spoke [{1}] is already setup" -f $AzureAdvConfigTenantB.VnetPeerNameAB,$AzureAdvConfigTenantB.VnetPeerNameBA) -ForegroundColor Green
}
#endregion



#get vnet and gateway subnet
$vNet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetHubName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
$gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet


#region 5. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantB.PublicIpName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureAdvConfigTenantB.PublicIPName) -ForegroundColor White -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureAdvConfigTenantB.PublicIpName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                -Location $AzureAdvConfigTenantB.LocationName -AllocationMethod Static | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantB.PublicIpName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureAdvConfigTenantB.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion


#region 6. attach public ip to gateway
Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureAdvConfigTenantB.PublicIPName, 'GatewaySubnet') -ForegroundColor White -NoNewline
Try{
    #$vnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantB.VnetName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
    $gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigTenantB.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigTenantB.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
#endregion


#region 7. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantB.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureAdvConfigTenantB.VnetGatewayName) -ForegroundColor White -NoNewline
    Try{
        $VNGBGPParams=@{}
        If($UseBGP){
            $VNGBGPParams.add('Asn',$AzureAdvConfigTenantB.VnetASN)
            $VNGBGPParams.add('EnableBgp',$true)
        }
        Else{
            $VNGBGPParams.add('EnableBgp',$false)
        }

        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantB.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
            -Location $AzureAdvConfigTenantB.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 @VNGBGPParams | Out-Null
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
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureAdvConfigTenantB.VnetGatewayName) -ForegroundColor Green
}
#endregion


#region 8. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSConfig.BgpPeeringAddress)
}

If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigTenantB.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureAdvConfigTenantB.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureAdvConfigTenantB.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                -Location $AzureAdvConfigTenantB.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) @LNGBGPParams | Out-Null
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
        #Update Local network gateway's connector IP address (on-premise IP)
        New-AzLocalNetworkGateway -Name $AzureAdvConfigTenantB.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                -Location $AzureAdvConfigTenantB.LocationName -GatewayIpAddress $HomePublicIP `
                -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) @LNGBGPParams -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureAdvConfigTenantB.LocalGatewayName) -ForegroundColor Green
}
#endregion


#https://docs.microsoft.com/en-us/powershell/module/azurerm.network/set-azurermvirtualnetworkpeering?view=azurermps-6.13.0
Write-Host ("Enabling Gateway transit setting for vnet [{0}]..." -f $AzureAdvConfigTenantB.VnetPeerNameAB) -ForegroundColor White -NoNewline
Try{
    $HubvNetPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $HubVnet.Name -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -Name $AzureAdvConfigTenantB.VnetPeerNameAB
    # Change AllowGatewayTransit property
    $HubvNetPeering.AllowGatewayTransit = $True
    # Update the virtual network peering
    Set-AzVirtualNetworkPeering -VirtualNetworkPeering $HubvNetPeering | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}


Write-Host ("Enabling Remote Gateway and Traffic forwarding settings for vnet [{0}]..." -f $AzureAdvConfigTenantB.VnetPeerNameBA) -ForegroundColor White -NoNewline
Try{
    $SpokevNetPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $SpokeVnet.name -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -Name $AzureAdvConfigTenantB.VnetPeerNameBA
    # Change the UseRemoteGateways property
    $SpokevNetPeering.UseRemoteGateways = $True
    # Change value of AllowForwardedTraffic property
    $SpokevNetPeering.AllowForwardedTraffic = $True
    # Update the virtual network peering
    Set-AzVirtualNetworkPeering -VirtualNetworkPeering $SpokevNetPeering | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}


#region 9. Create the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName `
            -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -ErrorAction SilentlyContinue

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
    #create the Tenant-to-Tenant VPN connection between your virtual network gateway and your VPN device.
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantB.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigTenantB.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureAdvConfigTenantB.ConnectionName) -ForegroundColor White -NoNewline
    Try{
        #Create the connection
        If($PolicyBased){
            $ipsecpolicy = New-AzIpsecPolicy -IkeEncryption AES256 -IkeIntegrity SHA384 -DhGroup DHGroup24 -IpsecEncryption AES256 -IpsecIntegrity SHA256 -PfsGroup None -SALifeTimeSeconds 14400 -SADataSizeKilobytes 102400000
            New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                                            -Location $AzureAdvConfigTenantB.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
                                            -ConnectionType IPsec -UsePolicyBasedTrafficSelectors $True -IpsecPolicies $ipsecpolicy -SharedKey $Global:RegionASharedPSK -EnableBgp $UseBGP | Out-Null
        }
        Else{
            New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName `
                                            -Location $AzureAdvConfigTenantB.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
                                            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $Global:RegionBSharedPSK -EnableBgp $UseBGP | Out-Null
        }

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
        Write-Host "==========================================" -ForegroundColor Black -BackgroundColor Red
        Write-Host " WARNING THIS WILL BREAK REGION 1 CONFIGS " -ForegroundColor Black -BackgroundColor Red
        Write-Host "==========================================" -ForegroundColor Black -BackgroundColor Red
        $ReconfigureVpn = Read-host "Would you like to re-run the router configurations? [Y or N]"
    }
    If( ($ReconfigureVpn -eq 'Y') )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:RegionBSharedPSK = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $RouterAutomationMode = $false
    }
}
#endregion


# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantB.PublicIpName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
If($azpip.IpAddress -eq 'Not Assigned'){
    Write-Host ("Public IP is not assigned. Please wait 10 mins to rerun script!") -ForegroundColor Black -BackgroundColor Yellow
    Break
}

# Grab BGP settings form JSON
If($UseBGP){$bgpsettings = $gateway1.BgpSettingsText | ConvertFrom-Json}


#region 10. Build VyOS VPN Configuration Commands
$VyOSFinal = @"
`n
# Enter configuration mode.
configure
"@

If($VyOSConfig.ResetVPNConfigs){
    $VyOSFinal += @"
`n
#delete current configurations
delete vpn
delete protocols
delete nat
"@
}

$VyOSFinal += @"
`n
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
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) authentication mode 'pre-shared-secret'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) authentication pre-shared-secret '$($Global:RegionBSharedPSK)'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) description '$($AzureAdvConfigTenantB.TunnelDescription)'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) local-address '$($VyOSExternalIP)'
"@

#combine cidr address.
$AzureCIDRSubnets = @()
$AzureCIDRSubnets += $AzureAdvConfigTenantB.VnetHubCIDRPrefix
$AzureCIDRSubnets += $AzureAdvConfigTenantB.VnetSpokeCIDRPrefix
$i = 1
foreach ($AzureCIDR in $AzureCIDRSubnets){
    $VyOSFinal += @"
`n
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) tunnel $($i) allow-nat-networks 'disable'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) tunnel $($i) allow-public-networks 'disable'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) tunnel $($i) local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec Tenant-to-Tenant peer $($azpip.IpAddress) tunnel $($i) remote prefix '$($AzureCIDR)'
"@
    $i++
}

#Default route and blackhole route for BGP and set private ASN number
$VyOSFinal += @"
`n
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'
"@

foreach ($SubnetRoute in $AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix){
    $VyOSFinal += @"
`n
set protocols static route '$($SubnetRoute)' next-hop '$($azpip.IpAddress)'
"@
}

If($UseBGP){
    $VyOSFinal += @"
`n
#BGP for Azure $($AzureAdvConfigTenantB.LocationName)
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) ebgp-multihop '8'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) remote-as '$($bgpsettings.Asn)'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) soft-reconfiguration 'inbound'
"@
}

foreach ($SpokeVnetPrefix in $SpokeVnet.AddressSpace.AddressPrefixes){
    #use the last octet of network id as the rule id (keeps it sort of unique)
    [int32]$RuleID = ((Get-NetworkDetails -CidrAddress $HubVnetPrefix).NetworkID -replace '\.0','').split('.')[-1]
    If( ($RuleID -eq 10) -or ($RuleID -eq 100) ){$RuleID++}
    $VyOSFinal += @"
`n
set nat source rule $($RuleID) destination address '$($SpokeVnetPrefix)'
set nat source rule $($RuleID) exclude
set nat source rule $($RuleID) outbound-interface 'eth0'
set nat source rule $($RuleID) source address '$($VyOSConfig.LocalCIDRPrefix)'
"@
}

#If reset is true, all NAT configs will be delete; need to re-add this one
If($VyOSConfig.EnableNAT -and $VyOSConfig.ResetVPNConfigs){
    $VyOSLanCmd += @"
`n
#Enable NAT Configuration
set nat source rule 300 outbound-interface eth0
set nat source rule 300 source address '$($VyOSConfig.LocalCIDRPrefix)'
set nat source rule 300 translation address masquerade
"@
}

If($VyOSConfig.ResetVPNConfigs){
    $VyOSFinal += @"
`n
reset vpn ipsec-peer $($azpip.IpAddress) tunnel 1
"@
}

$VyOSFinal += @"
`n
commit
save
"@
#endregion


#region 11: Build reset vpn config
$VyOSVpnReset = @"
`n
restart vpn
run show ipsec vpn sa
`n
"@
#endregion

#Always output script
$ScriptName = $LogfileName.replace('.log','.script')
Remove-Item "$ResourcePath\Logs\$ScriptName" -Force -ErrorAction SilentlyContinue | Out-Null
$VyOSFinal | Add-Content "$ResourcePath\Logs\$ScriptName"
$VyOSConfig['ResetVPNConfigs'] = $False

If($RouterAutomationMode)
{
    $RunManualSteps = $false
    Write-Host "Attempting to automatically configure router's Tenant-2-Tenant vpn settings for region 2..." -ForegroundColor Yellow
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
            Write-Host "===============================================================" -ForegroundColor Black -BackgroundColor Green
            Write-Host " Done configuring router advanced Tenant-2-Tenant vpn for region 2 " -ForegroundColor Black -BackgroundColor Green
            Write-Host "===============================================================" -ForegroundColor Black -BackgroundColor Green
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
        Write-Host ("Checking Tenant-2-Tenant VPN tunnel connection status...") -ForegroundColor Yellow -NoNewline

        Start-sleep 30
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
        If($currentGwConnection.ConnectionStatus -eq "Connected")
        {
            Write-Host ("{0}!" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Green
            #set to false so the next gateway setup does not delete this setup
            $VyOSConfig['ResetVPNConfigs'] = $false
        }
        Else{
            Write-Host ("{0}" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Red
            $ResetVpnPrompt = Read-host "Would you like to attempt to repair the VPN connection? [Y or N]"
            If($ResetVpnPrompt -eq 'Y' -or $ResetVpnPrompt -eq 'yes'){
                Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName | 
                    Set-AzVirtualNetworkGatewayConnection -Force | Out-Null

                $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName
                If($currentGwConnection.ConnectionStatus -eq "Connected")
                {
                    Write-Host ("Resetting Preshared Key...") -ForegroundColor White -NoNewline
                    Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigTenantB.ConnectionName `
                            -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -Value $Global:RegionASharedPSK -Force | Out-Null

                    Reset-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantB.ConnectionName -ResourceGroupName $AzureAdvConfigTenantB.ResourceGroupName -Force | Out-Null
                    Write-Host ("Done") -ForegroundColor Green
                    Start-Sleep 10
                    $VyOSVpnResetScript = New-VyattaScript -Value $VyOSVpnReset -AsObject
                    #TEST $VyOSFinalScript.value
                    New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Verbose

                    $Result = Invoke-VyattaScript -IP $VyOSExternalIP -Path $VyOSVpnResetScript.Path -Verbose
                    
                    If(!$Result){
                        Write-Host "The reset may have failed on vyos router; check vpn status and use manual process if necessary" -ForegroundColor Black -BackgroundColor Red
                    }
                }
            }
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
    Write-Host ("Azure Location:           {0}" -f $AzureAdvConfigTenantB.LocationName)
    Write-Host ("Azure Peer Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Remote Subnet Prefix:     {0}" -f ($AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix -Join ','))
    Write-host ("Shared Key (PSK):         {0}" -f $Global:RegionBSharedPSK)
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
    Write-Host "Then copy the script between the lines or `n from $ResourcePath\Logs\$ScriptName" -ForegroundColor White
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "In router's ssh session, run command [" -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow -NoNewline
    Write-Host "] to reboot" -ForegroundColor Gray
    #endregion
}

Stop-Transcript
