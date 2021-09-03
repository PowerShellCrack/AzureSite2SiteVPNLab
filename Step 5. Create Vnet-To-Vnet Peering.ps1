$ErrorActionPreference = "Stop"
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell

#dot source configuration file
. "$PSScriptRoot\Configs.ps1"


# connect to first tenant to setup vNET peering
Connect-AzAccount -Tenant $AzureVnetToVnetPeering.SiteATenantID
Select-AzSubscription -Tenant $AzureVnetToVnetPeering.SiteATenantID

$vNetA=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubSubnetName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
Add-AzVirtualNetworkPeering `
  -Name 'ToSiteBHub' `
  -VirtualNetwork $vNetA `
  -RemoteVirtualNetworkId "/subscriptions/$($AzureVnetToVnetPeering.SiteBSubscriptionID)/resourceGroups//$($AzureAdvConfigSiteB.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteB.VnetHubSubnetName)" `
  -AllowGatewayTransit `
  -AllowForwardedTraffic

Clear-AzDefault


# connect to second tenant to complete vNET peering
Connect-AzAccount -Tenant $AzureVnetToVnetPeering.SiteBTenantID
Select-AzSubscription -Tenant $AzureVnetToVnetPeering.SiteBTenantID


$vNetB=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubSubnetName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
Add-AzVirtualNetworkPeering `
  -Name 'ToSiteAHub' `
  -VirtualNetwork $vNetB `
  -RemoteVirtualNetworkId "/subscriptions/$($AzureVnetToVnetPeering.SiteASubscriptionID)/resourceGroups/$($AzureAdvConfigSiteA.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteA.VnetHubSubnetName)" `
  -AllowForwardedTraffic `
  -UseRemoteGateways

Clear-AzDefault

