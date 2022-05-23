<#
    .SYNOPSIS
        Builds a Azure VM

    .DESCRIPTION
        Builds a Azure VM

    .NOTES
        1. Build VM configurations
        2. Create a resource group
        3. Create Storage Account
        4. Creating a new NSG
        5. Attach VM nic to subnet
        6. Build local admin credentials
        7. Set VM Configuration and boot info
        8. Deploying virtual machine
        9. Set Autoshutdown
        10. Join Domain (optional)

    .PARAMETER VMName
    STRING
    Specifies an custom VM name; if already found increments name by 1

    .PARAMETER OSType
    SET
    Decides to deploy the latest Windows 10 or latest Windows Server operating system

    .PARAMETER SecureVM
    SWITCH

    .PARAMETER JoinDomain
    SWITCH

    .PARAMETER Domain
    MANDATORY (if JoinDomain switch is used)

    .PARAMETER OU
    STRING (if JoinDomain switch is used)

    .PARAMETER Credentials
    MANDATORY (if JoinDomain switch is used)

    .EXAMPLE

    & '.\Step 4C. Build Azure VM for Existing Network.ps1'

    RESULT: Builds a Windows Server VM

    .EXAMPLE

    & '.\Step 4C. Build Azure VM for Existing Network.ps1' -VMName CONTOSO-WK1 -OSType Workstation

    RESULT: Builds a Windows 10 VM named CONTOSO-WK1

    .EXAMPLE

    & '.\Step 4C. Build Azure VM for Existing Network.ps1' -VMName CONTOSO-WK1 -OSType Workstation -JoinDomain -Domain CONTOSO.local -DomainJoinCreds (Get-Credential)

    RESULT: Builds a Windows 10 VM named CONTOSO-WK1 and attempts to join it to domain CONTOSO.local using credentials

    .EXAMPLE

    & '.\Step 4C. Build Azure VM for Existing Network.ps1' -VMName CONTOSO-WK1 -OSType Workstation -JoinDomain -Domain CONTOSO.local -DomainJoinCreds (Get-Credential) -OU "OU=Workstations,OU=Region1,DC=CONTOSO,DC=LOCAL"

    RESULT: Builds a Windows 10 VM named CONTOSO-WK1 and attempts to join it to domain CONTOSO.local in Region 1 workstation OU using credentials

    .EXAMPLE

    & '.\Step 4C. Build Azure VM for Existing Network.ps1' -ConfigurationFile configs-gov.ps1 -VMName CONTOSO-WK1 -OSType Workstation -JoinDomain -Domain CONTOSO.local -DomainJoinCreds (Get-Credential) -OU "OU=Workstations,OU=Region1,DC=CONTOSO,DC=LOCAL"

    RESULT: Builds a Windows 10 VM named CONTOSO-WK1 and attempts to join it to domain CONTOSO.local in Region 1 workstation OU using credentials in Azure Gov

#>
[CmdletBinding(DefaultParameterSetName = 'Workgroup')]
Param(
    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $Configs = Get-Childitem $_ -Filter configs* | Where Extension -eq '.ps1' | Select -ExpandProperty Name

        $Configs | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("config")]
    [string]$ConfigurationFile = "configs.ps1",

    [ValidatePattern("^(?![0-9]{1,64}$)[a-zA-Z0-9-]{1,64}$")]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $RGs = Get-AzResourceGroup | Select -ExpandProperty ResourceGroupName

        $RGs | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("rg")]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )

        $vNets = Get-AzVirtualNetwork | Select -ExpandProperty Name

        $vNets | Where-Object {
            $_ -like "$wordToComplete*"
        }
    } )]
    [Alias("vNet")]
    [string]$VirtualNetwork,

    [Parameter(Mandatory = $False)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )

        $NSGs = Get-AzNetworkSecurityGroup | Where Name -notmatch 'Bastion' | Select -ExpandProperty Name

        $NSGs  | Where-Object {
            $_ -like "$wordToComplete*"
        }
    } )]
    [Alias("NSG")]
    [string]$NetworkSecurityGroup,

    [ValidateSet('Workstation', 'Server')]
    [string]$OSType = 'Server',

    [Parameter(ParameterSetName = 'JoinDomain')]
    [switch]$SecureVM,

    [Parameter(ParameterSetName = 'JoinDomain')]
    [switch]$JoinDomain,

    [Parameter(Mandatory = $true,ParameterSetName = 'JoinDomain')]
    [string]$Domain,

    [Parameter(Mandatory = $false,ParameterSetName = 'JoinDomain')]
    [ValidatePattern("(?=OU)(.*\n?)(?<=.)")]
    [string]$OU,

    [Parameter(Mandatory = $true,ParameterSetName = 'JoinDomain')]
    [System.Management.Automation.PSCredential]$DomainJoinCreds
)

