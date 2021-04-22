$ErrorActionPreference = "Stop"

#region Grab Configurations
. "$PSScriptRoot\Configs.ps1"
#endregion

#start transcript
$LogfileName = "$RegionName-BuildAzureVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#https://docs.microsoft.com/en-us/powershell/module/az.compute/new-azvm?view=azps-2.8.0
#Example 3: Create a VM from a marketplace image without a Public IP
#region Create a resource group:
If(-Not(Get-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    New-AzResourceGroup -Name $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName
}
#endregion

#region Create Storage Account
$storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
If(-Not(Get-AzStorageAccount -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $storageName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){
    #build random char for storage name
    $Global:randomChar = (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})).ToString()
    $storageName = ($RegionBName +'-' + $Global:randomChar).ToLower() -replace '[\W]', ''
    $storageAcc = New-AzStorageAccount -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $storageName -SkuName $AzureSimpleConfig.StorageSku -Location $AzureSimpleConfig.LocationName -Kind Storage -verbose
}
#endregion

#region Creating a new NSG to allow PS Remoting Port 5986 and RDP Port 3389
#grab Vnet for NSG and NIC configurations
$VNET = Get-AzVirtualNetwork -Name $AzureSimpleConfig.VNETName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName

If(-Not($NSG = Get-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)){

    $NSG = New-AzNetworkSecurityGroup -Name $AzureSimpleVM.NSGName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -Verbose
    $NSG | Add-AzNetworkSecurityRuleConfig -Name "RDP" -Priority 1200 -Protocol TCP -Access Allow -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Direction Inbound -Verbose | Set-AzNetworkSecurityGroup

    
    Set-AzVirtualNetworkSubnetConfig -Name 'DefaultSubnet' -VirtualNetwork $VNET -AddressPrefix $AzureSimpleConfig.VnetSubnetPrefix -NetworkSecurityGroup $NSG -WarningAction SilentlyContinue
    $VNET | Set-AzVirtualNetwork -WarningAction SilentlyContinue
}
#endregion

#region Attach VM to second subnet which should be defaultsubnet
$NIC = New-AzNetworkInterface -Name $AzureSimpleVM.NICName -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -SubnetId $Vnet.Subnets[1].Id
#endregion

#region Build local admin credentials for VM
$LocalAdminSecurePassword = ConvertTo-SecureString $AzureSimpleVM.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AzureSimpleVM.LocalAdminUser, $LocalAdminSecurePassword);
#endregion

#region Build VM configurations
$VirtualMachine = New-AzVMConfig -VMName $AzureSimpleVM.Name -VMSize $AzureSimpleVM.Size
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $AzureSimpleVM.ComputerName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2016-Datacenter' -Version latest
#endregion

#region Deploy VM
New-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Location $AzureSimpleConfig.LocationName -VM $VirtualMachine -Verbose
#endregion

#region set autoshutdown (using custom function)
If($AzureSimpleVM.EnableAutoshutdown){
    #determin is notification is by email or webhookurl; set the appropiate param
    $EmailRegex = '^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'
    $URLRegex = '(http[s]?|[s]?ftp[s]?)(:\/\/)([^\s,]+)'
    If($AzureSimpleVM.AutoShutdownNotificationType -match $EmailRegex){$ShutdownParam = @{Email=$AzureSimpleVM.AutoShutdownNotificationType}}
    If($AzureSimpleVM.AutoShutdownNotificationType -match $URLRegex){$ShutdownParam =@{WebhookUrl=$AzureSimpleVM.AutoShutdownNotificationType}}
    Set-AzVMAutoShutdown -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleVM.Name -Enable -Time $AzureSimpleVM.ShutdownTime -TimeZone $AzureSimpleVM.ShutdownTimeZone @ShutdownParam
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
#Set-AzVMAccessExtension -Credential $Credential -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name -Name 'enablevmaccess' -TypeHandlerVersion $typeHandlerVersion -Location $AzureSimpleConfig.LocationName
Update-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VM $VM
Restart-AzVM -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -Name $AzureSimpleVM.Name

#>
#Reset the Remote Desktop Services configuration
#Set-AzVMAccessExtension -ResourceGroupName $AzureSimpleConfig.ResourceGroupName -VMName $AzureSimpleVM.Name -Name "VMRDPAccess" -Location $AzureSimpleConfig.LocationName -typeHandlerVersion "2.0" -ForceRerun:$true
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