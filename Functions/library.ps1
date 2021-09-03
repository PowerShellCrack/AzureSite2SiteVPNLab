
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
        [string]$SubscriptionID ,

        [Parameter(Mandatory = $false,
            Position = 2)]
        [string]$ResourceGroupName,

        [switch]$ClearAll
    )
    Begin{
        ## Get the name of this function
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

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

        #overwrite global resource group is parameter is called
        if ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $global:MyResourceGroup = $ResourceGroupName
        }

        If($ClearAll){
            Write-host ("There was an issue signing into Azure. Resetting and attempting again...") -ForegroundColor yellow
            Clear-AzDefault -ErrorAction SilentlyContinue -Force
            Clear-AzContext -ErrorAction SilentlyContinue -Force
            Disconnect-AzAccount -ErrorAction SilentlyContinue
        }
        Else{
            Try{
                #grab current AZ resources
                $Context = Get-AzContext -ErrorAction Stop
                #if defualt is not set, attempt to set it
                If($null -eq (Get-AzDefault) )
                {
                    $DefaultRG = Set-AzDefault -ResourceGroupName $global:MyResourceGroup -Force
                }Else{
                    $DefaultRG = Get-AzDefault -ErrorAction Stop
                }
            }Catch{
                Write-host ("Failed to get Azure context. {0}" -f $_.Exception.Message) -ForegroundColor yellow
            }
        }

        $MySubscriptions = @()
        $MyRGs = @()

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
                Write-Host "You must select an Azure Subscription"
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
        }
    }
    End{
        #once logged in, set defaults context
        Get-AzContext
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

Function Test-IPAddress ($strIP)
{
	# ensure we have a valid IP address
    Try{
        [IPAddress]$IP = $strIP;
        $bValidIP = $true
    }
    Catch{
        $bValidIP = $false
    }
	Return $bValidIP
}

Function ConvertTo-Binary ($strDecimal)
{
	$strBinary = [Convert]::ToString($strDecimal, 2)
	if ($strBinary.length -lt 8)
	{
		while ($strBinary.length -lt 8)
		{
			$strBinary = "0"+$strBinary
		}
	}
	Return $strBinary
}

Function ConvertTo-IPv4Binary ($strIP)
{
	$strBinaryIP = $null
	if (Test-IPAddress $strIP)
	{
		$arrSections = @()
		$arrSections += $strIP.split(".")
		foreach ($section in $arrSections)
		{
			if ($strBinaryIP -ne $null)
			{
				$strBinaryIP = $strBinaryIP+"."
			}
				$strBinaryIP = $strBinaryIP+(ConvertTo-Binary $section)
		}
	}
	Return $strBinaryIP
}

Function ConvertTo-IPv4MaskBinary ($strSubnetMask)
{
		$strBinarySubnetMask = $null
	if (Test-IPv4MaskString $strSubnetMask)
	{
		$arrSections = @()
		$arrSections += $strSubnetMask.split(".")
		foreach ($section in $arrSections)
		{
			if ($strBinarySubnetMask -ne $null)
			{
				$strBinarySubnetMask = $strBinarySubnetMask+"."
			}
				$strBinarySubnetMask = $strBinarySubnetMask+(ConvertTo-Binary $section)
		}
	}
	Return $strBinarySubnetMask
}

Function ConvertFrom-IPv4Binary ($BinaryIP)
{
	$FirstSection = [Convert]::ToInt64(($BinaryIP.substring(0, 8)),2)
	$SecondSection = [Convert]::ToInt64(($BinaryIP.substring(8,8)),2)
	$ThirdSection = [Convert]::ToInt64(($BinaryIP.substring(16,8)),2)
	$FourthSection = [Convert]::ToInt64(($BinaryIP.substring(24,8)),2)
	$strIP = "$FirstSection`.$SecondSection`.$ThirdSection`.$FourthSection"
	Return $strIP
}

Function ConvertTo-IPv4MaskString {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 32)]
    [Int] $MaskBits
  )
  $mask = ([Math]::Pow(2, $MaskBits) - 1) * [Math]::Pow(2, (32 - $MaskBits))
  $bytes = [BitConverter]::GetBytes([UInt32] $mask)
  (($bytes.Count - 1)..0 | ForEach-Object { [String] $bytes[$_] }) -join "."
}

