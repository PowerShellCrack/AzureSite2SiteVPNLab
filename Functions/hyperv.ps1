
function Get-VMSettings
{
    <#
    .SYNOPSIS
    Get the BIOS Serial Number and Asset Tag for a VM

    .DESCRIPTION
    This function will get the BIOS Serial Number and Asset Tag for a VM

    .PARAMETER VMName
    The name of the VM to get the settings for

    .EXAMPLE
    Get-VMSettings -VMName "VM01"
    This will get the BIOS Serial Number and Asset Tag for VM01

    .EXAMPLE
    Get-VMSettings
    This will get the BIOS Serial Number and Asset Tag for all VMs

    #>
    [CmdletBinding()]
    param
       (
        [Parameter(ValueFromPipelineByPropertyName=$true, Position=0)]
        [string[]]$VMName
    )
    Begin{
        If($VMName.count -eq 0){
            $VMs = Get-VM
        }Else{
            $VMs = $VMName | Get-VM
        }

        $VMData = @()
    }
    Process{

        Foreach($VM in $VMs)
        {
            Write-Verbose "Getting VM settings for $($VM.Name)"
            $VMData += Get-CimInstance -Class 'Msvm_VirtualSystemSettingData' -Namespace 'root\virtualization\v2' -Filter "elementname = '$($VM.Name)'" | 
                Where-Object BIOSSerialNumber -ne $null |
                Select-Object `
                    @{Name='VMName';Expression={$_.elementname}},
                    BIOSSerialNumber,
                    ChassisAssetTag,
                    @{Name='GenType';Expression={$_.VirtualSystemSubType.split(':')[-1]}},
                    @{Name='VMState';Expression={$VM.State}}
        }

    }End{
        Return $VMData
    
    }
}


function Set-VMSettings
{
    <#
    .SYNOPSIS
    Set the BIOS Serial Number and Asset Tag for a VM

    .DESCRIPTION
    This function will set the BIOS Serial Number and Asset Tag for a VM

    .PARAMETER VMName
    The name of the VM to set the settings for

    .PARAMETER SerialNumber
    The Serial Number to set for the VM

    .PARAMETER AssetTag
    The Asset Tag to set for the VM

    .PARAMETER Force
    If the VM is running, this will force the VM to shut down to apply the settings

    .EXAMPLE
    Set-VMSettings -VMName "VM01" -SerialNumber "123456"
    This will set the Serial Number to 123456 for VM01

    .EXAMPLE
    Set-VMSettings -SerialNumber "123456" -AssetTag "ABC123" -Force
    This will set the Serial Number to 123456 and the Asset Tag to ABC123 for all VMs and force the VM to shut down if it is running

    #>
    [CmdletBinding()]
    param
       (
        [Parameter(ValueFromPipelineByPropertyName=$true, Position=0)]
        [string[]]$VMName,
        [Parameter()]
        [string]$SerialNumber,
        [Parameter()]
        [string]$AssetTag,
        [Parameter()]
        [switch]$Force
    )
    Begin{
        If($VMName.count -eq 0){
            $VMs = Get-VM
        }Else{
            $VMs = $VMName | Get-VM
        }
        $ErrorCode = 0
    }
    Process{

        #TEST $VM=$VMs[0]
        Foreach($VM in $VMs)
        {
            $StartVmOnComplete = $false
            If($VM.State -eq 'Running')
            {
                $StartVmOnComplete = $true
                If($Force)
                {
                    Write-Warning "VM $($VM.Name) is running. Shutting down VM to apply settings"
                    Stop-VM -Name $VM.Name -Force
                }
                Else
                {
                    Write-Error "VM $($VM.Name) is running. Use -Force to shut down VM to apply settings"
                }
            }

            #get the VMMS object
            $VMMS = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_VirtualSystemManagementService' -ErrorAction Stop
            $ModifySystemSettingsParams = $VMMS.GetMethodParameters('ModifySystemSettings')

            #Get the VM object
            $VMObject = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' -Filter "elementname = '$($VM.Name)'"
            $CurrentSettingsDataCollection = $VMObject.GetRelated('Msvm_VirtualSystemSettingData')

            #correlate the VM object with the settings object
            $CurrentSettingsData = $null
            foreach($SettingsObject in $CurrentSettingsDataCollection)
            {
                if($VMObject.Name -eq $SettingsObject.ConfigurationID)
                {
                    $CurrentSettingsData = [System.Management.ManagementObject]($SettingsObject)
                }
            }

            If($SerialNumber){
                Write-Verbose "Setting Serial Number for $($VM.Name) to: $SerialNumber"
                $CurrentSettingsData.BIOSSerialNumber = $SerialNumber
            }
            If($AssetTag){
                Write-Verbose "Setting Asset Tag for $($VM.Name) to: $AssetTag"
                $CurrentSettingsData.ChassisAssetTag = $AssetTag
            }
            
            #buld the settings object
            $ModifySystemSettingsParams['SystemSettings'] = $CurrentSettingsData.GetText([System.Management.TextFormat]::CimDtd20)
            #ACTION Update the settings to the VM
            $WmiResponse = $VMMS.InvokeMethod('ModifySystemSettings', $ModifySystemSettingsParams, $null)
            
            #monitor the job
            if($WmiResponse.ReturnValue -eq 4096)
            {
                    $Job = [WMI]$WmiResponse.Job

                    while ($Job.JobState -eq 4)
                    {
                            Write-Progress -Activity ('Modifying virtual machine {0} on host {1}' -f $VMName, $env:ComputerName) -Status ('{0}% Complete' -f $Job.PercentComplete) -PercentComplete $Job.PercentComplete
                            Start-Sleep -Milliseconds 100
                            $Job.PSBase.Get()
                    }

                    if($Job.JobState -ne 7)
                    {
                            if ($Job.ErrorDescription -ne "")
                            {
                                Write-Error -Message $Job.ErrorDescription
                                exit 1
                            }
                            else
                            {
                                $ErrorCode = $Job.ErrorCode
                            }
                            Write-Progress $Job.Caption "Completed" -Completed $true
                    }
            }
            elseif ($WmiResponse.ReturnValue -ne 0)
            {
                    $ErrorCode = $WmiResponse.ReturnValue
            }

            $PSWmiClass = [WmiClass]($VMMS.ClassPath)
            $PSWmiClass.PSBase.Options.UseAmendedQualifiers = $true
            $MethodQualifiers = $PSWmiClass.PSBase.Methods['ModifySystemSettings'].Qualifiers
            $IndexOfError = [System.Array]::IndexOf($MethodQualifiers["ValueMap"].Value, [String]$ErrorCode)
            if( ($IndexOfError -ne "-1") -and ($IndexOfError -ne "0") )
            {
                Write-Error -Message ('Error Code: {0}, Method: {1}, Error: {2}' -f $ErrorCode, 'ModifySystemSettings', $MethodQualifiers["Values"].Value[$IndexOfError])
                continue
            }

            if($StartVmOnComplete)
            {
                Write-Verbose "Starting VM $($VM.Name) back up"
                Start-VM -Name $VM.Name
            }
        }
    }
    End{
        Write-Verbose "Settings updated successfully"
    }
}


Function Get-RandomAlphanumericString {
    <#
    .SYNOPSIS
    Generate a random alphanumeric string

    .DESCRIPTION
    This function will generate a random alphanumeric string

    .PARAMETER length
    The length of the string to generate

    .EXAMPLE
    Get-RandomAlphanumericString -length 8
    This will generate a random alphanumeric string 8 characters long
    #>
    Param (
     [int] $length = 8
    )

    Begin{
    }
    Process{
     return ( -join ((0x30..0x39) + ( 0x41..0x5A) + ( 0x61..0x7A) | Get-Random -Count $length  | ForEach-Object {([char]$_).ToString().ToUpper()}) )
    }
}

Function Get-RandomAssetTag{
    <#
    .SYNOPSIS
    Generate a random Asset Tag

    .DESCRIPTION
    This function will generate a random Asset Tag

    .PARAMETER Count
    The number of Asset Tags to generate

    .EXAMPLE
    Get-RandomAssetTag -Count 5
    This will generate 5 random Asset Tags
    #>
    param($Count = 1)

    $AssetTags = @()
    For ($i = 0; $i -lt $Count) {
        $AssetTag = "$(Get-RandomAlphanumericString -length 3)$(Get-random -Minimum 1000000 -Maximum 9999999)$(Get-RandomAlphanumericString -length 2)"
        $AssetTags += $AssetTag
        $i++
    }
    Return $AssetTags

}

Function Get-RandomSerialNumber{
    <#
    .SYNOPSIS
    Generate a random Serial Number

    .DESCRIPTION
    This function will generate a random Serial Number

    .PARAMETER Count
    The number of Serial Numbers to generate
    
    .PARAMETER DellLike
    If this switch is used, the Serial Number will be in the format of a Dell Serial Number
    
    .EXAMPLE
    Get-RandomSerialNumber -Count 5
    This will generate 5 random Serial Numbers

    .EXAMPLE
    Get-RandomSerialNumber -Count 5 -DellLike
    This will generate 5 random Serial Numbers in the format of a Dell Serial Number
    #>
    param(
        $Count = 1,
        [switch]$DellLike
    )

    $SerialNumbers = @()
    For ($i = 0; $i -lt $Count) {
        If($DellLike){
            $SerialNumber = "$(Get-random -Minimum 10 -Maximum 99)$((65..90) | Get-Random | %{[Char]$_})$(Get-RandomAlphanumericString -length 2)$((66..68)+ 71 + 72 + (74..78) + (80..84)+ (86..90)  | Get-Random | %{[Char]$_})1"
        }
        Else{
            $SerialNumber = "$(Get-RandomAlphanumericString -length 3)$(Get-random -Minimum 1000 -Maximum 9999)"
        }
        $SerialNumbers += $SerialNumber
        $i++
    }
    Return $SerialNumbers
}

#https://www.powershellgallery.com/packages/AppVeyorBYOC/1.0.178
$AutoUnattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>500</Size>
                            <Type>EFI</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Size>128</Size>
                            <Type>MSR</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>Windows Server 2019 SERVERDATACENTER</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
            <UserData>
                <!-- Product Key from https://www.microsoft.com/de-de/evalcenter/evaluate-windows-server-technical-preview?i=1 -->
                <ProductKey>
                    <!-- Do not uncomment the Key element if you are using trial ISOs -->
                    <!-- You must uncomment the Key element (and optionally insert your own key) if you are using retail or volume license ISOs -->
                    <!-- <Key>6XBNX-4JQGW-QX6QG-74P76-72V67</Key> -->
                    <WillShowUI>OnError</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
                <FullName>AppVeyor</FullName>
                <Organization>AppVeyor</Organization>
            </UserData>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OEMInformation>
                <HelpCustomized>false</HelpCustomized>
            </OEMInformation>
            <ComputerName>appveyor-2019</ComputerName>
            <TimeZone>Pacific Standard Time</TimeZone>
            <RegisteredOwner/>
        </component>
        <component name="Microsoft-Windows-ServerManager-SvrMgrNc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
        </component>
        <component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <IEHardenAdmin>false</IEHardenAdmin>
            <IEHardenUser>false</IEHardenUser>
        </component>
        <component name="Microsoft-Windows-OutOfBoxExperience" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DoNotOpenInitialConfigurationTasksAtLogon>true</DoNotOpenInitialConfigurationTasksAtLogon>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Set Execution Policy 64 Bit</Description>
                    <Path>cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Description>Set Execution Policy 32 Bit</Description>
                    <Path>cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Description>Disable WinRM</Description>
                    <Path>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\disable-winrm.ps1</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>appveyor</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <Username>appveyor</Username>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"</CommandLine>
                    <Description>Set Execution Policy 64 Bit</Description>
                    <Order>1</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>C:\Windows\SysWOW64\cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"</CommandLine>
                    <Description>Set Execution Policy 32 Bit</Description>
                    <Order>2</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\disable-winrm.ps1</CommandLine>
                    <Description>Disable WinRM</Description>
                    <Order>3</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ /v HideFileExt /t REG_DWORD /d 0 /f</CommandLine>
                    <Order>4</Order>
                    <Description>Show file extensions in Explorer</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKCU\Console /v QuickEdit /t REG_DWORD /d 1 /f</CommandLine>
                    <Order>5</Order>
                    <Description>Enable QuickEdit mode</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ /v Start_ShowRun /t REG_DWORD /d 1 /f</CommandLine>
                    <Order>6</Order>
                    <Description>Show Run command in Start Menu</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ /v StartMenuAdminTools /t REG_DWORD /d 1 /f</CommandLine>
                    <Order>7</Order>
                    <Description>Show Administrative Tools in Start Menu</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKLM\SYSTEM\CurrentControlSet\Control\Power\ /v HibernateFileSizePercent /t REG_DWORD /d 0 /f</CommandLine>
                    <Order>8</Order>
                    <Description>Zero Hibernation File</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\System32\reg.exe ADD HKLM\SYSTEM\CurrentControlSet\Control\Power\ /v HibernateEnabled /t REG_DWORD /d 0 /f</CommandLine>
                    <Order>9</Order>
                    <Description>Disable Hibernation Mode</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c wmic useraccount where "name='appveyor'" set PasswordExpires=FALSE</CommandLine>
                    <Order>10</Order>
                    <Description>Disable password expiration for appveyor user</Description>
                </SynchronousCommand>

                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c powershell -Command "New-NetIPAddress -InterfaceAlias Ethernet -IPAddress 10.118.232.2 -AddressFamily IPv4 -PrefixLength 24 -DefaultGateway 10.118.232.1"</CommandLine>
                    <Description>Assign IP behind NAT</Description>
                    <Order>11</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c powershell -Command "Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses @('8.8.8.8','8.8.4.4')"</CommandLine>
                    <Description>Set DNS</Description>
                    <Order>12</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>

                <!-- WITHOUT WINDOWS UPDATES -->

                <!-- <SynchronousCommand wcm:action="add"> -->
                    <!-- <CommandLine>cmd.exe /c C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\enable-winrm.ps1</CommandLine> -->
                    <!-- <Description>Enable WinRM</Description> -->
                    <!-- <Order>99</Order> -->
                <!-- </SynchronousCommand> -->

                <!-- END WITHOUT WINDOWS UPDATES -->
                <!-- WITH WINDOWS UPDATES -->
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c e:\microsoft-updates.bat</CommandLine>
                    <Order>98</Order>
                    <Description>Enable Microsoft Updates</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\disable-screensaver.ps1</CommandLine>
                    <Description>Disable Screensaver</Description>
                    <Order>99</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\win-updates.ps1</CommandLine>
                    <Description>Install Windows Updates</Description>
                    <Order>100</Order>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File e:\enable-winrm.ps1</CommandLine>
                    <Description>Enable WinRM</Description>
                    <Order>101</Order>
                </SynchronousCommand>
                <!-- END WITH WINDOWS UPDATES -->
            </FirstLogonCommands>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>appveyor</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>appveyor</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Group>administrators</Group>
                        <DisplayName>AppVeyor</DisplayName>
                        <Name>appveyor</Name>
                        <Description>AppVeyor User</Description>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <RegisteredOwner />
        </component>
    </settings>
    <settings pass="offlineServicing">
        <component name="Microsoft-Windows-LUA-Settings" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <EnableLUA>false</EnableLUA>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="wim:c:/wim/install.wim#Windows Server 2012 R2 SERVERSTANDARD" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

$Unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="generalize">
        <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipRearm>0</SkipRearm>
        </component>
        <!--
        <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <PersistAllDeviceInstalls>false</PersistAllDeviceInstalls>
            <DoNotCleanUpNonPresentDevices>false</DoNotCleanUpNonPresentDevices>
        </component>
        -->
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <ProtectYourPC>3</ProtectYourPC>
                <NetworkLocation>Work</NetworkLocation>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
            <AutoLogon>
                <Password>
                    <Value>vagrant</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>vagrant</Username>
            </AutoLogon>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>vagrant</ComputerName>
            <CopyProfile>false</CopyProfile>
        </component>
    </settings>
</unattend>

"@
