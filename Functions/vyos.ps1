Function Test-CommandExists{
    Param ($command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'stop'
    try {if(Get-Command $command){RETURN $true}}
    Catch {Write-Host "$command does not exist"; RETURN $false}
    Finally {$ErrorActionPreference=$oldPreference}
}

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

    	Write-Host "INFO: Checking $env:USERPROFILE/.ssh/id_rsa exists" -ForegroundColor Cyan
    	if (-not(Test-Path -Path "./.ssh/id_rsa") -or $PSBoundParameters.ContainsKey('Force') )
    	{
    		if (-not(Test-Path -Path "./.ssh"))
    		{
    			[void](New-Item -Path "./" -Name .ssh -ItemType Directory -Force)
    			Write-Host "INFO: Created $env:USERPROFILE\.ssh directory" -ForegroundColor Cyan
    		}
            #this would only run if the file was found and forced to remove
            If(Test-Path -Path "./.ssh/id_rsa")
            {
                #remove both id_rsa and id_rsa.pub file
                Remove-Item "./.ssh/id_rsa*" -Force -ErrorAction SilentlyContinue | Out-Null
            }
            #option -y outputs to variable
            $sshrsakey = ssh-keygen.exe -y -t rsa -b 4096 -N '""' -f "./.ssh/id_rsa"
    		Write-Host "INFO: Generated $env:USERPROFILE\.ssh\id_rsa file" -ForegroundColor Cyan

            #TEST Get-Content "./.ssh/known_hosts" | Where-Object {$_ -match $DestinationIP}
            If(Test-Path "./.ssh/known_hosts"){
                $KnownHostContent = Get-Content "./.ssh/known_hosts"
        		#Get-Content "./.ssh/known_hosts" | Where-Object {$_ -notmatch $DestinationIP} | Set-Content "./.ssh/known_hosts" -Force
                $KnownHostContent | ForEach-Object {
                    $_ | Where-Object {$_ -notmatch $DestinationIP}
                } | Out-File "./.ssh/known_hosts" -Encoding utf8
            }

            #TEST Get-content "$env:USERPROFILE/.ssh/id_rsa"
    		$id_rsa_Location = "./.ssh/id_rsa"
    	    $remoteSSHServerLogin = "$User@$DestinationIP"


    		Write-Host "INFO: Copying $env:USERPROFILE\.ssh\id_rsa.pub to $DestinationIP..." -NoNewLine
    		start-sleep 5
    		Write-Host "If prompted, please type $User password`n" -ForegroundColor Cyan
        	scp -o 'StrictHostKeyChecking no' "$id_rsa_Location.pub" "${remoteSSHServerLogin}:~/tmp.pub"
        	Write-Host "INFO: Updating authorized_keys on $DestinationIP..." -NoNewLine
    		start-sleep 5
    		Write-Host "If prompted, please type $User password again`n" -ForegroundColor Cyan
        	ssh $remoteSSHServerLogin "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat ~/tmp.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f ~/tmp.pub"
    	}
    	else
    	{
    		Write-Host "INFO: $env:USERPROFILE\.ssh\id_rsa already exist, skipping..." -ForegroundColor Cyan
    	}

    	Write-Host "DONE: Try running command: 'ssh $User@$DestinationIP'; Now it will not prompt for password" -ForegroundColor Green
    }
    End{
        Set-Location -Path $oldLocation
    }
}

function ConvertTo-LinuxLineEndings($path) {
    $oldBytes = [io.file]::ReadAllBytes($path)
    if (!$oldBytes.Length) {
        return;
    }
    [byte[]]$newBytes = @()
    [byte[]]::Resize([ref]$newBytes, $oldBytes.Length)
    $newLength = 0
    for ($i = 0; $i -lt $oldBytes.Length - 1; $i++) {
        if (($oldBytes[$i] -eq [byte][char]"`r") -and ($oldBytes[$i + 1] -eq [byte][char]"`n")) {
            continue;
        }
        $newBytes[$newLength++] = $oldBytes[$i]
    }
    $newBytes[$newLength++] = $oldBytes[$oldBytes.Length - 1]
    [byte[]]::Resize([ref]$newBytes, $newLength)
    [io.file]::WriteAllBytes($path, $newBytes)
}

Function New-VyattaScript{
    Param (
        $Value,
        [string]$ExportPath,
        [switch]$SetReboot,
        [switch]$AsObject
    )
    If(!$ExportPath){
        $ExportPath = "$env:temp\vyos.script"
    }
    #build script for router
    #https://docs.vyos.io/en/crux/automation/command-scripting.html
    '#!/bin/vbash' | Set-Content $ExportPath
    'source /opt/vyatta/etc/functions/script-template' | Add-Content $ExportPath
    '' | Add-Content $ExportPath
    $Value -split '\n' | %{If($_ -notmatch '^#' -and $_.length -gt 1){$_ | Add-Content $ExportPath}}

    'exit' | Add-Content $ExportPath
    #'run show int' | Add-Content $ExportPath
    If($SetReboot){
        '' | Add-Content $ExportPath
        'run reboot now' | Add-Content $ExportPath
    }
    #get-content $ExportPath

    ConvertTo-LinuxLineEndings $ExportPath

    If($AsObject){
        $VyattaData = "" | Select Value,Path
        $VyattaData.Value = $Value
        $VyattaData.Path = $ExportPath
        return $VyattaData
    }
}

Function Initialize-VyattaScript {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateScript({Test-IPAddress $_})]
        [string]$IP,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Path,
        [switch]$Execute
    )

    #copy script to vyos router
    $remoteSSHServerLogin = "vyos@$IP"

    If(Test-Path $Path)
    {
        Write-Verbose "Transferring file $Path to $IP as ~/tmp.sh"
        scp -o 'StrictHostKeyChecking no' $Path "${remoteSSHServerLogin}:~/tmp.sh"
        #scp -o 'StrictHostKeyChecking no' "${remoteSSHServerLogin}:~/.scripts/test.sh" "$env:temp\test.bh"
        If($PSBoundParameters.ContainsKey('Execute'))
        {
            $scriptfile = 'intconfigure.sh'
            Write-Verbose "Executing file 'tmp.sh' as $scriptfile on $IP"
            #build bash command
            $bashCommands = @(
                'mkdir -p ~/.scripts'
                'chmod 700 ~/.scripts'
                "rm -f ~/.scripts/$scriptfile"
                "cat ~/tmp.sh >> ~/.scripts/$scriptfile"
                'rm -f ~/tmp.sh'
                "sed -i -e 's/\r$//' ~/.scripts/$scriptfile"
                "chmod u+x ~/.scripts/$scriptfile"
                "sg vyattacfg -c ~/.scripts/$scriptfile"
            )
            #join all commands as single line separated with &&
            $bashCommand = $bashCommands -join ' && '
            ssh $remoteSSHServerLogin $bashCommand
        }
    }
    Else{
        Throw "Unable to find file: $Path"
    }

}