Function Test-IPv4MaskString {
  param(
    [Parameter(Mandatory = $true)]
    [String] $MaskString
  )
  $validBytes = '0|128|192|224|240|248|252|254|255'
  $MaskString -match `
    ('^((({0})\.0\.0\.0)|'      -f $validBytes) +
    ('(255\.({0})\.0\.0)|'      -f $validBytes) +
    ('(255\.255\.({0})\.0)|'    -f $validBytes) +
    ('(255\.255\.255\.({0})))$' -f $validBytes)
}

Function ConvertTo-IPv4MaskBits {
  param(
    [parameter(Mandatory = $true)]
    [ValidateScript({Test-IPv4MaskString $_})]
    [String] $MaskString
  )
  $mask = ([IPAddress] $MaskString).Address
  for ( $bitCount = 0; $mask -ne 0; $bitCount++ ) {
    $mask = $mask -band ($mask - 1)
  }
  $bitCount
}

Function Get-NetworkStartEndAddress{
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateScript({Test-IPAddress $_})]
        [string]$IPAddress,
        [Parameter(Mandatory=$true,ParameterSetName="Subnet")]
        [ValidateScript({Test-IPv4MaskString $_})]
        [string]$SubnetMask,
        [Parameter(Mandatory=$true,ParameterSetName="Prefix")]
        [ValidateRange(16,30)]
        [int]$Prefix
    )

    If($PSBoundParameters.ContainsKey('SubnetMask')){
        $BinarySubnetMask = (ConvertTo-IPv4MaskBinary $SubnetMask).replace(".", "")
	    $BinaryNetworkAddressSection = $BinarySubnetMask.replace("1", "")
        $CIDR = ConvertTo-IPv4MaskBits $SubnetMask
    }

    If($PSBoundParameters.ContainsKey('Prefix')){
        $CIDR = $Prefix
        $SubnetMask = ConvertTo-IPv4MaskString -MaskBits $Prefix
        $BinarySubnetMask = (ConvertTo-IPv4MaskBinary $SubnetMask).replace(".", "")
	    $BinaryNetworkAddressSection = $BinarySubnetMask.replace("1", "")
    }

    $BinaryNetworkAddressLength = $BinaryNetworkAddressSection.length
	$iAddressPool = $iAddressWidth -2
	$BinaryIP = (ConvertTo-IPv4Binary $IPAddress).Replace(".", "")
	$BinaryIPNetworkSection = $BinaryIP.substring(0, $CIDR)
	$BinaryIPAddressSection = $BinaryIP.substring($CIDR, $BinaryNetworkAddressLength)

	#Starting IP
	$FirstAddress = $BinaryNetworkAddressSection -replace "0$", "1"
	$strFirstIP = ConvertFrom-IPv4Binary ($BinaryIPNetworkSection + $FirstAddress)

	#End IP
	$LastAddress = ($BinaryNetworkAddressSection -replace "0", "1") -replace "1$", "0"
	$strLastIP = ConvertFrom-IPv4Binary ($BinaryIPNetworkSection + $LastAddress)

    #build NetworkInfo object
    $NetworkInfo = New-Object -TypeName PSObject
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name IPAddress -Value $IPAddress
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name StartingIP -Value $strFirstIP
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name EndingIP -Value $strLastIP
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name Prefix -Value $CIDR

    return $NetworkInfo
}

#http://get-powershell.com/post/2010/01/29/Determining-if-IP-addresses-are-on-the-same-subnet.aspx
Function Test-SameSubnet {
    param (
    [parameter(Mandatory=$true,Position=0)]
    [Net.IPAddress]
    $ip1,

    [parameter(Mandatory=$true,Position=1)]
    [Net.IPAddress]
    $ip2,

    [parameter(Mandatory=$false,Position=2)]
    [alias("SubnetMask")]
    [Net.IPAddress]
    $mask ="255.255.255.0"
    )

    if (($ip1.address -band $mask.address) -eq ($ip2.address -band $mask.address)) {$true}
    else {$false}

}

Function Get-TypicalIPRange {
    param (
    [Parameter(Mandatory=$true,Position=0)]
    [ValidateScript({Test-IPAddress $_})]
    [string]$StartIP,
    [Parameter(Mandatory=$true,Position=1)]
    [ValidateScript({Test-IPAddress $_})]
    [string]$EndIP,
    [Parameter(Mandatory=$true,Position=2)]
    [ValidateSet('Front','Last')]
    [string]$Gateway 
    )

    If(Test-SameSubnet $StartIP $EndIP){

        switch($Gateway){
         'Front' {
            $Ip2 = $StartIP.Split('.')
            If($ip2[-1] -eq 0){
                #for gateway add 1
                $Ip2[-1] = [int]$Ip2[-1] + 1
                $GatewayIP = $ip2 -join '.'

                #for start add another (2)
                $Ip2[-1] = [int]$Ip2[-1] + 1
                $NewStartIP = $Ip2 -join '.'
            }
            Else{
                #for start IP; add 1
                $Ip2[-1] = [int]$Ip2[-1] + 1
                $NewStartIP = $Ip2 -join '.'

                #use given IP as gatway
                $GatewayIP = $StartIP
            }
            $NewEndIP =$EndIP

         }

         'Last'  {
            #subject 1 from last IP octet
            $Ip2 = $EndIP.Split('.')
            $Ip2[-1] = [int]$Ip2[-1]-1
            $NewEndIP = $Ip2 -join '.'
            $GatewayIP = $EndIP
            $NewStartIP = $StartIP
            }

        }

        #build NetworkInfo object
        $GatewayInfo = New-Object -TypeName PSObject
        Add-Member -InputObject $GatewayInfo -MemberType NoteProperty -Name GatewayIP -Value $GatewayIP
        Add-Member -InputObject $GatewayInfo -MemberType NoteProperty -Name StartIP -Value $NewStartIP
        Add-Member -InputObject $GatewayInfo -MemberType NoteProperty -Name EndIP -Value $NewEndIP 
    }
    return $GatewayInfo

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

#region clean all old variables
Function Clear-NonBultinVariables{
    #Invoke a new instance of PowerShell, get the built-in variables, then remove everything else that doesn't belong.
    $ps = [PowerShell]::Create()
    $ps.AddScript('Get-Variable | Select-Object -ExpandProperty Name') | Out-Null
    $builtIn = $ps.Invoke()
    $ps.Dispose()
    $builtIn += "profile","psISE","psUnsupportedConsoleApplications" # keep some ISE-specific stuff
    Remove-Variable (Get-Variable | Select-Object -ExpandProperty Name | Where-Object {$builtIn -NotContains $_}) -ErrorAction SilentlyContinue
}
#endregion

#region clean all old variables
Function Remove-OutdatedModules{
    param (
        [Parameter(Mandatory=$false,Position=0,ValueFromPipeline=$true)]
        [string[]]$module
    )
    Begin{
        If($PSBoundParameters.ContainsKey('module')){
            $Param = @{
                Name = $module
                AllVersions = $true
            }
            $mods = Get-InstalledModule @Param
        }
        Else{
            $mods = Get-InstalledModule
        }
        Write-Host "Found $($mod.count) installed modules"
    }
    Process{
        foreach ($mod in $mods){
            Write-Host ("Checking {0}..." -f $mod.name) -NoNewline
            $latest = Get-InstalledModule $mod.name
            $specificmods = Get-InstalledModule $mod.name -AllVersions
            Write-Host ("{0} versions of this module found" -f ($specificmods.version).count)

            foreach ($sm in $specificmods)
            {
                if ($sm.version -ne $latest.version)
	            {
	                write-host ("Uninstalling {0} - {1} [latest is {2}]..." -f $sm.name,$sm.version,$latest.version) -NoNewline
	                $sm | Uninstall-Module -force
	                Write-Host "Done"
	            }

            }
        }
    }

}
#endregion

Function New-SSHSharedKey{
	<#
    .SYNOPSIS
    Generate Pre-shared key for SSH authentication

    .DESCRIPTION
    Generate Pre-shared key for SSH authentication to the remote device

    .PARAMETER DestinationIP
    Mandatory. Must specify destination IP

    .PARAMETER User
    Specify user for ssh; defaults to root

    .PARAMETER Force
    Overwrite current ssh key

    .EXAMPLE
    New-SSHSharedKey -DestinationIP $VyOSExternalIP -User 'vyos' -Force

    .LINK
    http://vcloud-lab.com/entries/devops/How-to-Setup-Passwordless-SSH-Login-on-Windows
    #>
	[CmdletBinding(
		SupportsShouldProcess=$True,
		ConfirmImpact='Medium',
		HelpURI='http://vcloud-lab.com',
		DefaultParameterSetName='Manual'
	)]

	param
	(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
		[string]$DestinationIP,
		[string]$User = 'root',
		[switch]$Force
	)

    Begin{
        $oldLocation = Get-Location
    	Set-Location -Path $env:USERPROFILE

        try{Start-Process ssh -ErrorAction Stop -PassThru -Wait -WindowStyle Hidden | Out-Null;$SSHinstalled =$true}Catch{$SSHinstalled =$false}
        try{Start-Process scp -ErrorAction Stop -PassThru -Wait -WindowStyle Hidden | Out-Null;$SCPinstalled =$true}Catch{$SCPinstalled =$false}
    }
    Process{
        If($SSHinstalled -and $SCPinstalled){
            Write-Host ("START: Generating Pre-shared key for SSH authentication with no password") -ForegroundColor Green
            Write-Host ("INFO: You will be prompted a few times to login to {0}..." -f $DestinationIP) -ForegroundColor Gray
        }Else{
            Write-Host ("ERROR: SSH or SCP does not exist on host, install Git to use SSH") -ForegroundColor Red
            return
        }

    	Write-Host 'INFO: Checking <yourprofile>/.ssh/id_rsa exists' -ForegroundColor Cyan
    	if (-not(Test-Path -Path "./.ssh/id_rsa") -or $PSBoundParameters.ContainsKey('Force') )
    	{
    		if (-not(Test-Path -Path "./.ssh"))
    		{
    			[void](New-Item -Path "./" -Name .ssh -ItemType Directory -Force)
    			Write-Host 'INFO: Created <yourprofile>/.ssh directory' -ForegroundColor Cyan
    		}

            #this would only run if the file was found and forced to remove
    		If(Test-Path -Path "./.ssh/id_rsa")
    		{
                #remove both id_rsa and id_rsa.pub file
                Remove-Item "./.ssh/id_rsa*" -Force -ErrorAction SilentlyContinue | Out-Null
            }
            ssh-keygen.exe -t rsa -b 4096 -N '""' -f "./.ssh/id_rsa"
    		Write-Host 'INFO: Generated  <yourprofile>/.ssh/id_rsa file' -ForegroundColor Cyan
    	}
    	else
    	{
    		Write-Host 'INFO: <yourprofile>/.ssh/id_rsa already exist, skipping...' -ForegroundColor Cyan
    	}

    	$id_rsa_Location = "$env:USERPROFILE/.ssh/id_rsa"
    	$remoteSSHServerLogin = "$User@$DestinationIP"

    	Write-Host "INFO: Copying <yourprofile>/.ssh/id_rsa.pub to $DestinationIP, Type password`n" -ForegroundColor Cyan
    	scp -o 'StrictHostKeyChecking no' "$id_rsa_Location.pub" "${remoteSSHServerLogin}:~/tmp.pub"
    	Write-Host "INFO: Updating authorized_keys on $DestinationIP, Type password`n" -ForegroundColor Cyan
    	ssh "$remoteSSHServerLogin" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat ~/tmp.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f ~/tmp.pub"

    	Write-Host "`nDONE: Try running command: 'ssh $User@$DestinationIP'; Now it will not prompt for password" -ForegroundColor Green
    }
    End{
        Set-Location -Path $oldLocation
    }
}