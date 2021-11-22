
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

Function Get-NetworkDetails{
    Param (
        [Parameter(Mandatory=$true,ParameterSetName="Cidr")]
        [ValidatePattern('^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(3[0-2]|[1-2][0-9]|[0-9]))$')]
        [string]$CidrAddress,

        [Parameter(Mandatory=$true,ParameterSetName="Subnet")]
        [Parameter(Mandatory=$true,ParameterSetName = "Prefix")]
        [ValidateScript({Test-IPAddress $_})]
        [string]$IPAddress,

        [Parameter(Mandatory=$true,ParameterSetName="Subnet")]
        [ValidateScript({Test-IPv4MaskString $_})]
        [string]$SubnetMask,

        [Parameter(Mandatory=$true,ParameterSetName="Prefix")]
        [ValidateRange(16,30)]
        [int]$Prefix
    )

    If($PSCmdlet.ParameterSetName -eq 'Cidr'){
        $IPAddress=$CidrAddress.split('/')[0]
        $CIDR = $CidrAddress.split('/')[1]
        $SubnetMask = ConvertTo-IPv4MaskString -MaskBits $CIDR
        $BinarySubnetMask = (ConvertTo-IPv4MaskBinary $SubnetMask).replace(".", "")
	    $BinaryNetworkAddressSection = $BinarySubnetMask.replace("1", "")
    }

    If($PSCmdlet.ParameterSetName -eq 'SubnetMask'){
        $BinarySubnetMask = (ConvertTo-IPv4MaskBinary $SubnetMask).replace(".", "")
	    $BinaryNetworkAddressSection = $BinarySubnetMask.replace("1", "")
        $CIDR = ConvertTo-IPv4MaskBits $SubnetMask
    }

    If($PSCmdlet.ParameterSetName -eq 'Prefix'){
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

    #grab network ID (end in 0)
    $ip = [ipaddress]$IPAddress
    $subnet = [ipaddress]$SubnetMask
    $netid = [ipaddress]($ip.address -band $subnet.address)

    #build NetworkInfo object
    $NetworkInfo = New-Object -TypeName PSObject
    Add-Member -InputObject $NetworkInfo -MemberType NoteProperty -Name NetworkID -Value $netid.IPAddressToString
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

Function Get-TypicalRouterRange {
    param (
    [Parameter(Mandatory=$true,Position=0)]
    [ValidateScript({Test-IPAddress $_})]
    [string]$StartIP,
    [Parameter(Mandatory=$true,Position=1)]
    [ValidateScript({Test-IPAddress $_})]
    [string]$EndIP,
    [Parameter(Mandatory=$true,Position=2)]
    [string]$Gateway,
    [Parameter(Mandatory=$true,Position=3)]
    [ValidateSet('Front','Last')]
    [string]$Position
    )

    If(Test-SameSubnet -ip1 $StartIP -ip2 $EndIP -mask $Gateway){

        switch($Position){
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


Function Get-SimpleSubnets {
    param (
        [string]$Cidr,
        [int]$Count = 255,

        [ValidateSet('Front','Last')]
        [string]$Position
    )
    $OctetArray = @()
    <#TESTS
    $Network = Get-NetworkDetails -IPAddress 120.10.10.1 -Prefix 30
    Get-TypicalRouterRange -StartIP $Network.IPAddress -EndIP $Network.EndingIP
    #>
    $Network = Get-NetworkDetails -Cidr $Cidr
    $OctetArray = $Network.SubnetMask.Split('.')
    $OctetStartPos = [array]::LastIndexOf($OctetArray,'255') + 1
    $NetworkArray = $Network.NetworkID.Split('.')
    #If there is an non 255 octet after last 255 and its is the 4 octet, there can only be one subnet
    If($OctetStartPos -eq 3){
        return $Network.NetworkID
    }
    Else{
        $a = 0
        $Subnets = @()
        Do{
            $a++
            #test [int]$NetworkArray[$OctetStartPos] = 254
            $done = $false
            #store the octet in a new variable to use later
            $StartNetID = $NetworkArray

            #increment the current octet until 255
            If([int]$NetworkArray[$OctetStartPos] -le 254){
                [int]$NetworkArray[$OctetStartPos] +=1
            }
            #As each octet is incremented; make sure it does not increment the 4 octet
            ElseIf( ([int]$OctetStartPos + 1) -eq 3){
                $done = $true
            }
            #continue to next network id octet
            Else{
                #reset octet array back to original, increment the octet position, the start next subnet
                $NetworkArray = $StartNetID
                $OctetStartPos = $OctetStartPos + 1
                [int]$NetworkArray[$OctetStartPos] += 1
            }

            $Subnets += (($NetworkArray -join '.') + '/24')

        } Until ($a -eq $Count -or $done)

        Switch($Position){
            'First'{Return $Subnets[0]}
            'Last' {Return $Subnets[-1]}
            default {Return $Subnets}
        }
    }
}


Function Get-NextAddress {
    param (
        [Parameter(Mandatory=$true,ParameterSetName="Cidr")]
        [string]$Cidr,
        [Parameter(Mandatory=$true,ParameterSetName="Address")]
        [string]$IP,
        [ValidateRange(2,4)]
        [int]$FromOctet
    )

    If($PSCmdlet.ParameterSetName -eq 'Cidr'){
        $IP=$Cidr.split('/')[0]
    }

    $a = [System.Net.IpAddress]::Parse($IP) ## turn the string to IP address
    $z = $a.GetAddressBytes() ## and then to an array of bytes
    if ($z[$FromOctet-1] -eq 255) ## last octet full
    {
        $z[$FromOctet-1] = 0 ## so reset

        if ($z[$FromOctet-2] -eq 255) ## third octet full
        {
            $z[$FromOctet-2] = 0 ## so reset
            $z[$FromOctet-3] += 1 ## increment second octet
        }
        else
        {
            $z[$FromOctet-2] += 1 ##  increment third octect
        }
    }
    else
    {
        $z[$FromOctet-1] += 1 ## increment last octet
    }

    $c = [System.Net.IpAddress]($z) ## recreate IP address
    return $c.ToString()
}
