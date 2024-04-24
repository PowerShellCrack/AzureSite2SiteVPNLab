[CmdletBinding()]
Param(
    [switch]$NoAzureCheck,
    [switch]$NoVyosISOCheck

)
#============================================
# General Configurations - EDIT THIS
#============================================
$IgnoreISECheck = $False #PowerShell ISE has issues with prompting for password during VYOS setup. Recommend running in PowerShell or VSCode.

$AzureGov = $false # changing to true, will use the Azure environment for gov

$LabPrefix = 'Contoso' #identifier for names in lab

$domain = 'contoso.com' #just a name for now (no DC install....yet)

$Email = '<email>' #used only in VM notification for VM auto shutdown settings

#this is used to configure default username and password on Azure VM's
$VMAdminUser = 'xAdmin'
$VMAdminPassword = '<password>'

#NOTE: Make sure ALL subnets do not overlap!
$OnPremSubnetCIDR = '10.100.0.0/16' #Always use /16
$OnPremSubnetCount = 2

$TenantASiteName = 'SiteA'
$TenantAHubCIDR = '10.10.0.0/16' #Always use /16
$TenantASpokeCIDR = '10.11.0.0/16' #Always use /16; keep this subnet higher than hub (when incrementing)
$TenantASpokeSubnetCount = 1 #keep this at 1 for now

$TenantBSiteName = 'SiteB'
$TenantBHubCIDR = '10.21.0.0/16' #Always use /16
$TenantBSpokeCIDR = '10.22.0.0/16' #Always use /16
$TenantBSpokeSubnetCount = 1 #keep this at 1 for now

$DHCPLocation = 'router'   #defaults to DHCP server not on router; assumes DHCP is on a server
#$DHCPLocation = '<IP, server, or router>'   #defaults to DHCP server not on router; assumes DHCP is on a server
                                            #if <router> is specified, DHCP server will be enabled and a full DHCP scope will be built for each subnets automatically (eg. 10.22.1.1-10.22.1.255)

$DNSServers = '<IP, IP addresses (comma separated), router>'   #if not specified; defaults to fourth IP in spoke subnet scope (eg. 10.22.1.4). This would be Azure's first available IP for VM
                                                                # if <router> is specified; google IP 8.8.8.8 will be used since no DNS server role exist on router

$HyperVVMLocation = '<default>' #Leave as <default> for auto detect
$HyperVHDxLocation = '<default>' #Leave as <default> for auto detect

$VyosIsoPath = '<default>' #Add path (eg. 'E:\ISOs\VyOS-1.1.8-amd64.iso') or use <latest> to get the latest VyOS ISO (this is still in BETA)
                  #If path left blank or default, it will attempt to download the supported versions (1.1.8)

$HyperVVmIsoPath = 'E:\ISOs\en-us_windows_10_business_editions_version_20h2_updated_october_2021_x64_dvd_e057173c.iso'

$UseBGP = $false # not required for VPN, but can help. Costs more.
#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview

#used in step 5
$AzureVnetToVnetPeering = @{
    TenantASubscriptionID = '<SubscriptionAID>'
    TenantATenantID= '<TenantAID>'
    TenantBSubscriptionID = '<SubscriptionBID>'
    TenantBTenantID = '<TenantBID>'
}

#Uses Git, SSH and SCP to build VyOS router
# 99% automated; but 90% successful
$RouterAutomationMode = $True

#Name appended to the simple S2S resources
$SimpleAppendix = 'Simple'

$AzureLocation = 'East US' #Azure location: supports East US, East US 2, West US, West US 2, Central US, North Central US, South Central US

$timeZone = 'Eastern Standard Time'
#============================================
# General Configurations - STOP HERE
#============================================
#change location to Azure Gov based on $Azurelocation
If($AzureGov){
    switch($AzureLocation){
        'East US' {$AzureLocation = 'usgovvirginia';$timeZone = 'Eastern Standard Time'}
        'East US 2' {$AzureLocation = 'usgovvirginia';$timeZone = 'Eastern Standard Time'}
        'West US' {$AzureLocation = 'usgovarizona';$timeZone = 'US Mountain Standard Time'}
        'West US 2' {$AzureLocation = 'usgovarizona';$timeZone = 'US Mountain Standard Time'}
        'Central US' {$AzureLocation = 'usgovvirginia';$timeZone = 'Eastern Standard Time'}
        'North Central US' {$AzureLocation = 'usgovvirginia';$timeZone = 'Eastern Standard Time'}
        'South Central US' {$AzureLocation = 'usgovarizona';$timeZone = 'US Mountain Standard Time'}
    }
}
##*=============================================
##* Runtime Function - REQUIRED
##*=============================================


