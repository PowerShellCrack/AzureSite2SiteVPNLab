

Function New-SSHSharedKey{
	<#
    .SYNOPSIS
    Generate Pre-shared key for SSH authentication

    .DESCRIPTION
    Generate Pre-shared key for SSH authentication to the remote device

    .PARAMETER IP
    Mandatory. Must specify SSH IP

    .PARAMETER User
    Specify user for ssh; defaults to root

    .PARAMETER Force
    Overwrite current ssh key

    .EXAMPLE
    New-SSHSharedKey -IP $VyOSExternalIP -User 'vyos' -Force

    .LINK
    http://vcloud-lab.com/entries/devops/How-to-Setup-Passwordless-SSH-Login-on-Windows
    https://slowkow.com/notes/ssh-tutorial/
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
        [ValidateScript({Test-IPAddress $_})]
		[string]$IP,
		[string]$User = 'root',
		[switch]$Force
	)

    Begin{
        $oldLocation = Get-Location
    	Set-Location -Path $env:USERPROFILE

        $exeNotExists = @()
        If(!(Test-Command ssh-keygen)){$exeNotExists += 'ssh-keygen'}
        If(!(Test-Command ssh)){$exeNotExists += 'ssh'}
        If(!(Test-Command scp)){$exeNotExists += 'scp'}

        If($exeNotExists.count -eq 1){
            Write-Error ("{0} does not exist on host, install Git to use executable" -f $exeNotExists[0])
            return $false
        }
        ElseIf($exeNotExists.count -gt 1){
            Write-Error ("{0} do not exist on host, install Git to use executables" -f ($exeNotExists -join ','))
            return $false
        }
        Else{
            Write-Verbose ("Generating Pre-shared key for SSH authentication")
            Write-Host ("You may be prompted a few times to login to {0}..." -f $IP) -ForegroundColor Gray
        }
    }
    Process{

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
            #ssh-keygen.exe -t rsa -b 4096 -N "" -f ./.ssh/id_rsa
            $sshrsakey = Start-ExeProcess ssh-keygen.exe -Arguments '-t rsa -b 4096 -N "" -f ./.ssh/id_rsa' -PassThru -Wait
            If($sshrsakey.ExitCode -eq 0){Write-Host "INFO: Generated $env:USERPROFILE\.ssh\id_rsa file" -ForegroundColor Cyan;}
            Else{Return $sshrsakey.ExitCode}

            #TEST Get-Content "./.ssh/known_hosts" | Where-Object {$_ -match $IP}
            If(Test-Path "./.ssh/known_hosts"){
                $KnownHostContent = Get-Content "./.ssh/known_hosts"
        		#Get-Content "./.ssh/known_hosts" | Where-Object {$_ -notmatch $IP} | Set-Content "./.ssh/known_hosts" -Force
                $KnownHostContent | ForEach-Object {
                    $_ | Where-Object {$_ -notmatch $IP}
                } | Out-File "./.ssh/known_hosts" -Encoding utf8
            }

            #TEST Get-content "$env:USERPROFILE/.ssh/id_rsa"
    		$id_rsa_Location = "./.ssh/id_rsa"
    	    #TEST $remoteSSHServerLogin = "vyos@$IP"
    	    $remoteSSHServerLogin = "$User@$IP"
            If(Test-Path "$env:USERPROFILE\.ssh\id_rsa.pub"){
                Write-Host "INFO: Copying $env:USERPROFILE\.ssh\id_rsa.pub to $IP..." -NoNewLine
                start-sleep 5
                Write-Host "When prompted, please type $User password..." -ForegroundColor Cyan
                #Start-ExeProcess scp -Arguments "-o StrictHostKeyChecking no '$id_rsa_Location.pub' '${remoteSSHServerLogin}:~/tmp.pub'" -PassThru -Wait
                Write-Verbose "scp -o 'StrictHostKeyChecking no' `"$id_rsa_Location.pub`" `"${remoteSSHServerLogin}:~/tmp.pub`""
                scp -o 'StrictHostKeyChecking no' "$id_rsa_Location.pub" "${remoteSSHServerLogin}:~/tmp.pub"
                Write-Host "INFO: Updating authorized_keys on $IP..." -NoNewLine
                start-sleep 5
                Write-Verbose "ssh `"${remoteSSHServerLogin}`" `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat ~/tmp.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f ~/tmp.pub`""
                ssh "${remoteSSHServerLogin}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat ~/tmp.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f ~/tmp.pub"
                #TEST & scp -o 'StrictHostKeyChecking no' -i ./.ssh/id_rsa "$id_rsa_Location.pub" "${remoteSSHServerLogin}:~/tmp.pub"
            }
    	}
    	else
    	{
    		Write-Host "INFO: $env:USERPROFILE\.ssh\id_rsa already exist, reading rsa key..." -ForegroundColor Cyan
    		#$sshrsakey = Start-ExeProcess ssh-keygen.exe -Arguments '-t rsa -b 4096 -N "" -y -f ./.ssh/id_rsa' -PassThru -Wait
    		#If($sshrsakey.ExitCode -ne 0){Return $sshrsakey.ExitCode}Else{$sshrsakey.stdout}
            If($sshrsakey.ExitCode -ne 0){Return $sshrsakey.ExitCode}
    	}

    	#Write-Host "DONE: Try running command: 'ssh $User@$IP'; Now it will not prompt for password" -ForegroundColor Green
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
    [CmdletBinding(
		SupportsShouldProcess=$True,
		ConfirmImpact='Medium',
		HelpURI='http://vcloud-lab.com',
		DefaultParameterSetName='Manual'
	)]
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

Function Invoke-VyattaScript {
    [CmdletBinding(
		SupportsShouldProcess=$True,
		ConfirmImpact='Medium',
		HelpURI='http://vcloud-lab.com',
		DefaultParameterSetName='Manual'
	)]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateScript({Test-IPAddress $_})]
        [string]$IP,
        [string]$RSAFile = "$env:USERPROFILE\.ssh\id_rsa",
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Path
    )

    #copy script to vyos router
    $remoteSSHServerLogin = "vyos@$IP"

    $exeNotExists = @()
    If(!(Test-Command ssh)){$exeNotExists += 'ssh'}
    If(!(Test-Command scp)){$exeNotExists += 'scp'}

    If($exeNotExists.count -eq 1){
        Write-Error ("{0} does not exist on host, install Git to use executable" -f $exeNotExists[0])
        return $false
    }
    ElseIf($exeNotExists.count -gt 1){
        Write-Error ("{0} do not exist on host, install Git to use executables" -f ($exeNotExists -join ','))
        return $false
    }
    Else{
        Write-Verbose ("Executables exist on host. Attempting to run script...")
    }

    If((Test-Path $Path) -and (Test-Connection $IP -Count 1))
    {
        Write-Verbose "Transferring file $Path to $IP as ~/tmp.sh"
        If(Test-Path $RSAFile){
            scp -o 'StrictHostKeyChecking no' -i $RSAFile $Path "${remoteSSHServerLogin}:~/tmp.sh"
        }Else{
            scp -o 'StrictHostKeyChecking no' $Path "${remoteSSHServerLogin}:~/tmp.sh"
        }

        #TEST scp -o 'StrictHostKeyChecking no' "${remoteSSHServerLogin}:~/.scripts/test.sh" "$env:temp\test.bh"
        $randomchar = -join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})
        $scriptfile = "vyos_" + $randomchar.ToLower() + ".sh"
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
        If(Test-Path $RSAFile){
            Write-Verbose "ssh -i `"$RSAFile`" `"$remoteSSHServerLogin`" $bashCommand"
            #VERBOSE & ssh -v -i $RSAFile $remoteSSHServerLogin $bashCommand
            ssh -i "$RSAFile" "$remoteSSHServerLogin" $bashCommand
        }Else{
            Write-Verbose "ssh `"$remoteSSHServerLogin`" $bashCommand"
            ssh "$remoteSSHServerLogin" $bashCommand
        }
    }
    Else{
        Throw "Unable to find file: $Path"
    }

}

Function Invoke-VyattaCmd {
    [CmdletBinding(
		SupportsShouldProcess=$True,
		ConfirmImpact='Medium',
		HelpURI='http://vcloud-lab.com',
		DefaultParameterSetName='Manual'
	)]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateScript({Test-IPAddress $_})]
        [string]$IP,
        [string]$RSAFile = "$env:USERPROFILE\.ssh\id_rsa",
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeline=$true)]
        [string]$Cmd
    )
    Begin{
        #copy script to vyos router
        $remoteSSHServerLogin = "vyos@$IP"

        $exeNotExists = @()
        If(!(Test-Command ssh)){$exeNotExists += 'ssh'}

        If($exeNotExists.count -eq 1){
            Write-Error ("{0} does not exist on host, install Git to use executable" -f $exeNotExists[0])
            return $false
        }
        ElseIf($exeNotExists.count -gt 1){
            Write-Error ("{0} do not exist on host, install Git to use executables" -f ($exeNotExists -join ','))
            return $false
        }
        Else{
            Write-Verbose ("Executables exist on host. Attempting to run command...")
        }

    }
    Process{

        If(Test-Path $RSAFile){
            Write-Verbose "RUNNING COMMAND: ssh `"${remoteSSHServerLogin}`" `"$Cmd`""
            ssh "${remoteSSHServerLogin}" "$Cmd"
        }
        Else{
            Write-Verbose "RUNNING COMMAND: ssh -i `"$RSAFile`" `"${remoteSSHServerLogin}`" `"$Cmd`""
            ssh -i "$RSAFile" "${remoteSSHServerLogin}" "$Cmd"
        }
    }
    End{

    }

}
