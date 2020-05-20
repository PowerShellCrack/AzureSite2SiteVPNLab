$ErrorActionPreference = "Stop"

#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#start transcript
$LogfileName = "$RegionBName-BuildAzureVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#https://docs.microsoft.com/en-us/powershell/module/az.compute/new-azvm?view=azps-2.8.0
#Example 3: Create a VM from a marketplace image without a Public IP
#region Create a resource group:
if (!(Get-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    New-AzResourceGroup -Name $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName
}
#endregion

#region Create Storage Account
$storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
if (!(Get-AzStorageAccount -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $storageName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    #build random char for storage name
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
    $storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
    $storageAcc = New-AzStorageAccount -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $storageName -SkuName $AzureAdvConfigSiteB.StorageSku -Location $AzureAdvConfigSiteB.LocationName -Kind Storage -verbose
}
#endregion

#region Creating a new NSG to allow PS Remoting Port 5986 and RDP Port 3389
#grab Vnet for NSG and NIC configurations
$VNET = Get-AzVirtualNetwork -Name $AzureAdvConfigSiteB.VNETSpokeName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName

if (!($NSG = Get-AzNetworkSecurityGroup -Name $AzureVMSiteB.NSGName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){

    $NSG = New-AzNetworkSecurityGroup -Name $AzureVMSiteB.NSGName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName -Verbose
    $NSG | Add-AzNetworkSecurityRuleConfig -Name "RDP" -Priority 1200 -Protocol TCP -Access Allow -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Direction Inbound -Verbose | Set-AzNetworkSecurityGroup

    
    Set-AzVirtualNetworkSubnetConfig -Name $AzureAdvConfigSiteB.VNETSpokeSubnetName -VirtualNetwork $VNET -AddressPrefix $AzureAdvConfigSiteB.VNETSpokeSubnetAddressPrefix -NetworkSecurityGroup $NSG -WarningAction SilentlyContinue
    $VNET | Set-AzVirtualNetwork -WarningAction SilentlyContinue
}
#endregion

#region Attach VM to second subnet which should be defaultsubnet
$NIC = New-AzNetworkInterface -Name $AzureVMSiteB.NICName -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName -SubnetId $Vnet.Subnets[0].Id
#endregion

#region build local admin credentials for VM
$LocalAdminSecurePassword = ConvertTo-SecureString $AzureVMSiteB.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AzureVMSiteB.LocalAdminUser, $LocalAdminSecurePassword);
#endregion

#region Build VM configurations
$VirtualMachine = New-AzVMConfig -VMName $AzureVMSiteB.Name -VMSize $AzureVMSiteB.Size
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $AzureVMSiteB.ComputerName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $AzureVMSiteB.PublisherName -Offer $AzureVMSiteB.Offer -Skus $AzureVMSiteB.Skus -Version $AzureVMSiteB.Version
#endregion

#region Deploy VM
New-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Location $AzureAdvConfigSiteB.LocationName -VM $VirtualMachine -Verbose
#endregion

#region set autoshutdown (using custom function)
If($AzureAdvConfigSiteB.EnableAutoshutdown){
    #determin is notification is by email or webhookurl; set the appropiate param
    $EmailRegex = '^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'
    $URLRegex = '(http[s]?|[s]?ftp[s]?)(:\/\/)([^\s,]+)'
    If($AzureAdvConfigSiteB.AutoShutdownNotificationType -match $EmailRegex){$ShutdownParam = @{Email=$AzureAdvConfigSiteB.AutoShutdownNotificationType}}
    If($AzureAdvConfigSiteB.AutoShutdownNotificationType -match $URLRegex){$ShutdownParam =@{WebhookUrl=$AzureAdvConfigSiteB.AutoShutdownNotificationType}}
    Set-AzVMAutoShutdown -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureAdvConfigSiteB.Name -Enable -Time $AzureAdvConfigSiteB.ShutdownTime -TimeZone $AzureAdvConfigSiteB.ShutdownTimeZone @ShutdownParam
}
#endregion

#region Reset VM password (Not working)
<#
#Re-reset password. Sometimes password set during deployment does not work
$VM = Get-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureVMSiteB.Name

Get-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VMName $AzureVMSiteB.Name -Status
#must grab the VM Computer Type handler
$typeParams = @{
 'PublisherName' = 'Microsoft.Compute'
 'Type' = 'VMAccessAgent'
 'Location' = $AzureAdvConfigSiteB.LocationName
}
$typeHandlerVersion = (Get-AzVMExtensionImage @typeParams | Sort-Object Version -Descending | Select-Object -first 1).Version

#remove the access exetension
Remove-AzVMAccessExtension -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VMName $AzureVMSiteB.Name -Name 'enablevmaccess' -Force

#build params
$extensionParams = @{
    Credential = $Credential
    VMName = $AzureVMSiteB.Name
    ResourceGroupName = $AzureAdvConfigSiteB.ResourceGroupName
    Name = 'enablevmaccess'
    Location = $AzureAdvConfigSiteB.LocationName
    TypeHandlerVersion = $typeHandlerVersion  
}
#add enablevmaccess back with new creds
Set-AzVMAccessExtension @extensionParams
#Set-AzVMAccessExtension -Credential $Credential -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VMName $AzureVMSiteB.Name -Name 'enablevmaccess' -TypeHandlerVersion $typeHandlerVersion -Location $AzureAdvConfigSiteB.LocationName
Update-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VM $VM
Restart-AzVM -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -Name $AzureVMSiteB.Name

#>
#Reset the Remote Desktop Services configuration
#Set-AzVMAccessExtension -ResourceGroupName $AzureAdvConfigSiteB.ResourceGroupName -VMName $AzureVMSiteB.Name -Name "VMRDPAccess" -Location $AzureAdvConfigSiteB.LocationName -typeHandlerVersion "2.0" -ForceRerun:$true
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