#region FUNCTION: Check if running in ISE
Function Test-IsISE {
    # try catch accounts for:
    # Set-StrictMode -Version latest
    try {
        return ($null -ne $psISE);
    }
    catch {
        return $false;
    }
}
#endregion

#region FUNCTION: Check if running in Visual Studio Code
Function Test-VSCode{
    if($env:TERM_PROGRAM -eq 'vscode') {
        return $true;
    }
    Else{
        return $false;
    }
}
#endregion
##*========================================================================
##* BUILD PATHS
##*========================================================================
[string]$ResourceRoot = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]
[string]$FunctionPath = Join-Path -Path $ResourceRoot -ChildPath 'Functions'

#region library custom functions
. "$FunctionPath\library.ps1"
. "$FunctionPath\vyos.ps1"
. "$FunctionPath\network.ps1"
. "$FunctionPath\hyperv.ps1"
. "$FunctionPath\azure.ps1"
#endregion

Write-Host "Done." -ForegroundColor Green

#check if SSH and SCP exist for automation mode to work
If(-Not(Test-Command ssh) -and -Not(Test-Command scp) -and -Not(Test-Command ssh-keygen) )
{
    Write-Host ("SSH, SCP, SSH-KEYGEN commands not found. Disabling Automation mode {0} " -f $_.exception.message) -ForegroundColor Red
    $RouterAutomationMode = $False
}

