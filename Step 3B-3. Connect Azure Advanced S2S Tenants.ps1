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
        
    .PARAMETER ConfigurationFile
    STRING

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
$LogfileName = "TenantAtoBConn-AdvSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#get the Site A Gateway
$gateway1 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantAtoBConn.VNetGatewayName1 -ResourceGroupName $AzureAdvConfigTenantAtoBConn.rg1

#get the Site B Gateway
$gateway2 = Get-AzVirtualNetworkGateway -Name $AzureAdvConfigTenantAtoBConn.VNetGatewayName2 -ResourceGroupName $AzureAdvConfigTenantAtoBConn.rg2

# Create the links (two are needed)
Try{
    Write-Host ("Building site-2-site gateway connection to second Azure tenant gateway [{0}]" -f $AzureAdvConfigTenantAtoBConn.Connection12) -ForegroundColor White -NoNewline
    New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantAtoBConn.Connection12 -ResourceGroupName $AzureAdvConfigTenantAtoBConn.rg1 `
            -VirtualNetworkGateway1 $gateway1 -VirtualNetworkGateway2 $gateway2 -Location $AzureAdvConfigTenantAtoBConn.loc1 `
            -ConnectionType Vnet2Vnet -SharedKey $Global:SharedPSK -EnableBgp $UseBGP -RoutingWeight 10 | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}

Try{
    Write-Host ("Building site-2-site gateway connection to first Azure tenant gateway [{0}]" -f $AzureAdvConfigTenantAtoBConn.Connection21) -ForegroundColor White -NoNewline
    New-AzVirtualNetworkGatewayConnection -Name $AzureAdvConfigTenantAtoBConn.Connection21 -ResourceGroupName $AzureAdvConfigTenantAtoBConn.rg2 `
            -VirtualNetworkGateway1 $gateway2 -VirtualNetworkGateway2 $gateway1 -Location $AzureAdvConfigTenantAtoBConn.loc2 `
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
