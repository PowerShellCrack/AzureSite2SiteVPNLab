Param(
    [switch]$NoAzureCheck,
    [switch]$NoVyosISOCheck
)
#============================================
# General Configurations - EDIT THIS
#============================================

$LabPrefix = 'MECMCBLAB' #identifier for names in lab

$domain = 'contoso.com' #just a name for now (no DC install....yet)

$Email = 'ritracyi@microsoft.com' #used only in autoshutdown (for now)

#this is used to configure default username and password on Azure VM's
$VMAdminUser = 'xAdmin'
$VMAdminPassword = '<password>'

#NOTE: Make sure ALL subnets do not overlap!
$OnPremSubnetCIDR = '10.120.0.0/16' #Always use /16
$OnPremSubnetCount = 2

$RegionSiteAId = 'SiteA'
$AzureSiteAHubCIDR = '10.23.0.0/16' #Always use /16
$AzureSiteASpokeCIDR = '10.22.0.0/16' #Always use /16

$RegionSiteBId = 'SiteB'
$AzureSiteBHubCIDR = '10.33.0.0/16' #Always use /16
$AzureSiteBSpokeCIDR = '10.32.0.0/16' #Always use /16

$DHCPLocation = '<ip, server, or router>'   #defaults to dhcp server not on router; assumes dhcp is on a server
                                            #if <router> is specified, dhcp server will be enabled but a full DHCP scope will be built for each subnets automatically (eg. 10.22.1.1-10.22.1.255)

$DNSServer = '<ip, ip addresses (comma delimitated), router>'   #if not specified; defaults to fourth IP in spoke subnet scope (eg. 10.22.1.4). This would be Azure's first available ip for VM
                                                                # if <router> is specified; google ip 8.8.8.8 will be used since no dns server exist on router

$HyperVVMLocation = '<default>' #Leave as <default> for auto detect
$HyperVHDxLocation = '<default>' #Leave as <default> for auto detect

$VyosIsoPath = '<default>' #Add path (eg. 'E:\ISOs\VyOS-1.1.8-amd64.iso') or use <latest> to get the latest vyos ISO (this is still in BETA)
                  #If path left blank or default, it will attempt to download the supported versions (1.1.8)

$HyperVVmIsoPath = 'E:\ISOs\en-us_windows_10_business_editions_version_20h2_updated_october_2021_x64_dvd_e057173c.iso'

$UseBGP = $false # not required for VPN, but can help. Costs more.
#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview

#used in step 5
$AzureVnetToVnetPeering = @{
    SiteASubscriptionID = '<SubscriptionAID>'
    SiteATenantID= '<TenantAID>'
    SiteBSubscriptionID = '<SubscriptionBID>'
    SiteBTenantID = '<TenantBID>'
}

#Uses Git, SSH and SCP to build vyos router
# 99% automated; but 90% successful
$RouterAutomationMode = $True

#============================================
# General Configurations - STOP HERE
#============================================

##*=============================================
##* Runtime Function - REQUIRED
##*=============================================

