#grabbed from: https://gallery.technet.microsoft.com/scriptcenter/Enable-or-disable-auto-c7837c84
#thanks to: Floris van der Ploeg
Function Set-AzVMAutoShutdown{
<#
    .SYNOPSIS
        Sets the auto-shutdown property for a virtual machine hosted in Microsoft Azure.

    .DESCRIPTION
        The Set-AzVMAutoShutdown script set the auto-shutdown property for a virtual machine.

    .PARAMETER ResourceGroupName
        Specifies the name of a resource group.

    .PARAMETER Name
        Specifies the name of the virtual machine for which auto-shutdown should be enabled or disabled.

    .PARAMETER Disable
        Sets the auto-shutdown property to disabled.

    .PARAMETER Enable
        Sets the auto-shutdown property to enabled.

    .PARAMETER Time
        The time of day the schedule will occur.

    .PARAMETER TimeZone
        The timezone

    .PARAMETER WebhookUrl
        The webhook URL to which the notification will be sent.

    .PARAMETER Email
        The e-mail address to which the notification will be sent.

    .EXAMPLE
        Set-AzVMAutoShutdown -ResourceGroupName RG-WE-001 -Name MYVM001 -Enable -Time 19:00

        Enables auto-shutdown on virtual machine MYVM001 in resource group RG-WE-001 and sets the daily shutdown to take place at 19:00.

    .EXAMPLE
        Set-AzVMAutoShutdown -ResourceGroupName RG-WE-001 -Name MYVM001 -Enable -Time 19:00 -TimeZone "W. Europe Standard Time"

        Enables auto-shutdown on virtual machine MYVM001 in resource group RG-WE-001 and sets the daily shutdown to take place at 19:00 in "W. Europe Standard Time" time zone.

    .EXAMPLE
        Set-AzVMAutoShutdown -ResourceGroupName RG-WE-001 -Name MYVM001 -Enable -Time 19:00 -TimeZone "W. Europe Standard Time" -WebhookURL "https://myapp.azurewebsites.net/webhook"

        Enables auto-shutdown on virtual machine MYVM001 in resource group RG-WE-001 and sets the daily shutdown to take place at 19:00 in "W. Europe Standard Time" time zone. Notifications will be enabled and the WebhookURL will be set to "https://myapp.azurewebsites.net/webhook".

    .EXAMPLE
        Set-AzVMAutoShutdown -ResourceGroupName RG-WE-001 -Name MYVM001 -Enable -Time 19:00 -TimeZone "W. Europe Standard Time" -Email "alerts@mycompany.com"

        Enables auto-shutdown on virtual machine MYVM001 in resource group RG-WE-001 and sets the daily shutdown to take place at 19:00 in "W. Europe Standard Time" time zone. Notifications will be enabled and sent to alerts@mycompany.com

    .EXAMPLE
        Set-AzVMAutoShutdown -ResourceGroupName RG-WE-001 -Name MYVM001 -Disable

        Disables auto-shutdown on virtual machine MYVM001 in resource group RG-WE-001.
    #>
    param (
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(ParameterSetName="PsDisable",Mandatory=$true)][switch]$Disable,
        [Parameter(ParameterSetName="PsEnable",Mandatory=$true)][switch]$Enable,
        [Parameter(ParameterSetName="PsEnable",Mandatory=$true)][DateTime]$Time,
        [Parameter(ParameterSetName="PsEnable",Mandatory=$false)][string]$TimeZone = (Get-TimeZone | Select-Object -ExpandProperty Id),
        [Parameter(ParameterSetName="PsEnable",Mandatory=$false)][AllowEmptyString()][string]$WebhookUrl = "",
        [Parameter(ParameterSetName="PsEnable",Mandatory=$false)][string]$Email
    )

    # Check the loaded modules
    $modules = @("Az.Compute", "Az.Resources", "Az.Accounts")
    foreach ($module in $modules) {
        if ((Get-Module -Name $module) -eq $null) {
            Write-Error -Message "PowerShell module '$module' is not loaded" -RecommendedAction "Please download the Azure PowerShell command-line tools from https://azure.microsoft.com/en-us/downloads/"
            return
        }
    }

    # Check if currently logged-on to Azure
    if ((Get-AzContext).Account -eq $null) {
        Write-Error -Message "No account found in the context. Please login using Login-AzAccount."
        return
    }

    # Validate the set timezone
    if ( (Get-TimeZone -ListAvailable | Select-Object -ExpandProperty Id) -notcontains $TimeZone) {
        Write-Error -Message "TimeZone $TimeZone is not valid"
        return
    }

    # Retrieve the VM from the defined resource group
    $vm = Get-AzVm -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($vm -eq $null) {
        Write-Error -Message "Virtual machine '$Name' under resource group '$ResourceGroupName' was not found."
        return
    }

    # Check if Auto-Shutdown needs to be enabled or disabled
    $properties = @{}
    if ($PsCmdlet.ParameterSetName -eq "PsEnable") {
        # Construct the notifications (only enable if webhook is enabled)
        if ([string]::IsNullOrEmpty($WebhookUrl) -and [string]::IsNullOrEmpty($Email)) {
            $notificationsettings = @{
                "status" = "Disabled";
                "timeInMinutes" = 30
            }
        } else {
            $notificationsettings = @{
                "status" = "Enabled";
                "timeInMinutes" = 30
            }

            # Add the Webhook URL if defined
            if ([string]::IsNullOrEmpty($WebhookUrl) -ne $true) { $notificationsettings.Add("WebhookUrl", $WebhookUrl) }

            # Add the recipient email address if it is defined
            if ([string]::IsNullOrEmpty($Email) -ne $true) {
                $notificationsettings.Add("emailRecipient", $Email)
                $notificationsettings.Add("notificationLocale", "en")
            }
        }

        # Construct the properties object
        $properties = @{
            "status" = "Enabled";
            "taskType" = "ComputeVmShutdownTask";
            "dailyRecurrence" = @{"time" = ("{0:HHmm}" -f $Time) };
            "timeZoneId" = $TimeZone;
            "notificationSettings" = $notificationsettings;
            "targetResourceId" = $vm.Id
        }
    } elseif ($PsCmdlet.ParameterSetName -eq "PsDisable") {
        # Construct the properties object
        $properties = @{
            "status" = "Disabled";
            "taskType" = "ComputeVmShutdownTask";
            "dailyRecurrence" = @{"time" = "1900" };
            "timeZoneId" = (Get-TimeZone).Id;
            "notificationSettings" = @{
                "status" = "Disabled";
                "timeInMinutes" = 30
            };
            "targetResourceId" = $vm.Id
        }
    } else {
        Write-Error -Message "Unable to determine auto-shutdown action. Use -Enable or -Disable as parameter."
        return
    }

    # Create the auto-shutdown resource
    try {
        $output = New-AzResource -ResourceId ("/subscriptions/{0}/resourceGroups/{1}/providers/microsoft.devtestlab/schedules/shutdown-computevm-{2}" -f (Get-AzContext).Subscription.Id, $ResourceGroupName, $Name) -Location $vm.Location -Properties $properties -ApiVersion "2017-04-26-preview" -Force -ErrorAction SilentlyContinue
    } catch {}

    # Check if resource deployment threw an error
    if ($? -eq $true) {
        # OK, return deployment object
        return $output
    } else {
        # Write error
        Write-Error -Message $Error[0].Exception.Message
    }
}

