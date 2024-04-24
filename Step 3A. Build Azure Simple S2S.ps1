<#
    .SYNOPSIS
        Sets up Site 2 Site VPN in Azure

    .DESCRIPTION
        Sets up Site 2 Site VPN in Azure with 1 gateway and subnet (no hub and spoke)

    .NOTES
        1. Gets new share key
        2. Retrieves VyOS external IP
        3. Create a resource group
        4. Build subnets configurations
        5. Create the VNet; bind subnets
        6. Attach gateway to vnet
        7. Create the local network gateway
        8. Create a Public IP address
        9. Attaches public IP to gateway
        10. Create the Virtual Network Gateway
        11. Create the local network gateway
        12. Create the VPN connection
        13. Build VyOS VPN Configuration
        14. Applies VyOS configurations
        15. Check VPN connection

    .PARAMETER ConfigurationFile
    STRING

    .EXAMPLE

    & '.\Step 3A. Build Azure Simple S2S.ps1 -ConfigurationFile configs-gov.ps1
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

#region start transcript
$LogfileName = "$SiteName-AzureSimpleS2S-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#Make it a global variable so it used for the entire session
#TEST $Global:SharedPSK='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'
If(!$Global:SharedPSK){$Global:SharedPSK = New-SharedPSKey}

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


#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell
#region 1. Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor White -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor Green
}
#endregion


