
Function Connect-AzureEnvironment{
    [CmdletBinding(DefaultParameterSetName = 'ListParameterSet',
        HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=398573',
        SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory = $false,Position = 0)]
        [string]$TenantID,

        [Parameter(Mandatory = $false,
            Position = 1,
            ParameterSetName = 'NameParameterSet')]
        [string]$SubscriptionName,

        [Parameter(Mandatory = $false,
            Position = 1,
            ParameterSetName = 'IDParameterSet')]
        [string]$SubscriptionID
    )
    Begin{
        ## Get the name of this function
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

        #build log name
        [string]$FileName = 'Profile_' + ${CmdletName} + '_' + (get-date -Format MM-dd-yyyy) + '.log'
        Start-Transcript -Path $env:TEMP\$FileName -Force -Append | Out-Null

        if (-not $PSBoundParameters.ContainsKey('Verbose')) {
            $VerbosePreference = $PSCmdlet.SessionState.PSVariable.GetValue('VerbosePreference')
        }

        #overwrite global variable if specified
        if ($PSBoundParameters.ContainsKey('TenantID')) {
            $global:MyTenantID = $TenantID
        }

        if ($PSBoundParameters.ContainsKey('SubscriptionID')) {
            $global:MySubscriptionID = $SubscriptionID
        }

        if ($PSBoundParameters.ContainsKey('SubscriptionName')) {
            $global:MySubscriptionName = $SubscriptionName
        }

        Try{
            #grab current AZ resources
            $Context = Get-AzContext -ErrorAction Stop
            $DefaultRG = Get-AzDefault -ErrorAction Stop
            #if default is not set, attempt to set it
            If($DefaultRG)
            {
                $DefaultRG = Set-AzDefault
            }
        }
        Catch{
            Write-host ("Failed to get Azure context. {0}" -f $_.Exception.Message) -ForegroundColor yellow
            Clear-AzDefault -ErrorAction SilentlyContinue -Force
            Clear-AzContext -ErrorAction SilentlyContinue -Force
            Disconnect-AzAccount -ErrorAction SilentlyContinue
        }

        If($VerbosePreference){Write-Host ''}
    }
    Process{
        If($VerbosePreference){Write-Host ("Attempting to connect to Azure...") -ForegroundColor Yellow -NoNewline}
        #region connect to Azure if not already connected
        Try{
            If(($null -eq $Context.Subscription.SubscriptionId) -or ($null -eq $Context.Subscription.Name))
            {
                If($global:MyTenantID){
                    $AzAccount = Connect-AzAccount -Tenant $global:MyTenantID -ErrorAction Stop
                }Else{
                    $AzAccount = Connect-AzAccount -ErrorAction Stop
                }

                $AzSubscription += Get-AzSubscription -WarningAction SilentlyContinue | Out-GridView -PassThru -Title "Select a valid Azure Subscription" | Select-AzSubscription -WarningAction SilentlyContinue
                Set-AzContext -Tenant $AzSubscription.Subscription.TenantId -Subscription $AzSubscription.Subscription.id | Out-Null
                If($VerbosePreference){Write-Host ("Successfully connected to Azure!") -ForegroundColor Green}
            }
            Else{
                If($VerbosePreference){Write-Host ("Already connected to Azure using account [{0}] and subscription [{1}]" -f $Context.Account.Id,$Context.Subscription.Name) -ForegroundColor Green}
            }
        }
        Catch{
            If($VerbosePreference){Write-Host ("Unable to connect to Azure account with credentials: {0}. Error: {1}" -f $AzAccount.Context.Account.Id, $_.Exception.Message) -ForegroundColor Red}
            Break
        }
        Finally{
            #To suppress these warning messages
            Write-Verbose ("Suppressing Azure Powershell change warnings...")
            Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

            #set the global values if connection
            If($AzSubscription){
                $global:MySubscriptionName = $AzSubscription.Subscription.Name;
                $global:MySubscriptionID = $AzSubscription.Subscription.Id;
                $global:MyTenantID = $AzSubscription.Subscription.TenantId;
            }
        }
    }
    End{
        #once logged in, set defaults context
        Get-AzContext
        Stop-Transcript | Out-Null
    }

}


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
