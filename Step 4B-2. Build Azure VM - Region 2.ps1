Param(
    [ValidatePattern("^(?![0-9]{1,64}$)[a-zA-Z0-9-]{1,64}$")]
    [string]$VMName
)
$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Compute,Az.Compute,Az.Resources,Az.Storage
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
#https://docs.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-powershell#create-a-virtual-machine
#https://docs.microsoft.com/en-us/azure/virtual-machines/windows/quick-create-powershell
#https://docs.microsoft.com/en-us/powershell/module/az.compute/new-azvm?view=azps-2.8.0

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading configuration file first...") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoVyosISOCheck
}
#endregion


#start transcript
$LogfileName = "$RegionName-BuildAzureVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#region Build VM configurations
$VMs = Get-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue
If($VMName)
{
    If($VMName -in $VMs.Name){
        Write-Host ("Name already exists. You must specify a different vm name other than [{0}]" -f $VMName) -ForegroundColor Red
        do {
            $VMresponse = Read-host "Whats the new VM name?"
        } until ($VMresponse -match "^(?![0-9]{1,64}$)[a-zA-Z0-9-]{1,64}$" -and $VMresponse -ne $VMName)
        $VMName = $VMresponse
    }
    #Azure vm can be 64 characters long but the computername cannot
    $computername = $VMName | Set-TruncateString -length 15
    $newVMname =  $VMName.ToLower()
    $newNIC = $VMName.ToLower() + '-nic'
}
Else{
    #Increment VM name and nic
    $i=1
    do {
        $computername = ($AzureVMSiteB.ComputerName -replace '\d+$', $i)
        $newVMname = ($AzureVMSiteB.Name -replace '\d+$', $i)
        $newNIC = ($AzureVMSiteB.NICName -replace '\d+', $i)
        $i++
    } until ($newVMname -notin $VMs.Name)
}
#Update Names in config
$AzureVMSiteB['ComputerName'] = $computername
$AzureVMSiteB['Name'] = $newVMname
$AzureVMSiteB['NICName'] = $newNIC

Write-Host ("Virtual Machine name will be [{0}]" -f $AzureVMSiteB.Name)  -ForegroundColor Green
#endregion

#region 1. Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureAdvConfigSiteB.ResourceGroupName) -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureAdvConfigSiteB.ResourceGroupName) -ForegroundColor Green
}
#endregion


#region Create Storage Account
#build random char for storage name

