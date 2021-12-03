Param(

    [ValidatePattern("^(?![0-9]{1,15}$)[a-zA-Z0-9-]{1,15}$")]
    [string]$VMName,
    [switch]$Autopilot
)
$ErrorActionPreference = "Stop"
#Requires -RunAsAdministrator
#https://docs.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/create-a-virtual-machine-in-hyper-v
#https://docs.microsoft.com/en-us/powershell/module/hyper-v/enable-vmtpm?view=windowsserver2019-ps

Write-Host ("THIS SCRIPT IS STILL IN BETA AND HAS NOT BEEN TESTED!!") -ForegroundColor Black -BackgroundColor Yellow
$response1 = Read-host "Would you like to continue? [Y or N]"
If($response1 -ne 'Y'){
    Break
}

#region Grab Configurations
If($PSScriptRoot.ToString().length -eq 0)
{
     Write-Host ("File not ran as script; Assuming its opened in ISE. ") -ForegroundColor Red
     Write-Host ("    Run configuration file first (eg: . .\configs.ps1)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading configuration file first...") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\configs.ps1" -NoAzureCheck -NoVyosISOCheck
}
#endregion

#start transcript
$LogfileName = "$RegionName-HyperVVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

If(-Not(Test-Path $HyperVSimpleVM.ISOLocation)){Write-Host ("Unable to find ISO: [{0}]. Please update config variable [`$HyperVVmIsoPath] and rerun setup" -f $HyperVSimpleVM.ISOLocation) -ForegroundColor Black -BackgroundColor Red;Break}

#check drive space availability
$DriveLetter = (Get-Item $HyperVConfig.VirtualHardDiskLocation).PSDrive.Name
$disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($DriveLetter):'" | Select-Object *
If($disk.FreeSpace -le $HyperVSimpleVM.HDDSize){
    Write-Host ("Not enough drive space [{1}GB] on [{0}]" -f $HyperVConfig.VirtualHardDiskLocation,[int]($disk.FreeSpace/1GB).ToString()) -ForegroundColor Black -BackgroundColor Red
    Break
}

#generate a serial number (for Autopilot)
$NewSerialNumber = Get-RandomSerialNumber

#region Check VM Name
$VMs = Get-VM -ErrorAction SilentlyContinue
If($VMName)
{
    If($VMName -in $VMs.Name){
        Write-Host ("Name already exists. You must specify a different vm name other than [{0}]" -f $VMName) -ForegroundColor Red
        do {
            $VMresponse = Read-host "Whats the new VM name?"
        } until ($VMresponse -match "^(?![0-9]{1,15}$)[a-zA-Z0-9-]{1,15}$" -and $VMresponse -ne $VMName)
        $VMName = $VMresponse
    }

    $computername = $VMName.ToUpper()
    $newVMname =  $VMName.ToUpper()
}
Else{
    #Increment VM
    $i=1
    do {
        $computername = ($HyperVSimpleVM.ComputerName -replace '\d+$', $i).ToUpper()
        $newVMname = ($HyperVSimpleVM.Name -replace '\d+$', $i).ToUpper()
        $i++
    } until ($newVMname -notin $VMs.Name)
}

