#Requires -Modules Az
# set error preference
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


#start transcript
$LogfileName = "SiteAtoBConn-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#get the East US Gateway
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteAtoBConn.VNetGatewayName1 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg1

#get the West US Gateway
$gateway2 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteAtoBConn.VNetGatewayName2 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg2

# Create the links (two are needed)
New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteAtoBConn.Connection12 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg1 `
            -VirtualNetworkGateway1 $gateway1 -VirtualNetworkGateway2 $gateway2 -Location $AzureAdvConfigSiteAtoBConn.loc1 `
            -ConnectionType Vnet2Vnet -SharedKey $sharedPSKKey -EnableBgp $UseBGP -RoutingWeight 10

New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteAtoBConn.Connection21 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg2 `
            -VirtualNetworkGateway1 $gateway2 -VirtualNetworkGateway2 $gateway1 -Location $AzureAdvConfigSiteAtoBConn.loc2 `
            -ConnectionType Vnet2Vnet -SharedKey $sharedPSKKey -EnableBgp $UseBGP -RoutingWeight 10

# check BGP ip address
If($UseBGP){
    $gateway1.BgpSettingsText
    $gateway2.BgpSettingsText
}


Stop-Transcript