#region FUNCTION: Check if running in ISE
Function Test-IsISE {
    # trycatch accounts for:
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

#region FUNCTION: Find script path for either ISE or console
Function Get-ScriptPath {
    <#
        .SYNOPSIS
            Finds the current script path even in ISE or VSC
        .LINK
            Test-VSCode
            Test-IsISE
    #>
    param(
        [switch]$Parent
    )

    Begin{}
    Process{
        Try{
            if ($PSScriptRoot -eq "")
            {
                if (Test-IsISE)
                {
                    $ScriptPath = $psISE.CurrentFile.FullPath
                }
                elseif(Test-VSCode){
                    $context = $psEditor.GetEditorContext()
                    $ScriptPath = $context.CurrentFile.Path
                }Else{
                    $ScriptPath = (Get-location).Path
                }
            }
            else
            {
                $ScriptPath = $PSCommandPath
            }
        }
        Catch{
            $ScriptPath = '.'
        }
    }
    End{

        If($Parent){
            Split-Path $ScriptPath -Parent
        }Else{
            $ScriptPath
        }
    }

}
#endregion

Function Resolve-ActualPath{
    [CmdletBinding()]
    param(
        [string]$FileName,
        [string]$WorkingPath,
        [Switch]$Parent
    )
    ## Get the name of this function
    [string]${CmdletName} = $MyInvocation.MyCommand

    If(Resolve-Path $FileName -ErrorAction SilentlyContinue){
        $FullPath = Resolve-Path $FileName
    }
    #If unable to resolve the file path try building path from working path location
    Else{
        $FullPath = Join-Path -Path $WorkingPath -ChildPath $FileName
    }

    #Try to resolve the path one more time using the fullpath set
    Try{
        $ResolvedPath = Resolve-Path $FullPath -ErrorAction $ErrorActionPreference
    }
    Catch{
        Throw ("{0}" -f $_.Exception.Message)
    }
    Finally{
        If($Parent){
            $Return = Split-Path $ResolvedPath -Parent
        }Else{
            $Return = $ResolvedPath.Path
        }
        $Return
    }
}


##*========================================================================
##* BUILD PATHS
##*========================================================================
#region VARIABLES: Building paths & values
# Use function to get paths because Powershell ISE & other editors have different results
[string]$scriptPath = Get-ScriptPath
[string]$scriptFileName = Split-Path -Path $scriptPath -Leaf
[string]$scriptRoot = Split-Path -Path $scriptPath -Parent

If($null -eq $scriptRoot){
    $FunctionPath = Resolve-ActualPath -FileName library.ps1 -WorkingPath 'Functions' -Parent
}Else{
    [string]$FunctionPath = Join-Path -Path $scriptRoot -ChildPath 'Functions'
}

#region library custom functions
. "$FunctionPath\library.ps1"
. "$FunctionPath\vyos.ps1"
. "$FunctionPath\network.ps1"
#endregion

Write-Host "Processed functions. Loading configuration data..." -ForegroundColor Green

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
        $HomePublicIP = Read-host "Unable to retrieve public ip. What is your public IP?"
    } until ( $HomePublicIP -as [System.Net.IPAddress])
}

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global variable so it used for the entire session
If(!$Global:randomChar){
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($AzureSiteAHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$AzureSiteAHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($AzureSiteBHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$AzureSiteBHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($AzureSiteAHubCIDR -replace '/\d+$','') -ip2 ($AzureSiteASpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$AzureSiteAHubCIDR] and [`$AzureSiteASpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($AzureSiteBHubCIDR -replace '/\d+$','') -ip2 ($AzureSiteBSpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$AzureSiteBHubCIDR] and [`$AzureSiteBSpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}
#============================================
# AZURE CONNECTION
#============================================
#region connect to Azure if not already connected
If(!$NoAzureCheck){
    If((Find-Module Az).Version -in (Get-InstalledModule Az -AllVersions).version){
        Write-Verbose "Az Module Loaded"
    }
    Else{
        Install-Module -Name Az -AllowClobber -Scope AllUsers -Force
    }

    Try{
        #grab current AZ resources
        $Context = Get-AzContext -ErrorAction Stop
    }
    Catch{
        Write-host ("Failed to get Azure context. {0}" -f $_.Exception.Message) -ForegroundColor yellow
        Clear-AzDefault -ErrorAction SilentlyContinue -Force
        Clear-AzContext -ErrorAction SilentlyContinue -Force
        Disconnect-AzAccount -ErrorAction SilentlyContinue
    }
    Finally{
        If($null -eq $Context){
            Connect-AzAccount -Force
        }
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
[string]$IsosPath = Join-Path -Path $scriptRoot -ChildPath 'isos'
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
        $vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        $vyosfilename = (Split-Path $vyossource -Leaf)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    Else{
        $vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
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
            $VyOSResponse = Read-host "Would you like to attempt to download the Vyos router ISO? [Y or N]"
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
                Write-host ('UNable to download [{0}]: {1}' -f $vyosfilename,$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
                break
            }
            Finally{
                $VyosIsoPath = $destination
            }
        }
        Else{
            Write-host ("You must download the vyos iso from [{0}] before continuing!" -f $vyossource) -ForegroundColor Black -BackgroundColor Red
            break
        }
    }
    ElseIf( ($runningsize = (Get-Item $destination).length/1MB) -lt $vyosIsoSizeMb){
        Write-host ("The downloaded vyos iso is smaller [{0}Mb] than [{1}Mb]. Please rerun script again..." -f $runningsize,$vyosIsoSizeMb) -BackgroundColor Red
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




$HyperVSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 11) + '-vm2'
    Name = $RegionName + '-vm2'
    ISOLocation = $HyperVVmIsoPath
    Unattended = $true
    HDDSize=60GB #in gigabytes
}
#endregion

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

    ResetVPNConfigs = $false # this will delete the configurations of any vpn settings in VyOS

    #CIDR for local network
    LocalCIDRPrefix = $OnPremSubnetCIDR

    LocalSubnetPrefix = @{}

    BgpAsn = 65168 #CHANGE: set as default asn

    UseDNSOption = 'Internal' #CHANGE: 'Internal'<--uses VM DNS like a DC; 'External' <--Use home network DNS configs; 'Internet' <-- Uses Google

    EnableDHCP = $IsDhcpOnRouter

    DhcpRelayIP = $DefaultRelayIp

    DHCPPoolsRanges = @{}

    EnablePXERelay = $IsDhcpPxeRelayAvailable #True or False: PXE relay may be same a DHCP relay

    EnableNAT = $True
}

#build dns server list
$VyOSConfig['InternalDNSIP']  = @()
$DNSServers = @()
$DNSServers = $DNSServer.split(',')
Foreach ($Dns in $DNSServers)
{
    If(Test-IPAddress $Dns){
        $VyOSConfig['InternalDNSIP'] += $Dns
    }
}
#incase there is no valid DNS IP's add fourth IP (we need at least one for router)
If($VyOSConfig['InternalDNSIP'].count -eq 0){
    If($DNSServer -match 'Router'){$DNStoAdd = '8.8.8.8'}Else{$DNStoAdd = $FourthIp}
    If($FourthIp -notin $VyOSConfig['InternalDNSIP']){
        $VyOSConfig['InternalDNSIP'] += $DNStoAdd
    }
}

#build vyos local subnet and description
$SubnetTable = $VyOSConfig['LocalSubnetPrefix']
Foreach ($Subnet in $SimpleSubnetsFromOnPremCIDR)
{
    $SubnetNoCider = $Subnet -replace '/\d+$',''
    if(-Not($SubnetTable.ContainsKey($Subnet)) ){
        $SubnetTable[$Subnet] = $SubnetNoCider + '_Subnet'
    }
}

#build vyos dhcp pool (even if its not used)
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
$RegionName = ($LabPrefix.Replace(" ",'') + '-Basic').ToLower()

$SubnetsFromAzureSiteASpokeCIDR = Get-SimpleSubnets -Cidr $AzureSiteASpokeCIDR
$SubnetsFromAzureSiteAHubCIDR = Get-SimpleSubnets -Cidr $AzureSiteAHubCIDR


$SubnetsFromAzureSiteBSpokeCIDR = Get-SimpleSubnets -Cidr $AzureSiteBSpokeCIDR
$SubnetsFromAzureSiteBHubCIDR = Get-SimpleSubnets -Cidr $AzureSiteBHubCIDR


$AzureSimpleConfig = @{
    LocationName = 'East US 2'
    #Dynabmic Variables

    ResourceGroupName = $RegionName + '-rg'
    VnetName = $RegionName + '-vNet'
    VnetGatewayName = $RegionName + '-vng'
    LocalGatewayName = $RegionName + '-lng'
    PublicIPName = $RegionName + '-pip'
    ConnectionName = ('connection-to-' + $RegionName)

    #Azure vnet CIDR
    VnetCIDRPrefix = $AzureSiteAHubCIDR
    #Azure subnet prefixes
    DefaultSubnetName = $RegionName + '-default-subnet'
    #VnetSubnetPrefix = ($AzureSiteAHubCIDR -replace '/\d+$', '/24')
    VnetSubnetPrefix = $SubnetsFromAzureSiteAHubCIDR[0]

    VnetGatewayIpConfigName = $RegionName + '-gateway-ipconfig'
    VnetGatewayPrefix = ($SubnetsFromAzureSiteAHubCIDR[-1] -replace '/\d+$', '/26')

    TunnelDescription = ('Gateway to ' + $RegionName + ' in Azure').Replace('-',' ')

    #storage account info
    StorageAccountName = $RegionName + '-sa'
    StorageSku = 'Standard_LRS'
}
#endregion


#region Virtual Machine Configurations
#-------------------------------------------
$AzureSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 11) + '-vm1'
    Name = $RegionName + '-vm1'
    Size = 'Standard_B1ms'

    NICName = $LabPrefix + '-vm1-ni'

    VNetName = $AzureSimpleConfig.VnetName
    VnetAddressPrefix = $AzureSimpleConfig.VnetCIDRPrefix

    SubnetName = $AzureSimpleConfig.DefaultSubnetName
    SubnetAddressPrefix = $AzureSimpleConfig.VnetSubnetPrefix

    NSGName = $RegionName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email #set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}


#============================================
## ADVANCED CONFIGURATION
#============================================
#region Azure Network Configurations - Region 1
#---------------------------------------------------------
$RegionAName = ($LabPrefix.Replace(" ",'') + '-' + $RegionSiteAId).ToLower()

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteA = @{
    LocationName = 'East US'

    ResourceGroupName = $RegionAName + '-rg'

    VnetSpokeName = $RegionAName + '-spoke-vnet'
    VnetSpokeCIDRPrefix = $AzureSiteASpokeCIDR
    VnetSpokeSubnetName = $RegionAName + '-spoke-subnet'
    #VnetSpokeSubnetAddressPrefix = ($AzureSiteASpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureSiteASpokeCIDR[0]

    VnetGatewayIpConfigName = $RegionAName + '-gateway-ipconfig'

    VnetHubName = $RegionAName + '-hub-vnet'
    VnetHubCIDRPrefix = $AzureSiteAHubCIDR
    VnetHubSubnetName = $RegionAName + '-hub-subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureSiteAHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureSiteAHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65010

    NSGSpokeName = $RegionAName + '-spoke-nsg'
    NSGGatewayName = $RegionAName + '-gateway-nsg'

    StorageSku = 'standard_lrs'

    PublicIpName = $RegionAName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($RegionAName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionAName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionAName).Replace(" ",'').ToLower() + '-vng'
    LocalGatewayName = $RegionAName + '-lng'
    ConnectionName = ('connection-to-' + $RegionAName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionAName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionAName).Replace(" ",'').ToLower() + '-sa'
}


# Virtual Machine Configurations - Region 1
#-------------------------------------------
$AzureVMSiteA = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 9) + '-a-vm1'
    Name = $LabPrefix + '-vm1'
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2019-Datacenter'
    Version = 'latest'

    NICName = $RegionAName + '-vm1-ni'

    VNetName = $AzureAdvConfigSiteA.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigSiteA.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix

    NSGName = $RegionAName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}

