Param(
    [string]$Prefix,
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $vNets = Get-AzVirtualNetwork | Select -ExpandProperty Name

        $vNets | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("vNet")]
    [string]$VirtualNetwork,
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $RGs = Get-AzResourceGroup | Select -ExpandProperty ResourceGroupName

        $RGs | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("rg")]
    [string]$ResourceGroup
)
<#
#TEST VARIABLES
$Prefix='contoso'
$ResourceGroup='mecmcb-arm-rg'
$VirtualNetwork='contoso-vnet'
#>

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
    . "$PSScriptRoot\configs.ps1" -NoVyosISOCheck
}
#endregion

#if prefix specified, make it lower case else use config's prefix
If($Prefix){$Prefix = $Prefix.ToLower()}Else{$Prefix = $LabPrefix.ToLower()}

$AzureExistingConfig = @{

    LocalGatewayName = $Prefix + '-lng'
    PublicIPName = $Prefix + '-pip'
    ConnectionName = ('sitetosite-connection-to-' + $Prefix)

    TunnelDescription = ('Gateway to ' + $Prefix + ' in Azure').Replace('-',' ')
}

#region start transcript
$LogfileName = "$Prefix-$ResourceGroup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
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
#region 1. Grab the resource group:
If($RG = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)
{
    $Location = $RG.Location
    Write-Host ("The Azure resource group [{0}] is in [{1}]..." -f $RG.ResourceGroupName,$Location)
}
Else{
    Write-Host ("The specified Azure resource group [{0}] does not exist. You must use an existing Resource Group." -f $ResourceGroup) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion


#append to hashtable
$AzureExistingConfig['ResourceGroupName'] = $RG.ResourceGroupName
$AzureExistingConfig['LocationName'] = $RG.Location


#region 2. Find Virtual network
If($vNets = Get-AzVirtualNetwork -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue)
{
    $vNetHubExist = $false
    $vNetSpokeExist = $false
    If($vNets.count -gt 1){
       If($vNets.Name -eq $VirtualNetwork){
            $vNet = $vNets | Where Name -eq $VirtualNetwork
            $vNetName = $vNet.Name
            $vNetLocation = $vNet.Location
            $vNetCidr = $vNet.AddressSpace.AddressPrefixes
            $vNetSubnets = $vNet.Subnets.AddressPrefix
            $GatewaySubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet -ErrorAction SilentlyContinue | Where Name -eq 'GatewaySubnet'
            Write-Host ("Found Azure virtual network [{0}] with CIDR [{1}] with subnets [{2}]" -f $vNetName,($vNetCidr -join ','),($vNetSubnets -join ','))
       }

       If($vNets.Name -match 'Spoke'){
            $vNetSpokeExist = $true
            $vNetSpoke = $vNets | Where Name -match 'Spoke'
            $vNetSpokeName = $vNetSpoke.Name
            $vNetSpokeLocation = $vNetSpoke.Location
            $vNetSpokeCidr = $vNetSpoke.AddressSpace.AddressPrefixes
            $vNetSpokeSubnets = $vNetSpoke.Subnets.AddressPrefix

            Write-Host ("Found Spoke Azure virtual network [{0}] with CIDR [{1}] with subnets [{2}]" -f $vNetSpokeName,($vNetSpokeCidr -join ','),($vNetSpokeSubnets -join ','))
       }

       If($vNets.Name -match 'Hub'){
            $vNetHubExist = $true
            $vNet = $vNets | Where Name -match 'Hub'
            $vNetName = $vNetHub.Name
            $vNetLocation = $vNetHub.Location
            $vNetCidr = $vNetHub.AddressSpace.AddressPrefixes
            $vNetSubnets = $vNetHub.Subnets.AddressPrefix
            $GatewaySubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNetHub -ErrorAction SilentlyContinue  | Where Name -eq 'GatewaySubnet'
            Write-Host ("Found Hub Azure virtual network [{0}] with CIDR [{1}] with subnets [{2}]" -f $vNetName,($vNetCidr -join ','),($vNetSubnets -join ','))
       }
    }
    Else{
        $vNet = $vNets
        $vNetName = $vNet.Name
        $vNetLocation = $vNet.Location
        $vNetCidr = $vNet.AddressSpace.AddressPrefixes
        $vNetSubnets = $vNet.Subnets.AddressPrefix
        $GatewaySubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet -ErrorAction SilentlyContinue | Where Name -eq 'GatewaySubnet'
        Write-Host ("Found single Azure virtual network [{0}] with CIDR [{1}] with subnets [{2}]" -f $vNetName,($vNetCidr -join ','),($vNetSubnets -join ','))
    }

    $AvailableSubnetsFromVnetCIDR = Get-SimpleSubnets -Cidr $vNetCidr

    #append to hashtable
    $AzureExistingConfig['VnetName'] = $vNetName
    $AzureExistingConfig['VnetGatewayName'] = $Prefix + '-vng'
    $AzureExistingConfig['VnetCIDRPrefix'] = $vNetCidr
    $AzureExistingConfig['DefaultSubnetName'] = $Prefix + '-default-subnet'
    $AzureExistingConfig['VnetSubnetPrefix'] = $vNetSubnets
    $AzureExistingConfig['VnetGatewayPrefix'] = ($AvailableSubnetsFromVnetCIDR[-1] -replace '/\d+$', '/26')
    $AzureExistingConfig['VnetGatewayIpConfigName'] = $Prefix + '-gateway-ipconfig'
}
Else{
    Write-Host ("The specified Azure virtual network [{0}] does not exist. You must use an existing Resource Group." -f $AzureExistingConfig.ResourceGroupName) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion

#region 2. Configure subnets
Write-Host ("Building Azure subnets configurations for both gateway subnet [{0}] and subnets [{1}]..." -f $AzureExistingConfig.VnetGatewayPrefix,($AzureExistingConfig.VnetSubnetPrefix -join ',')) -ForegroundColor White -NoNewline
Try{
    $subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureExistingConfig.VnetGatewayPrefix
    $subnet2 = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet | Where Name -ne 'GatewaySubnet'
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}
#endregion

#region 3. Create the VNet
If(-Not(Get-AzVirtualNetwork -Name $AzureExistingConfig.VnetName -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure virtual network [{0}]..." -f $AzureExistingConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        New-AzVirtualNetwork -Name $AzureExistingConfig.VnetName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                -Location $AzureExistingConfig.LocationName -AddressPrefix $AzureExistingConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else
{
    Write-Host ("Updating Azure virtual network [{0}]..." -f $AzureExistingConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        New-AzVirtualNetwork -Name $AzureExistingConfig.VnetName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                -Location $AzureExistingConfig.LocationName -AddressPrefix $AzureExistingConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}

#endregion
#region 4. Attach gateway to vnet
$vNet = Get-AzVirtualNetwork -Name $AzureExistingConfig.VnetName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
# add gateway prefix if not already exists
If( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet | Where Name -eq 'GatewaySubnet').AddressPrefix -ne $AzureExistingConfig.VnetGatewayPrefix){

    Write-Host ("Attaching Azure gateway subnet [{0}] to virtual network [{1}]..." -f $AzureExistingConfig.VnetGatewayPrefix,$AzureExistingConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureExistingConfig.VnetGatewayPrefix -VirtualNetwork $vNet | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
ElseIf( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vNet | Where Name -eq 'GatewaySubnet').AddressPrefix -ne $AzureExistingConfig.VnetGatewayPrefix )
{
    Write-Host ("Attaching Azure gateway subnet [{0}] to virtual network [{1}]..." -f $AzureExistingConfig.VnetGatewayPrefix,$AzureExistingConfig.VnetName) -ForegroundColor White -NoNewline
    Try{
        Remove-AzVirtualNetworkSubnetConfig  -Name 'GatewaySubnet' -VirtualNetwork $vNet | Out-Null
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureExistingConfig.VnetGatewayPrefix -VirtualNetwork $vNet | Out-Null
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
If( -Not(Get-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-Host ("Creating Azure local network gateway [{0}]..." -f $AzureExistingConfig.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                    -Location $AzureExistingConfig.LocationName -GatewayIpAddress $HomePublicIP `
                    -AddressPrefix @($VyOSConfig.LocalSubnetPrefix.GetEnumerator().Name) | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureExistingConfig.LocalGatewayName) -ForegroundColor Green
}
#endregion

#region 6. Create a Public IP address
If( $null -eq ($azpip = Get-AzPublicIpAddress -Name $AzureExistingConfig.PublicIpName -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpAddress )
{
    Write-Host ("Creating Azure public IP [{0}]..." -f $AzureExistingConfig.PublicIpName) -ForegroundColor White -NoNewline
    Try{
        New-AzPublicIpAddress -Name $AzureExistingConfig.PublicIpName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                        -Location $AzureExistingConfig.LocationName -AllocationMethod Dynamic | Out-Null
        $azpip = Get-AzPublicIpAddress -Name $AzureExistingConfig.PublicIpName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure public ip [{0}] with ip [{1}]" -f $AzureExistingConfig.PublicIPName,$azpip.IpAddress) -ForegroundColor Green
}
#endregion

#region 7. make the gateway
If( $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vNet -ErrorAction SilentlyContinue )
{
    Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureExistingConfig.PublicIpName, 'GatewaySubnet') -ForegroundColor White -NoNewline
    Try{
        #$vNet = Get-AzVirtualNetwork -Name $AzureExistingConfig.VnetName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
        $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureExistingConfig.VnetGatewayIpConfigName -SubnetId $subnet.Id -PublicIpAddressId $azpip.Id
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("No gateway subnet was found [{0}]" -f $AzureExistingConfig.VnetGatewayIpConfigName) -ForegroundColor Red
    Break
}
#endregion

#region 8. Create the VPN gateway
#Check to see if public IP is attached to VNG
If( -Not(Get-AzVirtualNetworkGateway -Name $AzureExistingConfig.VnetGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue).IpConfigurations.PublicIpAddress.id )
{
    Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureExistingConfig.VnetGatewayName) -ForegroundColor White -NoNewline
    Try{
        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
        New-AzVirtualNetworkGateway -Name $AzureExistingConfig.VnetGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                -Location $AzureExistingConfig.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 | Out-Null
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
    Write-Host ("Using Azure virtual network gateway [{0}]" -f $AzureExistingConfig.VnetGatewayName) -ForegroundColor Green
}
#endregion

#region 9. Create the Virtual Network Gateway
If( -Not($Local = Get-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue) )
{
    Write-host ("Building the local network gateway [{0}]..." -f $AzureExistingConfig.LocalGatewayName) -ForegroundColor White -NoNewline
    Try{
        New-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                -Location $AzureExistingConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalSubnetPrefix.keys | Out-Null
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
        New-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
                -Location $AzureExistingConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalSubnetPrefix.keys -Force | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure local network gateway [{0}]" -f $AzureExistingConfig.LocalGatewayName) -ForegroundColor Green
}
#endregion


#region 9. Create the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureExistingConfig.ConnectionName `
            -ResourceGroupName $AzureExistingConfig.ResourceGroupName -ErrorAction SilentlyContinue

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
    $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureExistingConfig.VnetGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
    $Local = Get-AzLocalNetworkGateway -Name $AzureExistingConfig.LocalGatewayName -ResourceGroupName $AzureExistingConfig.ResourceGroupName

    Write-host ("Create the VPN connection for [{0}]..." -f $AzureExistingConfig.ConnectionName) -ForegroundColor White -NoNewline
    Try{
        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureExistingConfig.ConnectionName -ResourceGroupName $AzureExistingConfig.ResourceGroupName `
            -Location $AzureExistingConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey -Force | Out-Null
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
        do {
            #cls
            $response1 = Read-host "Would you like to re-run the router configurations? [Y or N]"
        } until ($response1 -eq 'Y')
    }
    If( ($response1 -eq 'Y') -or ($VyOSConfig['ResetVPNConfigs'] -eq $true) )
    {
        Write-Host ("Attempting to update vyos router vpn configurations to use Azure's public IP [{0}]..." -f $azpip.IpAddress) -ForegroundColor Yellow
        $Global:sharedPSKKey = Get-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureExistingConfig.ConnectionName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
        $VyOSConfig['ResetVPNConfigs'] = $true
    }
    Else{
        $RouterAutomationMode = $false
    }
}
#endregion

# be sure to grab the public ip again
$azpip = Get-AzPublicIpAddress -Name $AzureExistingConfig.PublicIpName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
If($azpip.IpAddress -eq 'Not Assigned'){
    Write-Host ("Public IP is not assigned. Please wait 10 mins to rerun script!") -ForegroundColor Black -BackgroundColor Yellow
    Break
}

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
set vpn ipsec site-to-site peer $($azpip.IpAddress) description '$($AzureExistingConfig.TunnelDescription)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ike-group 'azure-ike'
set vpn ipsec site-to-site peer $($azpip.IpAddress) ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $($azpip.IpAddress) local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $($azpip.IpAddress) tunnel 1 remote prefix '$($AzureExistingConfig.VnetSubnetPrefix)'

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
            Write-Host "." -ForegroundColor Yellow -NoNewline
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
        $currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureExistingConfig.ConnectionName -ResourceGroupName $AzureExistingConfig.ResourceGroupName
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
                Set-AzVirtualNetworkGatewayConnectionSharedKey -Name $AzureExistingConfig.ConnectionName `
                        -ResourceGroupName $AzureExistingConfig.ResourceGroupName -Value $Global:sharedPSKKey -Force | Out-Null

                Reset-AzVirtualNetworkGatewayConnection -Name $AzureExistingConfig.ConnectionName `
                        -ResourceGroupName $AzureExistingConfig.ResourceGroupName -Force | Out-Null
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
    Write-Host ("Azure Location:      {0}" -f $AzureExistingConfig.LocationName)
    Write-Host ("Azure Public IP:     {0}" -f $azpip.IpAddress)
    Write-Host ("Azure Subnet Prefix: {0}" -f $AzureExistingConfig.VnetSubnetPrefix)
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
