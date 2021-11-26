﻿Param(
    [switch]$NoAzureCheck
)
#============================================
# General Configurations - EDIT THIS
#============================================

$LabPrefix = 'contoso' #identifier for names in lab

$domain = 'lab.contoso.com' #just a name for now (no DC install....yet)

$Email = '' #used only in autoshutdown (for now)

#this is used to configure default username and password on Azure VM's
$VMAdminUser = 'xAdmin'
$VMAdminPassword = '<password>'

$OnPremSubnetCIDR = '10.120.0.0/16' #Always use /16
$OnPremSubnetCount = 2

$RegionSiteAId = 'SiteA'
$AzureSiteAHubCIDR = '10.23.0.0/16' #Always use /16
$AzureSiteASpokeCIDR = '10.22.0.0/16' #Always use /16

$RegionSiteBId = 'SiteB'
$AzureSiteBHubCIDR = '10.33.0.0/16' #Always use /16
$AzureSiteBSpokeCIDR = '10.32.0.0/16' #Always use /16

$VyosIsoPath = 'E:\ISOs\VyOS-1.1.8-amd64.iso'

$HyperVVMLocation = '<default>' #Leave as <default> for auto detect
$HyperVHDxLocation = '<default>' #Leave as <default> for auto detect

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
# STOP
#============================================

# Destination to save the file
If(Test-Path "$Env:USERPROFILE\downloads"){
    $destination = "$Env:USERPROFILE\downloads\VyOS-1.1.8-amd64.iso"
}Else{
    $destination = "$Env:temp\VyOS-1.1.8-amd64.iso"
}

# Source file location
If( !(Test-Path $VyosIsoPath) -and !(Test-Path $destination) )
{
    $vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
    $VyOSResponse = Read-host "Would you like to attempt to download the Vyos router ISO? [Y or N]"
    If($VyOSResponse -eq 'Y')
    {
        Write-host "Attempting to download [vyos-1.1.8-amd64.iso] from [$vyossource]. This can take awhile..." -ForegroundColor Yellow -NoNewline
        #Download the file
        Invoke-WebRequest -Uri $vyossource -OutFile $destination
        Write-Host "Done" -ForegroundColor Green
        $VyosIsoPath = $destination
    }
    Else{
        Write-host "You must download the vyos iso before continuing! [$vyossource]" -ForegroundColor Red
        break
    }
}

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

#check if SSH and SCP exist for automation mode to work
If(-Not(Test-Command ssh) -and -Not(Test-Command scp) -and -Not(Test-Command ssh-keygen) )
{
    Write-Host ("SSH, SCP, SSH-KEYGEN commands not found. Disabling Automation mode {0} " -f $_.exception.message) -ForegroundColor Red
    $RouterAutomationMode = $False
}

#Build a log folder for transactions
New-Item "$scriptPath\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Home network Public IP
# go to whatsmyip.com
$HomePublicIP = Invoke-RestMethod http://ipinfo.io/json | Select -exp ip