#endregion


#region Azure Network Configurations - Region 2
#--------------------------------------------------------
$RegionBName = ($LabPrefix.Replace(" ",'') + '-' + $RegionSiteBId).ToLower()

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteB = @{
    LocationName = 'East US 2'

    ResourceGroupName = $RegionBName + '-rg'

    VnetSpokeName = $RegionBName + '-spoke-vnet'
    VnetSpokeCIDRPrefix = $AzureSiteBSpokeCIDR
    VnetSpokeSubnetName =  $RegionBName + '-spoke-subnet'
    #VnetSpokeSubnetAddressPrefix = ($AzureSiteBSpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureSiteBSpokeCIDR[0]

    VnetGatewayIpConfigName = $RegionBName + '-gateway-ipconfig'

    VnetHubName = $RegionAName + '-Hub-vnet'
    VnetHubCIDRPrefix = $AzureSiteAHubCIDR
    VnetHubSubnetName = $RegionAName + '-hub-subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureSiteBHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureSiteBHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65011

    NSGSpokeName = $RegionBName + '-spoke-nsg'
    NSGGatewayName = $RegionBName + '-gateway-nsg'

    StorageSku = "standard_lrs"

    PublicIpName = $RegionBName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($RegionBName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionBName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionBName).Replace(" ",'').ToLower() + '-vng'
    LocalGatewayName = $RegionBName + '-lng'
    ConnectionName = ('connection-to-' + $RegionBName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionBName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionBName).Replace(" ",'').ToLower() + '-sa'
}

