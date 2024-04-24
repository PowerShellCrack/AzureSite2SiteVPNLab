<#
    .SYNOPSIS
        Sets up Site 2 Site VPN in Azure in Region 1

    .DESCRIPTION
        Sets up Site 2 Site VPN in Azure Region 1 using hub and spoke design

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
    & '.\Step 3B-1. Build Azure Advanced S2S - Region 1.ps1 -ConfigurationFile configs-gov.ps1
#>
param(

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )

        $Configs = Get-Childitem $_ -Filter config* | Where Extension -eq '.json' | Select -ExpandProperty Name

        $Configs | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("config")]
    [string]$ConfigurationFile = "config.json",

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
$LogfileName = "$SiteAName-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$ResourcePath\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$ResourcePath\$LogfileName"}
#endregion

#Make it a global variable so it used for the entire session
#TEST $Global:RegionASharedPSK='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'
If(!$Global:RegionASharedPSK){$Global:RegionASharedPSK = New-SharedPSKey}

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
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureAdvConfigTenantA.ResourceGroupName) -ForegroundColor White -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureAdvConfigTenantA.ResourceGroupName -Location $AzureAdvConfigTenantA.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureAdvConfigTenantA.ResourceGroupName) -ForegroundColor Green
}
#endregion


<#
# Add firewall
$Bastionsub = New-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet -AddressPrefix 10.0.0.0/27
$FWsub = New-AzVirtualNetworkSubnetConfig -Name AzureFirewallSubnet -AddressPrefix 10.0.1.0/26
$Worksub = New-AzVirtualNetworkSubnetConfig -Name Workload-SN -AddressPrefix 10.0.2.0/24


# Add routes to firewall
$GatewayRouteTable = New-AzRouteTable -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Location $AzureAdvConfigTenantA.LocationName -Name 'gateway-rt'
Add-AzRouteConfig -Name 'gateway-to-firewall' -AddressPrefix $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix -RouteTable $GatewayRouteTable `
            -NextHopType VirtualAppliance -NextHopIpAddress PRIVATE_IP_VM

#
$SpokeRouteTable = New-AzRouteTable -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Location $AzureAdvConfigTenantA.LocationName -Name 'spoke-rt'
Add-AzRouteConfig -Name 'spoke-to-firewall' -AddressPrefix 0.0.0.0/0 -RouteTable $SpokeRouteTable -NextHopType VirtualAppliance -NextHopIpAddress PRIVATE_IP_VM


#>


#region 2. Create virtual network A
If(-Not($HubVnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetHubName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure hub virtual network [{0}]..." -f $AzureAdvConfigTenantA.VnetHubName) -ForegroundColor White -NoNewline
    Try{
        $HubVnet = New-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetHubName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                        -Location $AzureAdvConfigTenantA.LocationName -AddressPrefix $AzureAdvConfigTenantA.VnetHubCIDRPrefix
        
        #Create a subnet configuration for the hub network or gateway subnet (Vnet A)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantA.VnetHubSubnetName -VirtualNetwork $HubVnet -AddressPrefix $AzureAdvConfigTenantA.VnetHubSubnetAddressPrefix | Out-Null

        <#
        If($AddAzFirewall){
            $SubnetConfigSplat = @{
                Name='GatewaySubnet'
                VirtualNetwork=$HubVnet
                AddressPrefix=$AzureAdvConfigTenantA.VnetHubSubnetGatewayAddressPrefix
                RouteTable=$GatewayRouteTable
            }
        }
        Else{
            $SubnetConfigSplat = @{
                Name='GatewaySubnet'
                VirtualNetwork=$HubVnet
                AddressPrefix=$AzureAdvConfigTenantA.VnetHubSubnetGatewayAddressPrefix
            }
        }
        #>
        #Add-AzVirtualNetworkSubnetConfig @SubnetConfigSplat | Out-Null
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $HubVnet -AddressPrefix $AzureAdvConfigTenantA.VnetHubSubnetGatewayAddressPrefix | Out-Null

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
    Write-Host ("Using Azure hub virtual network [{0}]" -f $AzureAdvConfigTenantA.VnetHubName) -ForegroundColor Green
}
#endregion



If($AzureAdvConfigTenantA.DeployBastionHost -and -Not(Get-AzBastion -Name $AzureAdvConfigTenantA.BastionHostName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue)){
    Write-Host ("Creating Bastion Host [{0}] for hub subnet [{1}]..." -f $AzureAdvConfigTenantA.BastionHostName,$AzureAdvConfigTenantA.VnetHubName) -ForegroundColor White -NoNewline
    Try{
        # Add Bastion host
        $HubVnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetHubName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
        $publicip = New-AzPublicIpAddress -Name $AzureAdvConfigTenantA.BastionPublicIPName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName  `
                        -Location $AzureAdvConfigTenantA.LocationName -AllocationMethod static -Sku standard

        New-AzBastion -Name $AzureAdvConfigTenantA.BastionHostName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -PublicIpAddress $publicip -VirtualNetwork $HubVnet -Sku Basic | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}


