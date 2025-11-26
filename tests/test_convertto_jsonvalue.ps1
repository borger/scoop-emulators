function ConvertTo-JsonValue {
    param(
        [object]$Value,
        [int]$Indent = 0
    )

    $indentStr = ' ' * $Indent

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [string]) {
        $escaped = $Value.Replace('\\', '\\\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return "`"$escaped`""
    }

    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $Value.ToString() }

    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return '[]' }
        $items = $Value | ForEach-Object { "$indentStr  $(ConvertTo-JsonValue -Value $_ -Indent ($Indent + 2))" }
        $joined = $items -join ",`n"
        return '[' + "`n" + $joined + "`n" + $indentStr + ']'
    }

    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $subItems = @()
        foreach ($k in $Value.Keys) {
            $v = $Value[$k]
            $jsonVal = ConvertTo-JsonValue -Value $v -Indent ($Indent + 2)
            $subItems += "$indentStr  `"$k`": $jsonVal"
        }
        return "{`n$($subItems -join ",`n")`n$indentStr}"
    }

    return "`"$Value`""
}

# Tests
Write-Host 'Test-ConvertTo-JsonValue: Basic types and round-trip via ConvertFrom-Json'

#$null
$r = ConvertFrom-Json (ConvertTo-JsonValue -Value $null)
Write-Host 'Null round-trip:' ($null -eq $r)

# String with quotes and backslash
$orig = 'Line1"WithQuote\\Backslash'
$parsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $orig)
Write-Host 'String round-trip:' ($orig -eq $parsed)

# Number
$num = 12345
$numParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $num)
Write-Host 'Integer round-trip:' ($num -eq $numParsed)

# Float
$f = 3.14159
$fParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $f)
Write-Host 'Float round-trip:' ([math]::Round($fParsed, 5) -eq [math]::Round($f, 5))

# Boolean
$b = $true
$bParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $b)
Write-Host 'Boolean round-trip:' ($b -eq $bParsed)

# Empty array
$arr = @()
$arrParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $arr)
Write-Host 'Empty array round-trip (count):' ($arrParsed.Count -eq 0)

# Nested arrays
$nested = @(@(1, 2), @(3, 4))
$nestedParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $nested)
Write-Host 'Nested arrays round-trip:' ($nested[0][1] -eq $nestedParsed[0][1] -and $nested[1][0] -eq $nestedParsed[1][0])

# Empty hashtable
$ht = @{}
$htParsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $ht)
Write-Host 'Empty hashtable round-trip is object:' ($htParsed -is [System.Management.Automation.PSCustomObject])

# Simple hashtable
$ht2 = @{ a = 1; b = 'x"y' }
$ht2Parsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $ht2)
Write-Host 'Hashtable keys present:' (($ht2Parsed.PSObject.Properties.Name -join ',') -match 'a' -and ($ht2Parsed.PSObject.Properties.Name -join ',') -match 'b')

# Indentation should not change parsed result
$s = @('a', 'b', 'c')
$p1 = ConvertFrom-Json (ConvertTo-JsonValue -Value $s -Indent 0)
$p2 = ConvertFrom-Json (ConvertTo-JsonValue -Value $s -Indent 10)
Write-Host 'Indentation invariant for arrays:' (($p1 -join ',') -eq ($p2 -join ','))