#region 2. Configure subnets
Write-Host ("Building Azure subnets configurations for both gateway subnet [{0}] and subnets [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetSubnetPrefix) -ForegroundColor White -NoNewline
Try{
    $subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix
    $subnet2 = New-AzVirtualNetworkSubnetConfig -Name $AzureSimpleConfig.DefaultSubnetName -AddressPrefix $AzureSimpleConfig.VnetSubnetPrefix
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}
#endregion

#region 3. Create the VNet
If(-Not($vNet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{

    Write-Host ("Creating Azure virtual network [{0}]..." -f $AzureSimpleConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        New-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -AddressPrefix $AzureSimpleConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }

}
ElseIf( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet).count -lt 2){
    Write-Host ("vNET is missing subnets. Recreating Azure virtual network [{0}]..." -f $AzureSimpleConfig.VnetName) -ForegroundColor Yellow -NoNewline
    Try{
        New-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -AddressPrefix $AzureSimpleConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure virtual network [{0}]" -f $AzureSimpleConfig.VnetName) -ForegroundColor Green
}
#endregion


#region 4. Attach gateway to vnet
$vNet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
# add gateway prefix if not already exists
If( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet | Where Name -eq 'GatewaySubnet').AddressPrefix -ne $AzureSimpleConfig.VnetGatewayPrefix )
{
    Write-Host ("Attaching Azure gateway subnet [{0}] to virtual network [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix -VirtualNetwork $vNet | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}

Set-AzVirtualNetwork -VirtualNetwork $vNet | Out-Null
#endregion

#region 5. Create the local network gateway
#add a local network gateway with a single address prefix:
If( -Not(Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-Host ("Creating Azure local network gateway [{0}]..." -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        #New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
        #            -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix | Out-Null

        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                    -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP `
                    -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor Green
}
#endregion

#region 6. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureSimpleConfig.PublicIpName) -ForegroundColor White -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                        -Location $AzureSimpleConfig.LocationName -AllocationMethod Static | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureSimpleConfig.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion

#region 7. Attaches public IP to gateway
If( $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet -ErrorAction SilentlyContinue )
{
    Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureSimpleConfig.PublicIpName, 'GatewaySubnet') -ForegroundColor White -NoNewline
    Try{
        #$vNet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureSimpleConfig.VnetGatewayIpConfigName -SubnetId $subnet.Id -PublicIpAddressId $azpip.Id
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("No gateway subnet was found [{0}]" -f $AzureSimpleConfig.VnetGatewayIpConfigName) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion

#region 8. Create the Virtual Network Gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureSimpleConfig.VnetGatewayName) -ForegroundColor White -NoNewline
    Try{
        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 | Out-Null
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
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureSimpleConfig.VnetGatewayName) -ForegroundColor Green
}
#endregion

#region 9. Create the Local Network Gateway
If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalSubnetPrefix.keys | Out-Null
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
        #Update Local network gratway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalSubnetPrefix.keys -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor Green
}
#endregion


#region 9. Create the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName `
            -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue

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
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureSimpleConfig.ConnectionName) -ForegroundColor White -NoNewline
    Try{
        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $Global:SharedPSK -Force | Out-Null
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
        $ReconfigureVpn = Read-host "Would you like to re-run the router configurations? [Y or N]"
    }

    If( ($ReconfigureVpn -eq 'Y') -or ($VyOSConfig['ResetVPNConfigs'] -eq $true) )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:SharedPSK = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $RouterAutomationMode = $false
    }
}
#endregion

# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
If($azpip.IpAddress -eq 'Not Assigned'){
    Write-Host ("Public IP is not assigned. Please wait 10 mins to rerun script!") -ForegroundColor Black -BackgroundColor Yellow
    Break
}

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
delete protocols bgp
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
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication pre-shared-secret '$($Global:SharedPSK)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec site-to-site peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureSimpleConfig.TunnelDescription) ($($AzureAdvConfigTenantA.LocationName))'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$($VyOSExternalIP)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 remote prefix '$($AzureSimpleConfig.VnetSubnetPrefix)'
"@

#Default route and blackhole route for BGP and set private ASN number
$VyOSFinal += @"
`n
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'
set protocols static route '$($AzureSimpleConfig.VnetSubnetPrefix)' next-hop '$($azpip.IpAddress)'
"@

foreach ($vNetPrefix in $vNet.AddressSpace.AddressPrefixes){
    #use the last octet of network id as the rule id (keeps it unique)
    [int32]$RuleID = ((Get-NetworkDetails -CidrAddress $vNetPrefix).NetworkID -replace '\.0','').split('.')[-1]
    If( ($RuleID -eq 10) -or ($RuleID -eq 100) ){$RuleID++}
    $VyOSFinal += @"
`n
set nat source rule $($RuleID) destination address '$($vNetPrefix)'
set nat source rule $($RuleID) exclude
set nat source rule $($RuleID) outbound-interface 'eth0'
set nat source rule $($RuleID) source address '$($VyOSConfig.LocalCIDRPrefix)'
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
$VyOSReset = @"
`n
restart vpn
run show ipsec vpn sa
`n
"@
#endregion

#Always output script
$ScriptName = $LogfileName.replace('.log','.script')
Remove-Item "$PSScriptRoot\Logs\$ScriptName" -Force -ErrorAction SilentlyContinue | Out-Null
$VyOSFinal | Add-Content "$PSScriptRoot\Logs\$ScriptName"
$VyOSConfig['ResetVPNConfigs'] = $False

If($RouterAutomationMode)
{
    $RunManualSteps = $false
    Write-Host "Attempting to automatically configure router's site-2-site vpn settings..." -ForegroundColor Yellow
    #region Automation Mode
    $VyOSFinalScript = New-VyattaScript -Value $VyOSFinal -AsObject -SetReboot
    #TEST $VyOSFinalScript.value
    #temporary set auto logon ssh keys
    New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Verbose

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
            Write-Host "=========================================" -ForegroundColor Black -BackgroundColor Green
            Write-Host " Done configuring router site-2-site vpn " -ForegroundColor Black -BackgroundColor Green
            Write-Host "=========================================" -ForegroundColor Black -BackgroundColor Green
        }
        Else{
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
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        If($currentGwConnection.ConnectionStatus -eq "Connected")
        {
            Write-Host ("{0}!" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Green
            #set to false so the next gateway setup does not delete this setup
            $VyOSConfig['ResetVPNConfigs'] = $false
        }
        Else{
            Write-Host ("{0}" -f $currentGwConnection.ConnectionStatus) -ForegroundColor Red
            $ResetVpn = Read-host "Would you like to attempt to reset the VPN connection? [Y or N]"
            If($ResetVpn -eq 'Y'){
                Write-Host ("Resetting VPN's shared key for connection [{0}]..." -f $AzureSimpleConfig.ConnectionName) -ForegroundColor White -NoNewline
                Try{
                    Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureSimpleConfig.ConnectionName `
                            -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Value $Global:SharedPSK -Force | Out-Null

                    Reset-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName `
                            -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Force | Out-Null

                    Write-Host "Done" -ForegroundColor Green
                }
                Catch{
                    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
                    Break
                }
                Finally{
                    Start-Sleep 10
                }
                $VyOSResetScript = New-VyattaScript -Value $VyOSReset -AsObject
                #TEST $VyOSFinalScript.value
                New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Verbose

                $Result = Invoke-VyattaScript -IP $VyOSExternalIP -Path $VyOSResetScript.Path -Verbose
                If(!$Result){
                    Write-Host "The reset may have failed on vyos router; check vpn status and use manual process if necessary" -ForegroundColor Black -BackgroundColor Red
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


#Run manual mode if automation steps fail or is not enabled
If($RunManualSteps)
{
    #Output information need for local router
    Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
    Write-Host ("Azure Location:      {0}" -f $AzureSimpleConfig.LocationName)
    Write-Host ("Azure Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Azure Subnet Prefix: {0}" -f $AzureSimpleConfig.VnetSubnetPrefix)
    Write-host ("Shared Key (PSK):    {0}" -f $Global:SharedPSK)
    Write-host ("Home Public IP:      {0}" -f $HomePublicIP)
    Write-Host ("Router CIDR Prefix:  {0}" -f $VyOSConfig.LocalCIDRPrefix)

    #region Copy Paste Mode
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName) by running command [" -ForegroundColor White -NoNewline
    Write-Host ("ssh vyos@{0}" -f $VyOSExternalIP) -ForegroundColor Yellow -NoNewline
    Write-Host "]" -ForegroundColor White
    Write-Host "Then copy the script between the lines or `n from $PSScriptRoot\Logs\$ScriptName" -ForegroundColor White
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "In router's ssh session, run command [" -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow -NoNewline
    Write-Host "] to reboot" -ForegroundColor Gray
    #endregion
}

Stop-Transcript