#region 3. Create NSG for virtual network A
If(-Not($HubVnetNsg = Get-AzNetworkSecurityGroup -Name $AzureAdvConfigTenantA.NSGHubName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Network Security Group [{0}] for hub subnet [{1}]..." -f $AzureAdvConfigTenantA.NSGHubName,$AzureAdvConfigTenantA.VnetHubName) -ForegroundColor White -NoNewline
    Try{
        $rule1 = New-AzNetworkSecurityRuleConfig -Name 'Allow443Inbound' -Description "Allow 443 traffic in" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 2000 `
                        -SourceAddressPrefix * -SourcePortRange * `
                        -DestinationAddressPrefix $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix -DestinationPortRange 443

        $rule2 = New-AzNetworkSecurityRuleConfig -Name 'AllowCertAuthInbound' -Description "Allow 49443 traffic in" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 2001 `
                        -SourceAddressPrefix * -SourcePortRange * `
                        -DestinationAddressPrefix $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix -DestinationPortRange 49443

        $HubVnetNsg = New-AzNetworkSecurityGroup -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                        -Location $AzureAdvConfigTenantA.LocationName `
                        -Name $AzureAdvConfigTenantA.NSGHubName -SecurityRules $rule1,$rule2

        #We associate the nsg to the subnet
        Set-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantA.VnetHubSubnetName `
                        -VirtualNetwork $HubVnet -AddressPrefix $AzureAdvConfigTenantA.VnetHubSubnetAddressPrefix `
                        -NetworkSecurityGroup $HubVnetNsg | Out-Null 

        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
    Finally{
        #Update our virtual network 
        #$SpokeVnet | Set-AzVirtualNetwork
        Set-AzVirtualNetwork -VirtualNetwork $HubVnet | Out-Null
    }
}
Else{
    Write-Host ("Using Azure network security group [{0}]" -f $AzureAdvConfigTenantA.NSGHubName) -ForegroundColor Green
}
#endregion

<#
# Add Bastion host
$vNet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetHubName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
$publicip = New-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Location $AzureAdvConfigTenantA.LocationName `
                    -Name bastion-pip -AllocationMethod static -Sku standard

New-AzBastion -ResourceGroupName Test-FW-RG -Name Bastion-01 -PublicIpAddress $publicip -VirtualNetwork $vNet

#>


#region 3. Create virtual network B
#TODO
#build subnet loop to incorporate multiple subnets
If(-Not($SpokeVnet = Get-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetSpokeName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke virtual network [{0}]..." -f $AzureAdvConfigTenantA.VnetSpokeName) -ForegroundColor White -NoNewline
    Try{
        $SpokeVnet = New-AzVirtualNetwork -Name $AzureAdvConfigTenantA.VnetSpokeName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                            -Location $AzureAdvConfigTenantA.LocationName -AddressPrefix $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix
        #Create a subnet configuration for first VM subnet (vnet B)
        Add-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantA.VnetSpokeSubnetName -VirtualNetwork $SpokeVnet `
                -AddressPrefix $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix -RouteTable $RouteTable | Out-Null

        # Add Additional Subnets
        #Add-AzVirtualNetworkSubnetConfig -Name 'AzureBastionSubnet' -VirtualNetwork $SpokeVnet `
        #                -AddressPrefix $AzureAdvConfigTenantA.VnetSpokeBastionAddressPrefix | Out-Null

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
    Write-Host ("Using Azure spoke virtual network [{0}]" -f $AzureAdvConfigTenantA.VnetSpokeName) -ForegroundColor Green
}
#endregion


<# Check DNS Server
Try{
    Write-Host (Adding DNS servers virtual network [{0}]..." -f $AzureAdvConfigTenantA.VnetSpokeName) -ForegroundColor White -NoNewline
    Foreach($DNSIP in $VyOSConfig['InternalDNSIP']){
        #add dns servers to vnet
        If($DNSIP -notin $SpokeVnet.DhcpOptions.DnsServers){
            $SpokeVnet.DhcpOptions.DnsServers += $DNSIP
        }
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
#>

#region 4. Build Peering between vnets
#https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
If(-Not($SpokeVnetNsg = Get-AzNetworkSecurityGroup -Name $AzureAdvConfigTenantA.NSGSpokeName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure spoke network security group [{0}]..." -f $AzureAdvConfigTenantA.NSGSpokeName) -ForegroundColor White -NoNewline
    Try{
        $rule1 = New-AzNetworkSecurityRuleConfig -Name 'AllowAllOnpremTraffic' -Description "Allow all On-Premise traffic" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 4000 `
                        -SourceAddressPrefix $OnPremSubnetCIDR -SourcePortRange * `
                        -DestinationAddressPrefix * -DestinationPortRange *
        <#
        $rule2 = New-AzNetworkSecurityRuleConfig -Name web-rule -Description "Allow HTTP" `
                        -Access Allow -Protocol Tcp -Direction Inbound -Priority 4001 `
                        -SourceAddressPrefix $OnPremSubnetCIDR -SourcePortRange * `
                        -DestinationAddressPrefix * -DestinationPortRange 80, 443
        #>
        $SpokeVnetNsg = New-AzNetworkSecurityGroup -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                        -Location $AzureAdvConfigTenantA.LocationName `
                        -Name $AzureAdvConfigTenantA.NSGSpokeName -SecurityRules $rule1 #,$rule2

        #We associate the nsg to the subnet
        Set-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigTenantA.VnetSpokeSubnetName `
                        -VirtualNetwork $SpokeVnet -AddressPrefix $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix `
                        -NetworkSecurityGroup $SpokeVnetNsg | Out-Null 

        

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
    Write-Host ("Using Azure network security group [{0}]" -f $AzureAdvConfigTenantA.NSGSpokeName) -ForegroundColor Green
}
#endregion


#region 3. Create Storage account for network troubleshooting
If(-Not($StorageAccount = Get-AzStorageAccount -Name $AzureAdvConfigTenantA.StorageAccountName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){

    Write-Host ("Creating Azure storage account [{0}]..." -f $AzureAdvConfigTenantA.StorageAccountName) -ForegroundColor White -NoNewline
    Try{
        $StorageAccount = New-AzStorageAccount -Name $AzureAdvConfigTenantA.StorageAccountName `
                            -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                            -SkuName $AzureAdvConfigTenantA.StorageSku `
                            -Location $AzureAdvConfigTenantA.LocationName -Kind Storage | Out-Null

        #create container
        [System.Object[]]$currentStorageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Name $AzureAdvConfigTenantA.StorageAccountName
        $ctx = New-AzStorageContext -StorageAccountName $AzureAdvConfigTenantA.StorageAccountName -StorageAccountKey $currentStorageAccountKeys.value[0]
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
If( -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantA.VnetPeerNameAB -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -VirtualNetwork $HubVnet.Name -ErrorAction SilentlyContinue) -and `
    -Not(Get-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantA.VnetPeerNameBA -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -VirtualNetwork $SpokeVnet.Name -ErrorAction SilentlyContinue) ){

    Write-Host ("Creating Peering between vnets [{0}] and [{1}]..." -f $HubVnet.Name,$SpokeVnet.Name) -ForegroundColor White -NoNewline
    try {
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantA.VnetPeerNameAB -VirtualNetwork $HubVnet -RemoteVirtualNetworkId $SpokeVnet.Id -ErrorAction SilentlyContinue
        Add-AzVirtualNetworkPeering -Name $AzureAdvConfigTenantA.VnetPeerNameBA -VirtualNetwork $SpokeVnet -RemoteVirtualNetworkId $HubVnet.Id -ErrorAction SilentlyContinue
        Write-Host "Done" -ForegroundColor Green
    }
    catch {
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
#endregion

#region 5. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantA.PublicIpName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureAdvConfigTenantA.PublicIPName) -ForegroundColor White -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureAdvConfigTenantA.PublicIpName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                -Location $AzureAdvConfigTenantA.LocationName -AllocationMethod Static | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantA.PublicIpName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureAdvConfigTenantA.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion


#region 6. attach public ip to gateway
Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureAdvConfigTenantA.PublicIPName, 'GatewaySubnet') -ForegroundColor White -NoNewline
Try{
    $gwsubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $HubVnet
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigTenantA.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

# get a public ip for the gateway
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureAdvConfigTenantA.VnetGatewayIpConfigName -SubnetId $gwsubnet.Id -PublicIpAddressId $azpip.Id
#endregion





#region 7. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantA.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureAdvConfigTenantA.VnetGatewayName) -ForegroundColor White -NoNewline
    Try{
        $VNGBGPParams=@{}
        If($UseBGP){
            $VNGBGPParams.add('Asn',$AzureAdvConfigTenantA.VnetASN)
            $VNGBGPParams.add('EnableBgp',$true)
        }
        Else{
            $VNGBGPParams.add('EnableBgp',$false)
        }

        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantA.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
            -Location $AzureAdvConfigTenantA.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 @VNGBGPParams | Out-Null
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
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureAdvConfigTenantA.VnetGatewayName) -ForegroundColor Green
}
#endregion


#region 8. Setup LNG connection
$LNGBGPParams=@{}
If($UseBGP){
    $LNGBGPParams.add('Asn',$VyOSConfig.BgpAsn)
    $LNGBGPParams.add('BgpPeeringAddress',$VyOSConfig.BgpPeeringAddress)
}

If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigTenantA.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureAdvConfigTenantA.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureAdvConfigTenantA.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                -Location $AzureAdvConfigTenantA.LocationName -GatewayIpAddress $Config.PublicIP -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) @LNGBGPParams | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
ElseIf($Local.GatewayIpAddress -ne $Config.PublicIP)
{
    Try{
        Write-Host ("Updating the local network gateway with ip [{0}]" -f $Config.PublicIP) -ForegroundColor Yellow -NoNewline
        #Update Local network gratway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureAdvConfigTenantA.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                -Location $AzureAdvConfigTenantA.LocationName -GatewayIpAddress $Config.PublicIP `
                -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) @LNGBGPParams -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureAdvConfigTenantA.LocalGatewayName) -ForegroundColor Green
}
#endregion


#https://docs.microsoft.com/en-us/powershell/module/azurerm.network/set-azurermvirtualnetworkpeering?view=azurermps-6.13.0
Write-Host ("Enabling Gateway transit setting for vnet [{0}]..." -f $AzureAdvConfigTenantA.VnetPeerNameAB) -ForegroundColor White -NoNewline
Try{
    $HubVnetPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $HubVnet.Name -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Name $AzureAdvConfigTenantA.VnetPeerNameAB
    # Change AllowGatewayTransit property
    $HubVnetPeering.AllowGatewayTransit = $True
    # Update the virtual network peering
    Set-AzVirtualNetworkPeering -VirtualNetworkPeering $HubVnetPeering | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}


Write-Host ("Enabling Remote Gateway and Traffic forwarding settings for vnet [{0}]..." -f $AzureAdvConfigTenantA.VnetPeerNameBA) -ForegroundColor White -NoNewline
Try{
    $SpokevNetPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $SpokeVnet.name -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Name $AzureAdvConfigTenantA.VnetPeerNameBA
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
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName `
            -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -ErrorAction SilentlyContinue

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
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantA.VnetGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureAdvConfigTenantA.LocalGatewayName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureAdvConfigTenantA.ConnectionName) -ForegroundColor White -NoNewline
    Try{
        #Create the connection
        If($PolicyBased){
            $ipsecpolicy = New-AzIpsecPolicy -IkeEncryption AES256 -IkeIntegrity SHA384 -DhGroup DHGroup24 -IpsecEncryption AES256 -IpsecIntegrity SHA256 -PfsGroup None -SALifeTimeSeconds 14400 -SADataSizeKilobytes 102400000
            New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                                            -Location $AzureAdvConfigTenantA.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
                                            -ConnectionType IPsec -UsePolicyBasedTrafficSelectors $True -IpsecPolicies $ipsecpolicy -SharedKey $Global:RegionASharedPSK -EnableBgp $UseBGP | Out-Null
        }
        Else{
            New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName `
                                            -Location $AzureAdvConfigTenantA.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
                                            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $Global:RegionASharedPSK -EnableBgp $UseBGP | Out-Null
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
        Write-Host " WARNING THIS WILL BREAK OTHER S2S CONFIGS" -ForegroundColor Black -BackgroundColor Red
        Write-Host "==========================================" -ForegroundColor Black -BackgroundColor Red
        $ReconfigureVpn = Read-host "Would you like to re-run the router configurations? [Y or N]"
    }
    If( ($ReconfigureVpn -eq 'Y') -or ($VyOSConfig['ResetVPNConfigs'] -eq $true) )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:RegionASharedPSK = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $Configs.RouterConfigs.AutomationMode = $false
    }
}
#endregion


# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureAdvConfigTenantA.PublicIpName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
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
delete vpn ipsec
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
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication pre-shared-secret '$($Global:RegionASharedPSK)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec site-to-site peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureAdvConfigTenantA.TunnelDescription)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$($VyOSExternalIP)'
"@

#combine cidr address.
$AzureCIDRSubnets = @()
$AzureCIDRSubnets += $AzureAdvConfigTenantA.VnetHubCIDRPrefix
$AzureCIDRSubnets += $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix
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

#Default route and blackhole route for BGP and set private ASN number
$VyOSFinal += @"
`n
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'
"@

foreach ($SubnetRoute in $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix){
    $VyOSFinal += @"
`n
set protocols static route '$($SubnetRoute)' next-hop '$($azpip.IpAddress)'
"@
}

If($UseBGP){
    $VyOSFinal += @"
`n
#BGP for Azure $($AzureAdvConfigTenantA.LocationName)
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) ebgp-multihop '8'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) remote-as '$($bgpsettings.Asn)'
set protocols bgp $($VyOSConfig.BgpAsn) neighbor $($bgpsettings.BgpPeeringAddress) soft-reconfiguration 'inbound'
"@
}

foreach ($HubVnetPrefix in $HubVnet.AddressSpace.AddressPrefixes){
    #use the last octet of network id as the rule id (keeps it sort of unique)
    [int32]$RuleID = ((Get-NetworkDetails -CidrAddress $HubVnetPrefix).NetworkID -replace '\.0','').split('.')[-1]
    If( ($RuleID -eq 10) -or ($RuleID -eq 100) ){$RuleID++}
    $VyOSFinal += @"
`n
set nat source rule $($RuleID) destination address '$($HubVnetPrefix)'
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

If($Configs.RouterConfigs.AutomationMode)
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
            Write-Host "===============================================================" -ForegroundColor Black -BackgroundColor Green
            Write-Host " Done configuring router advanced site-2-site vpn for region 1 " -ForegroundColor Black -BackgroundColor Green
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
        Write-Host ("Checking Site-2-Site VPN tunnel connection status...") -ForegroundColor Yellow -NoNewline

        Start-sleep 30
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
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
                Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName | 
                    Set-AzVirtualNetworkGatewayConnection -Force | Out-Null

                $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName
                If($currentGwConnection.ConnectionStatus -eq "Connected")
                {
                    Write-Host ("Resetting Preshared Key...") -ForegroundColor White -NoNewline
                    Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureAdvConfigTenantA.ConnectionName `
                            -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Value $Global:RegionASharedPSK -Force | Out-Null

                    Reset-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantA.ConnectionName -ResourceGroupName $AzureAdvConfigTenantA.ResourceGroupName -Force | Out-Null
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
    Write-Host ("Azure Location:           {0}" -f $AzureAdvConfigTenantA.LocationName)
    Write-Host ("Azure Peer Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Remote Subnet Prefix:     {0}" -f ($AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix -join ','))
    Write-host ("Shared Key (PSK):         {0}" -f $Global:RegionASharedPSK)
    Write-Host ("BGP Enabled:              {0}" -f $UseBGP.ToString())
    If($UseBGP){
        Write-Host ("BGP ASN:              {0}" -f $bgpsettings.Asn)
        Write-Host ("BGP Peering Address:  {0}" -f $bgpsettings.BgpPeeringAddress)
    }
    Write-Host ("Local Router Prefix:      {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-Host ("Local Router External:    {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-host ("Home Public IP:           {0}" -f $Config.PublicIP)

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
