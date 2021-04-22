Function Extract-String {
    Param(
        [Parameter(Mandatory=$true)][string]$string
        , [Parameter(Mandatory=$true)][char]$character
        , [Parameter(Mandatory=$false)][ValidateSet("Right","Left")][string]$range
        , [Parameter(Mandatory=$false)][int]$afternumber
        , [Parameter(Mandatory=$false)][int]$tonumber
    )
    Process
    {
        [string]$return = ""

        if ($range -eq "Right")
        {
            $return = $string.Split("$character")[($string.Length - $string.Replace("$character","").Length)].Trim()
        }
        elseif ($range -eq "Left")
        {
            $return = $string.Split("$character")[0].Trim()
        }
        elseif ($tonumber -ne 0)
        {
            for ($i = $afternumber; $i -le ($afternumber + $tonumber); $i++)
            {
                $return += $string.Split("$character")[$i].Trim()
            }
        }
        else
        {
            $return = $string.Split("$character")[$afternumber].Trim()
        }

        return $return
    }
}

$configs = Get-Content -Raw -Path C:\users\ritracyi\Downloads\edgerouter1.json
$line = [System.IO.File]::ReadLines("C:\users\ritracyi\Downloads\edgerouter1.json")

foreach($line in [System.IO.File]::ReadLines("C:\users\ritracyi\Downloads\edgerouter12linetest.json"))
{
    if($line -match ".*\{$"){
        $startcommand = $line.Replace("{","").Trim()
    }
    
    if($line -match "[^\s-].*\{$"){
        $nextpart = $line.Replace("{").Trim()
    }

    If($startcommand){
        If($startcommand -notlike "*$line*"){
        Write-Host $startcommand + $line -NoNewline
        }
    }
}


foreach ($line in [System.IO.File]::ReadLines("C:\users\ritracyi\Downloads\edgerouter1.json")) {
    $fields = $line.Split("`t")
    $fields.Count | Out-Host
    $fields
}