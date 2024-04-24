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
## ADVANCED CONFIGURATION - TENANT A
#============================================
Write-Host "Building Tenant A configurations..." -NoNewline

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


#region Azure Network Configurations - Region 1
#---------------------------------------------------------

$SiteAName = ($Config.LabPrefix + '-' + $Config.TenantA.SiteName + '-' + $Config.TenantA.ResourceLocation).Trim('-').Replace(" ",'').ToLower() 
$SiteAShortName = ($Config.LabPrefix + '-' + $Config.TenantA.ResourceLocation).Trim('-').Replace(" ",'').ToLower() 

#Static Properties [EDIT ALLOWED]
$AzureAdvConfigTenantA = @{
    LocationName = $Config.TenantA.ResourceLocation

    ResourceGroupName = 'rg-' + $SiteAName

    VnetSpokeName = 'vnet-' + $SiteAShortName + '-spoke'
    VnetSpokeCIDRPrefix = $Config.TenantA.SpokeCIDR
    VnetSpokeSubnetName = 'snet-' + $Config.LabPrefix.ToLower() + '-spoke-001'
    VnetSpokeSubnetAddressPrefix = $SubnetsFromAzureTenantASpokeCIDR[0]
    VnetSpokeBastionAddressPrefix = ((Get-SimpleSubnets -Cidr $Config.TenantA.SpokeCIDR)[-1] -replace '/\d+$', '/29')

    VnetGatewayIpConfigName = 'vgwip-' + $SiteAShortName

    VnetHubName = 'vnet-' + $SiteAShortName + '-hub'
    VnetHubCIDRPrefix = $Config.TenantA.HubCIDR
    VnetHubSubnetName = 'snet-' + $Config.LabPrefix.ToLower() + '-hub-001'
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
    ConnectionName = 'connection-to-' + $Config.LabPrefix.ToLower() + '-onprem'

    TunnelDescription = ('Gateway to ' + $SiteAShortName + ' (' + $TenantName + ')').replace('-',' ')

    StorageSku = 'standard_lrs'
    StorageAccountName = ('st' + $SiteAShortName + '001').replace('-','')

    RouteTableName = 'rt-' + $SiteAShortName
    RouteTableRoutes = @{
        "Route-To-$($Config.LabPrefix.ToUpper())"="$OnPremSubnetCIDR"
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
    ComputerName = ($Config.LabPrefix.ToUpper() | Set-TruncateString -length 10) + '-A001'
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