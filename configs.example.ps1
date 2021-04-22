#============================================
# Called Functions
#============================================
#region library custom functions
. "$PSScriptRoot\library.ps1"
#endregion

If((Find-Module Az).Version -in (Get-InstalledModule Az -AllVersions).version){
    Write-Host "Az Module Loaded"
}
Else{
    Install-Module -Name Az -AllowClobber -Scope AllUsers -Force
}

#============================================
# General Configurations - EDIT THIS
#============================================
$LabPrefix = '<lab name>' #identifier for names in lab

$domain = '<lab fqdn>' #just a name for now (no DC install....yet)

$UseBGP = $false # not required for VPN, but can help. Costs more.
#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview

$AzEmail = '' #used only in autoshutdown (for now)

$AzSubscription = $null
$Subscription = Get-AzContext

#this is used to configure default username and password on Azure VM's
$VMAdminUser = '<admin>'
$VMAdminPassword = '<password>'


#Build a log folder for transactions
New-Item "$PSScriptRoot\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Home network Public IP
# go to whatsmyip.com
$HomePublicIP = Invoke-RestMethod http://ipinfo.io/json | Select -exp ip

#run if not no variable found in global
#Make it a global varibale so it used for the entire session
If(!$Global:sharedPSKKey){$Global:sharedPSKKey = New-SharedPSKey}
#$sharedPSKKey='bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRKJ516CCc1LeSMChAI0rc'

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global varibale so it used for the entire session
If(!$Global:randomChar){
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion

#============================================
# AZURE CONNECTION
#============================================
#region connect to Azure if not already connected
Try{
    If($null -eq $Subscription){
        $AzAccount = Connect-AzAccount -ErrorAction Stop
        Write-Host ("Successfully connected to Azure!") -ForegroundColor Green
    }
    Else{
        Write-Host ("Already connected to Azure...") -ForegroundColor Green
    }
}
Catch{
    Write-Host ("Unable to connect to Azure account with credentials: {0}. Error: {1}" -f $AzAccount.Context.Account.Id, $_.Exception.Message) -ForegroundColor Red
    Clear-NonBultinVariables
    Break
}
Finally{
    #To suppress these warning messages
    Write-Host ("Supressing Azure Powershell change warnings...") -ForegroundColor Yellow
    Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
}

#Check the current subscription
If($Subscription.Subscription.Name -ne $AzSubscription){
    $AzSubscription = Get-AzSubscription | Out-GridView -PassThru -Title "Select a valid Azure Subscription" | Select-AzSubscription
    Set-AzContext -Subscription $AzSubscription.Subscription.Name -ErrorAction Stop | Out-Null
    $Subscription = Get-AzContext
}

Write-Host ("Using Account ID:   {0} " -f $Subscription.Account.Id) -ForegroundColor Green
Write-host ("Using Subscription: {0} " -f $Subscription.Subscription.Name) -ForegroundColor Green

#used in step 5
$AzureVnetToVnetPeering = @{
    SiteASubscriptionID = 'cb673656-d089-4158-a27a-628bf324ce44'
    SiteATenantID= '72f988bf-86f1-41af-91ab-2d7cd011db47'
    SiteBSubscriptionID = '07b9b78b-95b9-4d20-96e4-049cce8d92fb'
    SiteBTenantID = '2ec9dcf0-b109-434a-8bcd-238a3bf0c6b2'
}
#============================================
# LAB CONFIGURATIONS
#============================================
#region Hyper-V Configurations
#------------------------------
$HyperVConfig = @{
    ChangeLocation = $true
    VirtualMachineLocation = 'D:\Hyper-V\Virtual Machines\'
    VirtualHardDiskLocation = 'D:\Hyper-V\Virtual Hard Disks\'
    EnableSessionMode = $true
    InternalNetworks = @{
        DMZ = "$($LabPrefix)-10.10.1.x"
        SVR = "$($LabPrefix)-10.10.2.x"
    }
    ExternalNetworks = @{
        External = "Default Switch"
    }
}
#endregion

#region Edge router Configurations
#---------------------------------
#grab local router subnet for next hop
$NextHop = Get-WmiObject -Class Win32_IP4RouteTable | where { $_.destination -eq '0.0.0.0' -and $_.mask -eq '0.0.0.0'} | Select -ExpandProperty nexthop

$VyOSConfig = @{
    HostName = "VyOS"
    VMName = "$($LabPrefix.ToUpper())-Router"
    ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
    NetPrefix = "VLAN"
    SubnetPrefix = "10.100"
    TimeZone = 'US/Eastern'

    ExternalInterface = 'Default Switch' #Match one of the external network names in hyper config

    NextHopSubnet = $NextHop

    ResetVPNConfigs = $true #this will delete the configurations of any vpn settings in VyOS 1 time 

    #CIDR for local network
    LocalCIDRPrefix = '10.100.0.0/16'
    LocalSubnetPrefix = @(
        '10.100.1.0/24',
        '10.100.2.0/24'
    )

    BgpAsn = 65168 #set as default asn

    UseDNSOption = 'Internal' # Options: 'Internal'<--uses VM DNS like a DC; 'External' <--Use home network DNS configs; 'Internet' <-- Uses Google
    InternalDNSIP = @(
        '10.100.1.1'
    )
    EnableDHCP = $false
    DHCPPools = @(
       '10.100.1.0/24',
       '10.100.2.0/24'
    )

    EnablePXEPRelay = $true
    PXERelayIP = '10.100.1.1'

    EnableNAT = $True
}

#============================================
## SIMPLE CONFIGURATION
#============================================
#region Azure Network Configurations
#-----------------------------------------
$RegionName = "$($LabPrefix.Replace(" ",''))-Basic"

$AzureSimpleConfig = @{
    LocationName = 'East US 2'
    #Dynabmic Variables

    ResourceGroupName = "rg-$RegionName"
    VnetName = "vnet-$RegionName"
    VnetGatewayName = "vngw-$RegionName"
    LocalGatewayName = "lgn-$RegionName"
    PublicIPName = "pip-$RegionName"
    ConnectionName = "ConnTo-$RegionName"

    #Azure vnet CIDR
    VnetCIDRPrefix = '10.1.0.0/16'
    #Azure subnet prefixes
    VnetSubnetPrefix = '10.1.0.0/24'
    VnetGatewayPrefix = '10.1.255.0/27'

    #storage account info
    StorageAccountName = "sa-$RegionName"
    StorageSku = "Standard_LRS"
}
#endregion


#region Virtual Machine Configurations
#-------------------------------------------
$AzureSimpleVM = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ("$RegionName-vm1" | Set-TruncateString -length 15)
    Name = "$RegionName-vm1"
    Size = "Standard_DS3"

    NICName = "$LabPrefix-svrb-nic"
    SubnetName = "DefaultSubnet"
    SubnetAddressPrefix = $AzureSimpleConfig.VnetSubnetPrefix
    VnetAddressPrefix = $AzureSimpleConfig.VnetCIDRPrefix

    NSGName = "$RegionName-nsg"

    TunnelDescription = 'Gateway To Azure'

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $AzEmail # set to either an email or webhook url 
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}
#endregion