#Build a log folder for transactions
New-Item "$scriptPath\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Home network Public IP
$HomePublicIP = Get-MyPublicIP
If(!$HomePublicIP){
    do {
        $HomePublicIP = Read-host "Unable to retrieve public IP. What is your public IP?"
    } until ( $HomePublicIP -as [System.Net.IPAddress])
}

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global variable so it used for the entire session
If(!$Global:randomChar){
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($TenantAHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$TenantAHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($TenantBHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$TenantBHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($TenantAHubCIDR -replace '/\d+$','') -ip2 ($TenantASpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$TenantAHubCIDR] and [`$TenantASpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($TenantBHubCIDR -replace '/\d+$','') -ip2 ($TenantBSpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$TenantBHubCIDR] and [`$TenantBSpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}
#============================================
# AZURE CONNECTION
#============================================
#region connect to Azure if not already connected


If(!$NoAzureCheck){
    #need modules: Az.Accounts, Az.Resources ,Az.Network, Az.Storage, Az.Compute
    $modules = @(
        'Az.Accounts',
        'Az.Resources',
        'Az.Network',
        'Az.Storage',
        'Az.Compute'
    )

    foreach ($module in $modules){
        Write-Host ("Checking for installed module: {0}..." -f $module) -ForegroundColor White -NoNewline
        If((Find-Module $module).Version -in (Get-InstalledModule $module -AllVersions).version)
        {
            Write-Host ("Version [{0}] installed" -f (Get-InstalledModule $module -AllVersions).version) -ForegroundColor Green
        }
        Else{
            Write-Host " |--Updating, please wait..." -ForegroundColor Yellow -NoNewline
            Install-Module -Name $module -AllowClobber -Scope AllUsers -Force
            Write-Host "Done" -ForegroundColor Green
        }
    }

    Update-AzConfig -DisplayBreakingChangeWarning $false | Out-Null

    #get azure context
    $Context = Get-AzContext -ErrorAction SilentlyContinue

    Try{
        #if no context assume not connected to Azure
        If($null -eq $Context){
            If($AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
            Else{Connect-AzAccount -Force}
        }
        #if context is not connected to gov; reconnect
        ElseIf ($AzureGov -and $Context.Environment.Name -ne 'AzureUSGovernment'){
            Clear-AzDefault -ErrorAction Stop -Force
            Clear-AzContext -ErrorAction Stop -Force
            Disconnect-AzAccount -ErrorAction Stop
            Connect-AzAccount -EnvironmentName AzureUSGovernment -Force
        }
    }
    Catch{
        Write-host ("Failed to get Azure context. {0}" -f $_.Exception.Message) -ForegroundColor yellow
        Clear-AzDefault -ErrorAction SilentlyContinue -Force
        Clear-AzContext -ErrorAction SilentlyContinue -Force
        Disconnect-AzAccount -ErrorAction SilentlyContinue
        #reconnect
        If($AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
        Else{Connect-AzAccount -Force}
    }
    Finally{
        If($null -eq $Global:AzSubscription){
            $Global:AzSubscription = Get-AzSubscription -WarningAction SilentlyContinue | Out-GridView -PassThru -Title "Select a valid Azure Subscription" | Select-AzSubscription -WarningAction SilentlyContinue
            Set-AzContext -Tenant $Global:AzSubscription.Tenant.id -SubscriptionId $Global:AzSubscription.Subscription.id | Out-Null
        }
        
        Update-AzConfig -DisplayBreakingChangeWarning $false -ErrorAction SilentlyContinue | Out-Null 

        Write-Host ("Using Account ID:   ") -ForegroundColor White -NoNewline
        Write-Host ("{0}" -f $Global:AzSubscription.Account.Id) -ForegroundColor Green
        Write-Host ("Using Tenant ID:    ") -ForegroundColor White -NoNewline
        Write-Host ("{0}" -f $Global:AzSubscription.Tenant.Id) -ForegroundColor Green
        Write-host ("Using Subscription: ") -ForegroundColor White -NoNewline
        Write-Host ("{0}" -f $Global:AzSubscription.Subscription.Name) -ForegroundColor Green
    }
    
}

#endregion

If(Test-IsISE){
    If($IgnoreISECheck -eq $False){
        Write-Host "===============================" -ForegroundColor Black -BackgroundColor Yellow
        Write-Host "      CONTINUE AT OWN RISK     " -ForegroundColor Black -BackgroundColor Yellow
        Write-Host "===============================" -ForegroundColor Black -BackgroundColor Yellow
        Write-Host "You are currently running this script using PowerShell ISE.`nThere are known issues with the interface during vyos configurations" -ForegroundColor Yellow
        $ISEResponse = Read-host "Would you like to continue? [Y or N]"
        If ($ISEResponse -eq 'N'){
            Break
        }
    }
}

#============================================
# HYPER-V CHECK
#============================================

If($HyperVVMLocation -match 'default')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $HyperVVMLocation = Get-VMHost | Select -ExpandProperty VirtualMachinePath
    }
    Else{
        $HyperVVMLocation = 'C:\ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines\'
    }
}

If($HyperVHDxLocation -match 'default')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $HyperVHDxLocation = Get-VMHost | Select -ExpandProperty VirtualHardDiskPath
    }
    Else{
        $HyperVHDxLocation = 'C:\Users\Public\Documents\Hyper-V\Virtual hard disks\'
    }
}
#============================================
# VYOS ISO CHECK
#============================================
#build the path to iso in scripts root dir
[string]$IsosPath = Join-Path -Path $ResourceRoot -ChildPath 'isos'
$vyosIsoSizeMb = 230

If(!$NoVyosISOCheck){
    If($VyosIsoPath -match 'latest'){
        [uri]$vyossource = 'https://downloads.vyos.io/rolling/current/amd64/vyos-rolling-latest.iso'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
        #Assume if set to latest, force download (no prompt)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    ElseIf( ($VyosIsoPath -match 'default') -and (Test-Path "$IsosPath\vyos-1.1.8-amd64.iso") ){
        $destination = "$IsosPath\vyos-1.1.8-amd64.iso"
    }
    ElseIf([string]::IsNullOrEmpty($VyosIsoPath) -or ($VyosIsoPath -match 'default') ){
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        [uri]$vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    Else{
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        [uri]$vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)

        # Destination to save the file
        If(Test-Path $VyosIsoPath -ErrorAction SilentlyContinue){
            $destination = $VyosIsoPath
        }
        ElseIf(Test-Path "$Env:USERPROFILE\downloads" -ErrorAction SilentlyContinue){
            $destination = "$Env:USERPROFILE\downloads\$vyosfilename"
        }
        Else{
            $destination = "$Env:temp\$vyosfilename"
        }
    }

    If( !(Test-Path $destination) )
    {
        If($Null -eq $VyOSResponse){
            Write-host ("No iso found in [{0}]" -f $destination) -ForegroundColor Red
            $VyOSResponse = Read-host "Would you like to attempt to download the VyOS router ISO? [Y or N]"
        }

        If($VyOSResponse -eq 'Y')
        {
            $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
            Write-host ("Attempting to download [{0}] from [{1}].`nThis can take awhile..." -f $vyosfilename,$vyossource) -ForegroundColor Yellow -NoNewline
            #Download the file
            Try{
                Invoke-WebRequest -Uri $vyossource -OutFile $destination -ErrorAction Stop
                Write-Host "Done" -ForegroundColor Green
            }
            Catch{
                Write-host ('Unable to download [{0}]: {1}' -f $vyosfilename,$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
                break
            }
            Finally{
                $VyosIsoPath = $destination
            }
        }
        Else{
            Write-host ("You must download the VyOS iso from [{0}] before continuing!" -f $vyossource) -ForegroundColor Black -BackgroundColor Red
            break
        }
    }
    ElseIf( ($runningsize = (Get-Item $destination).length/1MB) -lt $vyosIsoSizeMb){
        Write-host ("The downloaded VyOS iso is smaller [{0}Mb] than [{1}Mb]. Please rerun script again..." -f $runningsize,$vyosIsoSizeMb) -BackgroundColor Red
        Remove-Item $destination -Confirm -Force | Out-null
        break
    }
    Else{
        $VyosIsoPath = $destination
    }
}
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

#get the next available IP for the router
$SubnetsFromAzureTenantASpokeCIDR = @()
$SubnetsFromAzureTenantASpokeCIDR += Get-SimpleSubnets -Cidr $TenantASpokeCIDR -Count $TenantASpokeSubnetCount
$SubnetsFromAzureTenantAHubCIDR = Get-SimpleSubnets -Cidr $TenantAHubCIDR

Write-host "Done." -ForegroundColor Green
#============================================
## SIMPLE CONFIGURATION
#============================================

Write-Host "Building Simple configurations..." -NoNewline

#region Azure Network Configurations
#-----------------------------------------
$SiteName = ($LabPrefix + '-' + $SimpleAppendix + '-' + $AzureLocation).Trim('-').Replace(" ",'').ToLower() 

$AzureSimpleConfig = @{
    LocationName = $AzureLocation
    #Dynamic Variables

    ResourceGroupName = 'rg-' + $SiteName
    VnetName = 'vnet-' + $SiteName
    VnetGatewayName = 'vgw-' + $SiteName
    LocalGatewayName = 'lgw-' + $SiteName
    PublicIPName = 'pip-' + $SiteName
    ConnectionName = 'cn-' + $SiteName

    #Azure vnet CIDR
    VnetCIDRPrefix = $TenantAHubCIDR
    #Azure subnet prefixes
    DefaultSubnetName = 'snet-' + $SiteName + '-default001'
    #VnetSubnetPrefix = ($TenantAHubCIDR -replace '/\d+$', '/24')
    VnetSubnetPrefix = $SubnetsFromAzureTenantAHubCIDR[0]

    VnetGatewayIpConfigName = 'vgwip-' + $SiteName
    VnetGatewayPrefix = ($SubnetsFromAzureTenantAHubCIDR[-1] -replace '/\d+$', '/26')

    TunnelDescription = ('Gateway to ' + $SiteName + '(' + $TenantName + ')').Replace('-',' ')

    #storage account info
    StorageAccountName = ('st' + $SiteName + '001').replace('-','')
    StorageSku = 'Standard_LRS'
}
#endregion


#region Virtual Machine Configurations
#-------------------------------------------
$AzureSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToUpper() | Set-TruncateString -length 11)
    Name = 'vm-' + $SiteName
    Size = 'Standard_B1ms'

    NICName = 'nic-' + $SiteName

    VNetName = $AzureSimpleConfig.VnetName
    VnetAddressPrefix = $AzureSimpleConfig.VnetCIDRPrefix

    SubnetName = $AzureSimpleConfig.DefaultSubnetName
    SubnetAddressPrefix = $AzureSimpleConfig.VnetSubnetPrefix[0]

    NSGName = 'nsg-' + $SiteName

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email #set to either an email or webhook url
    ShutdownTimeZone = $timeZone 
    ShutdownTime = '21:00'
}

