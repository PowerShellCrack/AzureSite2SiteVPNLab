<#
    .SYNOPSIS
        Sets up Azure to Azure Vnet peering

    .DESCRIPTION
        Sets up Azure to Azure Vnet peering

    .NOTES
        1.

    .PARAMETER ConfigurationFile
    STRING

    .EXAMPLE

    & '.\Step 3B-4. Connect Azure to Azure vNets.ps1 -ConfigurationFile configs-gov.ps1
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
    [string]$ConfigurationFile = "configs.ps1"
)

$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Resources,Az.Network
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\$ConfigurationFile)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\$ConfigurationFile") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\$ConfigurationFile" -NoVyosISOCheck
}
#endregion

#start transcript
$LogfileName = "VnetToVnet-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
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
  Write-Host ("Building vnet peering to first SiteA Tenant's vnet [{0}]" -f 'ToSiteBSpoke') -ForegroundColor White -NoNewline
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
  Write-Host ("Building vnet peering to first SiteA Tenant's vnet [{0}]" -f 'ToSiteASpoke') -ForegroundColor White -NoNewline
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

Write-Host "======================================" -ForegroundColor Black -BackgroundColor Green
Write-Host " Done connecting region 1 to region 2 " -ForegroundColor Black -BackgroundColor Green
Write-Host "======================================" -ForegroundColor Black -BackgroundColor Green
Stop-Transcript
