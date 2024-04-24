<#
    .SYNOPSIS
        Builds a Hyper-V VM

    .DESCRIPTION
        Builds a Hyper-V VM

    .NOTES


    .PARAMETER ConfigurationFile
    STRING

    .EXAMPLE

    & '.\Step 4A-2. Build Hyper-V VM.ps1 -ConfigurationFile configs-gov.ps1
#>
param(
    [Parameter(Mandatory = $true)]
    $ISOPath,

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
    
    
    [switch]$SetChassisSettings
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
     Write-Host ("    Run configuration file first (eg: . .\$ConfigurationFile)") -ForegroundColor Yellow
     Break
}
Else{
    Write-Host ("Loading {0}..." -f "$PSScriptRoot\$ConfigurationFile") -ForegroundColor Yellow -NoNewline
    . "$PSScriptRoot\$ConfigurationFile" -NoVyosISOCheck
}
#endregion

#start transcript
$LogfileName = "$RegionName-HyperVVMSetup-$(Get-Date -Format 'yyyy-MM-dd_Thh-mm-ss-tt').log"
Try{Start-transcript "$PSScriptRoot\Logs\$LogfileName" -ErrorAction Stop}catch{Start-Transcript "$PSScriptRoot\$LogfileName"}

#check drive space availability
$DriveLetter = (Get-Item $HyperVConfig.VirtualHardDiskLocation).PSDrive.Name


#Set VM Parameters
$VMname = Read-Host 'Please enter the name of the VM to be created, [eg. W11VM]'
if ((Get-VM -Name $VMname -ErrorAction SilentlyContinue).count -ge 1) {
    Write-Warning ("VM {0} already exists on this system, aborting..." -f $VMname)
    return
}Else{
    Write-Host ("New VM will be named: {0}" -f $VMname) -ForegroundColor Green
}

$VMCores = Read-Host 'Please enter the amount of cores [1-4]'
[int64]$VMRAM = 1GB * (read-host "Enter Memory in Gb's [4-12]")
[int64]$VMDISK = 1GB * (read-host "Enter HDD size in Gb's [40-200]")
$VMdir = (get-vmhost).VirtualMachinePath + "\" + $VMname
$VMDiskDir = (get-vmhost).VirtualMachinePath + "\" + $VMname+ "\Virtual Hard Disks"
#$VMDiskDir = (get-vmhost).VirtualHardDiskPath

$disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($DriveLetter):'" | Select-Object *
If($disk.FreeSpace -le $VMDISK){
    Write-Host ("Not enough drive space [{1}GB] on [{0}]" -f $HyperVConfig.VirtualHardDiskLocation,[int]($disk.FreeSpace/1GB).ToString()) -ForegroundColor Black -BackgroundColor Red
    Break
}

Write-Host ("Select ISO...") -ForegroundColor White
$ISO = Get-Childitem $ISOPath *.ISO | Out-GridView -OutputMode Single -Title 'Please select the ISO from the list and click OK'
if (($ISO.FullName).Count -ne '1') {
    Write-Warning ("No ISO selected...")
}Else{
    Write-Host ("Using ISO: {0}..." -f $ISO.FullName) -ForegroundColor Green
}

Write-Host ("Select Switch...") -ForegroundColor White
$SwitchName = Get-VMSwitch | Out-GridView -OutputMode Single -Title 'Please select the VM Switch and click OK' | Select-Object Name
if (($SwitchName.Name).Count -ne '1') {
    Write-Warning ("No Virtual Switch selected, script aborted...")
    return
}Else{
    Write-Host ("Using Virtual Switch: {0}..." -f $SwitchName.Name) -ForegroundColor Green
}

