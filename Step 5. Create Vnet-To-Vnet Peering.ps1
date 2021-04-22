$ErrorActionPreference = "Stop"
# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell

#dot source configuration file
. "$PSScriptRoot\Configs.ps1"


# connect to first tenant to setup vNET peering
Connect-AzAccount -Tenant $AzureConnections.SiteATenantID
Select-AzSubscription -Tenant $AzureConnections.SiteATenantID

$vNetA=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetHubSubnetName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
Add-AzVirtualNetworkPeering `
  -Name 'ToSiteBHub' `
  -VirtualNetwork $vNetA `
  -RemoteVirtualNetworkId "/subscriptions/$($AzureConnections.SiteBSubscriptionID)/resourceGroups//$($AzureAdvConfigSiteB.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteB.VnetHubSubnetName)" `
  -AllowGatewayTransit `
  -AllowForwardedTraffic

Clear-AzDefault


# connect to second tenant to complete vNET peering
Connect-AzAccount -Tenant $AzureConnections.SiteBTenantID
Select-AzSubscription -Tenant $AzureConnections.SiteBTenantID


$vNetB=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetHubSubnetName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
Add-AzVirtualNetworkPeering `
  -Name 'ToSiteAHub' `
  -VirtualNetwork $vNetB `
  -RemoteVirtualNetworkId "/subscriptions/$($AzureConnections.SiteASubscriptionID)/resourceGroups/$($AzureAdvConfigSiteA.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteA.VnetHubSubnetName)" `
  -AllowForwardedTraffic `
  -UseRemoteGateways

Clear-AzDefault

