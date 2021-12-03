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
$VMs = Get-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue
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
    $newNIC = $VMName.ToLower() + '-ni'
}
Else{
    #Increment VM name and nic
    $i=1
    do {
        $computername = ($AzureSimpleVM.ComputerName -replace '\d+$', $i)
        $newVMname = ($AzureSimpleVM.Name -replace '\d+$', $i)
        #only replace last digit in name (incase multiple digits exist)
        $newNIC = ($AzureSimpleVM.NICName -replace '\d(?!.*\d)', $i)
        $i++
    } until ($newVMname -notin $VMs.Name)
}

#Update Names in config
$AzureSimpleVM['ComputerName'] = $computername
$AzureSimpleVM['Name'] = $newVMname
$AzureSimpleVM['NICName'] = $newNIC

Write-Host ("Virtual Machine name will be [{0}]" -f $AzureSimpleVM.Name)  -ForegroundColor Green
#endregion

#region 1. Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue))
{
    Write-Host ("Creating Azure resource group [{0}]..." -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor White -NoNewline
    Try{
        New-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}Else{
    Write-Host ("Using Azure resource group [{0}]" -f $AzureSimpleConfig.ResourceGroupName) -ForegroundColor Green
}
#endregion


#region Create Storage Account
#build random char for storage name

If(-Not($StorageAccount = Get-AzStorageAccount -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where {$_.Sku.Name -eq $AzureSimpleConfig.StorageSku} | Select -First 1)){
    Write-Host ("Creating Azure storage account [{0}]..." -f $storageName) -ForegroundColor White -NoNewline
    Try{
        $randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
        $storageName = ($RegionName +'-' + $randomChar).ToLower() -replace '[\W]', ''

        $StorageAccount = New-AzStorageAccount -Name $storageName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -SkuName $AzureSimpleConfig.StorageSku `
                            -Location $AzureSimpleConfig.LocationName -Kind Storage | Out-Null
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
$vNet = Get-AzVirtualNetwork -Name $AzureSimpleVM.VNetName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue

If(-Not($NSG = Get-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    Write-Host ("Creating Azure network security group [{0}]..." -f $AzureSimpleVM.NSGName) -ForegroundColor White -NoNewline
    Try{
        $NSG = New-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
        $NSG | Add-AzNetworkSecurityRuleConfig -Name "Allow_Port_3389" -Priority 1200 -Protocol TCP -Access Allow -SourceAddressPrefix * `
                        -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Direction Inbound | Set-AzNetworkSecurityGroup | Out-Null

        Set-AzVirtualNetworkSubnetConfig -Name $AzureSimpleConfig.DefaultSubnetName -VirtualNetwork $vNet -AddressPrefix $AzureSimpleConfig.VnetSubnetPrefix `
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
    Write-Host ("Using Azure network security group [{0}]" -f $AzureSimpleVM.NSGName) -ForegroundColor Green
}
#endregion




#region Attach VM to second subnet which should be defaultsubnet
$VMSubnet = $vNet.Subnets | Where Name -eq $AzureSimpleVM.SubnetName
Write-Host ("Attaching VM's network interface [{0}] to subnet [{1}]..." -f $AzureSimpleVM.NICName,$AzureSimpleVM.SubnetName) -ForegroundColor White -NoNewline
Try{
    $NIC = New-AzNetworkInterface -Name $AzureSimpleVM.NICName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName `
                -Location $AzureSimpleConfig.LocationName -SubnetId $VMSubnet.Id -Force
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
    $ChangePassword = Read-host "Would you like to set a new password? [Y or N]"
    If($ChangePassword -eq 'Y'){
        do {
            $NewPassword = Read-host "Whats the new password?"
        } until ($NewPassword -match '((?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%&*()]).{8,123})')
        $AzureSimpleVM['LocalAdminPassword'] = $NewPassword
    }
    Else{
        Write-Host ("Unable to continue. Change config.ps1 variable [`$VMAdminPassword] value") -ForegroundColor Black -BackgroundColor Red
        Break
    }
}


Write-Host ("Building [{0}] credentials for VM [{1}]..." -f $AzureSimpleVM.LocalAdminUser,$AzureSimpleVM.Name) -ForegroundColor White -NoNewline
$LocalAdminSecurePassword = ConvertTo-SecureString $AzureSimpleVM.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AzureSimpleVM.LocalAdminUser, $LocalAdminSecurePassword)
Write-Host "Done" -ForegroundColor Green
#endregion

#Set VM Configuration
$VMConfig = New-AzVMConfig -VMName $AzureSimpleVM.Name -VMSize $AzureSimpleVM.Size
#Set VM operating system parameters

$VMConfig = Set-AzVMOperatingSystem -VM $VMConfig -Windows -ComputerName $AzureSimpleVM.ComputerName -Credential $Credential `
            -ProvisionVMAgent -EnableAutoUpdate
#Set VM network interface
$VMConfig = Add-AzVMNetworkInterface -VM $VMConfig -Id $NIC.Id

#Set VM operating system parameters
$VMConfig = Set-AzVMSourceImage -VM $VMConfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' `
            -Skus '2016-Datacenter' -Version latest

#Set boot diagnostic storage account
$VMConfig = Set-AzVMBootDiagnostic -Disable -VM $VMConfig
#Set-AzVMBootDiagnostic -Enable -VM $VMConfig -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -StorageAccountName $StorageAccount
Try{
    Write-Host ("Deploying virtual machine [{0}]..." -f $AzureSimpleVM.Name) -ForegroundColor White -NoNewline
    New-AzVM -VM $VMConfig -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName | Out-Null
    Write-Host "Done" -ForegroundColor Green
}
Catch{
    Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Break
}
#endregion


#region set autoshutdown (using custom function)
If($AzureSimpleVM.EnableAutoShutdown){
    #determine is notification is by email or webhookurl; set the appropiate param
    $EmailRegex = '^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'
    $URLRegex = '(http[s]?|[s]?ftp[s]?)(:\/\/)([^\s,]+)'
    $ShutdownParam = @{Time=$AzureSimpleVM.ShutdownTime;TimeZone=$AzureSimpleVM.ShutdownTimeZone}
    If($AzureSimpleVM.AutoShutdownNotificationType -match $EmailRegex){$ShutdownParam += @{Email=$AzureSimpleVM.AutoShutdownNotificationType}}
    If($AzureSimpleVM.AutoShutdownNotificationType -match $URLRegex){$ShutdownParam +=@{WebhookUrl=$AzureSimpleVM.AutoShutdownNotificationType}}

    Try{
        Write-Host ("Setting AutoShutdown on virtual machine [{0}]..." -f $AzureSimpleVM.Name) -ForegroundColor White -NoNewline
        Set-AzVMAutoShutdown -Enable -Name $AzureSimpleVM.Name -ResourceGroupName $AzureSimpleConfig.ResourceGroupName @ShutdownParam | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
#endregion

#region Reset VM password (Not working)
<#
#Re-reset password. Sometimes password set during deployment does not work
$VM = Get-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleVM.Name

Get-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name -Status
#must grab the VM Computer Type handler
$typeParams = @{
 'PublisherName' = 'Microsoft.Compute'
 'Type' = 'VMAccessAgent'
 'Location' = $AzureSimpleConfig.LocationName
}
$typeHandlerVersion = (Get-AzVMExtensionImage @typeParams | Sort-Object Version -Descending | Select-Object -first 1).Version

#remove the access exetension
Remove-AzVMAccessExtension -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name -Name 'enablevmaccess' -Force

#build params
$extensionParams = @{
    Credential = $Credential
    VMName = $AzureSimpleVM.Name
    ResourceGroupName = $AzureSimpleConfig.ResourceGroupName
    Name = 'enablevmaccess'
    Location = $AzureSimpleConfig.LocationName
    TypeHandlerVersion = $typeHandlerVersion
}
#add enablevmaccess back with new creds
Set-AzVMAccessExtension @extensionParams
#Set-AzVMAccessExtension -Credential $Credential -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name `
            -Name 'enablevmaccess' -TypeHandlerVersion $typeHandlerVersion -Location $AzureSimpleConfig.LocationName
Update-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VM $VM
Restart-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleVM.Name

#Reset the Remote Desktop Services configuration
#Set-AzVMAccessExtension -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name -Name "VMRDPAccess" `
            -Location $AzureSimpleConfig.LocationName -typeHandlerVersion "2.0" -ForceRerun:$true
#>
#endregion
Write-Host ("Done creating virtual machine [{0}]" -f $AzureSimpleVM.Name) -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green

Stop-Transcript