#Function to generate a random key, I used AES randomization
#or go https://www.pskgen.com/
Function New-SharedPSKey{
    Begin{
        $AESCryptoObject = new-object System.Security.Cryptography.AesCryptoServiceProvider
        $AESCryptoObject.GenerateKey()
    }
    Process{
        #crreate string builder
        $AESKey = new-object System.Text.StringBuilder
        #loop though each key and buold a single string
        foreach ($b in $AESCryptoObject.Key) {
            $AESKey = $AESKey.AppendFormat([System.Globalization.CultureInfo]::InvariantCulture, "{0:X2}", $b)
        }
    }
    End{
        $AESCryptoObject.Dispose()
        return $AESKey.ToString().ToLowerInvariant()
    }
}


Function Set-TruncateString{
    param (
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [string]$str,
        [Parameter(Mandatory=$true,Position=1)]
        [int]$length
    )

    process{
        $str.subString(0, [System.Math]::Min($length, $str.Length))
    }
}




Function Start-ExeProcess{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        $Executable,
        [Parameter(Mandatory=$false,Position=1)]
        $Arguments,
        $IgnoreCodes,
        [string[]]$SendKeys,
	    [switch]$Wait,
        [switch]$PassThru
    )

    [string]${CmdletName} = $MyInvocation.MyCommand
    #[string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

    If(!(Test-Command $Executable)){
        return $False
    }

    try{
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.FileName = $Executable
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $pinfo.Verb = 'runas'
        $pinfo.Arguments = $Arguments

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pinfo
        $p.Start() | Out-Null

        $SendKeys -split ',' | Foreach{
            Switch($_){
                'Tab'    {Send-Keystrokes -Keys '{Tab}'}
                'Enter'  {Send-Keystrokes -Keys '{Enter}'}
                'TabEnter' {Send-Keystrokes -Keys '{Tab}'; Send-Keystrokes -Keys '{Enter}' -Delay 1}
                default   {Send-Keystrokes -Keys $_}
            }
        }


        Write-Debug ("Command Executed: {0} {1}" -f $Executable,$Arguments)

        If($Wait){
            $p.WaitForExit()
        }

        $pStdout = $p.StandardOutput.ReadToEnd()
        $pStderr = $p.StandardError.ReadToEnd()

        Write-Debug ("Command StandardOutput: {0}" -f $pStdout)
        Write-Debug ("Command StandardError: {0}" -f $pStderr)

        If($p.ExitCode -in $IgnoreCodes){
            $ExitCode = 0
        }Else{
            $ExitCode = $p.ExitCode
        }

        Write-Debug ("Command ExitCode: {0}" -f $p.ExitCode)

        If($PassThru){
            return @{ stdout = $pStdout; stderr = $pStderr; ExitCode = $p.ExitCode }
        }Else{
            If($Wait){return $p.ExitCode}
        }
    }
    catch { $_.Exception }
}


function Send-Keystrokes ([string] $Keys, [int] $Delay = 0)
{
    try
    {
        Start-Sleep -Seconds $Delay
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.SendKeys($Keys)
        Start-Sleep -Seconds 1
    }
    finally
    {
        try
        {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject([System.__ComObject]$wshell) | Out-Null
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
        catch { }
    }
}

Function Test-Command{
    Param ($command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'stop'
    try {if(Get-Command $command){RETURN $true}}
    Catch {Write-Verbose "$command does not exist"; RETURN $false}
    Finally {$ErrorActionPreference=$oldPreference}
}
