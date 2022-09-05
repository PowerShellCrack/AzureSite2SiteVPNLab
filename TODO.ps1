

<#
# Add firewall
$Bastionsub = New-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet -AddressPrefix 10.0.0.0/27
$FWsub = New-AzVirtualNetworkSubnetConfig -Name AzureFirewallSubnet -AddressPrefix 10.0.1.0/26
$Worksub = New-AzVirtualNetworkSubnetConfig -Name Workload-SN -AddressPrefix 10.0.2.0/24


# Add routes to firewall
$GatewayRouteTable = New-AzRouteTable -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -Name 'gateway-rt'
Add-AzRouteConfig -Name 'gateway-to-firewall' -AddressPrefix $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix -RouteTable $GatewayRouteTable `
            -NextHopType VirtualAppliance -NextHopIpAddress PRIVATE_IP_VM

#
$SpokeRouteTable = New-AzRouteTable -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -Name 'spoke-rt'
Add-AzRouteConfig -Name 'spoke-to-firewall' -AddressPrefix 0.0.0.0/0 -RouteTable $SpokeRouteTable -NextHopType VirtualAppliance -NextHopIpAddress PRIVATE_IP_VM
#>


<#
# Add Bastion host
$vNet = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
$publicip = New-AzPublicIpAddress -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName `
                    -Name bastion-pip -AllocationMethod static -Sku standard

New-AzBastion -ResourceGroupName Test-FW-RG -Name Bastion-01 -PublicIpAddress $publicip -VirtualNetwork $vNet

#>
#build subnet loop to incorporate multiple subnets



<# Check DNS Server
Try{
    Write-Host (Adding DNS servers virtual network [{0}]..." -f $AzureAdvConfigSiteA.VnetSpokeName) -ForegroundColor White -NoNewline
    Foreach($DNSIP in $VyOSConfig['InternalDNSIP']){
        #add dns servers to vnet
        If($DNSIP -notin $vNetB.DhcpOptions.DnsServers){
            $vNetB.DhcpOptions.DnsServers += $DNSIP
        }
    }
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
Finally{
    Set-AzVirtualNetwork -VirtualNetwork $vNetB | Out-Null
}
#>
