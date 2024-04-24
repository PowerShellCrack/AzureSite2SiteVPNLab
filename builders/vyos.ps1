
#============================================
# CONFIGURATIONS
#============================================
Write-Host "Collecting local data..." -NoNewline
#region Hyper-V Configurations
#------------------------------
$HyperVConfig = @{
    ChangeLocation = $true
    VirtualMachineLocation = $HyperVVMLocation
    VirtualHardDiskLocation = $HyperVHDxLocation
    VirtualSwitchNetworks = @{}
    EnableSessionMode = $true
    ConfigureForVLAN = $False
    VLANID = 21
    AllowedvLanIdRange = '1-100'
}

#region Edge router Configurations
#---------------------------------
#grab local router subnet for next hop
$NextHop = Get-WmiObject -Class Win32_IP4RouteTable | where { $_.destination -eq '0.0.0.0' -and $_.mask -eq '0.0.0.0'} | Select -ExpandProperty nexthop
$OnPremNetworkRange = Get-NetworkDetails -CidrAddress $OnPremSubnetCIDR
$SimpleSubnetsFromOnPremCIDR = Get-SimpleSubnets -Cidr $OnPremSubnetCIDR -Count $OnPremSubnetCount
$FourthIp = Get-NextAddress -Cidr $SimpleSubnetsFromOnPremCIDR[0] -Increment 3

If(Test-IPAddress $DHCPLocation){
    $IsDhcpOnRouter = $false
    $IsDhcpPxeRelayAvailable = $true
    $DefaultRelayIp = $DHCPLocation

}
ElseIf($DHCPLocation -match 'router'){
    $IsDhcpOnRouter = $true
    $IsDhcpPxeRelayAvailable = $false
    $DefaultRelayIp = $null
}
Else{
    $IsDhcpOnRouter = $false
    $IsDhcpPxeRelayAvailable = $true
    $DefaultRelayIp = $FourthIp
}


$VyOSConfig = @{
    HostName = ('VyOS').ToLower()
    VMName = $LabPrefix.ToUpper() + '-ROUTER'
    ISOLocation = $VyosIsoPath
    TimeZone = 'US/Eastern'
    ExternalInterface = 'Default Switch' #CHANGE: Match one of the external network names in hyper config

    NextHopSubnet = $NextHop
    ResetVPNConfigs = $false # this will delete the configurations of any VPN settings in VyOS

    #CIDR for local network
    LocalCIDRPrefix = $OnPremSubnetCIDR
    LocalSubnetPrefix = @{}

    BgpAsn = 65168 #CHANGE: set as default ASN

    UseDNSOption = 'Internal' #CHANGE: 'Internal'<--uses VM DNS like a DC; 'External' <--Use home network DNS configs; 'Internet' <-- Uses Google
    EnableDHCP = $IsDhcpOnRouter
    DhcpRelayIP = $DefaultRelayIp
    DHCPPoolsRanges = @{}
    EnablePXERelay = $IsDhcpPxeRelayAvailable #True or False: PXE relay may be same a DHCP relay

    EnableNAT = $True
}

#build DNS server list
$VyOSConfig['InternalDNSIP']  = @()
$DNSServersArray = @()
$DNSServersArray = $DNSServers.split(',')
Foreach ($Dns in $DNSServersArray)
{
    If(Test-IPAddress $Dns){
        $VyOSConfig['InternalDNSIP'] += $Dns
    }
}
#incase there is no valid DNS IP's add fourth IP (we need at least one for router)
If($VyOSConfig['InternalDNSIP'].count -eq 0){
    If($DNSServers -match 'Router'){$DNStoAdd = '8.8.8.8'}Else{$DNStoAdd = $FourthIp}
    If($FourthIp -notin $VyOSConfig['InternalDNSIP']){
        $VyOSConfig['InternalDNSIP'] += $DNStoAdd
    }
}

#build VyOS local subnet and description
$SubnetTable = $VyOSConfig['LocalSubnetPrefix']
Foreach ($Subnet in $SimpleSubnetsFromOnPremCIDR)
{
    $SubnetNoCider = $Subnet -replace '/\d+$',''
    if(-Not($SubnetTable.ContainsKey($Subnet)) ){
        $SubnetTable[$Subnet] = $SubnetNoCider + '_Subnet'
    }
}

#build VyOS DHCP pool (even if its not used)
$DHCPPoolTable = $VyOSConfig['DHCPPoolsRanges']
Foreach ($Subnet in $SimpleSubnetsFromOnPremCIDR)
{
    $SubnetNoCider = $Subnet -replace '/\d+$',''
    if(-Not($DHCPPoolTable.ContainsKey($Subnet)) ){
        $DHCPPoolTable[$SubnetNoCider] = ($SubnetNoCider -replace '.\d+$','.254')
    }
}

#build hyper-v's Virtual Switch Networks
$i = 1
$VirtualSwitchTable = $HyperVConfig['VirtualSwitchNetworks']
Foreach($Subnet in $VyOSConfig.LocalSubnetPrefix.GetEnumerator() | Sort Name)
{
    $SwitchName = ($LabPrefix.ToUpper() + ' LAN ' + $i + ' - ' + $Subnet.Name)
    $Description = ("LAN subnet for {1}: {0}" -f $Subnet.Name,$LabPrefix)
    $VirtualSwitchTable[$SwitchName] = $Description
    $i++
}