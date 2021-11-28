$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Compute,Az.Compute,Az.Resources,Az.Storage
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null


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

#region start transcript
$LogfileName = "$RegionName-AzureSimpleS2S-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}
#endregion

#grab external interface for VyOS router
If($null -ne $VyOSConfig.ExternalInterfaceIP){
    $VyOSExternalIP = $VyOSConfig.ExternalInterfaceIP
}
ElseIf(Test-Path "$env:temp\VyOSextip.txt"){
    $VyOSExternalIP = Get-Content "$env:temp\VyOSextip.txt"
}
Else{
    $VyOSExternalIP = Read-host "Whats the VyOS interface '$($VyOSConfig.ExternalInterface)' IP (eg. '192.168.1.36')"
}
$VyOSConfig.Add('ExternalInterfaceIP',$VyOSExternalIP)


#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell
#region 1. Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureSimpleConfig.ResourceGroupName) -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor Green
}
#endregion


#region 2. Configure subnets
Write-Host ("Building Azure subnets configurations for both gateway subnet [{0}] and subnets [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetSubnetPrefix) -NoNewline
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
If(-Not(Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure virtual network [{0}]..." -f $AzureSimpleConfig.VnetName) -NoNewline
    Try{
        New-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -AddressPrefix $AzureSimpleConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host ("Using Azure virtual network [{0}]" -f $AzureSimpleConfig.VnetName) -ForegroundColor Green
}
#endregion


#region 4. Attach gateway to vnet
$vnet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
# add gateway prefix if not already exists
If( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet | Where Name -eq 'GatewaySubnet').AddressPrefix -ne $AzureSimpleConfig.VnetGatewayPrefix )
{
    Write-Host ("Attaching Azure gateway subnet [{0}] to virtual network [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetName) -NoNewline
    Try{
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix -VirtualNetwork $vnet | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}

Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
#endregion

#region 5. Create the local network gateway
#add a local network gateway with a single address prefix:
If( -Not(Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-Host ("Creating Azure local network gateway [{0}]..." -f $AzureSimpleConfig.LocalGatewayName) -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                    -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor Green
}
#endregion

#region 6. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureSimpleConfig.PublicIpName) -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                        -Location $AzureSimpleConfig.LocationName -AllocationMethod Dynamic | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureSimpleConfig.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion

#region 7. make the gateway
If( $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet -ErrorAction SilentlyContinue )
{
    Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureSimpleConfig.PublicIpName, 'GatewaySubnet') -NoNewline
    Try{
        #$vnet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureSimpleConfig.VnetGatewayIpConfigName -SubnetId $subnet.Id -PublicIpAddressId $azpip.Id
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Redd
    }
}
Else{
    Write-Host ("No gateway subnet was found [{0}]" -f $AzureSimpleConfig.VnetGatewayIpConfigName) -ForegroundColor Red
    Break
}
#endregion

#region 8. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureSimpleConfig.VnetGatewayName) -NoNewline
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
    }
}
Else{
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureSimpleConfig.VnetGatewayName) -ForegroundColor Green
}
#endregion

#region 9. Create the VPN connection
<#If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Create the VPN connection for [{0}]..." -f $AzureSimpleConfig.ConnectionName) -NoNewline
    Try{
        #create the Site-to-Site VPN connection between your virtual network gateway and your VPN device.
        $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName

        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
ElseIf($Local.GatewayIpAddress -ne $HomePublicIP)
{
    Try{
        Write-Host ("Updating the local network gateway with ip [{0}]" -f $HomePublicIP) -ForegroundColor Yellow -NoNewline
        #Update Local network gateway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureSimpleConfig.LocalGatewayName) -ForegroundColor Green
}

#>

If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureSimpleConfig.LocalGatewayName) -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
ElseIf($Local.GatewayIpAddress -ne $HomePublicIP)
{
    Try{
        Write-Host ("Updating the local network gateway with ip [{0}]" -f $HomePublicIP) -ForegroundColor Yellow -NoNewline
        #Update Local network gratway's connector IP address (onpremise IP)
        New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
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

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureSimpleConfig.ConnectionName) -NoNewline
    Try{
        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
Else{
    Write-Host ("Gateway is not connected! ") -ForegroundColor Red -NoNewline
    If($VyOSConfig['ResetVPNConfigs'] -eq $false){
        do {
            #cls
            $response1 = Read-host "Would you like to re-run the router configurations? [Y or N]"
        } until ($response1 -eq 'Y')
    }
    If( ($response1 -eq 'Y') -or ($VyOSConfig['ResetVPNConfigs'] -eq $true) )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:sharedPSKKey = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $RouterAutomationMode = $false
    }
}
#endregion

# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName


#region 10. Build VyOS VPN Configuration Commands
$VyOSFinal = @"
# Enter configuration mode.
configure
`n
"@

If($VyOSConfig.ResetVPNConfigs){
    $VyOSFinal += @"
#delete current configurations
delete vpn ipsec
delete protocols bgp
`n
"@
}

$VyOSFinal += @"
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
set vpn ipsec site-to-site peer $($azpip.IpAddress) authentication pre-shared-secret '$Global:sharedPSKKey'
set vpn ipsec site-to-site peer $($azpip.IpAddress) connection-type 'initiate'
set vpn ipsec site-to-site peer $($azpip.IpAddress) default-esp-group 'azure'
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureSimpleConfig.TunnelDescription)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 remote prefix '$($AzureSimpleConfig.VnetSubnetPrefix)'

#Default route and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'

"@

$VyOSFinal += @"

commit
save
"@
#endregion


#region 11: Build reset vpn config
$VyOSReset = @"
restart vpn
run show ipsec vpn sa
`n
"@
#endregion

#Always output script
$ScriptName = $LogfileName.replace('.log','.script')
$VyOSFinal -split '\n' | %{$_ | Set-Content "$PSScriptRoot\Logs\$ScriptName"}
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
            Write-Host "." -NoNewline
            Start-Sleep 3
        } until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)

        Write-Host "Ready" -ForegroundColor Green
        Write-Host "--------------------------------------------"
        Write-Host "Log into router and run [" -ForegroundColor Gray -NoNewline
        Write-Host "show vpn ipsec sa" -ForegroundColor Yellow -NoNewline
        Write-Host "]" -ForegroundColor Gray
        Write-Host "---------------------------------------------"
        $response1 = Read-host "Is the VPN tunnel up? [Y or N]"
        If($response1 -eq 'Y'){
            Write-Host ("Done configuring router basic site-2-site vpn") -ForegroundColor Green
            Write-Host "==============================================" -ForegroundColor Green
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
            $response2 = Read-host "Would you like to attempt to reset the VPN connection? [Y or N]"
            If($response2 -eq 'Y'){
                Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureSimpleConfig.ConnectionName `
                        -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Value $Global:sharedPSKKey -Force | Out-Null

                Reset-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName `
                        -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Force | Out-Null
                Start-Sleep 10
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
    Write-host ("Shared Key (PSK):    {0}" -f $Global:sharedPSKKey)
    Write-host ("Home Public IP:      {0}" -f $HomePublicIP)
    Write-Host ("Router CIDR Prefix:  {0}" -f $VyOSConfig.LocalCIDRPrefix)
    Write-Host "Be sure to follow a the configuration file: '$PSScriptRoot\Logs\$ScriptName'`n" -ForegroundColor Yellow

    #region Copy Paste Mode
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
    Write-Host "Copy script below line or from $PSScriptRoot\Logs\$ScriptName" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Stop copying above line this and paste in ssh session" -ForegroundColor Yellow
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "Log into router and run [" -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow -NoNewline
    Write-Host "]" -ForegroundColor Gray
}

Stop-Transcript
