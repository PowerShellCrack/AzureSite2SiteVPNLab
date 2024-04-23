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
#============================================
# General Configurations - STOP HERE
#============================================

##*=============================================
##* Runtime Function - REQUIRED
##*=============================================


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

Write-Host "Done" -ForegroundColor Green

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
        $vyossource = 'https://downloads.vyos.io/rolling/current/amd64/vyos-rolling-latest.iso'
        $vyosfilename = (Split-Path $vyossource -Leaf)
        #Assume if set to latest, force download (no prompt)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    ElseIf( ($VyosIsoPath -match 'default') -and (Test-Path "$IsosPath\vyos-1.1.8-amd64.iso") ){
        $destination = "$IsosPath\vyos-1.1.8-amd64.iso"
    }
    ElseIf([string]::IsNullOrEmpty($VyosIsoPath) -or ($VyosIsoPath -match 'default') ){
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        $vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource -Leaf)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    Else{
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        $vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource -Leaf)

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
            $vyosfilename = (Split-Path $vyossource -Leaf)
            Write-host ("Attempting to download [{0}] from [{1}].\nThis can take awhile..." -f $vyosfilename,$vyossource) -ForegroundColor Yellow -NoNewline
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
Write-Host "Building configuration data..." -NoNewline
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
    VMName = $LabPrefix.ToUpper() + '-Router'
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
    $SwitchName = ('LAN ' + $i + ' - ' + $Subnet.Name)
    $Description = ("LAN subnet for {1}: {0}" -f $Subnet.Name,$LabPrefix)
    $VirtualSwitchTable[$SwitchName] = $Description
    $i++
}
#============================================
## SIMPLE CONFIGURATION
#============================================
#region Azure Network Configurations
#-----------------------------------------
$SiteName = ($LabPrefix.Replace(" ",'') + '-' + $SimpleAppendix).Trim('-').ToLower()

$SubnetsFromAzureTenantASpokeCIDR = @()
$SubnetsFromAzureTenantASpokeCIDR += Get-SimpleSubnets -Cidr $TenantASpokeCIDR -Count $TenantASpokeSubnetCount
$SubnetsFromAzureTenantAHubCIDR = Get-SimpleSubnets -Cidr $TenantAHubCIDR

$SubnetsFromAzureTenantBSpokeCIDR = @()
$SubnetsFromAzureTenantBSpokeCIDR += Get-SimpleSubnets -Cidr $TenantBSpokeCIDR -Count $TenantBSpokeSubnetCount
$SubnetsFromAzureTenantBHubCIDR = Get-SimpleSubnets -Cidr $TenantBHubCIDR


$AzureSimpleConfig = @{
    LocationName = 'East US 2'
    #Dynabmic Variables

    ResourceGroupName = $SiteName + '-rg'
    VnetName = $SiteName + '-vNet'
    VnetGatewayName = $SiteName + '-vng'
    LocalGatewayName = $SiteName + '-lng'
    PublicIPName = $SiteName + '-pip'
    ConnectionName = ('connection-to-' + $SiteName)

    #Azure vnet CIDR
    VnetCIDRPrefix = $TenantAHubCIDR
    #Azure subnet prefixes
    DefaultSubnetName = $SiteName + '-default-subnet'
    #VnetSubnetPrefix = ($TenantAHubCIDR -replace '/\d+$', '/24')
    VnetSubnetPrefix = $SubnetsFromAzureTenantAHubCIDR[0]

    VnetGatewayIpConfigName = $SiteName + '-gateway-ipconfig'
    VnetGatewayPrefix = ($SubnetsFromAzureTenantAHubCIDR[-1] -replace '/\d+$', '/26')

    TunnelDescription = ('Gateway to ' + $SiteName + ' in Azure').Replace('-',' ')

    #storage account info
    StorageAccountName = $SiteName + '-sa'
    StorageSku = 'Standard_LRS'
}
#endregion

#update location if running gov
If($AzureGov){
    $AzureSimpleConfig['LocationName'] = 'usgovvirginia'
    $AzureSimpleConfig['TunnelDescription'] = ('Gateway to ' + $SiteName + ' in Azure Gov').Replace('-',' ')
}

#region Virtual Machine Configurations
#-------------------------------------------
$AzureSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 11) + '-vm1'
    Name = $SiteName + '-vm1'
    Size = 'Standard_B1ms'

    NICName = $LabPrefix + '-vm1-ni'

    VNetName = $AzureSimpleConfig.VnetName
    VnetAddressPrefix = $AzureSimpleConfig.VnetCIDRPrefix

    SubnetName = $AzureSimpleConfig.DefaultSubnetName
    SubnetAddressPrefix = $AzureSimpleConfig.VnetSubnetPrefix[0]

    NSGName = $SiteName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email #set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}

$HyperVSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 11) + '-vm2'
    Name = $SiteName + '-vm2'
    ISOLocation = $HyperVVmIsoPath
    Unattended = $true
    HDDSize=60GB #in gigabytes
}
#endregion