#run if not no variable found in global
#Make it a global variable so it used for the entire session
#If(!$Global:sharedPSKKey){$Global:sharedPSKKey = New-SharedPSKey}
$Global:sharedPSKKey = New-SharedPSKey
#TEST $Global:sharedPSKKey='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global variable so it used for the entire session
If(!$Global:randomChar){
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($AzureSiteAHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$AzureSiteAHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($AzureSiteBHubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$OnPremSubnetCIDR] and [`$AzureSiteBHubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($AzureSiteAHubCIDR -replace '/\d+$','') -ip2 ($AzureSiteASpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$AzureSiteAHubCIDR] and [`$AzureSiteASpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($AzureSiteBHubCIDR -replace '/\d+$','') -ip2 ($AzureSiteBSpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$AzureSiteBHubCIDR] and [`$AzureSiteBSpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Red
    break
}
#============================================
# AZURE CONNECTION
#============================================
#region connect to Azure if not already connected
If(!$NoAzureCheck){
    If((Find-Module Az).Version -in (Get-InstalledModule Az -AllVersions).version){
        Write-Host "Az Module Loaded"
    }
    Else{
        Install-Module -Name Az -AllowClobber -Scope AllUsers -Force
    }

    Try{
        $Subscription = Connect-AzureEnvironment -ErrorAction Stop
        Write-Host ("Using Account ID:   {0} " -f $Subscription.Account.Id) -ForegroundColor Green
        Write-host ("Using Subscription: {0} " -f $Subscription.Subscription.Name) -ForegroundColor Green
    }
    Catch{
        Write-Host ("DO NOT CONTINUE. {0} " -f $_.exception.message) -ForegroundColor Red
    }
}
#endregion
#============================================
# LAB CONFIGURATIONS
#============================================
If($HyperVVMLocation -eq '<default>')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $HyperVVMLocation = Get-VMHost | Select -ExpandProperty VirtualMachinePath
    }
    Else{
        $HyperVVMLocation = 'C:\ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines\'
    }
}

If($HyperVHDxLocation -eq '<default>')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $HyperVHDxLocation = Get-VMHost | Select -ExpandProperty VirtualHardDiskPath
    }
    Else{
        $HyperVHDxLocation = 'C:\Users\Public\Documents\Hyper-V\Virtual hard disks\'
    }
}


#region Hyper-V Configurations
#------------------------------
$HyperVConfig = @{
    ChangeLocation = $true
    VirtualMachineLocation = $HyperVVMLocation
    VirtualHardDiskLocation = $HyperVHDxLocation
    EnableSessionMode = $true
    ConfigureForVLAN = $False
    VLANID = 21
    AllowedvLanIdRange = '1-100'
}
#endregion


#region Edge router Configurations
#---------------------------------
#grab local router subnet for next hop
$NextHop = Get-WmiObject -Class Win32_IP4RouteTable | where { $_.destination -eq '0.0.0.0' -and $_.mask -eq '0.0.0.0'} | Select -ExpandProperty nexthop
$OnPremNetworkRange = Get-NetworkDetails -CidrAddress $OnPremSubnetCIDR
$SimpleSubnetsFromOnPremCIDR = Get-SimpleSubnets -Cidr $OnPremSubnetCIDR -Count $OnPremSubnetCount
$FirstIP = Get-NextAddress -Cidr $SimpleSubnetsFromOnPremCIDR[0]

$VyOSConfig = @{
    HostName = ('VyOS').ToLower()
    VMName = $LabPrefix.ToUpper() + '-Router'
    ISOLocation = $VyosIsoPath
    NetPrefix = 'LAN'
    TimeZone = 'US/Eastern'

    ExternalInterface = 'Default Switch' #CHANGE: Match one of the external network names in hyper config

    NextHopSubnet = $NextHop

    ResetVPNConfigs = $true #this will delete the configurations of any vpn settings in VyOS 1 time

    #CIDR for local network
    LocalCIDRPrefix = $OnPremSubnetCIDR

    LocalSubnetPrefix = @{}

    BgpAsn = 65168 #CHANGE: set as default asn

    UseDNSOption = 'Internal' #CHANGE: 'Internal'<--uses VM DNS like a DC; 'External' <--Use home network DNS configs; 'Internet' <-- Uses Google
    InternalDNSIP = @(
        $FirstIP
    )
    EnableDHCP = $false
    DHCPPoolsRanges = @{}

    EnablePXEPRelay = $true
    PXERelayIP = $FirstIP  #CHANGE this to actual ip if needed: ie 10.10.1.1

    EnableNAT = $True
}

$SubnetTable = $VyOSConfig['LocalSubnetPrefix']
Foreach ($Subnet in $SimpleSubnetsFromOnPremCIDR)
{
    $SubnetNoCider = $Subnet -replace '/\d+$',''
    if(-Not($SubnetTable.ContainsKey($Subnet)) ){
        $SubnetTable[$Subnet] = $SubnetNoCider + '_Subnet'
    }
}

$DHCPPoolTable = $VyOSConfig['DHCPPoolsRanges']
Foreach ($Subnet in $SimpleSubnetsFromOnPremCIDR)
{
    $SubnetNoCider = $Subnet -replace '/\d+$',''
    if(-Not($DHCPPoolTable.ContainsKey($Subnet)) ){
        $DHCPPoolTable[$SubnetNoCider] = ($SubnetNoCider -replace '.\d+$','.255')
    }
}

#============================================
## SIMPLE CONFIGURATION
#============================================
#region Azure Network Configurations
#-----------------------------------------
$RegionName = $LabPrefix.Replace(" ",'') + '-Basic'

$SubnetsFromAzureSiteASpokeCIDR = Get-SimpleSubnets -Cidr $AzureSiteASpokeCIDR
$SubnetsFromAzureSiteAHubCIDR = Get-SimpleSubnets -Cidr $AzureSiteAHubCIDR


$SubnetsFromAzureSiteBSpokeCIDR = Get-SimpleSubnets -Cidr $AzureSiteBSpokeCIDR
$SubnetsFromAzureSiteBHubCIDR = Get-SimpleSubnets -Cidr $AzureSiteBHubCIDR


$AzureSimpleConfig = @{
    LocationName = 'East US 2'
    #Dynabmic Variables

    ResourceGroupName = $RegionName + '-rg'
    VnetName = $RegionName + '-vNet'
    VnetGatewayName = $RegionName + '-vngw'
    LocalGatewayName = $RegionName + '-lgn'
    PublicIPName = $RegionName + '-pip'
    ConnectionName = $RegionName + '-Connection'

    #Azure vnet CIDR
    VnetCIDRPrefix = $AzureSiteAHubCIDR
    #Azure subnet prefixes
    DefaultSubnetName = $RegionName + '-default-subnet'
    #VnetSubnetPrefix = ($AzureSiteAHubCIDR -replace '/\d+$', '/24')
    VnetSubnetPrefix = $SubnetsFromAzureSiteAHubCIDR[0]

    VnetGatewayIpConfigName = $RegionName + '-Gateway-IpConfig'
    VnetGatewayPrefix = ($SubnetsFromAzureSiteAHubCIDR[-1] -replace '/\d+$', '/27')

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
    ComputerName = ($RegionName + '-vm1' | Set-TruncateString -length 15)
    Name = $RegionName + '-vm1'
    Size = 'Standard_DS3'

    NICName = $LabPrefix + '-svrb-nic'

    SubnetAddressPrefix = $AzureSimpleConfig.VnetSubnetPrefix
    VnetAddressPrefix = $AzureSimpleConfig.VnetCIDRPrefix

    NSGName = $RegionName + '-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email #set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}
#endregion

#============================================
## ADVANCED CONFIGURATION
#============================================
#region Azure Network Configurations - Region 1
#---------------------------------------------------------
$RegionAName = ($LabPrefix.Replace(" ",'') + '-' + $RegionSiteAId)

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteA = @{
    LocationName = 'East US'

    ResourceGroupName = $RegionAName + '-rg'

    VnetSpokeName = $RegionAName + '-Spoke-vNet'
    VnetSpokeCIDRPrefix = $AzureSiteASpokeCIDR
    VnetSpokeSubnetName = $RegionAName + '-Spoke-Subnet'
    #VnetSpokeSubnetAddressPrefix = ($AzureSiteASpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureSiteASpokeCIDR[0]

    VnetGatewayIpConfigName = $RegionAName + '-Gateway-IpConfig'

    VnetHubName = $RegionAName + '-Hub-vNet'
    VnetHubCIDRPrefix = $AzureSiteAHubCIDR
    VnetHubSubnetName = $RegionAName + '-Hub-Subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureSiteAHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureSiteAHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65010

    NSGSpokeName = $RegionAName + '-SpokeNSG'
    NSGGatewayName = $RegionAName + '-GatewayNSG'

    StorageSku = 'standard_lrs'

    PublicIpName = $RegionAName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($RegionAName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionAName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionAName).Replace(" ",'').ToLower() + '-vngw'
    LocalGatewayName = $RegionAName + '-lng'
    VnetConnectionName = ('ConnectionTo-' + $RegionAName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionAName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionAName).Replace(" ",'').ToLower() + '-sa'
}


# Virtual Machine Configurations - Region 1
#-------------------------------------------
$AzureVMSiteA = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($LabPrefix + '-dc2' | Set-TruncateString -length 15)
    Name = $LabPrefix + '-dc2'
    Size = 'Standard_DS3'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2019-Datacenter'
    Version = 'latest'

    NICName = $RegionAName + '-vm1-nic'
    SubnetName = $AzureAdvConfigSiteA.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix
    VnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix

    NSGName = $RegionAName + '-vm-nsg'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $Email # set to either an email or webhook url
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}

#endregion


#region Azure Network Configurations - Region 2
#--------------------------------------------------------
$RegionBName = ($LabPrefix.Replace(" ",'') + '-' + $RegionSiteBId)

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteB = @{
    LocationName = 'East US 2'

    ResourceGroupName = $RegionBName + '-rg'

    VnetSpokeName = $RegionBName + '-Spoke-vNet'
    VnetSpokeCIDRPrefix = $AzureSiteBSpokeCIDR
    VnetSpokeSubnetName =  $RegionBName + '-Spoke-Subnet'
    #VnetSpokeSubnetAddressPrefix = ($AzureSiteBSpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureSiteBSpokeCIDR[0]

    VnetGatewayIpConfigName = $RegionBName + '-Gateway-IpConfig'

    VnetHubName = $RegionAName + '-Hub-vNet'
    VnetHubCIDRPrefix = $AzureSiteAHubCIDR
    VnetHubSubnetName = $RegionAName + '-Hub-Subnet'
    VnetHubSubnetAddressPrefix = $SubnetsFromAzureSiteBHubCIDR[0]
    VnetHubSubnetGatewayAddressPrefix = ($SubnetsFromAzureSiteBHubCIDR[-56] -replace '/\d+$', '/26')

    VnetASN = 65011

    NSGSpokeName = $RegionBName + '-SpokeNSG'
    NSGGatewayName = $RegionBName + '-GatewayNSG'

    StorageSku = "standard_lrs"

    PublicIpName = $RegionBName.Replace(" ",'') + '-vngw-pip'

    VnetPeerNameAB = ($RegionBName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionBName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionBName).Replace(" ",'').ToLower() + '-vngw'
    LocalGatewayName = $RegionBName + '-lng'
    VnetConnectionName = ('ConnectionTo-' + $RegionBName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionBName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionBName).Replace(" ",'').ToLower() + '-sa'
}

# Virtual Machine Configurations - Region 2
#-------------------------------------------
$AzureVMSiteB = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ($RegionBName + '-vm1' | Set-TruncateString -length 15)
    Name = $RegionBName + '-vm1'
    Size = 'Standard_D2s_v3'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2016-Datacenter'
    Version = 'latest'

    NICName = $RegionBName + '-vm1-nic'
    SubnetName = $AzureAdvConfigSiteB.VnetSpokeSubnetName
    SubnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix
    VnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeCIDRPrefix

    NSGName = $RegionBName + '-vm-nsg'

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