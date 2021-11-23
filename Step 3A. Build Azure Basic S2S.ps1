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
#region 1. Create a virtual network and a gateway subnet

#Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureSimpleConfig.ResourceGroupName) -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor Green
}


#Set the vnet subnets
Write-Host ("Building Azure subnets configurations for both gateway subnet [{0}] and subnets [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetSubnetPrefix) -NoNewline
Try{
    $subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix
    $subnet2 = New-AzVirtualNetworkSubnetConfig -Name $AzureSimpleConfig.DefaultSubnetName -AddressPrefix $AzureSimpleConfig.VnetSubnetPrefix
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}

#Create the VNet
Write-Host ("Creating Azure virtual network [{0}]..." -f $AzureSimpleConfig.VnetName) -NoNewline
Try{
    New-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -AddressPrefix $AzureSimpleConfig.VnetCIDRPrefix -Subnet $subnet1, $subnet2 | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}

#add a gateway subnet to a virtual network you have already created
$vnet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
# add gateway prefix if not already exists
If( (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet |Where Name -eq 'GatewaySubnet').AddressPrefix -ne $AzureSimpleConfig.VnetGatewayPrefix )
{
    Write-Host ("Attaching Azure gateway subnet [{0}] to virtual network [{1}]..." -f $AzureSimpleConfig.VnetGatewayPrefix,$AzureSimpleConfig.VnetName) -NoNewline
    Try{
        Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $AzureSimpleConfig.VnetGatewayPrefix -VirtualNetwork $vnet | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}

Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
#endregion

#region 2. Create the local network gateway
#add a local network gateway with a single address prefix:
Write-Host ("Creating Azure local network gateway [{0}]..." -f $AzureSimpleConfig.LocalGatewayName) -NoNewline
Try{
    New-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -GatewayIpAddress $HomePublicIP -AddressPrefix $VyOSConfig.LocalCIDRPrefix | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}
#endregion

#region 3. Create a Public IP address
Write-Host ("Creating Azure public IP [{0}]..." -f $AzureSimpleConfig.PublicIpName) -NoNewline
Try{
    $gwpip= New-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                    -Location $AzureSimpleConfig.LocationName -AllocationMethod Dynamic
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}
#endregion

#region 4. make the gateway
Write-host ("Attaching Azure public IP [{0}] to gateway subnet [{1}]..." -f $AzureSimpleConfig.PublicIpName, 'GatewaySubnet') -NoNewline
Try{
    #$vnet = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VnetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name $AzureSimpleConfig.VnetGatewayIpConfigName -SubnetId $subnet.Id -PublicIpAddressId $gwpip.Id
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}

#region 5. Create the VPN gateway
#this can take up to 40 minutes (eg: started at 4:15; ended at 4:39)
Write-host ("Building Azure virtual network gateway [{0}], this can take up to 45 minutes..." -f $AzureSimpleConfig.VnetGatewayName) -NoNewline
Try{
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
    #https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
    New-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 | Out-Null
    $stopwatch.Stop()
    $totalSecs =  [math]::Round($stopwatch.Elapsed.TotalSeconds,0)
    Write-Host ("Completed in [{0}] seconds" -f $totalSecs) -ForegroundColor Green
}
Catch{
    $stopwatch.Stop()
    $totalSecs =  [math]::Round($stopwatch.Elapsed.TotalSeconds,0)
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
}
#endregion

#region 6 & 7. Create the VPN connection
If( $azpip = (Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName).IpAddress)
{
    Write-host ("Create the VPN connection for [{0}]..." -f $AzureSimpleConfig.ConnectionName) -NoNewline
    Try{
        #create the Site-to-Site VPN connection between your virtual network gateway and your VPN device.
        $gateway1 = Get-AzVirtualNetworkGateway -Name $AzureSimpleConfig.VnetGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
        $Local = Get-AzLocalNetworkGateway -Name $AzureSimpleConfig.LocalGatewayName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName

        #Create the connection
        New-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -Location $AzureSimpleConfig.LocationName -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $Local `
            -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedPSKKey | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Red
    }
}Else{
    Write-Host ("No IP has been assigned to: {0}" -f $AzureSimpleConfig.PublicIpName) -ForegroundColor Red
    Break
}
#endregion

#region 8. Verify the VPN connection
$currentGwConnection = Get-AzVirtualNetworkGatewayConnection -Name $AzureSimpleConfig.ConnectionName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName
#endregion

#get the Public IP
#$azpip = (Get-AzPublicIpAddress -Name $AzureSimpleConfig.PublicIpName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName).IpAddress

#Output information need for local router
Write-Host "Information needed to configure local router vpn:" -ForegroundColor Yellow
Write-Host ("Azure Location:      {0}" -f $AzureSimpleConfig.LocationName)
Write-Host ("Azure Public IP:     {0}" -f $azpip)
Write-Host ("Azure Subnet Prefix: {0}" -f $AzureSimpleConfig.VnetSubnetPrefix)
Write-host ("Shared Key (PSK):    {0}" -f $Global:sharedPSKKey)
Write-host ("Home Public IP:      {0}" -f $HomePublicIP)
Write-Host ("Router CIDR Prefix:  {0}" -f $VyOSConfig.LocalCIDRPrefix)
Write-Host "Be sure to follow a the configuration file 'VyOS_vpn_basic.md' in the VyOS_setup folder" -ForegroundColor Yellow

#region Build VyOS VPN Configuration Commands
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
#set to false so the next gateway setup does not delete this setup
$VyOSConfig['ResetVPNConfigs']=$false
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
set vpn ipsec site-to-site peer $azpip authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer $azpip authentication pre-shared-secret '$Global:sharedPSKKey'
set vpn ipsec site-to-site peer $azpip connection-type 'initiate'
set vpn ipsec site-to-site peer $azpip default-esp-group 'azure'
set vpn ipsec site-to-site peer $azpip description '$($AzureSimpleConfig.TunnelDescription)'
set vpn ipsec site-to-site peer $azpip ike-group 'azure-ike'
set vpn ipsec site-to-site peer $azpip ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer $azpip local-address '$VyOSExternalIP'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer $azpip tunnel 1 local prefix '$($VyOSConfig.LocalCIDRPrefix)'
set vpn ipsec site-to-site peer $azpip tunnel 1 remote prefix '$($AzureSimpleConfig.VnetSubnetPrefix)'

#Default route and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop '$($VyOSConfig.NextHopSubnet)'

"@

$VyOSFinal += @"

commit
save
"@

#region Automation Mode
If($RouterAutomationMode)
{
    $VyOSFinalScript = New-VyattaScript -Value $VyOSFinal -AsObject -SetReboot
    #TEST $VyOSFinalScript.value
    #temporary set auto logon ssh keys
    New-SSHSharedKey -DestinationIP $VyOSExternalIP -User 'vyos' -Force

    $Result = Initialize-VyattaScript -IP $VyOSExternalIP -Path $VyOSFinalScript.Path -Execute -Verbose

    $Result

    If(!$Result){
        Write-Host "Failed to run automation script for vyos router; use manual process" -ForegroundColor Red
        $RunManualSteps = $true
    }

    #wait for VM to boot completely
    Write-Host "VM is rebooting" -ForegroundColor Yellow -NoNewline
    do {
        Write-Host "." -NoNewline
        Start-Sleep 3
    } until(Test-Connection $VyOSExternalIP -Count 1 -ErrorAction SilentlyContinue)

    Write-Host "Booted" -ForegroundColor Green
    Write-Host "Login to router and run [show vpn ipsec sa]..." -ForegroundColor Gray
    $response1 = Read-host "Is the VPN tunnel up? ? [Y or N]"
    If($response1 -eq 'Y'){
        Write-Host ("Done configuring router basic site-2-site vpn") -ForegroundColor Green
        Write-Host "--------------------------------------------------" -ForegroundColor Green
    }Else{
        Write-Host "Automation may have failed try running the commands manually" -ForegroundColor Red
        $RunManualSteps = $true
    }
    #endregion
}
Else{
    $RunManualSteps = $true
}

If($RunManualSteps){
    $VyOSFinal -split '\n' | %{$_ | Add-Content "$PSScriptRoot\Logs\vyoss2ssimplesetup.txt"}
    #region Copy Paste Mode
    Write-Host "`nOpen ssh session for $($VyOSConfig.VMName):`n" -ForegroundColor Yellow
    Write-Host "Copy script below line or from $PSScriptRoot\Logs\vyoss2ssimplesetup.txt" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $VyOSFinal -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Stop copying above line this and paste in ssh session" -ForegroundColor Yellow
    Write-Host "`nA reboot may be required on $($VyOSConfig.VMName) for updates to take effect" -ForegroundColor Red
    Write-Host "Run this command last in ssh session: " -ForegroundColor Gray -NoNewline
    Write-Host "reboot now" -ForegroundColor Yellow
    #endregion
}

Stop-Transcript