#============================================
## ADVANCED CONFIGURATION
#============================================
#region Azure Network Configurations - Region 1
#---------------------------------------------------------
$SiteAName = ($LabPrefix.Replace(" ",'') + '-' + $TenantASiteName).ToLower()

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantA = @{
    LocationName = 'East US'

    ResourceGroupName = $SiteAName + '-rg'

    VnetSpokeName = $SiteAName + '-spoke-vnet'
    VnetSpokeCIDRPrefix = $TenantASpokeCIDR
    VnetSpokeSubnetName = $SiteAName + '-spoke-subnet'
    #VnetSpokeSubnetAddressPrefix = ($TenantASpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantASpokeCIDR

    VnetGatewayIpConfigName = $SiteAName + '-gateway-ipconfig'

    VnetHubName = $SiteAName + '-hub-vnet'
    VnetHubCIDRPrefix = $TenantAHubCIDR
    VnetHubSubnetName = $SiteAName + '-hub-subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureTenantAHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureTenantAHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65010

    NSGSpokeName = $SiteAName + '-spoke-nsg'
    NSGGatewayName = $SiteAName + '-gateway-nsg'

    StorageSku = 'standard_lrs'

    PublicIpName = $SiteAName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($SiteAName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($SiteAName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($SiteAName).Replace(" ",'').ToLower() + '-vng'
    LocalGatewayName = $SiteAName + '-lng'
    ConnectionName = ('connection-to-' + $SiteAName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $SiteAName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($SiteAName).Replace(" ",'').ToLower() + '-sa'
}
#update location if running gov
If($AzureGov){
    $AzureAdvConfigTenantA['LocationName'] = 'usgovvirginia'
    $AzureAdvConfigTenantA['TunnelDescription'] = ('Gateway to ' + $SiteAName + ' in Azure Gov').Replace('-',' ')
}

# Virtual Machine Configurations - Region 1
#-------------------------------------------
$AzureVMTenantA = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 9) + '-a-vm1'
    Name = $LabPrefix + '-vm1'
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2019-Datacenter'
    Version = 'latest'

    NICName = $SiteAName + '-vm1-ni'

    VNetName = $AzureAdvConfigTenantA.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigTenantA.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigTenantA.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigTenantA.VnetSpokeSubnetAddressPrefix[0]

    NSGName = $SiteAName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}

#endregion


#region Azure Network Configurations - Region 2
#--------------------------------------------------------
$SiteBName = ($LabPrefix.Replace(" ",'') + '-' + $TenantBSiteName).ToLower()

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantB = @{
    LocationName = 'West US'

    ResourceGroupName = $SiteBName + '-rg'

    VnetSpokeName = $SiteBName + '-spoke-vnet'
    VnetSpokeCIDRPrefix = $TenantBSpokeCIDR
    VnetSpokeSubnetName =  $SiteBName + '-spoke-subnet'
    #VnetSpokeSubnetAddressPrefix = ($TenantBSpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantBSpokeCIDR

    VnetGatewayIpConfigName = $SiteBName + '-gateway-ipconfig'

    VnetHubName = $SiteBName + '-Hub-vnet'
    VnetHubCIDRPrefix = $TenantBHubCIDR
    VnetHubSubnetName = $SiteBName + '-hub-subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureTenantBHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureTenantBHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65011

    NSGSpokeName = $SiteBName + '-spoke-nsg'
    NSGGatewayName = $SiteBName + '-gateway-nsg'

    StorageSku = "standard_lrs"

    PublicIpName = $SiteBName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($SiteBName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($SiteBName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($SiteBName).Replace(" ",'').ToLower() + '-vng'
    LocalGatewayName = $SiteBName + '-lng'
    ConnectionName = ('connection-to-' + $SiteBName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $SiteBName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($SiteBName).Replace(" ",'').ToLower() + '-sa'
}

#update location if running gov
If($AzureGov){
    $AzureAdvConfigTenantB['LocationName'] = 'usgovarizona'
    $AzureAdvConfigTenantB['TunnelDescription'] = ('Gateway to ' + $SiteBName + ' in Azure Gov').Replace('-',' ')
}

# Virtual Machine Configurations - Region 2
#-------------------------------------------
$AzureVMTenantB = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 9) + '-b-vm1'
    Name = $SiteBName + '-vm1'
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2016-Datacenter'
    Version = 'latest'

    NICName = $SiteBName + '-vm1-ni'

    VNetName = $AzureAdvConfigTenantB.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigTenantB.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigTenantB.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigTenantB.VnetSpokeSubnetAddressPrefix[0]

    NSGName = $SiteBName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = 'Pacific Standard Time'
    ShutdownTime = '21:00'
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

    Connection12  = $SiteAName + '-to-' + $SiteBName +'-conn'
    Connection21  = $SiteBName + '-to-' + $SiteAName +'-conn'
}

#endregion
Write-Host "Done" -ForegroundColor Green