#Create VM directory
If( -NOT(Test-Path -Path $VMdir -ErrorAction SilentlyContinue) ){
    Write-Host ("Creating Virtual Machine: {0}..." -f $VMname) -ForegroundColor White
    try {
        New-Item -ItemType Directory -Path $VMdir -Force:$true -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Warning ("Couldn't create {0} folder, please check VM Name for illegal characters or permissions on folder..." -f $VMdir)
        return
    }
    finally {
        if (test-path -Path $VMdir -ErrorAction SilentlyContinue) {
            Write-Host ("Using {0} as Virtual Machine location..." -f $VMdir) -ForegroundColor Green
        }
    }
}


#Create VM with the specified values
try {
    write-host ("Creating VM: {0}..." -f $VMname) -ForegroundColor White
    New-VM -Name $VMname `
        -SwitchName $SwitchName.Name `
        -Path $VMdir `
        -Generation 2 `
        -Confirm:$false `
        -NewVHDPath "$($VMDiskDir)\$($VMname).vhdx" `
        -NewVHDSizeBytes ([math]::Round($vmdisk * 1024) / 1KB) `
        -ErrorAction Stop `
    | Out-Null
}
catch {
    Write-Warning ("Error creating {0}: {1}..." -f $VMname, $_.Exception.Message)
    return
}
finally {
    if (Get-VM -Name $VMname -ErrorAction SilentlyContinue | Out-Null) {
        write-host ("Created {0})..." -f $VMname) -ForegroundColor Green
    }
}

