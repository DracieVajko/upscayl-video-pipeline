# Upscayl Video Pipeline V2 - paths module.
# File, path, key/value and formatting helpers.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Generic file and path helpers

function Read-TextUtf8 {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        try {
            [IO.File]::Replace($temporary, $Path, $null)
        } catch {
            Move-Item -LiteralPath $temporary -Destination $Path -Force
        }
    } else {
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
}

function Read-KvFile {
    param([string]$Path)
    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    $text = Read-TextUtf8 $Path
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        $index = $line.IndexOf('=')
        if ($index -lt 0) { continue }
        $key = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        $values[$key] = $value
    }
    return $values
}

function Write-KvFile {
    param([string]$Path, $Data)
    $lines = @()
    foreach ($key in $Data.Keys) {
        $lines += ([string]$key + '=' + [string]$Data[$key])
    }
    $text = ($lines -join "`n")
    if ($lines.Count -gt 0) { $text += "`n" }
    Write-TextAtomic $Path $text
}

function Expand-HomePath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return (Join-Path $HOME $Path.Substring(2))
    }
    return $Path
}

function Resolve-AbsolutePath {
    param([string]$Path, [string]$Base = $null)
    $value = Expand-HomePath $Path
    if (-not [IO.Path]::IsPathRooted($value)) {
        if (-not $Base) { $Base = (Get-Location).Path }
        $value = Join-Path $Base $value
    }
    return [IO.Path]::GetFullPath($value)
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    try {
        return ([IO.Path]::GetFullPath($Left) -eq [IO.Path]::GetFullPath($Right))
    } catch {
        return $false
    }
}

function Test-WithinPath {
    param([string]$Path, [string]$Root)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $rootResolved = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($resolved -eq $rootResolved) { return $true }
    return $resolved.StartsWith($rootResolved + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Ensure-WithinPath {
    param([string]$Path, [string]$Root)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-WithinPath $resolved $Root)) {
        throw [PipelineException]::new("Path is outside the allowed root: $resolved (root: $Root)", $null, 4)
    }
    return $resolved
}

function Get-FreeBytes {
    param([string]$Path)
    $candidate = $Path
    while (-not (Test-Path -LiteralPath $candidate)) {
        $parent = Split-Path -Parent $candidate
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    try {
        $full = [IO.Path]::GetFullPath($candidate)
        $root = [IO.Path]::GetPathRoot($full)
        $drive = New-Object System.IO.DriveInfo($root)
        return [int64]$drive.AvailableFreeSpace
    } catch {
        return [int64]0
    }
}

function Format-Bytes {
    param([int64]$Size)
    $value = [double][math]::Max([int64]0, $Size)
    if ($value -lt 1024) { return ([int64]$value).ToString() + ' B' }
    $units = @('KiB', 'MiB', 'GiB', 'TiB', 'PiB')
    foreach ($unit in $units) {
        $value = $value / 1024.0
        if ($value -lt 1024 -or $unit -eq $units[$units.Count - 1]) {
            $rounded = [math]::Round($value, 1, [MidpointRounding]::ToEven)
            return $rounded.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $unit
        }
    }
    return $value.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' PiB'
}

function Format-Duration {
    param([double]$Seconds)
    $totalMs = [int64][math]::Round([math]::Max(0.0, $Seconds) * 1000.0, [MidpointRounding]::ToEven)
    $hours = [math]::Floor($totalMs / 3600000)
    $remainder = $totalMs % 3600000
    $minutes = [math]::Floor($remainder / 60000)
    $remainder = $remainder % 60000
    $whole = [math]::Floor($remainder / 1000)
    $millis = $remainder % 1000
    return ('{0:00}:{1:00}:{2:00}.{3:000}' -f $hours, $minutes, $whole, $millis)
}

function Round-HalfEven {
    param([double]$Value)
    return [int64][math]::Round($Value, [MidpointRounding]::ToEven)
}

function Parse-TimeValue {
    param([string]$Value)
    $raw = ([string]$Value).Trim()
    if (-not $raw) { throw [PipelineException]::new('Time value is empty', $null, 4) }
    if ($raw.StartsWith('-')) {
        throw [PipelineException]::new("Time value must not be negative: $Value", $null, 4)
    }
    $parts = $raw.Split(':')
    if ($parts.Count -gt 3) {
        throw [PipelineException]::new("Invalid time value: $Value", $null, 4)
    }
    $numbers = @()
    foreach ($part in $parts) {
        if (-not $part) { throw [PipelineException]::new("Invalid time value: $Value", $null, 4) }
        $number = 0.0
        if (-not [double]::TryParse($part, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            throw [PipelineException]::new("Invalid time value: $Value", $null, 4)
        }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
            throw [PipelineException]::new("Invalid time value: $Value", $null, 4)
        }
        $numbers += $number
    }
    if ($numbers.Count -eq 1) { return $numbers[0] }
    for ($i = 1; $i -lt $numbers.Count; $i++) {
        if ($numbers[$i] -ge 60) {
            throw [PipelineException]::new("Minutes and seconds must be below 60: $Value", $null, 4)
        }
    }
    if ($numbers.Count -eq 2) { return $numbers[0] * 60 + $numbers[1] }
    return $numbers[0] * 3600 + $numbers[1] * 60 + $numbers[2]
}

function Sanitize-JobId {
    param([string]$Stem)
    $value = ([string]$Stem).Trim()
    $value = [regex]::Replace($value, '[<>:"/\\|?*\x00-\x1f]', '_')
    $value = [regex]::Replace($value, '\s+', '_')
    $value = [regex]::Replace($value, '_+', '_')
    $value = $value.Trim(' ', '.', '_')
    if (-not $value) { return 'video' }
    if ($value.Length -gt 80) { $value = $value.Substring(0, 80) }
    $value = $value.Trim(' ', '.', '_')
    if (-not $value) { return 'video' }
    if ($value -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
        return $value.Substring(0, [math]::Min(79, $value.Length)) + '_'
    }
    return $value
}

function Get-NormalizedFps {
    param([string]$Average, [string]$Real)
    $candidate = @($Average, $Real)
    foreach ($value in $candidate) {
        if (-not $value) { continue }
        $match = [regex]::Match([string]$value, '^(\d+)/(\d+)$')
        if (-not $match.Success) { continue }
        $numerator = [int64]$match.Groups[1].Value
        $denominator = [int64]$match.Groups[2].Value
        if ($numerator -le 0 -or $denominator -le 0) { continue }
        $a = $numerator
        $b = $denominator
        while ($b -ne 0) {
            $temp = $b
            $b = $a % $b
            $a = $temp
        }
        $gcd = $a
        $numerator = $numerator / $gcd
        $denominator = $denominator / $gcd
        $decimal = [double]$numerator / [double]$denominator
        return [pscustomobject]@{
            Num      = [int64]$numerator
            Den      = [int64]$denominator
            Rational = ([string]$numerator + '/' + [string]$denominator)
            Decimal  = $decimal
            Text     = $decimal.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return [pscustomobject]@{
        Num      = [int64]30
        Den      = [int64]1
        Rational = '30/1'
        Decimal  = 30.0
        Text     = '30.000'
    }
}
