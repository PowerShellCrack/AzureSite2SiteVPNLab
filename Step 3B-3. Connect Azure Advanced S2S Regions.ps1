<#
    .SYNOPSIS
        Connect Azure vnet to Azure vnets

    .DESCRIPTION
        Connect Azure Region 1 vnet and Region 2 vnet using VPN gateway

    .NOTES
        1. Get Region 1 gateway
        2. Get Region 2 gateway
        3. Building site-2-site VPN gateway connection to second Azure tenant gateway
        4. Building site-2-site VPN gateway connection to first Azure tenant gateway
#>
$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Resources,Az.Network
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\configs.ps1") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoVyosISOCheck
}
#endregion


#start transcript
$LogfileName = "SiteAtoBConn-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#get the East US Gateway
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteAtoBConn.VNetGatewayName1 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg1

#get the West US Gateway
$gateway2 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigSiteAtoBConn.VNetGatewayName2 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg2

# Create the links (two are needed)
Try{
    Write-Host ("Building site-2-site gateway connection to second Azure tenant gateway [{0}]" -f $AzureAdvConfigSiteAtoBConn.Connection12) -ForegroundColor White -NoNewline
    New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteAtoBConn.Connection12 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg1 `
            -VirtualNetworkGateway1 $gateway1 -VirtualNetworkGateway2 $gateway2 -Location $AzureAdvConfigSiteAtoBConn.loc1 `
            -ConnectionType Vnet2Vnet -SharedKey $Global:SharedPSK -EnableBgp $UseBGP -RoutingWeight 10 | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

Try{
    Write-Host ("Building site-2-site gateway connection to first Azure tenant gateway [{0}]" -f $AzureAdvConfigSiteAtoBConn.Connection21) -ForegroundColor White -NoNewline
    New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigSiteAtoBConn.Connection21 -ResourceGroupName $AzureAdvConfigSiteAtoBConn.rg2 `
            -VirtualNetworkGateway1 $gateway2 -VirtualNetworkGateway2 $gateway1 -Location $AzureAdvConfigSiteAtoBConn.loc2 `
            -ConnectionType Vnet2Vnet -SharedKey $Global:SharedPSK -EnableBgp $UseBGP -RoutingWeight 10
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

# check BGP ip address
If($UseBGP){
    $gateway1.BgpSettingsText
    $gateway2.BgpSettingsText
}

Write-Host "======================================" -ForegroundColor Black -BackgroundColor Green
Write-Host " Done connecting region 1 to region 2 " -ForegroundColor Black -BackgroundColor Green
Write-Host "======================================" -ForegroundColor Black -BackgroundColor Green
Stop-Transcript