Write-host "Done." -ForegroundColor Green


#============================================
## ADVANCED CONFIGURATION - TENANT A
#============================================
Write-Host "Building Tenant A configurations..." -NoNewline

#region Azure Network Configurations - Region 1
#---------------------------------------------------------

$SiteAName = ($LabPrefix + '-' + $TenantASiteName + '-' + $AzureLocation).Trim('-').Replace(" ",'').ToLower() 
$SiteAShortName = ($LabPrefix + '-' + $AzureLocation).Trim('-').Replace(" ",'').ToLower() 

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantA = @{
    LocationName = $AzureLocation

    ResourceGroupName = 'rg-' + $SiteAName

    VnetSpokeName = 'vnet-' + $SiteAShortName + '-spoke'
    VnetSpokeCIDRPrefix = $TenantASpokeCIDR
    VnetSpokeSubnetName = 'snet-' + $LabPrefix.ToLower() + '-spoke-001'
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantASpokeCIDR[0]
    VnetSpokeBastionAddressPrefix = ((Get-SimpleSubnets -Cidr $TenantASpokeCIDR)[-1] -replace '/\d+$', '/29')

    VnetGatewayIpConfigName = 'vgwip-' + $SiteAShortName

    VnetHubName = 'vnet-' + $SiteAShortName + '-hub'
    VnetHubCIDRPrefix = $TenantAHubCIDR
    VnetHubSubnetName = 'snet-' + $LabPrefix.ToLower() + '-hub-001'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureTenantAHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureTenantAHubCIDR[1] -replace '/\d+$', '/27')
    VnetHubFirewallAddressPrefix = ($SubnetsFromAzureTenantAHubCIDR[2] -replace '/\d+$', '/26')
    VnetHubBastionAddressPrefix = ($SubnetsFromAzureTenantAHubCIDR[3] -replace '/\d+$', '/29')
    VnetASN = 65010

    NSGBastionName = 'nsg-' + $SiteAShortName + '-snet-bastion'
    NSGSpokeName = 'nsg-' + $SiteAShortName + '-snet-spoke'
    NSGHubName = 'nsg-' + $SiteAShortName + '-snet-hub'
    NSGGatewayName = 'nsg-' + $SiteAShortName + '-vgw'

    DeployBastionHost = $false
    BastionHostName = 'ab-' + $SiteAShortName + '-001'
    BastionPublicIPName = 'pip-' + $SiteAShortName + 'bastion-001'

    DeployFirewall = $false
    FirewallSku='Basic'
    FirewallHostName = 'fw-' + $SiteAShortName + '-001'

    PublicIpName = 'pip-' + $SiteAShortName + '-vgw'

    VnetPeerNameAB = ('peer-' + $SiteAShortName + '-hubtospoke')
    VnetPeerNameBA = ('peer-' + $SiteAShortName + '-spoketohub')

    VnetGatewayName = 'vgw-' + $SiteAShortName
    LocalGatewayName = 'lgw-' + $SiteAShortName
    ConnectionName = 'connection-to-' + $LabPrefix.ToLower() + '-onprem'

    TunnelDescription = ('Gateway to ' + $SiteAShortName + ' (' + $TenantName + ')').replace('-',' ')

    StorageSku = 'standard_lrs'
    StorageAccountName = ('st' + $SiteAShortName + '001').replace('-','')

    RouteTableName = 'rt-' + $SiteAShortName
    RouteTableRoutes = @{
        "Route-To-$($LabPrefix.ToUpper())"="$OnPremSubnetCIDR"
    }
    RouteTableSubnets = @(
        "snet-$SiteAShortName-spoke-001"
    )
}


