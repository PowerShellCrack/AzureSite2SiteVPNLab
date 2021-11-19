$ErrorActionPreference = "Stop"

#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#start transcript
$LogfileName = "$RegionAName-BuildAzureVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#https://docs.microsoft.com/en-us/powershell/module/az.compute/new-azvm?view=azps-2.8.0
#Example 3: Create a VM from a marketplace image without a Public IP
#region Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    New-AzResourceGroup -Name $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName
}
#endregion

#region Create Storage Account
$storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
If(-Not(Get-AzStorageAccount -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $storageName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    #build random char for storage name
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
    $storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
    $storageAcc = New-AzStorageAccount -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $storageName `
                            -SkuName $AzureAdvConfigSiteA.StorageSku -Location $AzureAdvConfigSiteA.LocationName -Kind Storage -verbose
}
#endregion

#region Creating a new NSG to allow PS Remoting Port 5986 and RDP Port 3389
#grab Vnet for NSG and NIC configurations
$VNET = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteA.VNETSpokeName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName

If(-Not($NSG = Get-AzNetworkSecurityGroup -Name $AzureVMSiteA.NSGName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){

    $NSG = New-AzNetworkSecurityGroup -Name $AzureVMSiteA.NSGName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                        -Location $AzureAdvConfigSiteA.LocationName -Verbose
    $NSG | Add-AzNetworkSecurityRuleConfig -Name "RDP" -Priority 1200 -Protocol TCP -Access Allow -SourceAddressPrefix * `
                        -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Direction Inbound -Verbose | Set-AzNetworkSecurityGroup

    
    Set-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteA.VNETSpokeSubnetName -VirtualNetwork $VNET `
                -AddressPrefix $AzureAdvConfigSiteA.VNETSpokeSubnetAddressPrefix -NetworkSecurityGroup $NSG -WarningAction SilentlyContinue
    $VNET | Set-AzVirtualNetwork -WarningAction SilentlyContinue
}
#endregion

#region Attach VM to second subnet which should be defaultsubnet
$NIC = New-AzNetworkInterface -Name $AzureVMSiteA.NICName -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName `
                    -Location $AzureAdvConfigSiteA.LocationName -SubnetId $Vnet.Subnets[0].Id
#endregion

#region build local admin credentials for VM
$LocalAdminSecurePassword = ConvertTo-SecureString $AzureVMSiteA.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AzureVMSiteA.LocalAdminUser, $LocalAdminSecurePassword);
#endregion

#region Build VM configurations
$VirtualMachine = New-AzVMConfig -VMName $AzureVMSiteA.Name -VMSize $AzureVMSiteA.Size
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $AzureVMSiteA.ComputerName -Credential $Credential `
                                -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $AzureVMSiteA.PublisherName -Offer $AzureVMSiteA.Offer `
                                -Skus $AzureVMSiteA.Skus -Version $AzureVMSiteA.Version
#endregion

#region Deploy VM
New-AzVM -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Location $AzureAdvConfigSiteA.LocationName -VM $VirtualMachine -Verbose
#endregion

#region set autoshutdown (using custom function)
If($AzureAdvConfigSiteA.EnableAutoshutdown){
    #determin is notification is by email or webhookurl; set the appropiate param
    $EmailRegex = '^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'
    $URLRegex = '(http[s]?|[s]?ftp[s]?)(:\/\/)([^\s,]+)'
    If($AzureAdvConfigSiteA.AutoShutdownNotificationType -match $EmailRegex){$ShutdownParam = @{Email=$AzureAdvConfigSiteA.AutoShutdownNotificationType}}
    If($AzureAdvConfigSiteA.AutoShutdownNotificationType -match $URLRegex){$ShutdownParam =@{WebhookUrl=$AzureAdvConfigSiteA.AutoShutdownNotificationType}}
    Set-AzVMAutoShutdown -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureAdvConfigSiteA.Name -Enable `
                -Time $AzureAdvConfigSiteA.ShutdownTime -TimeZone $AzureAdvConfigSiteA.ShutdownTimeZone @ShutdownParam
}
#endregion

#region Reset VM password (Not working)
<#
#Re-reset password. Sometimes password set during deployment does not work
$VM = Get-AzVM -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $AzureVMSiteA.Name

Get-AzVM -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VMName $AzureVMSiteA.Name -Status
#must grab the VM Computer Type handler
$typeParams = @{
 'PublisherName' = 'Microsoft.Compute'
 'Type' = 'VMAccessAgent'
 'Location' = $AzureAdvConfigSiteA.LocationName
}
$typeHandlerVersion = (Get-AzVMExtensionImage @typeParams | Sort-Object Version -Descending | Select-Object -first 1).Version

#remove the access exetension
Remove-AzVMAccessExtension -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VMName $AzureVMSiteA.Name -Name 'enablevmaccess' -Force

#build params
$extensionParams = @{
    Credential = $Credential
    VMName = $AzureVMSiteA.Name
    ResourceGroupName = $AzureAdvConfigSiteA.ResourceGroupName
    Name = 'enablevmaccess'
    Location = $AzureAdvConfigSiteA.LocationName
    TypeHandlerVersion = $typeHandlerVersion  
}
#add enablevmaccess back with new creds
Set-AzVMAccessExtension @extensionParams
#Set-AzVMAccessExtension -Credential $Credential -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VMName $AzureVMSiteA.Name `
            -Name 'enablevmaccess' -TypeHandlerVersion $typeHandlerVersion -Location $AzureAdvConfigSiteA.LocationName
Update-AzVM -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VM $VM
Restart-AzVM -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -Name $AzureVMSiteA.Name


#Reset the Remote Desktop Services configuration
#Set-AzVMAccessExtension -ResourceGroupName $AzureAdvConfigSiteA.ResourceGroupName -VMName $AzureVMSiteA.Name -Name "VMRDPAccess" `
            -Location $AzureAdvConfigSiteA.LocationName -typeHandlerVersion "2.0" -ForceRerun:$true
#>
#endregion

#get all VMs and their IP's
$vms = Get-AzVM
$nics = Get-AzNetworkInterface | where VirtualMachine -NE $null #skip Nics with no VM

foreach($nic in $nics)
{
    $vm = $vms | where-object -Property Id -EQ $nic.VirtualMachine.id
    $prv =  $nic.IpConfigurations | select-object -ExpandProperty PrivateIpAddress
    Write-Host "$($vm.Name) : $prv" -ForegroundColor Yellow

}

Stop-Transcript