#Configure settings on the VM, CPU/Memory/Disk/BootOrder/TPM/Checkpoints
try {
    Write-Host ("Configuring settings on {0}..." -f $VMname) -ForegroundColor Green

    #VM Settings
    Set-VM -name $VMname `
        -ProcessorCount $VMCores `
        -StaticMemory `
        -MemoryStartupBytes $VMRAM `
        -CheckpointType ProductionOnly `
        -AutomaticCheckpointsEnabled:$false `
        -ErrorAction SilentlyContinue `
    | Out-Null

    #Add Harddisk
    Add-VMHardDiskDrive -VMName $VMname -Path "$($VMDiskDir)\$($VMname).vhdx" -ControllerType SCSI -ErrorAction SilentlyContinue | Out-Null

    #Add DVD with iso and set it as bootdevice
    If($ISO.count -eq 1){
        Add-VMDvdDrive -VMName $VMName -Path $ISO.FullName -Passthru -ErrorAction SilentlyContinue | Out-Null
        $DVD = Get-VMDvdDrive -VMName $VMname
    }
    $VMHD = Get-VMHardDiskDrive -VMName $VMname

    Set-VMFirmware -VMName $VMName -FirstBootDevice $VMHD
    If($ISO.count -eq 1){
        Set-VMFirmware -VMName $VMName -FirstBootDevice $DVD
    }
    Set-VMFirmware -VMName $VMname -EnableSecureBoot:On

    #Enable TPM
    Set-VMKeyProtector -VMName $VMname -NewLocalKeyProtector
    Enable-VMTPM -VMName $VMname

    #Enable all integration services
    Enable-VMIntegrationService -VMName $VMname -Name 'Guest Service Interface' , 'Heartbeat', 'Key-Value Pair Exchange', 'Shutdown', 'Time Synchronization', 'VSS'
}
catch {
    Write-Warning ("Error setting VM parameters, check settings of VM {0} ..." -f $VMname)
    return
}



If($SetChassisSettings){
    #$CurrentSerial = Get-VMSettings -VMName $VM.Name | Select-Object -ExpandProperty BIOSSerialNumber
    #$CurrentAssetTag = Get-VMSettings -VMName $VM.Name | Select-Object -ExpandProperty ChassisAssetTag

    do{    
        Write-Host "What would you like the serial to be for: $($VMName):"
        $SerialResponse = Read-Host "Options are: ([D]ellLike, [R]andom, [C]ustom, [A]fterDashInName, [G]uid, [H]yper-V number)?"
        switch ($SerialResponse.ToUpper()) {
            'D' {
                $SerialNumber = (Get-RandomSerialNumber -DellLike)
                $AssetTag = (Get-RandomAssetTag)
            }
            'R' {
                $SerialNumber = 'HVM' + (Get-RandomSerialNumber)
                $AssetTag = (Get-RandomAssetTag)
            }
            'C' {
                $SerialNumber = Read-Host "Enter the Serial Number for $($VMName)"
                $AssetTag = Read-Host "Enter the AssetTag for $($VMName)"
            }
            'A' {
                $SerialNumber = $VMName.Split('-')[-1]
                $AssetTag = (Get-RandomAssetTag)
            }
            'G' {
                $SerialNumber = [System.Guid]::NewGuid().ToString()
                $AssetTag = [System.Guid]::NewGuid().ToString()
            }
            'H' {
                #random number between 1000 and 9999 5 time and then set two random numbers
                $NumberSet = @()
                For ($i = 0; $i -lt 6) {
                    $NumberSet += (Get-Random -Minimum 1000 -Maximum 9999)
                    $i++
                }
                $NumberSet += (Get-Random -Minimum 10 -Maximum 99)
                $NumberSet = $NumberSet -join '-'
                
                $SerialNumber = $NumberSet
                $AssetTag = $NumberSet
            }
            default {
                Write-Host ("Invalid input, please enter D, R, C, A, G, or H...") -ForegroundColor Red
            }
        }
    } Until($SerialResponse -match 'D|R|C|A|G|H')


    Set-VMSettings -VMName $VMname -SerialNumber $SerialNumber
    Set-VMSettings -VMName $VMname -AssetTag $AssetTag
}

Write-Host "Done" -ForegroundColor Green
#endregion

#region Add unattend file to hyper-v guest harddrive
#NOT WORKING YET
If($Unattended){
    #region Build local admin credentials for VM
    If($VMAdminPassword -notmatch '((?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%&*()]).{8,123})' -or $VMAdminPassword -match 'password')
    {
        Write-Host ("You must specify a more complex password other than [{0}]" -f $VMAdminPassword) -ForegroundColor Red
        $ChangePassword = Read-host "Would you like to set a new password? [Y or N]"
        If($ChangePassword -eq 'Y'){
            do {
                $NewPassword = Read-host "Whats the new password?"
            } until ($NewPassword -match '((?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%&*()]).{8,123})')
            #DO ACTION
            
        }
        Else{
            Write-Host ("Unable to continue. Change config.ps1 variable [`$VMAdminPassword] value") -ForegroundColor Black -BackgroundColor Red
            Break
        }
    }

    #Mount vhd

    #copy Autounattend.xml to vhdx root

    #unmount vhd

    #start VM
}
#endregion



#region grab hyper-v vm serialnumbers
If($Autopilot){
    #grab VM's current IP
    $CurrentIPaddress = Get-VM -Name $VMName | Select -ExpandProperty Networkadapters | Select -ExpandProperty IPAddresses


    $HyperVMInfo = Get-WmiObject -ComputerName 'localhost' -Namespace root\virtualization\v2 -class Msvm_VirtualSystemSettingData |
            Where InstanceID -match "(:)(\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1}$" |
            select * elementname, InstanceID, BIOSSerialNumber,SecureBootEnabled,ChassisAssetTag

    #run commands within VM
    #https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct
    $s = New-PSSession -VMName $VMName -Credential $Credential

    #Copy-Item -FromSession $s -Path C:\guest_path\data.txt -Destination C:\host_path\
    Invoke-Command -VMName $VMName -ScriptBlock { Install-script Get-WindowsAutopilotInfo -Force }
    Invoke-Command -VMName $VMName -ScriptBlock { Get-WindowsAutopilotInfo.ps1 -OutputFile C:\$NewSerialNumber.csv  }
    Move-Item -FromSession $s -Path C:\$NewSerialNumber.csv -Destination C:\host_path\
    Remove-PSSession $s
}

#endregion

Stop-Transcript
