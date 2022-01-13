
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
		$WorkingDirectory,
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
        If($WorkingDirectory){$pinfo.WorkingDirectory = $WorkingDirectory}
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