#============================================
## ADVANCED CONFIGURATION
#============================================
#region Azure Network Configurations - Region 1
#---------------------------------------------------------
$RegionAName = "$($LabPrefix.Replace(" ",''))-SiteA"

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteA = @{
    LocationName = 'East US'

    ResourceGroupName = "$RegionAName-rg"

    VnetSpokeName = "$RegionAName-Spoke-vNet"
    VnetSpokeCIDRPrefix = '10.20.0.0/16'
    VnetSpokeSubnetName = "Spoke-Subnet"
    VnetSpokeSubnetAddressPrefix = '10.20.0.0/24'

    VnetHubName = "$RegionAName-Hub-vNet"
    VnetHubCIDRPrefix = '10.10.0.0/16'
    VnetHubSubnetName = "Hub-Subnet"
    VnetHubSubnetAddressPrefix = '10.10.0.0/24'
    VnetHubSubnetGatewayAddressPrefix = '10.10.200.0/26'

    VnetASN = 65010

    NSGSpokeName = "$RegionAName-SpokeNSG"
    NSGGatewayName = "$RegionAName-GatewayNSG"

    StorageSku = "standard_lrs"

    PublicIpAddressName = $RegionAName.Replace(" ",'').ToLower() + '-vngw-pip'

    VnetPeerNameAB = ($RegionAName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionAName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionAName).Replace(" ",'').ToLower() + '-vngw'
    LocalGatewayName = $RegionAName + '-' + '-gw'
    VnetConnectionName = ('ConnectionTo-' + $RegionAName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionAName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionAName).Replace(" ",'').ToLower() + '-sa'
}
# Virtual Machine Configurations - Region 1
#-------------------------------------------
$AzureVMSiteA = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ("$LabPrefix-dc2" | Set-TruncateString -length 15)
    Name = "$LabPrefix-dc2"
    Size = 'Standard_DS3'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2019-Datacenter'
    Version = 'latest'

    NICName = ("$RegionAName-vm1-nic").ToLower()
    SubnetName = $AzureAdvConfigSiteA.VnetSpokeSubnetName  
    SubnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeSubnetAddressPrefix
    VnetAddressPrefix = $AzureAdvConfigSiteA.VnetSpokeCIDRPrefix

    NSGName = "$RegionAName-vm-nsg"

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $AzEmail # set to either an email or webhook url 
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
}