If(-Not($StorageAccount = Get-AzStorageAccount -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where {$_.Sku.Name -eq $AzureAdvConfigSiteB.StorageSku} | Select -First 1)){
    Write-Host ("Creating Azure storage account [{0}]..." -f $storageName) -NoNewline
    Try{
        $randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
        $storageName = ($RegionName +'-' + $randomChar).ToLower() -replace '[\W]', ''

        $StorageAccount = New-AzStorageAccount -Name $storageName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -SkuName $AzureAdvConfigSiteB.StorageSku `
                            -Location $AzureAdvConfigSiteB.LocationName -Kind Storage | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure storage account [{0}]" -f $StorageAccount.StorageAccountName) -ForegroundColor Green
}
#endregion


#region Creating a new NSG to allow PS Remoting Port 5986 and RDP Port 3389
#grab Vnet for NSG and NIC configurations
$vNet = Get-AzVirtualNetwork -Name $AzureVMSiteB.VNetName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue

If(-Not($NSG = Get-AzNetworkSecurityGroup -Name $AzureVMSiteB.NSGName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    Write-Host ("Creating Azure network security group [{0}]..." -f $AzureVMSiteB.NSGName) -NoNewline
    Try{
        $NSG = New-AzNetworkSecurityGroup -Name $AzureVMSiteB.NSGName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName | Out-Null
        $NSG | Add-AzNetworkSecurityRuleConfig -Name "RDP" -Priority 1200 -Protocol TCP -Access Allow -SourceAddressPrefix * `
                        -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Direction Inbound | Set-AzNetworkSecurityGroup | Out-Null

        Set-AzVirtualNetworkSubnetConfig -Name 'DefaultSubnet' -VirtualNetwork $vNet -AddressPrefix $AzureAdvConfigSiteB.VnetSubnetPrefix `
                    -NetworkSecurityGroup $NSG -WarningAction SilentlyContinue | Out-Null
        $vNet | Set-AzVirtualNetwork -WarningAction SilentlyContinue | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure network security group [{0}]" -f $AzureVMSiteB.NSGName) -ForegroundColor Green
}
#endregion




#region Attach VM to second subnet which should be defaultsubnet
$VMSubnet = $vNet.Subnets | Where Name -eq $AzureVMSiteB.SubnetName
Write-Host ("Attaching VM's network interface [{0}] to subnet [{1}]..." -f $AzureVMSiteB.NICName,$AzureVMSiteB.SubnetName) -NoNewline
Try{
    $NIC = New-AzNetworkInterface -Name $AzureVMSiteB.NICName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName `
                -Location $AzureAdvConfigSiteB.LocationName -SubnetId $VMSubnet.Id -Force
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion

#region Build local admin credentials for VM
If($VMAdminPassword -notmatch '((?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%&*()]).{8,123})' -or $VMAdminPassword -match 'password')
{
    Write-Host ("You must specify a more complex password other than [{0}]" -f $VMAdminPassword) -ForegroundColor Red
    $response1 = Read-host "Would you like to set a new password? [Y or N]"
    If($response1 -eq 'Y'){
        do {
            $response2 = Read-host "Whats the new password?"
        } until ($response2 -match '((?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%&*()]).{8,123})')
        $AzureVMSiteB['LocalAdminPassword'] = $response2
    }
    Else{
        Write-Host ("Unable to continue. Change config.ps1 variable [`$VMAdminPassword] value") -ForegroundColor Black -BackgroundColor Red
        Break
    }
}


Write-Host ("Building [{0}] credentials for VM [{1}]..." -f $AzureVMSiteB.LocalAdminUser,$AzureVMSiteB.Name) -NoNewline
$LocalAdminSecurePassword = ConvertTo-SecureString $AzureVMSiteB.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AzureVMSiteB.LocalAdminUser, $LocalAdminSecurePassword)
Write-Host "Done" -ForegroundColor Green
#endregion

#Set VM Configuration
$VMConfig = New-AzVMConfig -VMName $AzureVMSiteB.Name -VMSize $AzureVMSiteB.Size
#Set VM operating system parameters

$VMConfig = Set-AzVMOperatingSystem -VM $VMConfig -Windows -ComputerName $AzureVMSiteB.ComputerName -Credential $Credential `
            -ProvisionVMAgent -EnableAutoUpdate
#Set VM network interface
$VMConfig = Add-AzVMNetworkInterface -VM $VMConfig -Id $NIC.Id

#Set VM operating system parameters
$VMConfig = Set-AzVMSourceImage -VM $VMConfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' `
            -Skus '2016-Datacenter' -Version latest

#Set boot diagnostic storage account
$VMConfig = Set-AzVMBootDiagnostic -Enable -VM $VMConfig -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -StorageAccountName $StorageAccount
Try{
    Write-Host ("Deploying virtual machine [{0}]..." -f $AzureVMSiteB.Name) -NoNewline
    New-AzVM -VM $VMConfig -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion


#region set autoshutdown (using custom function)
If($AzureVMSiteB.EnableAutoShutdown){
    #determine is notification is by email or webhookurl; set the appropiate param
    $EmailRegex = '^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'
    $URLRegex = '(http[s]?|[s]?ftp[s]?)(:\/\/)([^\s,]+)'
    $ShutdownParam = @{Time=$AzureVMSiteB.ShutdownTime;TimeZone=$AzureVMSiteB.ShutdownTimeZone}
    If($AzureVMSiteB.AutoShutdownNotificationType -match $EmailRegex){$ShutdownParam += @{Email=$AzureVMSiteB.AutoShutdownNotificationType}}
    If($AzureVMSiteB.AutoShutdownNotificationType -match $URLRegex){$ShutdownParam +=@{WebhookUrl=$AzureVMSiteB.AutoShutdownNotificationType}}

    Try{
        Write-Host ("Setting AutoShutdown on virtual machine [{0}]..." -f $AzureVMSiteB.Name) -NoNewline
        Set-AzVMAutoShutdown -Enable -Name $AzureVMSiteB.Name -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName @ShutdownParam | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
#endregion

Write-Host ("Done creating virtual machine [{0}]" -f $AzureVMSiteB.Name) -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green

Stop-Transcript