# Virtual Machine Configurations - Region 1
#-------------------------------------------
$AzureVMSiteA = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToUpper() | Set-TruncateString -length 10) + '-A001'
    Name = 'vm-' + $SiteAName
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2019-Datacenter'
    Version = 'latest'

    NICName = 'nic-' + $SiteAName

    VNetName = $AzureAdvConfigTenantA.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigTenantA.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix

    NSGName = 'nsg-' + $SiteAName

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = $timeZone 
    ShutdownTime = '23:00'
}

#endregion

Write-Host "Done" -ForegroundColor Green
#============================================
## ADVANCED CONFIGURATION - TENANT B
#============================================
Write-Host "Building Tenant B configurations..." -NoNewline

$SubnetsFromAzureTenantBSpokeCIDR = @()
$SubnetsFromAzureTenantBSpokeCIDR += Get-SimpleSubnets -Cidr $TenantBSpokeCIDR -Count $TenantBSpokeSubnetCount
$SubnetsFromAzureTenantBHubCIDR = Get-SimpleSubnets -Cidr $TenantBHubCIDR

#region Azure Network Configurations - Region 2
#--------------------------------------------------------
$TenantBLocationName = 'West US'
$SiteBName = ($LabPrefix + '-' + $TenantBSiteName + '-' + $TenantBLocationName).Trim('-').Replace(" ",'').ToLower() 


