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
        If($Config.TenantB.AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
        Else{Connect-AzAccount -Force}
    }
    #if context is not connected to gov; reconnect
    ElseIf ($Config.TenantB.AzureGov -and $Context.Environment.Name -ne 'AzureUSGovernment'){
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
    If($Config.TenantB.AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
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
#============================================
## ADVANCED CONFIGURATION - TENANT B
#============================================
Write-Host "Building Tenant B configurations.." -NoNewline

$SubnetsFromAzureTenantBSpokeCIDR = @()
$SubnetsFromAzureTenantBSpokeCIDR += Get-SimpleSubnets -Cidr $Config.TenantB.SpokeCIDR -Count $Config.TenantB.SpokeSubnetCount
$SubnetsFromAzureTenantBHubCIDR = Get-SimpleSubnets -Cidr $Config.TenantB.HubCIDR

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global variable so it used for the entire session
If($Config.TenantB.StorageRandomAppendix -eq '<auto>'){
    $Config.TenantB.StorageRandomAppendix = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion

#change location to Azure Gov based on $Config.TenantB.ResourceLocation 
If($Config.TenantB.AzureGov){
    switch($Config.TenantB.ResourceLocation){
        'East US' {$Config.TenantB.ResourceLocation = 'usgovvirginia';$Config.TenantB.timeZone = 'Eastern Standard Time'}
        'East US 2' {$Config.TenantB.ResourceLocation  = 'usgovvirginia';$Config.TenantB.timeZone = 'Eastern Standard Time'}
        'West US' {$Config.TenantB.ResourceLocation  = 'usgovarizona';$Config.TenantB.timeZone = 'US Mountain Standard Time'}
        'West US 2' {$Config.TenantB.ResourceLocation  = 'usgovarizona';$Config.TenantB.timeZone = 'US Mountain Standard Time'}
        'Central US' {$Config.TenantB.ResourceLocation  = 'usgovvirginia';$Config.TenantB.timeZone = 'Eastern Standard Time'}
        'North Central US' {$Config.TenantB.ResourceLocation  = 'usgovvirginia';$Config.TenantB.timeZone = 'Eastern Standard Time'}
        'South Central US' {$Config.TenantB.ResourceLocation  = 'usgovarizona';$Config.TenantB.timeZone = 'US Mountain Standard Time'}
    }
}

If(Test-SameSubnet -Ip1 ($Config.OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($Config.TenantB.HubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$Config.OnPremSubnetCIDR] and [`$Config.TenantB.HubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($Config.TenantB.HubCIDR -replace '/\d+$','') -ip2 ($Config.TenantB.SpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$Config.TenantB.HubCIDR] and [`$Config.TenantB.SpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}
#region Azure Network Configurations - Region 2
#--------------------------------------------------------

$SiteBName = ($Config.LabPrefix + '-' + $Config.TenantB.SiteName + '-' + $Config.TenantB.ResourceLocation).Trim('-').Replace(" ",'').ToLower() 

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantB = @{
    LocationName = $TenantBLocationName

    ResourceGroupName = 'rg-' + $SiteBName

    VnetSpokeName = 'vnet-' + $SiteBName + '-spoke'
    VnetSpokeCIDRPrefix = $Config.TenantB.SpokeCIDR
    VnetSpokeSubnetName =  'snet-' + $SiteBName
    #VnetSpokeSubnetAddressPrefix = ($Config.TenantB.SpokeCIDR -replace '/\d+$', '/24')
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantBSpokeCIDR

    VnetGatewayIpConfigName = $SiteBName + '-gateway-ipconfig'

    VnetHubName = 'vnet-' + $SiteBName + '-hub'
    VnetHubCIDRPrefix = $Config.TenantB.HubCIDR
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
    ComputerName = ($Config.LabPrefix.ToUpper() | Set-TruncateString -length 10) + '-B001'
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
Write-Host "Done" -ForegroundColor Green