$ErrorActionPreference = "Stop"
#Requires -Modules Az.Accounts,Az.Compute,Az.Resources,Az.Storage,Az.Network,Az.KeyVault
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
#https://docs.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-powershell#create-a-virtual-machine
#https://docs.microsoft.com/en-us/azure/virtual-machines/windows/quick-create-powershell
#https://docs.microsoft.com/en-us/powershell/module/az.compute/new-azvm?view=azps-2.8.0

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\$ConfigurationFile)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\$ConfigurationFile") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\$ConfigurationFile" -NoVyosISOCheck
}
#endregion


#start transcript
$LogfileName = "$RegionName-BuildAzureVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#install Devlabs for Arm Templates support
If((Get-AzResourceProvider -ProviderNamespace Microsoft.DevTestLab).RegistrationState -eq 'NotRegistered'){
    Register-AzResourceProvider -ProviderNamespace Microsoft.DevTestLab | Out-Null
}
$Location = Get-AzResourceGroup -Name $ResourceGroup | Select -ExpandProperty Location

#region Build VM configurations
$VMs = Get-AzVM -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
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
$AzureSimpleVM['NSGName'] = $NetworkSecurityGroup
$AzureSimpleVM['VNetName'] = $VirtualNetwork

Write-Host ("Virtual Machine name will be [{0}]" -f $AzureSimpleVM.Name)  -ForegroundColor Green
#endregion


#region Create Storage Account
#build random char for storage name

If(-Not($StorageAccount = Get-AzStorageAccount -ResourceGroupName $AzureSimpleVM.ResourceGroupName `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where {$_.Sku.Name -eq $AzureSimpleVM.StorageSku -and $_.StorageAccountName -like "$RegionName*"} | Select -First 1)){

    $randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
    $storageName = ($RegionName +'-' + $randomChar).ToLower() -replace '[\W]', ''
    Write-Host ("Creating Azure storage account [{0}]..." -f $storageName) -ForegroundColor White -NoNewline
    Try{
        $StorageAccount = New-AzStorageAccount -Name $storageName -ResourceGroupName $AzureSimpleVM.ResourceGroupName -SkuName $AzureSimpleVM.StorageSku `
                            -Location $AzureSimpleVM.LocationName -Kind Storage | Out-Null
        $AzureSimpleVM['StorageAccount'] = $storageName
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Break
    }
}
Else{
    Write-Host ("Using Azure storage account [{0}]" -f $StorageAccount.StorageAccountName) -ForegroundColor Green
    $AzureSimpleVM['StorageAccount'] = $StorageAccount.StorageAccountName
}
#endregion


#region Creating a new NSG to allow PS Remoting Port 5986 and RDP Port 3389
#grab Vnet for NSG and NIC configurations
$vNet = Get-AzVirtualNetwork -Name $AzureSimpleVM.VNetName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue

If(-Not($NSG = Get-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    Write-Host ("Creating Azure network security group [{0}]..." -f $AzureSimpleVM.NSGName) -ForegroundColor White -NoNewline
    Try{
        $NSG = New-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $ResourceGroup -Location $AzureSimpleConfig.LocationName | Out-Null
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
    $NIC = New-AzNetworkInterface -Name $AzureSimpleVM.NICName -ResourceGroupName $ResourceGroup `
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
If($OSType){
    Switch($OSType){

        'Workstation' {
            $VMConfig = Set-AzVMSourceImage -VM $VMConfig `
                -PublisherName 'MicrosoftWindowsDesktop' `
                -Offer 'Windows-10' `
                -Skus 'rs5-enterprise' `
                -Version latest
        }
        'Server'      {
            $VMConfig = Set-AzVMSourceImage -VM $VMConfig `
                -PublisherName 'MicrosoftWindowsServer' `
                -Offer 'WindowsServer' `
                -Skus '2016-Datacenter' `
                -Version latest
        }
    }
}
Else{
    $VMConfig = Set-AzVMSourceImage -VM $VMConfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2016-Datacenter' -Version latest
}




#Set boot diagnostic storage account
$VMConfig = Set-AzVMBootDiagnostic -Disable -VM $VMConfig -StorageAccountName $AzureSimpleVM.StorageAccount
#Set-AzVMBootDiagnostic -Enable -VM $VMConfig -ResourceGroupName $ResourceGroup -StorageAccountName $StorageAccount
Try{
    Write-Host ("Deploying virtual machine [{0}]..." -f $AzureSimpleVM.Name) -ForegroundColor White -NoNewline
    New-AzVM -VM $VMConfig -ResourceGroupName $ResourceGroup -Location $AzureSimpleConfig.LocationName | Out-Null
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
        Set-AzVMAutoShutdown -Enable -Name $AzureSimpleVM.Name -ResourceGroupName $ResourceGroup @ShutdownParam | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }
}
#endregion


If($SecureVM){
    # Advisor Recommendation (high): Virtual machines should encrypt temp disks, caches, and data flows between Compute and Storage resources
    #https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disk-encryption-powershell-quickstart
    $KeyVaultName = ($LabPrefix + 'vmdiskkeys')
    If(-Not($AzKeyVault = AzKeyVault -Name $KeyVaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
        Write-Host ("Creating Azure Keyvault [{0}]..." -f $KeyVaultName) -ForegroundColor White -NoNewline
        Try{
            $AzKeyVault = New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $ResourceGroup -Location $AzureSimpleVM.LocationName -EnabledForDiskEncryption | Out-Null
            Write-Host "Done" -ForegroundColor Green
        }
        Catch{
            Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        }
    }
    Else{
        Write-Host ("Using Azure Azure Keyvault [{0}]" -f $KeyVaultName) -ForegroundColor Green
    }

    #$AzKeyVault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroup
    Write-Host ("Enabling Disk encryption on virtual Machine [{0}]..." -f $AzureSimpleVM.Name) -ForegroundColor White -NoNewline
    Try{
        Set-AzVMDiskEncryptionExtension -ResourceGroupName $ResourceGroup -VMName $AzureSimpleVM.Name -DiskEncryptionKeyVaultUrl $AzKeyVault.VaultUri -DiskEncryptionKeyVaultId $AzKeyVault.ResourceId -Force
        Write-Host ("Done. Key is stored in Azure KeyVault: {0}" -f $KeyVaultName) -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }

    #TODO
    # Advisor Recommendation (high): Install endpoint protection solution on virtual machines
    # Advisor Recommendation (high): SQL IaaS Agent should be installed in full mode
    # Advisor Recommendation (Medium): Network traffic data collection agent should be installed on Windows virtual machines
    # Advisor Recommendation (Medium): Windows Defender Exploit Guard should be enabled on machines
    # Advisor Recommendation (Low): Azure Backup should be enabled for virtual machines
}


If($JoinDomain){
    #https://docs.microsoft.com/en-us/powershell/module/az.compute/set-azvmaddomainextension?view=azps-7.1.0
    If($OU){
        $DomainParams = @{
            DomainName=$Domain
            Credential=$DomainJoinCreds
            JoinOption=0x00000001
            OUPath=$OU
        }
    }Else{
        $DomainParams = @{
            DomainName=$Domain
            Credential=$DomainJoinCreds
            JoinOption=0x00000001
        }
    }
    Try{
        Write-Host ("Attempting to join vm to domain [{0}]..." -f $Domain) -ForegroundColor White -NoNewline
        Set-AzVMADDomainExtension -VMName $AzureSimpleVM.Name -ResourceGroupName $ResourceGroup @DomainParams -Restart
        Write-Host "Done" -ForegroundColor Green
    }
    Catch{
        Write-Host ("Failed: {0}" -f $_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    }

}

Write-Host "=================================================" -ForegroundColor Black -BackgroundColor Green
Write-Host (" Done creating virtual machine [{0}]" -f $AzureSimpleVM.Name) -ForegroundColor Black -BackgroundColor Green
Write-Host "=================================================" -ForegroundColor Black -BackgroundColor Green

Stop-Transcript