#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantB = @{
    LocationName = $TenantBLocationName

    ResourceGroupName = 'rg-' + $SiteBName

    VnetSpokeName = 'vnet-' + $SiteBName + '-spoke'
    VnetSpokeCIDRPrefix = $TenantBSpokeCIDR
    VnetSpokeSubnetName =  'snet-' + $SiteBName
    #VnetSpokeSubnetAddressPrefix = ($TenantBSpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantBSpokeCIDR

    VnetGatewayIpConfigName = $SiteBName + '-gateway-ipconfig'

    VnetHubName = 'vnet-' + $SiteBName + '-hub'
    VnetHubCIDRPrefix = $TenantBHubCIDR
    VnetHubSubnetName = 'snet-' + $SiteBName
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureTenantBHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureTenantBHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65011

    NSGSpokeName = 'nsg-snet-' + $SiteBName
    NSGGatewayName = 'nsg-vgw-' + $SiteBName

    StorageSku = "standard_lrs"

    PublicIpName = 'pip-' + $SiteBName + '-vgw'

    VnetPeerNameAB = ($SiteBName + 'HubToSpoke').replace("-",'')
    VnetPeerNameBA = ($SiteBName + 'SpokeToHub').replace("-",'')

    VnetGatewayName = ($SiteBName).ToLower() + '-vgw'
    LocalGatewayName = $SiteBName + '-lgw'
    ConnectionName = ('cn-' + $SiteBName)

    TunnelDescription = ('Gateway to ' + $SiteBName + '(' + $TenantName + ')').replace('-',' ')

    StorageAccountName = ('sa' + $SiteBName.ToLower() + '001').replace('-','')
}


# Virtual Machine Configurations - Region 2
#-------------------------------------------
$AzureVMTenantB = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToUpper() | Set-TruncateString -length 10) + '-B001'
    Name = 'vm-' + $SiteBName
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2016-Datacenter'
    Version = 'latest'

    NICName = 'nic-' + $SiteBName

    VNetName = $AzureAdvConfigTenantB.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigTenantB.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigTenantB.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix

    NSGName = 'nsg-' + $SiteBName

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = $timeZone 
    ShutdownTime = '23:00'
}

#endregion

#region Region 1 to Region 2 connection
#----------------------------------------------------------
$AzureAdvConfigTenantAtoBConn= @{
    rg1=$AzureAdvConfigTenantA.ResourceGroupName
    rg2=$AzureAdvConfigTenantB.ResourceGroupName
    loc1=$AzureAdvConfigTenantA.LocationName
    loc2=$AzureAdvConfigTenantB.LocationName
    VNetGatewayName1=$AzureAdvConfigTenantA.VnetGatewayName
    VNetGatewayName2=$AzureAdvConfigTenantB.VnetGatewayName

    Connection12  = 'cn-' + $SiteAName + '-to-' + $SiteBName +$Appendix
    Connection21  = 'cn-' + $SiteBName + '-to-' + $SiteAName +$Appendix
}

#endregion
Write-Host "Done" -ForegroundColor Green