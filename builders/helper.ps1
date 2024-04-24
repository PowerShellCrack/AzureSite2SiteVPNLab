[CmdletBinding()]
Param(
    [string]$JSONConfig,
    [switch]$NoAzureCheck,
    [switch]$NoVyosISOCheck

)

#TEST $JSONConfig = '\\192.168.1.142\Development\Github\PowerShellCrack\AzureSite2SiteVPNLab\config.json'
$Config = ConvertFrom-Json (Get-Content $JSONConfig -Raw)


##*=============================================
##* Runtime Function - REQUIRED
##*=============================================


#region FUNCTION: Check if running in ISE
Function Test-IsISE {
    # try catch accounts for:
    # Set-StrictMode -Version latest
    try {
        return ($null -ne $psISE);
    }
    catch {
        return $false;
    }
}
#endregion

#region FUNCTION: Check if running in Visual Studio Code
Function Test-VSCode{
    if($env:TERM_PROGRAM -eq 'vscode') {
        return $true;
    }
    Else{
        return $false;
    }
}
#endregion
##*========================================================================
##* BUILD PATHS
##*========================================================================
If(Test-IsISE){
    Write-Host "===============================" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "      CONTINUE AT OWN RISK     " -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "===============================" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "You are currently running this script using PowerShell ISE.`nThere are known issues with the interface during vyos configurations" -ForegroundColor Yellow
    $ISEResponse = Read-host "Would you still like to continue? [Y or N]"
    If ($ISEResponse -eq 'N'){
        Break
    }
}

[string]$ResourceRoot = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]
[string]$FunctionPath = Join-Path -Path $ResourceRoot -ChildPath 'Functions'

#region library custom functions
. "$FunctionPath\library.ps1"
. "$FunctionPath\vyos.ps1"
. "$FunctionPath\network.ps1"
. "$FunctionPath\hyperv.ps1"
. "$FunctionPath\azure.ps1"
#endregion

Write-Host "Done." -ForegroundColor Green

#check if SSH and SCP exist for automation mode to work
If(-Not(Test-Command ssh) -and -Not(Test-Command scp) -and -Not(Test-Command ssh-keygen) )
{
    Write-Host ("SSH, SCP, SSH-KEYGEN commands not found. Disabling Automation mode {0} " -f $_.exception.message) -ForegroundColor Red
    $Config.RouterConfigs.AutomationMode = $False
}

#Build a log folder for transactions
New-Item "$ResourceRoot\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Home network Public IP
$PublicIP = Get-MyPublicIP
If($Config.PublicIP -ne $PublicIP){
    do {
        $Config.PublicIP = Read-host "Unable to retrieve public IP. What is your public IP?"
    } until ( $Config.PublicIP -as [System.Net.IPAddress])
}


#============================================
# HYPER-V CHECK
#============================================

If($Config.HyperVConfigs.HyperVVMLocation -match 'default')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $Config.HyperVConfigs.HyperVVMLocation = Get-VMHost | Select -ExpandProperty VirtualMachinePath
    }
    Else{
        $Config.HyperVConfigs.HyperVVMLocation = 'C:\ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines\'
    }
}

If($Config.HyperVConfigs.HyperVHDxLocation -match 'default')
{
    If( (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled' ){
        $Config.HyperVConfigs.HyperVHDxLocation = Get-VMHost | Select -ExpandProperty VirtualHardDiskPath
    }
    Else{
        $Config.HyperVConfigs.HyperVHDxLocation = 'C:\Users\Public\Documents\Hyper-V\Virtual hard disks\'
    }
}
#============================================
# VYOS ISO CHECK
#============================================
#build the path to iso in scripts root dir
[string]$IsosPath = Join-Path -Path $ResourceRoot -ChildPath 'isos'
$vyosIsoSizeMb = 230

If(!$NoVyosISOCheck){
    If($Config.VyosIsoPath -match 'latest'){
        [uri]$vyossource = 'https://downloads.vyos.io/rolling/current/amd64/vyos-rolling-latest.iso'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
        #Assume if set to latest, force download (no prompt)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    ElseIf( ($Config.VyosIsoPath -match 'default') -and (Test-Path "$IsosPath\vyos-1.1.8-amd64.iso") ){
        $destination = "$IsosPath\vyos-1.1.8-amd64.iso"
    }
    ElseIf([string]::IsNullOrEmpty($Config.VyosIsoPath) -or ($Config.VyosIsoPath -match 'default') ){
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        [uri]$vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
        $VyOSResponse = 'Y'
        $destination = "$Env:temp\$vyosfilename"
    }
    Else{
        #$vyossource = 'https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso'
        [uri]$vyossource = 'https://master.dl.sourceforge.net/project/vyos-firewall/vyos-1.1.8-amd64.iso?viasf=1'
        $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)

        # Destination to save the file
        If(Test-Path $Config.VyosIsoPath -ErrorAction SilentlyContinue){
            $destination = $Config.VyosIsoPath
        }
        ElseIf(Test-Path "$Env:USERPROFILE\downloads" -ErrorAction SilentlyContinue){
            $destination = "$Env:USERPROFILE\downloads\$vyosfilename"
        }
        Else{
            $destination = "$Env:temp\$vyosfilename"
        }
    }

    If( !(Test-Path $destination) )
    {
        If($Null -eq $VyOSResponse){
            Write-host ("No iso found in [{0}]" -f $destination) -ForegroundColor Red
            $VyOSResponse = Read-host "Would you like to attempt to download the VyOS router ISO? [Y or N]"
        }

        If($VyOSResponse -eq 'Y')
        {
            $vyosfilename = (Split-Path $vyossource.AbsolutePath -Leaf)
            Write-host ("Attempting to download [{0}] from [{1}].`nThis can take awhile..." -f $vyosfilename,$vyossource) -ForegroundColor Yellow -NoNewline
            #Download the file
            Try{
                Invoke-WebRequest -Uri $vyossource -OutFile $destination -ErrorAction Stop
                Write-Host "Done" -ForegroundColor Green
            }
            Catch{
                Write-host ('Unable to download [{0}]: {1}' -f $vyosfilename,$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
                break
            }
            Finally{
                $Config.VyosIsoPath = $destination
            }
        }
        Else{
            Write-host ("You must download the VyOS iso from [{0}] before continuing!" -f $vyossource) -ForegroundColor Black -BackgroundColor Red
            break
        }
    }
    ElseIf( ($runningsize = (Get-Item $destination).length/1MB) -lt $vyosIsoSizeMb){
        Write-host ("The downloaded VyOS iso is smaller [{0}Mb] than [{1}Mb]. Please rerun script again..." -f $runningsize,$vyosIsoSizeMb) -BackgroundColor Red
        Remove-Item $destination -Confirm -Force | Out-null
        break
    }
    Else{
        $Config.VyosIsoPath = $destination
    }
}