# Virtual Machine Configurations - Region 2
#-------------------------------------------
$AzureVMSiteB = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix.ToLower() | Set-TruncateString -length 9) + '-b-vm1'
    Name = $RegionBName + '-vm1'
    Size = 'Standard_B2s'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2016-Datacenter'
    Version = 'latest'

    NICName = $RegionBName + '-vm1-ni'

    VNetName = $AzureAdvConfigSiteB.VnetSpokeName
    VnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeCIDRPrefix

    SubnetName = $AzureAdvConfigSiteB.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix

    NSGName = $RegionBName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = 'Pacific Standard Time'
    ShutdownTime = '21:00'
}

#endregion

#region Region 1 to Region 2 connection
#----------------------------------------------------------
$AzureAdvConfigSiteAtoBConn= @{
    rg1=$AzureAdvConfigSiteA.ResourceGroupName
    rg2=$AzureAdvConfigSiteB.ResourceGroupName
    loc1=$AzureAdvConfigSiteA.LocationName
    loc2=$AzureAdvConfigSiteB.LocationName
    VNetGatewayName1=$AzureAdvConfigSiteA.VnetGatewayName
    VNetGatewayName2=$AzureAdvConfigSiteB.VnetGatewayName

    Connection12  = $RegionAName + '-to-' + $RegionBName +'-conn'
    Connection21  = $RegionBName + '-to-' + $RegionAName +'-conn'
}

#endregion