#Update Names in config
$HyperVSimpleVM['ComputerName'] = $computername
If($Autopilot){
    $HyperVSimpleVM['Name'] = $VMName.ToUpper() + ' (' + $NewSerialNumber + ')'
}
Else{
    $HyperVSimpleVM['Name'] = $VMName.ToUpper()
}
$VHDxFilePath = ($HyperVConfig.VirtualHardDiskLocation + '\'+ $newVMname +'.vhdx')

Write-Host ("Virtual Machine name will be [{0}]" -f $HyperVSimpleVM.Name)  -ForegroundColor Green
#endregion

#region Build VM
Write-Host ("Creating VM [{0}]..." -f $HyperVSimpleVM.Name) -ForegroundColor White -NoNewline

Try{
    If(Get-VHD -Path $VHDxFilePath -ErrorAction SilentlyContinue){
        Remove-Item $VHDxFilePath -Confirm -Force -ErrorAction Stop
    }
    New-VHD -Path $VHDxFilePath -SizeBytes $HyperVSimpleVM.HDDSize -Dynamic -ErrorAction stop | Out-Null
}
Catch{
    Write-Host ("Unable to create VHD: [{0}]. {1}" -f $VHDxFilePath ,$_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
    Break
}

Try{
    If($Autopilot){
        $NetworkSwitchName = Get-VMSwitch -SwitchType External | Select -ExpandProperty Name -First 1
    }
    Else{
        $NetworkSwitchName = $HyperVConfig['VirtualSwitchNetworks'].GetEnumerator() | Select -ExpandProperty Name -First 1
    }

    New-VM -Name $HyperVSimpleVM.Name -VHDPath $VHDxFilePath  `
        -SwitchName $NetworkSwitchName -MemoryStartupBytes 1GB -Generation 2 -ErrorAction Stop | Out-Null
    Set-VM -Name $HyperVSimpleVM.Name -AutomaticCheckpointsEnabled $false -Notes "StartupOrder: $i" `
        -AutomaticStartAction StartIfRunning -AutomaticStopAction ShutDown -CheckpointType Disabled `
        -DynamicMemory -ErrorAction Stop | Out-Null

    #Generation 1 Set-VMBios -StartupOrder@("IDE","CD","LegacyNetworkAdapter","Floppy")

    Remove-VMCheckpoint -VMName $HyperVSimpleVM.Name -ErrorAction SilentlyContinue
    #enable secureboot
    Set-VMFirmware -VMName $HyperVSimpleVM.Name -EnableSecureBoot
    #enable tpm
    Set-VMKeyProtector -VMName $HyperVSimpleVM.Name -NewLocalKeyProtector
    Enable-VMTPM -VMName $HyperVSimpleVM.Name
    #Connect ISO
    Set-VMDvdDrive -VMName $HyperVSimpleVM.Name -Path $HyperVSimpleVM.ISOLocation -ErrorAction Stop
    #Get-VMNetworkAdapter -VMName $HyperVSimpleVM.Name | Connect-VMNetworkAdapter -SwitchName $NetworkSwitchName -ErrorAction Stop
    If($Autopilot){
        Set-VMAdvancedSettings -VM $HyperVSimpleVM.Name -BaseBoardSerialNumber $NewSerialNumber -BIOSSerialNumber $NewSerialNumber -ChassisSerialNumber $NewSerialNumber
    }
}
Catch{
    Write-Host ("Unable to build the VM: [{0}]. {1}" -f $HyperVSimpleVM.Name,$_.Exception.Message) -ForegroundColor Black -BackgroundColor Red
    Break
}
Write-Host "Done" -ForegroundColor Green
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
        $HyperVSimpleVM['LocalAdminPassword'] = $NewPassword
    }
    Else{
        Write-Host ("Unable to continue. Change config.ps1 variable [`$VMAdminPassword] value") -ForegroundColor Black -BackgroundColor Red
        Break
    }
}


Write-Host ("Building [{0}] credentials for VM [{1}]..." -f $HyperVSimpleVM.LocalAdminUser,$HyperVSimpleVM.Name) -ForegroundColor White -NoNewline
$LocalAdminSecurePassword = ConvertTo-SecureString $HyperVSimpleVM.LocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($HyperVSimpleVM.LocalAdminUser, $LocalAdminSecurePassword)
Write-Host "Done" -ForegroundColor Green
#endregion

#region Add unattend file to hyper-v guest harddrive
If($HyperVSimpleVM.Unattended){
    #Mount vhd

    #copy Autounattend.xml to vhdx root

    #unmount vhd

    #start VM
}
#endregion


#grab VM's current IP
$CurrentIPaddress = Get-VM -Name $HyperVSimpleVM.Name | Select -ExpandProperty Networkadapters | Select -ExpandProperty IPAddresses

#region grab hyper-v vm serialnumbers
If($Autopilot){
    $HyperVMInfo = Get-WmiObject -ComputerName 'localhost' -Namespace root\virtualization\v2 -class Msvm_VirtualSystemSettingData |
            Where InstanceID -match "(:)(\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1}$" |
            select * elementname, InstanceID, BIOSSerialNumber,SecureBootEnabled,ChassisAssetTag




    #run commands within VM
    #https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct
    $s = New-PSSession -VMName $HyperVSimpleVM.Name -Credential $Credential

    #Copy-Item -FromSession $s -Path C:\guest_path\data.txt -Destination C:\host_path\
    Invoke-Command -VMName $HyperVSimpleVM.Name -ScriptBlock { Install-script Get-WindowsAutopilotInfo -Force }
    Invoke-Command -VMName $HyperVSimpleVM.Name -ScriptBlock { Get-WindowsAutopilotInfo.ps1 -OutputFile C:\$NewSerialNumber.csv  }
    Move-Item -FromSession $s -Path C:\$NewSerialNumber.csv -Destination C:\host_path\
    Remove-PSSession $s
}

#endregion

Stop-Transcript
