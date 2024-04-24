
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
        If($Config.TenantA.AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
        Else{Connect-AzAccount -Force}
    }
    #if context is not connected to gov; reconnect
    ElseIf ($Config.TenantA.AzureGov -and $Context.Environment.Name -ne 'AzureUSGovernment'){
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
    If($Config.TenantA.AzureGov){Connect-AzAccount -EnvironmentName AzureUSGovernment -Force}
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
## SIMPLE CONFIGURATION
#============================================

Write-Host "Building Simple configurations..." -NoNewline
#get the next available IP for the router
$SubnetsFromAzureTenantASpokeCIDR = @()
$SubnetsFromAzureTenantASpokeCIDR += Get-SimpleSubnets -Cidr $Config.TenantA.SpokeCIDR -Count $Config.TenantA.SpokeSubnetCount
$SubnetsFromAzureTenantAHubCIDR = Get-SimpleSubnets -Cidr $Config.TenantA.HubCIDR

#build random character set to ensure no duplication (mainly used for storage accounts)
#Make it a global variable so it used for the entire session
If($Config.TenantA.StorageRandomAppendix -eq '<auto>'){
    $Config.TenantA.StorageRandomAppendix = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
}
#endregion


#change location to Azure Gov based on $Config.TenantA.ResourceLocation 
If($Config.TenantA.AzureGov){
    switch($Config.TenantA.ResourceLocation){
        'East US' {$Config.TenantA.ResourceLocation = 'usgovvirginia';$Config.TenantA.timeZone = 'Eastern Standard Time'}
        'East US 2' {$Config.TenantA.ResourceLocation  = 'usgovvirginia';$Config.TenantA.timeZone = 'Eastern Standard Time'}
        'West US' {$Config.TenantA.ResourceLocation  = 'usgovarizona';$Config.TenantA.timeZone = 'US Mountain Standard Time'}
        'West US 2' {$Config.TenantA.ResourceLocation  = 'usgovarizona';$Config.TenantA.timeZone = 'US Mountain Standard Time'}
        'Central US' {$Config.TenantA.ResourceLocation  = 'usgovvirginia';$Config.TenantA.timeZone = 'Eastern Standard Time'}
        'North Central US' {$Config.TenantA.ResourceLocation  = 'usgovvirginia';$Config.TenantA.timeZone = 'Eastern Standard Time'}
        'South Central US' {$Config.TenantA.ResourceLocation  = 'usgovarizona';$Config.TenantA.timeZone = 'US Mountain Standard Time'}
    }
}

If(Test-SameSubnet -Ip1 ($Config.OnPremSubnetCIDR -replace '/\d+$','') -ip2 ($Config.TenantA.HubCIDR -replace '/\d+$','') ){
    Write-Host ("[`$Config.OnPremSubnetCIDR] and [`$Config.TenantA.HubCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}

If(Test-SameSubnet -Ip1 ($Config.TenantA.HubCIDR -replace '/\d+$','') -ip2 ($Config.TenantA.SpokeCIDR -replace '/\d+$','') ){
    Write-Host ("[`$Config.TenantA.HubCIDR] and [`$Config.TenantA.SpokeCIDR] variables cannot be in the same subnet space!" ) -ForegroundColor Black -BackgroundColor Red
    break
}


$SiteName = ($Config.LabPrefix + '-' + $Config.SimpleAppendix + '-' + $Config.TenantA.ResourceLocation).Trim('-').Replace(" ",'').ToLower() 

$AzureSimpleConfig = @{
    LocationName = $Config.TenantA.ResourceLocation
    #Dynamic Variables

    ResourceGroupName = 'rg-' + $SiteName
    VnetName = 'vnet-' + $SiteName
    VnetGatewayName = 'vgw-' + $SiteName
    LocalGatewayName = 'lgw-' + $SiteName
    PublicIPName = 'pip-' + $SiteName
    ConnectionName = 'cn-' + $SiteName

    #Azure vnet CIDR
    VnetCIDRPrefix = $Config.TenantA.HubCIDR
    #Azure subnet prefixes
    DefaultSubnetName = 'snet-' + $SiteName + '-default001'
    #VnetSubnetPrefix = ($Config.TenantA.HubCIDR -replace '/\d+$', '/24')
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