#endregion


#region Azure Network Configurations - Region 2
#--------------------------------------------------------
$RegionBName = "$($LabPrefix.Replace(" ",''))-SiteB"

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigSiteB = @{
    LocationName = 'West US'

    ResourceGroupName = "$RegionBName-rg"

    VnetSpokeName = "$RegionBName-Spoke-vNet"
    VnetSpokeCIDRPrefix = '10.21.0.0/16'
    VnetSpokeSubnetName = "Spoke-Subnet"
    VnetSpokeSubnetAddressPrefix = '10.21.0.0/24'

    VnetHubName = "$RegionBName-Hub-vNet"
    VnetHubCIDRPrefix = '10.11.0.0/16'
    VnetHubSubnetName = "Hub-Subnet"
    VnetHubSubnetAddressPrefix = '10.11.0.0/24'
    VnetHubSubnetGatewayAddressPrefix = '10.11.200.0/26'

    VnetASN = 65011

    NSGSpokeName = "$RegionBName-SpokeNSG"
    NSGGatewayName = "$RegionBName-GatewayNSG"

    StorageSku = "standard_lrs"

    PublicIpAddressName = $RegionBName.Replace(" ",'').ToLower() + '-vngw-pip'

    VnetPeerNameAB = ($RegionBName + 'HubToSpoke').Replace(" ",'').Replace("-",'')
    VnetPeerNameBA = ($RegionBName + 'SpokeToHub').Replace(" ",'').Replace("-",'')

    VnetGatewayName = ($RegionBName).Replace(" ",'').ToLower() + '-vngw'
    LocalGatewayName = $RegionBName + '-' + 'gw'
    VnetConnectionName = ('ConnectionTo-' + $RegionBName).Replace(" ",'')

    TunnelDescription = ('Gateway to ' + $RegionBName + ' in Azure').Replace("-",' ')

    StorageAccountName = ($RegionBName).Replace(" ",'').ToLower() + '-sa'
}

# Virtual Machine Configurations - Region 2
#-------------------------------------------
$AzureVMSiteB = @{
    LocalAdminUser = $VMAdminUser
    LocalAdminPassword = $VMAdminPassword
    ComputerName = ("$RegionBName-vm1" | Set-TruncateString -length 15)
    Name = "$RegionBName-vm1"
    Size = 'Standard_D2s_v3'

    PublisherName = 'MicrosoftWindowsServer'
    Offer = 'WindowsServer'
    Skus = '2016-Datacenter'
    Version = 'latest'

    NICName = ("$RegionBName-vm1-nic").ToLower()
    SubnetName = $AzureAdvConfigSiteB.VnetSpokeSubnetName  
    SubnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeSubnetAddressPrefix
    VnetAddressPrefix = $AzureAdvConfigSiteB.VnetSpokeCIDRPrefix

    NSGName = "$RegionBName-vm-nsg"

    EnableAutoshutdown = $true
    AutoShutdownNotificationType = $AzEmail # set to either an email or webhook url 
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
    Connection21  = $RegionBName.ToLower() + '-to-' + $RegionAName +'-conn'
}

#endregion