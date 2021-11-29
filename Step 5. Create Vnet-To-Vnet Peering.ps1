$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Compute,Az.Compute,Az.Resources,Az.Storage
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

# https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-configure-vnet-connections
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading configuration file first...") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoAzureCheck -NoVyosISOCheck
}
#endregion

# connect to first tenant to setup vNET peering
If( ($AzureVnetToVnetPeering.SiteATenantID -notmatch 'TenantAID') -and ($AzureVnetToVnetPeering.SiteASubscriptionID -notmatch 'SubscriptionAID') ){
  Connect-AzAccount -Tenant $AzureVnetToVnetPeering.SiteATenantID
  Select-AzSubscription -Subscription $AzureVnetToVnetPeering.SiteASubscriptionID
}
Else{
  Write-Host ("You must specify Tenant A and Subscription A Id's in [config.ps1] before continuing") -ForegroundColor Black -BackgroundColor Red
  Break
}

$vNetA=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VnetSpokeSubnetName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName
Try{
  Write-Host ("Building vnet peering to first SiteA Tenant's vnet [{0}]" -f 'ToSiteBSpoke') -ForegroundColor Yellow -NoNewline
  Add-AzVirtualNetworkPeering -Name 'ToSiteBSpoke' -VirtualNetwork $vNetA `
      -RemoteVirtualNetworkId "/subscriptions/$($AzureVnetToVnetPeering.SiteBSubscriptionID)/resourceGroups//$($AzureAdvConfigSiteB.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteB.VnetHubSubnetName)" `
      -AllowGatewayTransit -AllowForwardedTraffic | Out-Null
  Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
Finally{
  Clear-AzDefault
}

If( ($AzureVnetToVnetPeering.SiteBTenantID -notmatch 'TenantBID') -and ($AzureVnetToVnetPeering.SiteBSubscriptionID -notmatch 'SubscriptionBID') ){
  Connect-AzAccount -Tenant $AzureVnetToVnetPeering.SiteBTenantID
  Select-AzSubscription -Subscription $AzureVnetToVnetPeering.SiteBSubscriptionID
}
Else{
  Write-Host ("You must specify Tenant A and Subscription B Id's in [config.ps1] before continuing") -ForegroundColor Black -BackgroundColor Red
  Break
}

$vNetB=Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VnetSpokeSubnetName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName
Try{
  Write-Host ("Building vnet peering to first SiteA Tenant's vnet [{0}]" -f 'ToSiteASpoke') -ForegroundColor Yellow -NoNewline
  Add-AzVirtualNetworkPeering -Name 'ToSiteASpoke' -VirtualNetwork $vNetB `
          -RemoteVirtualNetworkId "/subscriptions/$($AzureVnetToVnetPeering.SiteASubscriptionID)/resourceGroups/$($AzureAdvConfigSiteA.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($AzureAdvConfigSiteA.VnetHubSubnetName)" `
          -AllowForwardedTraffic -UseRemoteGateways | Out-Null
  Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
Finally{
  Clear-AzDefault
}
