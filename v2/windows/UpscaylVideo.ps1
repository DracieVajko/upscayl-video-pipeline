#requires -Version 5.1
<#
.SYNOPSIS
    Upscayl Video Pipeline V2 - native Windows implementation.

.DESCRIPTION
    No Python, Node, or jq. Uses FFmpeg/ffprobe and Upscayl's own CLI.
    Reads and writes the same job.txt/config.txt contract as V1.
#>

$ErrorActionPreference = 'Stop'
$script:V2Version = '0.3.0'
$script:ProgramName = 'upscayl-video'
$script:ToolDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:LogFile = $null
$script:Verbose = $false
$script:Quiet = $false

class PipelineException : System.Exception {
    [int]$ExitCode
    [string]$Hint

    PipelineException([string]$Message, [string]$HintText, [int]$Code) : base($Message) {
        $this.Hint = $HintText
        $this.ExitCode = $Code
    }

    [string] ToString() {
        if ($this.Hint) {
            return $this.Message + [Environment]::NewLine + 'Hint: ' + $this.Hint
        }
        return $this.Message
    }
}

#region Logging and process helpers

function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Set-LogFile {
    param([string]$Path)
    if (-not $Path) {
        $script:LogFile = $null
        return
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $script:LogFile = $Path
}

function Write-LogFileLine {
    param([string]$Level, [string]$Message)
    if (-not $script:LogFile) { return }
    $line = (Get-Timestamp) + ' [' + $Level + '] ' + $Message + [Environment]::NewLine
    [IO.File]::AppendAllText($script:LogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Info {
    param([string]$Message)
    if ($script:Quiet) {
        Write-LogFileLine 'INFO' $Message
        return
    }
    Write-LogFileLine 'INFO' $Message
    [Console]::Out.WriteLine($Message)
}

function Write-Warn {
    param([string]$Message)
    if ($script:Quiet) {
        Write-LogFileLine 'WARN' $Message
        return
    }
    Write-LogFileLine 'WARN' $Message
    [Console]::Error.WriteLine($Message)
}

function Write-Err {
    param([string]$Message)
    Write-LogFileLine 'ERROR' $Message
    [Console]::Error.WriteLine($Message)
}

function Write-DebugLog {
    param([string]$Message)
    if ($script:Verbose) {
        Write-LogFileLine 'DEBUG' $Message
        [Console]::Out.WriteLine($Message)
    } else {
        Write-LogFileLine 'DEBUG' $Message
    }
}

function Quote-DisplayArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -match '[\s"'']') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Quote-CommandLineArg {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($char)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Child {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment = $null,
        [string]$WorkingDirectory = $null,
        [switch]$NoCheck
    )

    $display = ($Arguments | ForEach-Object { Quote-DisplayArg $_ }) -join ' '
    $extra = ''
    if ($WorkingDirectory) { $extra += '  (cwd=' + $WorkingDirectory + ')' }
    if ($Environment) {
        $pairs = @()
        foreach ($key in ($Environment.Keys | Sort-Object)) {
            $pairs += ($key + '=' + $Environment[$key])
        }
        $extra += '  (env ' + ($pairs -join ' ') + ')'
    }
    Write-DebugLog ('$ ' + $display + $extra)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Arguments[0]
    $argList = @()
    for ($i = 1; $i -lt $Arguments.Count; $i++) {
        $argList += (Quote-CommandLineArg $Arguments[$i])
    }
    $startInfo.Arguments = ($argList -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    $result = [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
    if (-not $NoCheck -and $exitCode -ne 0) {
        $tail = Get-TextTail ($stderr + $stdout) 50
        $message = 'Command failed with exit code ' + $exitCode + ': ' + $display
        if ($tail) { $message += [Environment]::NewLine + $tail }
        throw [PipelineException]::new($message, $null, 1)
    }
    return $result
}

function Get-TextTail {
    param([string]$Text, [int]$Lines = 50)
    if (-not $Text) { return '' }
    $all = $Text -split "`r?`n"
    if ($all.Count -le $Lines) { return $Text.TrimEnd() }
    return (($all[($all.Count - $Lines)..($all.Count - 1)]) -join [Environment]::NewLine).TrimEnd()
}

function Get-PipelineException {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex -is [PipelineException]) { return $ex }
        if ($ex.InnerException) { $ex = $ex.InnerException } else { break }
    }
    return $ErrorRecord.Exception
}

#endregion

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

function Get-FileMtime {
    param([string]$Path)
    try {
        return [int64]([DateTimeOffset](Get-Item -LiteralPath $Path).LastWriteTimeUtc).ToUnixTimeSeconds()
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

#endregion

#region Configuration

function Get-DefaultConfigValues {
    return [ordered]@{
        ffmpeg          = 'ffmpeg'
        ffprobe         = 'ffprobe'
        upscayl_bin     = 'auto'
        models_dir      = 'auto'
        work_dir        = 'work'
        default_model   = 'upscayl-standard-4x'
        default_scale   = '2'
        default_preset  = 'mp4-h264'
        default_encoder = 'auto'
        default_audio   = 'auto'
        default_subs    = 'auto'
        tile            = 'auto'
        batch_size      = '100'
        gpu             = '0'
        icd             = 'auto'
        max_work_gb     = '40'
        min_free_gb     = '5'
        cleanup         = '0'
    }
}

function Test-PathLike {
    param([string]$Value)
    if (-not $Value) { return $false }
    $expanded = Expand-HomePath $Value
    if ([IO.Path]::IsPathRooted($expanded)) { return $true }
    if ($Value.Contains('/') -or $Value.Contains('\')) { return $true }
    if ($Value -match '^[A-Za-z]:') { return $true }
    return $false
}

function Resolve-ToolPath {
    param(
        [string]$Value,
        [string[]]$Names,
        [string[]]$SearchDirs
    )
    $raw = ([string]$Value).Trim()
    $searched = @()

    if ($raw -and (Test-PathLike $raw)) {
        $candidate = Expand-HomePath $raw
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path (Get-Location).Path $candidate }
        $candidate = [IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            foreach ($name in $Names) {
                $path = Join-Path $candidate $name
                $searched += $path
                if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
            }
            throw [PipelineException]::new("Executable not found in directory: $candidate", ('Searched: ' + ($searched -join ', ')), 3)
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
        $searched += $candidate
        throw [PipelineException]::new("Executable does not exist: $candidate", ('Searched: ' + ($searched -join ', ')), 3)
    }

    if ($raw) {
        $found = Get-Command $raw -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found -and $found.Source) { return [IO.Path]::GetFullPath($found.Source) }
        $searched += $raw
    }
    foreach ($directory in $SearchDirs) {
        foreach ($name in $Names) {
            $path = Join-Path $directory $name
            $searched += $path
            if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
        }
    }
    foreach ($name in $Names) {
        $found = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found -and $found.Source) { return [IO.Path]::GetFullPath($found.Source) }
    }
    $label = if ($raw) { $raw } elseif ($Names.Count -gt 0) { $Names[0] } else { 'unknown' }
    throw [PipelineException]::new("Executable not found: $label", ('Searched: ' + ($searched -join ', ')), 3)
}

function ConvertTo-IntValue {
    param([string]$Value, [string]$Key)
    $result = 0
    if (-not [int]::TryParse(([string]$Value).Trim(), [ref]$result)) {
        throw [PipelineException]::new("Invalid integer for $Key`: '$Value'", $null, 4)
    }
    return $result
}

function ConvertTo-BoolValue {
    param([string]$Value, [string]$Key)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if (@('1', 'true', 'yes', 'on') -contains $text) { return $true }
    if (@('0', 'false', 'no', 'off', '') -contains $text) { return $false }
    throw [PipelineException]::new("Invalid boolean for $Key`: '$Value'", $null, 4)
}

function Get-Config {
    param(
        [string]$ConfigPath = $null,
        [hashtable]$Overrides = $null,
        [string]$ToolDir = $null
    )

    if (-not $ToolDir) { $ToolDir = $script:ToolDir }
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $ToolDir 'config.txt'
    } else {
        $ConfigPath = Resolve-AbsolutePath $ConfigPath
    }
    $configDir = Split-Path -Parent $ConfigPath
    if (-not $configDir) { $configDir = (Get-Location).Path }

    $defaults = Get-DefaultConfigValues
    $merged = [ordered]@{}
    foreach ($key in $defaults.Keys) { $merged[$key] = $defaults[$key] }
    $fileValues = Read-KvFile $ConfigPath
    foreach ($key in $fileValues.Keys) {
        if ($merged.Contains($key)) { $merged[$key] = $fileValues[$key] }
    }
    $overrideKeys = @{}
    if ($Overrides) {
        foreach ($key in $Overrides.Keys) {
            $overrideKeys[$key] = $true
            if ($merged.Contains($key) -and $null -ne $Overrides[$key]) {
                $merged[$key] = [string]$Overrides[$key]
            }
        }
    }

    $searchDirs = @($ToolDir, (Split-Path -Parent $ToolDir), 'C:\ffmpeg\bin', 'C:\Program Files\ffmpeg\bin')
    $names = @('ffmpeg.exe', 'ffmpeg')
    $probeNames = @('ffprobe.exe', 'ffprobe')

    $ffmpegValue = $merged['ffmpeg'].Trim()
    if (-not $overrideKeys.ContainsKey('ffmpeg') -and $ffmpegValue -and (Test-PathLike $ffmpegValue) -and -not [IO.Path]::IsPathRooted((Expand-HomePath $ffmpegValue))) {
        $ffmpegValue = Join-Path $configDir $ffmpegValue
    }
    $ffprobeValue = $merged['ffprobe'].Trim()
    if (-not $overrideKeys.ContainsKey('ffprobe') -and $ffprobeValue -and (Test-PathLike $ffprobeValue) -and -not [IO.Path]::IsPathRooted((Expand-HomePath $ffprobeValue))) {
        $ffprobeValue = Join-Path $configDir $ffprobeValue
    }

    $ffmpeg = Resolve-ToolPath -Value $ffmpegValue -Names $names -SearchDirs $searchDirs
    $ffprobe = Resolve-ToolPath -Value $ffprobeValue -Names $probeNames -SearchDirs $searchDirs

    function Get-OptionalPath {
        param([string]$Key)
        $value = $merged[$Key].Trim()
        if (-not $value -or $value.ToLowerInvariant() -eq 'auto') { return $null }
        $origin = if ($overrideKeys.ContainsKey($Key)) { (Get-Location).Path } else { $configDir }
        $path = Expand-HomePath $value
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $origin $path }
        return [IO.Path]::GetFullPath($path)
    }

    $workOrigin = if ($overrideKeys.ContainsKey('work_dir')) { (Get-Location).Path } else { $configDir }
    $workDir = Expand-HomePath $merged['work_dir']
    if (-not [IO.Path]::IsPathRooted($workDir)) { $workDir = Join-Path $workOrigin $workDir }
    $workDir = [IO.Path]::GetFullPath($workDir)

    $defaultScale = ConvertTo-IntValue $merged['default_scale'] 'default_scale'
    if (@(2, 3, 4) -notcontains $defaultScale) {
        throw [PipelineException]::new('default_scale must be 2, 3, or 4', $null, 4)
    }
    $defaultPreset = $merged['default_preset'].Trim()
    if (@('mp4-h264', 'mp4-hevc', 'mkv-hevc', 'mov-prores') -notcontains $defaultPreset) {
        throw [PipelineException]::new('default_preset must be one of mp4-h264, mp4-hevc, mkv-hevc, mov-prores', $null, 4)
    }
    $defaultEncoder = $merged['default_encoder'].Trim()
    if (@('auto', 'nvidia', 'amd', 'cpu') -notcontains $defaultEncoder) {
        throw [PipelineException]::new('default_encoder must be one of auto, nvidia, amd, cpu', $null, 4)
    }
    $defaultAudio = $merged['default_audio'].Trim()
    if (@('auto', 'copy', 'aac', 'pcm', 'none') -notcontains $defaultAudio) {
        throw [PipelineException]::new('default_audio must be one of auto, copy, aac, pcm, none', $null, 4)
    }
    $defaultSubs = $merged['default_subs'].Trim()
    if (@('auto', 'copy', 'convert', 'none') -notcontains $defaultSubs) {
        throw [PipelineException]::new('default_subs must be one of auto, copy, convert, none', $null, 4)
    }
    $tile = $merged['tile'].Trim()
    if (-not $tile) { $tile = 'auto' }
    if ($tile -ne 'auto') {
        $tileValue = ConvertTo-IntValue $tile 'tile'
        if ($tileValue -lt 0) { throw [PipelineException]::new("tile must be 'auto' or a non-negative integer", $null, 4) }
    }
    $batchSize = ConvertTo-IntValue $merged['batch_size'] 'batch_size'
    if ($batchSize -le 0) { throw [PipelineException]::new('batch_size must be greater than zero', $null, 4) }
    $gpu = ConvertTo-IntValue $merged['gpu'] 'gpu'
    if ($gpu -lt 0) { throw [PipelineException]::new('gpu must be non-negative', $null, 4) }
    $maxWorkGb = ConvertTo-IntValue $merged['max_work_gb'] 'max_work_gb'
    if ($maxWorkGb -le 0) { throw [PipelineException]::new('max_work_gb must be greater than zero', $null, 4) }
    $minFreeGb = ConvertTo-IntValue $merged['min_free_gb'] 'min_free_gb'
    if ($minFreeGb -lt 0) { throw [PipelineException]::new('min_free_gb must be non-negative', $null, 4) }

    return @{
        ffmpeg          = $ffmpeg
        ffprobe         = $ffprobe
        upscayl_bin     = (Get-OptionalPath 'upscayl_bin')
        models_dir      = (Get-OptionalPath 'models_dir')
        work_dir        = $workDir
        default_model   = $merged['default_model'].Trim()
        default_scale   = $defaultScale
        default_preset  = $defaultPreset
        default_encoder = $defaultEncoder
        default_audio   = $defaultAudio
        default_subs    = $defaultSubs
        tile            = $tile
        batch_size      = $batchSize
        gpu             = $gpu
        icd             = $(if ($merged['icd'].Trim()) { $merged['icd'].Trim() } else { 'auto' })
        max_work_gb     = $maxWorkGb
        min_free_gb     = $minFreeGb
        cleanup         = (ConvertTo-BoolValue $merged['cleanup'] 'cleanup')
        config_path     = $ConfigPath
        tool_dir        = $ToolDir
    }
}

#endregion

#region Probing

function Get-JsonValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $value = $property.Value
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and $value -eq '') { return $Default }
    return $value
}

function ConvertTo-IntSafe {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-DoubleSafe {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Get-CleanText {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if (-not $text -or $text.ToLowerInvariant() -eq 'unknown') { return $null }
    return $text
}

function Get-RotationValue {
    param($Video)
    $sideData = Get-JsonValue $Video 'side_data_list' $null
    if ($sideData) {
        foreach ($item in @($sideData)) {
            $rotation = Get-JsonValue $item 'rotation' $null
            if ($null -ne $rotation) {
                $value = ConvertTo-IntSafe $rotation 0
                return ((($value % 360) + 360) % 360)
            }
        }
    }
    $tags = Get-JsonValue $Video 'tags' $null
    if ($tags) {
        $rotate = Get-JsonValue $tags 'rotate' $null
        if ($null -ne $rotate) {
            $value = ConvertTo-IntSafe $rotate 0
            return ((($value % 360) + 360) % 360)
        }
    }
    return 0
}

function Get-TagDuration {
    param($Value)
    if (-not $Value) { return $null }
    try { return (Parse-TimeValue ([string]$Value)) } catch { return $null }
}

function ConvertTo-StreamInfo {
    param($Stream)
    $tags = Get-JsonValue $Stream 'tags' $null
    $duration = ConvertTo-DoubleSafe (Get-JsonValue $Stream 'duration' 0.0) 0.0
    if (-not $duration -and $tags) {
        $fromTag = Get-TagDuration (Get-JsonValue $tags 'DURATION' $null)
        if ($null -ne $fromTag) { $duration = $fromTag }
    }
    $language = $null
    $title = $null
    if ($tags) {
        $language = Get-JsonValue $tags 'language' $null
        $title = Get-JsonValue $tags 'title' $null
    }
    $channels = $null
    if ($null -ne (Get-JsonValue $Stream 'channels' $null)) {
        $channels = ConvertTo-IntSafe (Get-JsonValue $Stream 'channels' 0) 0
    }
    $bitRate = $null
    if ($null -ne (Get-JsonValue $Stream 'bit_rate' $null)) {
        $bitRate = ConvertTo-IntSafe (Get-JsonValue $Stream 'bit_rate' 0) 0
    }
    return @{
        index      = (ConvertTo-IntSafe (Get-JsonValue $Stream 'index' 0) 0)
        codec_name = [string](Get-JsonValue $Stream 'codec_name' 'unknown')
        channels   = $channels
        bit_rate   = $bitRate
        language   = $language
        title      = $title
        duration   = $duration
    }
}

function Get-LastVideoEnd {
    param([string]$Ffprobe, [string]$Source, [double]$FormatDuration, $Logger = $null)
    if ($FormatDuration -le 0) { return $null }
    $start = [math]::Max(0.0, $FormatDuration - 2.0)
    $arguments = @(
        $Ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'packet=pts_time,duration_time',
        '-of', 'csv=p=0', '-read_intervals', ($start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + '%+2.0'),
        $Source
    )
    try {
        $result = Invoke-Child -Arguments $arguments -NoCheck
    } catch {
        return $null
    }
    if ($result.ExitCode -ne 0) { return $null }
    $lastEnd = $null
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $parts = $line.Split(',')
        if ($parts.Count -lt 1 -or -not $parts[0].Trim()) { continue }
        $pts = ConvertTo-DoubleSafe $parts[0].Trim() 0.0
        $duration = 0.0
        if ($parts.Count -gt 1) { $duration = ConvertTo-DoubleSafe $parts[1].Trim() 0.0 }
        $end = $pts + $duration
        # Packets are emitted in decode order; track the maximum end, not the
        # last line, so B-frames do not shrink the reported duration.
        if ($null -eq $lastEnd -or $end -gt $lastEnd) { $lastEnd = $end }
    }
    return $lastEnd
}

function Get-MediaInfo {
    param([string]$Ffprobe, [string]$Source, $Logger = $null)

    $arguments = @(
        $Ffprobe, '-v', 'error', '-print_format', 'json',
        '-show_format', '-show_streams', '-show_chapters', '-count_packets', $Source
    )
    try {
        $result = Invoke-Child -Arguments $arguments
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new("ffprobe failed for: $Source", $ex.Message, 4)
    }
    try {
        $data = $result.StdOut | ConvertFrom-Json
    } catch {
        throw [PipelineException]::new("ffprobe returned invalid JSON for: $Source", $_.Exception.Message, 4)
    }

    $video = $null
    foreach ($stream in @($data.streams)) {
        if ($stream.codec_type -eq 'video') { $video = $stream; break }
    }
    if ($null -eq $video) {
        throw [PipelineException]::new("No video stream found in: $Source", $null, 4)
    }

    $fps = Get-NormalizedFps ([string](Get-JsonValue $video 'avg_frame_rate' '')) ([string](Get-JsonValue $video 'r_frame_rate' ''))
    $packetCount = ConvertTo-IntSafe (Get-JsonValue $video 'nb_read_packets' (Get-JsonValue $video 'nb_frames' 0)) 0
    $duration = ConvertTo-DoubleSafe (Get-JsonValue $video 'duration' 0.0) 0.0
    if ($duration -le 0 -and $packetCount -gt 0 -and $fps.Den -gt 0) {
        $duration = ($packetCount * $fps.Den) / $fps.Num
    }
    if ($duration -le 0) {
        $formatInfo = Get-JsonValue $data 'format' $null
        $duration = ConvertTo-DoubleSafe (Get-JsonValue $formatInfo 'duration' 0.0) 0.0
    }

    $width = ConvertTo-IntSafe (Get-JsonValue $video 'width' 0) 0
    $height = ConvertTo-IntSafe (Get-JsonValue $video 'height' 0) 0
    if ($width -le 0 -or $height -le 0) {
        throw [PipelineException]::new("Invalid video dimensions in: $Source", $null, 4)
    }

    $audio = @()
    $subtitles = @()
    foreach ($stream in @($data.streams)) {
        if ($stream.codec_type -eq 'audio') { $audio += (ConvertTo-StreamInfo $stream) }
        if ($stream.codec_type -eq 'subtitle') { $subtitles += (ConvertTo-StreamInfo $stream) }
    }

    $chapters = 0
    if ($null -ne $data.chapters) { $chapters = @($data.chapters).Count }

    $item = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
    $sourceSize = 0
    $sourceMtime = 0
    if ($item) {
        $sourceSize = [int64]$item.Length
        $sourceMtime = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    $colorTrc = Get-CleanText (Get-JsonValue $video 'color_transfer' $null)
    $sampleAspect = Get-CleanText (Get-JsonValue $video 'sample_aspect_ratio' $null)
    $media = @{
        source              = [IO.Path]::GetFullPath($Source)
        duration            = $duration
        fps_num             = $fps.Num
        fps_den             = $fps.Den
        fps_rational        = $fps.Rational
        fps_decimal         = $fps.Decimal
        fps_text            = $fps.Text
        width               = $width
        height              = $height
        pix_fmt             = [string](Get-JsonValue $video 'pix_fmt' 'unknown')
        video_index         = (ConvertTo-IntSafe (Get-JsonValue $video 'index' 0) 0)
        audio               = $audio
        subtitles           = $subtitles
        chapters            = $chapters
        color_primaries     = (Get-CleanText (Get-JsonValue $video 'color_primaries' $null))
        color_trc           = $colorTrc
        colorspace          = (Get-CleanText (Get-JsonValue $video 'color_space' $null))
        color_range         = (Get-CleanText (Get-JsonValue $video 'color_range' $null))
        rotation            = (Get-RotationValue $video)
        hdr                 = (@('smpte2084', 'arib-std-b67') -contains ([string]$colorTrc).ToLowerInvariant())
        source_size         = $sourceSize
        source_mtime        = $sourceMtime
        nb_frames           = $(if ($packetCount -gt 0) { $packetCount } else { $null })
        sample_aspect_ratio = $sampleAspect
    }

    $streamDuration = ConvertTo-DoubleSafe (Get-JsonValue $video 'duration' 0.0) 0.0
    if ($streamDuration -le 0 -and $packetCount -le 0) {
        $formatInfo = Get-JsonValue $data 'format' $null
        $formatDuration = ConvertTo-DoubleSafe (Get-JsonValue $formatInfo 'duration' 0.0) 0.0
        $end = Get-LastVideoEnd -Ffprobe $Ffprobe -Source $Source -FormatDuration $formatDuration -Logger $Logger
        if ($null -ne $end -and $end -gt 0) { $media.duration = $end }
    }
    return $media
}

function Get-FirstFrameDimensions {
    param([string]$Ffprobe, [string]$Path, $Logger = $null)
    $arguments = @(
        $Ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height', '-of', 'csv=p=0', $Path
    )
    try {
        $result = Invoke-Child -Arguments $arguments
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new("Could not read frame dimensions: $Path", $ex.Message, 4)
    }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $parts = $line.Split(',')
        if ($parts.Count -ge 2) {
            $width = 0
            $height = 0
            if ([int]::TryParse($parts[0].Trim(), [ref]$width) -and [int]::TryParse($parts[1].Trim(), [ref]$height)) {
                return @($width, $height)
            }
        }
    }
    throw [PipelineException]::new("Could not parse frame dimensions: $Path", $null, 4)
}

#endregion

#region Jobs

function New-JobData {
    param([string]$JobId, [string]$Source)
    $data = [ordered]@{}
    $data['version'] = '1'
    $data['job_id'] = $JobId
    $data['source'] = $Source
    $data['created'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $data['frame_pattern'] = ''
    $data['upscaled_dir'] = ''
    $data['frame_count'] = '0'
    $data['upscaled_count'] = '0'
    $data['chunk_seconds'] = '0'
    $data['chunk_frames'] = '0'
    $data['preset'] = ''
    $data['encoder'] = ''
    $data['audio'] = ''
    $data['audio_bitrate'] = ''
    $data['all_audio'] = '0'
    $data['subs'] = ''
    $data['ten_bit'] = '0'
    $data['target_height'] = ''
    return $data
}

function Get-JobSourceFromFolder {
    param([string]$Path)
    $sourceFile = Join-Path $Path 'source.txt'
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        $value = (Read-TextUtf8 $sourceFile).Trim()
        if ($value) { return $value }
    }
    $jobFile = Join-Path $Path 'job.txt'
    if (Test-Path -LiteralPath $jobFile -PathType Leaf) {
        $data = Read-KvFile $jobFile
        if ($data.Contains('source')) { return [string]$data['source'] }
    }
    return $null
}

function New-JobObject {
    param([string]$Path, $Data)
    return @{ path = $Path; data = $Data }
}

function Open-Job {
    param([string]$Path)
    $resolved = Resolve-AbsolutePath $Path
    $jobFile = Join-Path $resolved 'job.txt'
    if (-not (Test-Path -LiteralPath $resolved -PathType Container) -or -not (Test-Path -LiteralPath $jobFile -PathType Leaf)) {
        throw [PipelineException]::new("Not a job folder (missing job.txt): $resolved", $null, 4)
    }
    $data = Read-KvFile $jobFile
    if (-not $data.Contains('source') -or -not $data['source']) {
        $fallback = Get-JobSourceFromFolder $resolved
        if ($fallback) { $data['source'] = $fallback }
        else { throw [PipelineException]::new("Job has no source path: $resolved", $null, 4) }
    }
    return (New-JobObject $resolved $data)
}

function Get-JobSourcePath {
    param($Job)
    $value = [string]$Job.data['source']
    if (-not $value) { throw [PipelineException]::new("Job has no source path: $($Job.path)", $null, 4) }
    return (Expand-HomePath $value)
}

function Write-JobSourceFile {
    param($Job)
    $path = [string]$Job.path
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Write-TextAtomic (Join-Path $path 'source.txt') ([IO.Path]::GetFullPath((Get-JobSourcePath $Job)) + "`n")
}

function Save-Job {
    param($Job)
    $Job.data['updated'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Write-KvFile (Join-Path $Job.path 'job.txt') $Job.data
    Write-JobSourceFile $Job
}

function Get-JobValue {
    param($Job, [string]$Key, $Default = $null)
    if ($Job.data.Contains($Key)) {
        $value = $Job.data[$Key]
        if ($null -eq $value) { return $Default }
        return $value
    }
    return $Default
}

function Set-JobValue {
    param($Job, [string]$Key, $Value)
    if ($Value -is [bool]) {
        $Job.data[$Key] = $(if ($Value) { '1' } else { '0' })
    } else {
        $Job.data[$Key] = [string]$Value
    }
}

function Get-JobInt {
    param($Job, [string]$Key, [int]$Default = 0)
    $raw = Get-JobValue $Job $Key $null
    if ($null -eq $raw -or "$raw" -eq '') { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-JobBool {
    param($Job, [string]$Key, [bool]$Default = $false)
    $raw = Get-JobValue $Job $Key $null
    if ($null -eq $raw -or "$raw" -eq '') { return $Default }
    return (@('1', 'true', 'yes', 'on') -contains ([string]$raw).Trim().ToLowerInvariant())
}

function Set-JobMarker {
    param($Job, [string]$Stage)
    $path = Join-Path $Job.path ('.done_' + $Stage)
    [IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding($false)))
}

function Test-JobMarker {
    param($Job, [string]$Stage)
    return (Test-Path -LiteralPath (Join-Path $Job.path ('.done_' + $Stage)) -PathType Leaf)
}

function Clear-JobMarker {
    param($Job, [string]$Stage)
    $path = Join-Path $Job.path ('.done_' + $Stage)
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Update-JobFromMedia {
    param($Job, $Media)
    Set-JobValue $Job 'source' ([IO.Path]::GetFullPath($Media.source))
    Set-JobValue $Job 'source_size' $Media.source_size
    Set-JobValue $Job 'source_mtime' $Media.source_mtime
    Set-JobValue $Job 'source_duration' $Media.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $Job 'duration' $Media.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $Job 'fps' $Media.fps_rational
    Set-JobValue $Job 'fps_decimal' $Media.fps_text
    Set-JobValue $Job 'width' $Media.width
    Set-JobValue $Job 'height' $Media.height
    Set-JobValue $Job 'pix_fmt' $Media.pix_fmt
    Set-JobValue $Job 'color_primaries' $(if ($Media.color_primaries) { $Media.color_primaries } else { 'unknown' })
    Set-JobValue $Job 'color_trc' $(if ($Media.color_trc) { $Media.color_trc } else { 'unknown' })
    Set-JobValue $Job 'colorspace' $(if ($Media.colorspace) { $Media.colorspace } else { 'unknown' })
    Set-JobValue $Job 'color_range' $(if ($Media.color_range) { $Media.color_range } else { 'unknown' })
    Set-JobValue $Job 'rotation' $Media.rotation
    Set-JobValue $Job 'hdr' $Media.hdr
}

function Find-OrCreateJob {
    param(
        [string]$WorkDir,
        [string]$Source,
        $Logger = $null,
        [switch]$NoCreate
    )
    $workDirPath = [IO.Path]::GetFullPath($WorkDir)
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $baseId = Sanitize-JobId ([IO.Path]::GetFileNameWithoutExtension($sourcePath))
    if (-not $NoCreate) {
        if (-not (Test-Path -LiteralPath $workDirPath)) { New-Item -ItemType Directory -Path $workDirPath -Force | Out-Null }
    }

    $candidate = Join-Path $workDirPath $baseId
    $suffix = 2
    while (Test-Path -LiteralPath $candidate) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $existingSource = Get-JobSourceFromFolder $candidate
            $same = $false
            if ($existingSource) {
                try { $same = (Test-SamePath $existingSource $sourcePath) } catch { $same = $false }
            }
            if ($same) {
                $jobFile = Join-Path $candidate 'job.txt'
                if (Test-Path -LiteralPath $jobFile -PathType Leaf) {
                    $job = Open-Job $candidate
                } else {
                    $data = New-JobData ([IO.Path]::GetFileName($candidate)) $sourcePath
                    $job = New-JobObject $candidate $data
                }
                if (-not $NoCreate) { Write-JobSourceFile $job }
                if ($Logger) { Write-DebugLog ("Reusing job: " + $candidate) }
                return $job
            }
        }
        $candidate = Join-Path $workDirPath ($baseId + '_' + $suffix)
        $suffix++
    }

    $data = New-JobData ([IO.Path]::GetFileName($candidate)) $sourcePath
    $job = New-JobObject $candidate $data
    if (-not $NoCreate) {
        New-Item -ItemType Directory -Path $candidate -Force | Out-Null
        Write-JobSourceFile $job
        if ($Logger) { Write-DebugLog ("Created job: " + $candidate) }
    }
    return $job
}

function Test-JobSourceChanged {
    param($Job)
    $data = $Job.data
    if (-not $data.Contains('source_size') -or -not $data.Contains('source_mtime')) { return $true }
    $source = Get-JobSourcePath $Job
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $true }
    $item = Get-Item -LiteralPath $source
    $size = [int64]$item.Length
    $mtime = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    $storedSize = [int64]0
    $storedMtime = [int64]0
    if (-not [int64]::TryParse([string]$data['source_size'], [ref]$storedSize)) { return $true }
    if (-not [int64]::TryParse([string]$data['source_mtime'], [ref]$storedMtime)) { return $true }
    return ($storedSize -ne $size -or $storedMtime -ne $mtime)
}

function Find-Jobs {
    param([string]$WorkDir)
    $jobs = @()
    $resolved = [IO.Path]::GetFullPath($WorkDir)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return $jobs }
    $children = Get-ChildItem -LiteralPath $resolved -Directory | Sort-Object { $_.Name.ToLowerInvariant() }
    foreach ($child in $children) {
        if (-not (Test-Path -LiteralPath (Join-Path $child.FullName 'job.txt') -PathType Leaf)) { continue }
        try {
            $jobs += (Open-Job $child.FullName)
        } catch {
            continue
        }
    }
    return $jobs
}

#endregion

#region Frame handling

function Get-FramePattern {
    param([string]$Format)
    $value = ([string]$Format).Trim().ToLowerInvariant()
    if ($value -eq 'png') { return 'frame_%08d.png' }
    if ($value -eq 'jpg' -or $value -eq 'jpeg') { return 'frame_%08d.jpg' }
    throw [PipelineException]::new("Unsupported frame format: $Format", $null, 4)
}

function Test-FrameSignature {
    param([string]$Path)
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] 12
            $read = $stream.Read($buffer, 0, 12)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
    if ($read -ge 8 -and $buffer[0] -eq 0x89 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x4E -and $buffer[3] -eq 0x47) { return $true }
    if ($read -ge 3 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xD8 -and $buffer[2] -eq 0xFF) { return $true }
    if ($read -ge 12 -and $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x49 -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x46 -and $buffer[8] -eq 0x57 -and $buffer[9] -eq 0x45 -and $buffer[10] -eq 0x42 -and $buffer[11] -eq 0x50) { return $true }
    return $false
}

function Get-FrameGroups {
    param([string]$Directory, [switch]$Recursive)
    $groups = @{}
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return $groups }
    $files = @()
    $files += @(Get-ChildItem -LiteralPath $resolved -File -ErrorAction SilentlyContinue)
    if ($Recursive) {
        foreach ($child in @(Get-ChildItem -LiteralPath $resolved -Directory -ErrorAction SilentlyContinue)) {
            $files += @(Get-ChildItem -LiteralPath $child.FullName -File -ErrorAction SilentlyContinue)
        }
    }
    foreach ($file in $files) {
        $match = [regex]::Match($file.Name, '^frame_(\d{8})(?:[_\-.].*)?\.(png|jpe?g|webp)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        $index = [int]$match.Groups[1].Value
        if (-not $groups.ContainsKey($index)) { $groups[$index] = New-Object System.Collections.ArrayList }
        [void]$groups[$index].Add($file)
    }
    return $groups
}

function Count-ContiguousFrames {
    param([string]$Directory, [string]$Extension)
    $groups = Get-FrameGroups $Directory
    $wanted = ([string]$Extension).TrimStart('.').ToLowerInvariant()
    $count = 0
    while ($true) {
        $index = $count + 1
        $paths = @()
        if ($groups.ContainsKey($index)) {
            $paths = @($groups[$index] | Where-Object {
                $_.PSIsContainer -eq $false -and $_.Length -gt 0 -and $_.Extension.TrimStart('.').ToLowerInvariant() -eq $wanted
            })
        }
        if ($paths.Count -eq 0) { return $count }
        $count++
    }
}

function Validate-FrameSet {
    param(
        [string]$Directory,
        $Expected = $null,
        [string]$Pick = 'error',
        [switch]$Verify
    )
    $resolved = [IO.Path]::GetFullPath($Directory)
    $raw = Get-FrameGroups $resolved -Recursive
    $selected = @{}
    foreach ($index in $raw.Keys) {
        $valid = @($raw[$index] | Where-Object { $_.PSIsContainer -eq $false -and $_.Length -gt 0 })
        if ($valid.Count -eq 0) { continue }
        if ($valid.Count -gt 1) {
            if ($Pick -eq 'error') {
                $listing = ($valid | ForEach-Object { $_.FullName }) -join ', '
                throw [PipelineException]::new("Multiple frames for index $('{0:D8}' -f $index): $listing", 'Use --pick newest or --pick largest, or remove duplicates.', 4)
            }
            if ($Pick -eq 'newest') {
                $best = $valid[0]
                foreach ($candidate in $valid) {
                    if ($candidate.LastWriteTimeUtc -gt $best.LastWriteTimeUtc -or
                        ($candidate.LastWriteTimeUtc -eq $best.LastWriteTimeUtc -and [string]::CompareOrdinal($candidate.Name, $best.Name) -gt 0)) {
                        $best = $candidate
                    }
                }
                $selected[$index] = $best
            } elseif ($Pick -eq 'largest') {
                $best = $valid[0]
                foreach ($candidate in $valid) {
                    if ($candidate.Length -gt $best.Length -or
                        ($candidate.Length -eq $best.Length -and [string]::CompareOrdinal($candidate.Name, $best.Name) -gt 0)) {
                        $best = $candidate
                    }
                }
                $selected[$index] = $best
            } else {
                throw [PipelineException]::new("Unknown --pick mode: $Pick", $null, 4)
            }
        } else {
            $selected[$index] = $valid[0]
        }
    }
    if ($selected.Count -eq 0) {
        throw [PipelineException]::new("No valid frames found in: $resolved", $null, 4)
    }

    $indices = @($selected.Keys | Sort-Object)
    $maximum = [math]::Max([int]$indices[-1], 1)
    if ($null -ne $Expected) { $maximum = [math]::Max($maximum, [int]$Expected) }
    $missing = @()
    for ($index = 1; $index -le $maximum; $index++) {
        if (-not $selected.ContainsKey($index)) { $missing += $index }
    }
    $extra = @()
    if ($null -ne $Expected) {
        foreach ($index in $indices) {
            if ($index -gt [int]$Expected) { $extra += $index }
        }
    }
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        $details = @()
        if ($missing.Count -gt 0) {
            $details += 'missing: ' + (($missing | Select-Object -First 20 | ForEach-Object { '{0:D8}' -f $_ }) -join ', ')
        }
        if ($extra.Count -gt 0) {
            $details += 'unexpected: ' + (($extra | Select-Object -First 20 | ForEach-Object { '{0:D8}' -f $_ }) -join ', ')
        }
        throw [PipelineException]::new("Frame set is not contiguous in: $resolved", ($details -join '; '), 4)
    }

    $extensions = @{}
    foreach ($index in $indices) {
        $extensions[$selected[$index].Extension.TrimStart('.').ToLowerInvariant()] = $true
    }
    if ($extensions.Count -ne 1) {
        throw [PipelineException]::new('Mixed frame formats are not supported: ' + (($extensions.Keys | Sort-Object) -join ', '), $null, 4)
    }
    $extension = @($extensions.Keys)[0]

    if ($Verify) {
        foreach ($index in $indices) {
            if (-not (Test-FrameSignature $selected[$index].FullName)) {
                throw [PipelineException]::new("Invalid frame signature at index $('{0:D8}' -f $index): $($selected[$index].FullName)", $null, 4)
            }
        }
    }

    $paths = @()
    foreach ($index in $indices) { $paths += $selected[$index].FullName }
    return @{
        directory = $resolved
        extension = $extension
        indices   = $indices
        paths     = $paths
        count     = $paths.Count
    }
}

function Build-FrameSequence {
    param($FrameSet, $Job, $Logger = $null)
    $isNormalized = $true
    if ($FrameSet.paths.Count -eq 0) { $isNormalized = $false }
    if ($isNormalized) {
        for ($i = 0; $i -lt $FrameSet.indices.Count; $i++) {
            $expectedName = 'frame_{0:D8}.{1}' -f $FrameSet.indices[$i], $FrameSet.extension
            if ([IO.Path]::GetFileName($FrameSet.paths[$i]) -ne $expectedName) { $isNormalized = $false; break }
        }
    }
    if ($isNormalized) { return $FrameSet }
    if ($FrameSet.count -eq 0) {
        throw [PipelineException]::new('Cannot build an image sequence from zero frames', $null, 4)
    }
    $sequence = Join-Path $Job.path 'sequence'
    if (Test-Path -LiteralPath $sequence) { Remove-Item -LiteralPath $sequence -Recurse -Force }
    New-Item -ItemType Directory -Path $sequence -Force | Out-Null
    $targets = @()
    for ($i = 0; $i -lt $FrameSet.indices.Count; $i++) {
        $target = Join-Path $sequence ('frame_{0:D8}.{1}' -f $FrameSet.indices[$i], $FrameSet.extension)
        $source = $FrameSet.paths[$i]
        try {
            New-Item -ItemType HardLink -Path $target -Target $source -Force | Out-Null
        } catch {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        $targets += $target
    }
    if ($Logger) { Write-DebugLog ("Normalized " + $targets.Count + " frames into " + $sequence) }
    return @{
        directory = $sequence
        extension = $FrameSet.extension
        indices   = $FrameSet.indices
        paths     = $targets
        count     = $targets.Count
    }
}

function Get-HwAccelArgs {
    param([string]$Decode)
    if ($Decode -ne 'gpu') { return @() }
    $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($smi) { return @('-hwaccel', 'cuda') }
    return @('-hwaccel', 'd3d11va')
}

function Get-SplitCommand {
    param(
        [string]$Source,
        $Media,
        [string]$OutputDir,
        [double]$Start,
        $Duration,
        [int]$FirstFrame,
        [string]$Format,
        [int]$JpegQuality,
        [int]$PngCompression,
        [string]$Denoise,
        [bool]$Tonemap,
        [string]$Decode,
        $FrameLimit
    )
    $fmt = ([string]$Format).ToLowerInvariant()
    if (@('png', 'jpg') -notcontains $fmt) {
        throw [PipelineException]::new("Unsupported frame format: $Format", $null, 4)
    }
    $denoiseMap = @{
        'none'   = $null
        'light'  = 'hqdn3d=1.5:1.5:6:6'
        'medium' = 'hqdn3d=2:2:8:8'
        'strong' = 'hqdn3d=3:3:10:10'
    }
    if (-not $denoiseMap.ContainsKey($Denoise)) {
        throw [PipelineException]::new("Unsupported denoise mode: $Denoise", $null, 4)
    }
    $pattern = Get-FramePattern $fmt
    $arguments = @('ffmpeg', '-hide_banner', '-nostdin', '-y', '-benchmark')
    $arguments += (Get-HwAccelArgs $Decode)
    if ($Start -gt 0) {
        $arguments += @('-ss', $Start.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments += @('-i', $Source)
    if ($null -ne $Duration) {
        $arguments += @('-t', ([double]$Duration).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments += @('-map', '0:v:0', '-an', '-sn', '-dn', '-fps_mode', 'cfr', '-r', $Media.fps_rational, '-start_number', [string]$FirstFrame)
    if ($null -ne $FrameLimit) {
        $arguments += @('-frames:v', [string]$FrameLimit)
    }

    $filters = @()
    if ($Tonemap) {
        $filters += 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p'
    }
    if ($denoiseMap[$Denoise]) { $filters += $denoiseMap[$Denoise] }
    if (($Media.width % 2) -ne 0 -or ($Media.height % 2) -ne 0) {
        $filters += 'pad=ceil(iw/2)*2:ceil(ih/2)*2'
    }
    if ($fmt -eq 'png') { $filters += 'format=rgb24' } else { $filters += 'format=yuvj420p' }
    $arguments += @('-vf', ($filters -join ','))
    if ($fmt -eq 'png') {
        $arguments += @('-compression_level', [string]$PngCompression)
    } else {
        $arguments += @('-q:v', [string]$JpegQuality)
    }
    $arguments += (Join-Path $OutputDir $pattern)
    return $arguments
}

function Measure-DecodeSpeed {
    param([string]$Ffmpeg, [string]$Source, $Media, [string]$Decode, $Logger = $null)
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('upscayl-bench-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $arguments = @($Ffmpeg, '-hide_banner', '-nostdin', '-y', '-benchmark')
        $arguments += (Get-HwAccelArgs $Decode)
        $arguments += @(
            '-i', $Source, '-map', '0:v:0', '-an', '-sn', '-dn',
            '-fps_mode', 'cfr', '-r', $Media.fps_rational, '-frames:v', '30',
            '-compression_level', '3', (Join-Path $tempDir 'frame_%08d.png')
        )
        try {
            $result = Invoke-Child -Arguments $arguments
        } catch {
            return $null
        }
        $matches = [regex]::Matches($result.StdErr, 'bench:.*?rtime=([0-9.]+)')
        if ($matches.Count -eq 0) { return $null }
        return [double]::Parse($matches[$matches.Count - 1].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Select-DecodePath {
    param([string]$Ffmpeg, [string]$Source, $Media, $Config, $Logger)
    if ($Media.fps_den -eq 0 -or (Get-HwAccelArgs 'gpu').Count -eq 0) { return 'cpu' }
    Write-DebugLog 'Benchmarking CPU and GPU frame extraction'
    $cpuTime = Measure-DecodeSpeed -Ffmpeg $Ffmpeg -Source $Source -Media $Media -Decode 'cpu' -Logger $Logger
    $gpuTime = Measure-DecodeSpeed -Ffmpeg $Ffmpeg -Source $Source -Media $Media -Decode 'gpu' -Logger $Logger
    if ($null -eq $cpuTime -and $null -eq $gpuTime) {
        Write-Warn 'Decode benchmark failed; using CPU'
        return 'cpu'
    }
    if ($null -ne $gpuTime -and ($null -eq $cpuTime -or $gpuTime -lt $cpuTime)) {
        $cpuText = if ($null -ne $cpuTime) { $cpuTime.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) } else { '0.00' }
        Write-Info ('Decode benchmark: GPU ' + $gpuTime.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + 's vs CPU ' + $cpuText + 's; using GPU')
        return 'gpu'
    }
    $gpuText = if ($null -ne $gpuTime) { $gpuTime.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) } else { '0.00' }
    Write-Info ('Decode benchmark: CPU ' + $cpuTime.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + 's vs GPU ' + $gpuText + 's; using CPU')
    return 'cpu'
}

function Invoke-FrameExtraction {
    param(
        $Job,
        $Media,
        $Config,
        [string]$Format,
        [int]$JpegQuality,
        [int]$PngCompression,
        [string]$Denoise,
        [bool]$Tonemap,
        [string]$Decode,
        [double]$Start,
        $End,
        [bool]$Verify,
        $Logger,
        [bool]$DryRun = $false
    )
    if (@('cpu', 'gpu', 'auto') -notcontains $Decode) {
        throw [PipelineException]::new("Unsupported decode mode: $Decode", $null, 4)
    }
    $fps = if ($Media.fps_decimal -gt 0) { $Media.fps_decimal } else { 30.0 }
    $totalDuration = [math]::Max(0.0, ($(if ($null -ne $End) { [double]$End } else { $Media.duration })) - $Start)
    $expected = [int](Round-HalfEven ($totalDuration * $fps))
    if ($expected -le 0) { return 0 }
    if ($Media.hdr -and -not $Tonemap) {
        throw [PipelineException]::new('HDR source detected. Upscayl models are 8-bit SDR.', 'Re-run with --tonemap to convert HDR to SDR BT.709.', 4)
    }
    if ($Tonemap -and -not $Media.hdr) {
        Write-Warn '--tonemap was requested for a non-HDR source; applying the SDR conversion anyway'
    }

    $chosen = $Decode
    if ($Decode -eq 'auto') {
        $chosen = Select-DecodePath -Ffmpeg $Config.ffmpeg -Source (Get-JobSourcePath $Job) -Media $Media -Config $Config -Logger $Logger
        Set-JobValue $Job 'decode' $chosen
        Write-Info ('Frame decode path: ' + $chosen)
    } elseif ($Decode -eq 'gpu') {
        Set-JobValue $Job 'decode' 'gpu'
    } else {
        Set-JobValue $Job 'decode' 'cpu'
    }

    $framesDir = Join-Path $Job.path 'frames'
    $groups = Get-FrameGroups $framesDir
    $totalFiles = 0
    foreach ($index in $groups.Keys) {
        foreach ($file in $groups[$index]) {
            if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $totalFiles++ }
        }
    }
    $existing = Count-ContiguousFrames $framesDir $(if ($Format -eq 'jpg') { 'jpg' } else { 'png' })
    if ($totalFiles -gt $existing) {
        throw [PipelineException]::new("Existing frame set is not contiguous: $framesDir", 'Use --force to start the split over.', 4)
    }
    if ($existing -gt $expected) {
        throw [PipelineException]::new("More frames exist than expected ($existing > $expected)", 'Use --force to start the split over.', 4)
    }
    if ($existing -eq $expected) { return $existing }

    $firstFrame = $existing + 1
    $adjustedStart = $Start + $(if ($existing -gt 0) { $existing / $fps } else { 0.0 })
    $remaining = $expected - $existing
    $command = Get-SplitCommand -Source (Get-JobSourcePath $Job) -Media $Media -OutputDir $framesDir -Start $adjustedStart -Duration ($remaining / $fps) -FirstFrame $firstFrame -Format $Format -JpegQuality $JpegQuality -PngCompression $PngCompression -Denoise $Denoise -Tonemap $Tonemap -Decode $chosen -FrameLimit $remaining
    $command[0] = $Config.ffmpeg
    if ($DryRun) {
        Write-Info ($command -join ' ')
        return $expected
    }

    if (-not (Test-Path -LiteralPath $framesDir)) { New-Item -ItemType Directory -Path $framesDir -Force | Out-Null }
    try {
        Invoke-Child -Arguments $command | Out-Null
    } catch {
        if ($chosen -eq 'gpu') {
            Write-Warn 'GPU frame extraction failed; retrying with CPU'
            Set-JobValue $Job 'decode' 'cpu'
            $command = Get-SplitCommand -Source (Get-JobSourcePath $Job) -Media $Media -OutputDir $framesDir -Start $adjustedStart -Duration ($remaining / $fps) -FirstFrame $firstFrame -Format $Format -JpegQuality $JpegQuality -PngCompression $PngCompression -Denoise $Denoise -Tonemap $Tonemap -Decode 'cpu' -FrameLimit $remaining
            $command[0] = $Config.ffmpeg
            try {
                Invoke-Child -Arguments $command | Out-Null
            } catch {
                $ex = Get-PipelineException $_
                throw [PipelineException]::new("Frame extraction failed: $(Get-JobSourcePath $Job)", $ex.Message, 7)
            }
        } else {
            $ex = Get-PipelineException $_
            throw [PipelineException]::new("Frame extraction failed: $(Get-JobSourcePath $Job)", $ex.Message, 7)
        }
    }

    $frameSet = Validate-FrameSet -Directory $framesDir -Expected $expected -Verify:$Verify
    return $frameSet.count
}

#endregion

#region Disk estimates

function Get-DiskEstimate {
    param([int64]$SampleBytes, [int]$FrameCount, [int]$Scale)
    $frameBytes = [math]::Max([int64]0, $SampleBytes)
    $count = [math]::Max(0, $FrameCount)
    $scaleValue = [math]::Max(1, $Scale)
    $framesBytes = [int64](Round-HalfEven ($frameBytes * $count * 1.15))
    $upscaledBytes = [int64](Round-HalfEven ($frameBytes * $scaleValue * $scaleValue * $count * 1.15))
    $totalBytes = $framesBytes + $upscaledBytes + [int64](1024 * 1024 * 1024)
    return @{
        frame_bytes    = $frameBytes
        frame_count    = $count
        frames_bytes   = $framesBytes
        upscaled_bytes = $upscaledBytes
        total_bytes    = $totalBytes
        free_bytes     = [int64]0
        fits           = $false
    }
}

function Test-DiskEstimate {
    param($Estimate, $Config, $Logger)
    $gib = [int64](1024 * 1024 * 1024)
    $cap = [int64]$Config.max_work_gb * $gib
    if ($Estimate.total_bytes -gt $cap) {
        Write-Warn ('Estimated work size ' + (Format-Bytes $Estimate.total_bytes) + ' exceeds the ' + $Config.max_work_gb + ' GiB cap; a long job should use chunked processing.')
    }
    $floor = [int64]$Config.min_free_gb * $gib
    $remaining = [int64]$Estimate.free_bytes - [int64]$Estimate.total_bytes
    if ($remaining -lt $floor) {
        throw [PipelineException]::new(
            ('Not enough free space: need ' + (Format-Bytes $Estimate.total_bytes) + ' plus ' + $Config.min_free_gb + ' GiB free, have ' + (Format-Bytes $Estimate.free_bytes)),
            'Use --work-dir on a larger drive, reduce the time range, or split the video first.',
            5
        )
    }
}

function Get-SampleFrameBytes {
    param(
        [string]$Source,
        $Job,
        $Media,
        $Config,
        [string]$Format,
        [string]$Denoise,
        [bool]$Tonemap,
        [string]$Decode,
        $Logger,
        [double]$Start = 0.0,
        $Duration = $null
    )
    $total = if ($null -ne $Duration) { [double]$Duration } else { [math]::Max(0.0, $Media.duration - $Start) }
    $offset = [math]::Min(1.0, [math]::Max(0.0, $total * 0.1))
    $sampleAt = if ($total -gt 0) { $Start + $offset } else { $Start }
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('upscayl-sample-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $reason = 'sample command produced no frame'
    try {
        $command = Get-SplitCommand -Source $Source -Media $Media -OutputDir $tempDir -Start $sampleAt -Duration $null -FirstFrame 1 -Format $Format -JpegQuality 1 -PngCompression 3 -Denoise $Denoise -Tonemap $Tonemap -Decode $Decode -FrameLimit 1
        $command[0] = $Config.ffmpeg
        try {
            Invoke-Child -Arguments $command | Out-Null
            $files = @(Get-ChildItem -LiteralPath $tempDir -File)
            if ($files.Count -gt 0 -and $files[0].Length -gt 0) {
                return [int64]$files[0].Length
            }
        } catch {
            $reason = (Get-PipelineException $_).Message
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($Format.ToLowerInvariant() -eq 'jpg') {
        $fallback = [int64][math]::Max(1, $Media.width * $Media.height)
    } else {
        $fallback = [int64][math]::Max(1, $Media.width * $Media.height * 3)
    }
    Write-Warn ('Could not measure a sample frame (' + $reason + '); using ' + (Format-Bytes $fallback) + ' per frame')
    return $fallback
}

#endregion

#region Encoding and muxing

function Get-Presets {
    return @{
        'mp4-h264'   = @{ name = 'mp4-h264'; container = 'mp4'; extension = 'mp4'; codec = 'h264'; default_audio = 'auto'; default_subs = 'auto' }
        'mp4-hevc'   = @{ name = 'mp4-hevc'; container = 'mp4'; extension = 'mp4'; codec = 'hevc'; default_audio = 'auto'; default_subs = 'auto' }
        'mkv-hevc'   = @{ name = 'mkv-hevc'; container = 'mkv'; extension = 'mkv'; codec = 'hevc'; default_audio = 'copy'; default_subs = 'copy' }
        'mov-prores' = @{ name = 'mov-prores'; container = 'mov'; extension = 'mov'; codec = 'prores'; default_audio = 'pcm'; default_subs = 'auto' }
    }
}

function Resolve-Preset {
    param([string]$Name)
    $presets = Get-Presets
    $key = ([string]$Name).Trim().ToLowerInvariant()
    if (-not $presets.ContainsKey($key)) {
        throw [PipelineException]::new("Unknown preset: $Name", ('Choose one of: ' + (($presets.Keys | Sort-Object) -join ', ')), 4)
    }
    return $presets[$key]
}

function Resolve-Quality {
    param($Preset, [string]$Quality, $Crf)
    $level = ([string]$Quality).Trim().ToLowerInvariant()
    if (@('fast', 'balanced', 'quality') -notcontains $level) {
        throw [PipelineException]::new("Unknown quality level: $Quality", $null, 4)
    }
    if ($Preset.codec -eq 'prores') {
        if ($null -ne $Crf) {
            throw [PipelineException]::new('ProRes does not support --crf; use --quality instead', $null, 4)
        }
        return 0
    }
    if ($null -ne $Crf) {
        $value = ConvertTo-IntValue ([string]$Crf) 'crf'
        if ($value -lt 0 -or $value -gt 51) {
            throw [PipelineException]::new('--crf must be between 0 and 51 for H.264/HEVC', $null, 4)
        }
        return $value
    }
    if ($Preset.codec -eq 'h264') {
        return @{ fast = 22; balanced = 20; quality = 18 }[$level]
    }
    return @{ fast = 24; balanced = 22; quality = 20 }[$level]
}

$script:EncoderCache = @{}

function Get-AvailableEncoders {
    param([string]$Ffmpeg)
    $key = $null
    try {
        $item = Get-Item -LiteralPath $Ffmpeg
        $key = $item.FullName + '|' + $item.LastWriteTimeUtc.Ticks
    } catch {
        $key = [string]$Ffmpeg
    }
    if ($script:EncoderCache.ContainsKey($key)) { return $script:EncoderCache[$key] }
    try {
        $result = Invoke-Child -Arguments @($Ffmpeg, '-hide_banner', '-encoders') -NoCheck
    } catch {
        $script:EncoderCache[$key] = @{}
        return $script:EncoderCache[$key]
    }
    $names = @{}
    if ($result.ExitCode -eq 0) {
        foreach ($match in [regex]::Matches($result.StdOut, '(?m)^\s*[A-Z.]{6}\s+(\S+)')) {
            $names[$match.Groups[1].Value] = $true
        }
    }
    $script:EncoderCache[$key] = $names
    return $names
}

function Apply-Quality {
    param($Choice, [string]$Quality)
    $level = ([string]$Quality).Trim().ToLowerInvariant()
    if (@('fast', 'balanced', 'quality') -notcontains $level) {
        throw [PipelineException]::new("Unknown quality level: $Quality", $null, 4)
    }
    if ($Choice.video_codec -eq 'prores_ks') {
        $profile = @{ fast = '1'; balanced = '2'; quality = '3' }[$level]
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = @($profile) }
    }
    if ($Choice.family -eq 'nvidia') {
        $preset = @{ fast = 'p5'; balanced = 'p6'; quality = 'p7' }[$level]
        $qualityArgs = @('-preset', $preset, '-tune', 'hq', '-rc', 'vbr')
        if ($level -eq 'quality') {
            $qualityArgs += @('-multipass', 'fullres', '-spatial_aq', '1', '-aq-strength', '12')
        }
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = $qualityArgs }
    }
    if ($Choice.family -eq 'amd') {
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = @('-quality', 'quality', '-rc', 'cqp') }
    }
    if ($Choice.video_codec -eq 'libx264') {
        $preset = @{ fast = 'veryfast'; balanced = 'medium'; quality = 'slow' }[$level]
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = @('-preset', $preset) }
    }
    if ($Choice.video_codec -eq 'libx265') {
        $preset = @{ fast = 'fast'; balanced = 'medium'; quality = 'slow' }[$level]
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = @('-preset', $preset) }
    }
    return $Choice
}

function Get-VideoCodecArgs {
    param($Choice, [int]$QualityValue, [bool]$TenBit)

    if ($Choice.video_codec -eq 'prores_ks') {
        if ($TenBit) {
            throw [PipelineException]::new('--10bit is not valid with ProRes; ProRes is already 10-bit', $null, 4)
        }
        $profile = if ($Choice.quality_args.Count -gt 0) { $Choice.quality_args[0] } else { '3' }
        return @('-c:v', 'prores_ks', '-profile:v', [string]$profile, '-vendor', 'apl0', '-pix_fmt', 'yuv422p10le')
    }

    $h264 = @('h264_nvenc', 'h264_amf', 'libx264') -contains $Choice.video_codec
    $hevc = @('hevc_nvenc', 'hevc_amf', 'libx265') -contains $Choice.video_codec
    if ($TenBit -and $h264) {
        throw [PipelineException]::new('--10bit is only valid for HEVC output', $null, 4)
    }

    $result = @('-c:v', $Choice.video_codec)
    $result += $Choice.quality_args
    if ($Choice.family -eq 'nvidia') {
        if (@($result) -notcontains '-preset') {
            $result += @('-preset', 'p6', '-tune', 'hq', '-rc', 'vbr')
        }
        $result += @('-cq', [string]$QualityValue, '-b:v', '0')
    } elseif ($Choice.family -eq 'amd') {
        if (@($result) -notcontains '-quality') {
            $result += @('-quality', 'quality', '-rc', 'cqp')
        }
        $result += @('-qp_i', [string]$QualityValue, '-qp_p', [string]$QualityValue)
    } else {
        if (@('libx264', 'libx265') -contains $Choice.video_codec) {
            if (@($result) -notcontains '-preset') {
                $result += @('-preset', 'medium')
            }
            $result += @('-crf', [string]$QualityValue)
        }
    }
    $pixFmt = if ($TenBit -and $hevc) { 'yuv420p10le' } else { 'yuv420p' }
    $result += @('-pix_fmt', $pixFmt)
    return $result
}

function Get-EncoderCandidates {
    param($Preset, [string]$Requested, [string]$Ffmpeg)
    $mode = ([string]$Requested).Trim().ToLowerInvariant()
    if (@('auto', 'nvidia', 'amd', 'cpu') -notcontains $mode) {
        throw [PipelineException]::new("Unknown encoder: $Requested", $null, 4)
    }
    $available = Get-AvailableEncoders $Ffmpeg
    $codecs = switch ($Preset.codec) {
        'h264' { @{ nvidia = 'h264_nvenc'; amd = 'h264_amf'; cpu = 'libx264' } }
        'hevc' { @{ nvidia = 'hevc_nvenc'; amd = 'hevc_amf'; cpu = 'libx265' } }
        'prores' { @{ nvidia = $null; amd = $null; cpu = 'prores_ks' } }
    }
    $order = if ($mode -eq 'auto') { @('nvidia', 'amd', 'cpu') } else { @($mode) }
    $candidates = @()
    foreach ($family in $order) {
        $codec = $codecs[$family]
        if ($codec -and $available.ContainsKey($codec)) {
            $candidates += (Apply-Quality @{ family = $family; video_codec = $codec; quality_args = @() } 'balanced')
        }
    }
    if ($candidates.Count -eq 0) {
        if ($mode -eq 'auto') {
            throw [PipelineException]::new("No usable encoder found for $($Preset.name)", 'Install FFmpeg with the required encoders or use --encoder cpu.', 3)
        }
        $codec = $codecs[$mode]
        throw [PipelineException]::new("Encoder not available: $(if ($codec) { $codec } else { $mode })", 'Use --encoder auto or cpu.', 3)
    }
    return $candidates
}

$script:MP4Audio = @('aac', 'mp3', 'ac3', 'eac3', 'alac')
$script:TextSubtitles = @('subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'text')
$script:ImageSubtitles = @('hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub')

function Test-AudioCompatible {
    param([string]$Container, [string]$Codec)
    $name = $Codec.ToLowerInvariant()
    if ($Container -eq 'mkv') { return $true }
    if ($Container -eq 'mp4') { return ($script:MP4Audio -contains $name) }
    if ($Container -eq 'mov') { return (($script:MP4Audio -contains $name) -or $name.StartsWith('pcm_')) }
    return $false
}

function Test-SubtitleCompatible {
    param([string]$Container, [string]$Codec)
    $name = $Codec.ToLowerInvariant()
    if ($Container -eq 'mkv') { return ($name -ne 'mov_text') }
    if (@('mp4', 'mov') -contains $Container) { return ($name -eq 'mov_text') }
    return $false
}

function Get-AudioPlan {
    param($Media, $Preset, [string]$Mode, [int]$Bitrate, [bool]$AllAudio)
    $requested = ([string]$Mode).Trim().ToLowerInvariant()
    if (@('auto', 'copy', 'aac', 'pcm', 'none') -notcontains $requested) {
        throw [PipelineException]::new("Unknown audio mode: $Mode", $null, 4)
    }
    if ($Bitrate -le 0) {
        throw [PipelineException]::new('Audio bitrate must be greater than zero', $null, 4)
    }
    if ($Media.audio.Count -eq 0 -or $requested -eq 'none') {
        return @{ streams = @(); enabled = $false }
    }
    $selected = if ($AllAudio) { $Media.audio } else { @($Media.audio[0]) }
    if ($requested -eq 'auto' -and @('copy', 'aac', 'pcm') -contains $Preset.default_audio) {
        $requested = $Preset.default_audio
    }
    if ($requested -eq 'pcm') {
        if ($Preset.container -eq 'mp4') {
            throw [PipelineException]::new('PCM audio is not supported in MP4.', 'Use --preset mkv-hevc or --audio aac.', 4)
        }
        $streams = @()
        foreach ($stream in $selected) { $streams += @{ source_index = $stream.index; mode = 'pcm' } }
        return @{ streams = $streams; enabled = $true }
    }
    if ($requested -eq 'copy') {
        $bad = @()
        foreach ($stream in $selected) {
            if (-not (Test-AudioCompatible $Preset.container $stream.codec_name)) { $bad += $stream.codec_name }
        }
        if ($bad.Count -gt 0) {
            $unique = @($bad | Sort-Object -Unique)
            throw [PipelineException]::new(('Audio codec cannot be copied into ' + $Preset.container + ': ' + ($unique -join ', ')), 'Use --audio aac or --preset mkv-hevc.', 4)
        }
        $streams = @()
        foreach ($stream in $selected) { $streams += @{ source_index = $stream.index; mode = 'copy' } }
        return @{ streams = $streams; enabled = $true }
    }
    if ($requested -eq 'aac') {
        $streams = @()
        foreach ($stream in $selected) { $streams += @{ source_index = $stream.index; mode = 'aac' } }
        return @{ streams = $streams; enabled = $true }
    }
    $streams = @()
    foreach ($stream in $selected) {
        $streamMode = if (Test-AudioCompatible $Preset.container $stream.codec_name) { 'copy' } else { 'aac' }
        $streams += @{ source_index = $stream.index; mode = $streamMode }
    }
    return @{ streams = $streams; enabled = $true }
}

function Get-SubtitlePlan {
    param($Media, $Preset, [string]$Mode, $Logger = $null)
    $requested = ([string]$Mode).Trim().ToLowerInvariant()
    if (@('auto', 'copy', 'convert', 'none') -notcontains $requested) {
        throw [PipelineException]::new("Unknown subtitle mode: $Mode", $null, 4)
    }
    if ($Media.subtitles.Count -eq 0 -or $requested -eq 'none') {
        return @{ streams = @(); dropped = @() }
    }
    if ($requested -eq 'copy') {
        $bad = @()
        foreach ($stream in $Media.subtitles) {
            if (-not (Test-SubtitleCompatible $Preset.container $stream.codec_name)) { $bad += $stream.codec_name }
        }
        if ($bad.Count -gt 0) {
            $unique = @($bad | Sort-Object -Unique)
            throw [PipelineException]::new(('Subtitle codec cannot be copied into ' + $Preset.container + ': ' + ($unique -join ', ')), 'Use --subs convert or --preset mkv-hevc.', 4)
        }
        $streams = @()
        foreach ($stream in $Media.subtitles) { $streams += @{ source_index = $stream.index; mode = 'copy' } }
        return @{ streams = $streams; dropped = @() }
    }
    if ($requested -eq 'convert') {
        $image = @()
        foreach ($stream in $Media.subtitles) {
            if ($script:ImageSubtitles -contains $stream.codec_name.ToLowerInvariant()) { $image += $stream.index }
        }
        if ($image.Count -gt 0) {
            throw [PipelineException]::new('Image subtitles cannot be converted to a text format.', 'Use --preset mkv-hevc to keep them.', 4)
        }
        $textMode = if ($Preset.container -eq 'mkv') { 'subrip' } else { 'mov_text' }
        $streams = @()
        foreach ($stream in $Media.subtitles) { $streams += @{ source_index = $stream.index; mode = $textMode } }
        return @{ streams = $streams; dropped = @() }
    }
    if ($Preset.container -eq 'mkv') {
        $streams = @()
        foreach ($stream in $Media.subtitles) {
            $streamMode = if ($stream.codec_name.ToLowerInvariant() -eq 'mov_text') { 'subrip' } else { 'copy' }
            $streams += @{ source_index = $stream.index; mode = $streamMode }
        }
        return @{ streams = $streams; dropped = @() }
    }
    $streams = @()
    $dropped = @()
    foreach ($stream in $Media.subtitles) {
        $codec = $stream.codec_name.ToLowerInvariant()
        if ($script:ImageSubtitles -contains $codec) { $dropped += $stream.index; continue }
        if ($script:TextSubtitles -contains $codec) {
            $streams += @{ source_index = $stream.index; mode = 'mov_text' }
            continue
        }
        $dropped += $stream.index
    }
    if ($dropped.Count -gt 0 -and $Logger) {
        Write-Warn ('Dropped subtitle stream(s) ' + ($dropped -join ', ') + " that cannot be stored in $($Preset.container); use mkv-hevc to keep them.")
    }
    return @{ streams = $streams; dropped = $dropped }
}

function Get-EvenValue {
    param([int]$Value)
    if (($Value % 2) -eq 0) { return $Value }
    return $Value + 1
}

function Get-OutputDimensions {
    param([int]$FrameWidth, [int]$FrameHeight, $TargetHeight, [bool]$AllowHuge)
    if ($null -ne $TargetHeight) {
        $target = [math]::Max(2, (Get-EvenValue ([int]$TargetHeight)))
        if ($target -gt $FrameHeight) {
            throw [PipelineException]::new("--target-height ($target) exceeds the upscaled height ($FrameHeight)", $null, 4)
        }
        $outputHeight = $target
        $rawWidth = Round-HalfEven ($FrameWidth * $target / $FrameHeight)
        $outputWidth = Get-EvenValue ([math]::Max(2, [int]$rawWidth))
    } else {
        $outputWidth = $FrameWidth
        $outputHeight = $FrameHeight
    }
    if (-not $AllowHuge) {
        if ($outputWidth -gt 8192 -or $outputHeight -gt 8192) {
            throw [PipelineException]::new('Output exceeds 8192 px on a side; use --allow-huge only if you really need it', $null, 4)
        }
        if (([int64]$outputWidth * $outputHeight) -gt 40000000) {
            throw [PipelineException]::new('Output exceeds 40 megapixels; use --allow-huge only if you really need it', $null, 4)
        }
    }
    return @($outputWidth, $outputHeight)
}

$script:ColorPrimaries = @('bt709', 'bt470m', 'bt470bg', 'smpte170m', 'smpte240m', 'film', 'bt2020', 'smpte428', 'smpte431', 'smpte432', 'jedec-p22', 'ebu3213')
$script:ColorTransfers = @('bt709', 'gamma22', 'gamma28', 'smpte170m', 'smpte240m', 'linear', 'log100', 'log316', 'iec61966-2-4', 'bt1361e', 'iec61966-2-1', 'bt2020-10', 'bt2020-12', 'smpte2084', 'smpte428', 'arib-std-b67')
$script:ColorSpaces = @('bt709', 'fcc', 'bt470bg', 'smpte170m', 'smpte240m', 'ycgco', 'bt2020nc', 'bt2020c', 'smpte2085', 'chroma-derived-nc', 'chroma-derived-c', 'ictcp')

function Get-ColorValue {
    param($Job, $MediaValue, [string]$Key, [int]$Height = 1080)
    $value = Get-JobValue $Job $Key $null
    if (-not $value) { $value = $MediaValue }
    $default = if ($Height -ge 720) { 'bt709' } else { 'smpte170m' }
    if ($Key -eq 'color_range') {
        if ($null -eq $value) { return 'tv' }
        $rangeText = ([string]$value).Trim().ToLowerInvariant()
        if (@('tv', 'pc') -contains $rangeText) { return $rangeText }
        return 'tv'
    }
    if ($null -eq $value) { return $default }
    $text = ([string]$value).Trim().ToLowerInvariant()
    if (-not $text -or $text -eq 'unknown') { return $default }
    $allowed = switch ($Key) {
        'color_primaries' { $script:ColorPrimaries }
        'color_trc' { $script:ColorTransfers }
        'colorspace' { $script:ColorSpaces }
        default { @() }
    }
    if ($allowed -contains $text) { return $text }
    # RGB sources report gbr, which is not a valid YUV output matrix.
    return $default
}

function Build-AssembleCommand {
    param(
        $Job,
        $FrameSet,
        $Media,
        $Preset,
        $Encoder,
        $AudioPlan,
        $SubtitlePlan,
        $Options,
        [string]$Output,
        [int]$FrameWidth,
        [int]$FrameHeight
    )
    $qualityValue = Resolve-Quality $Preset $Options.quality $Options.crf
    $Encoder = Apply-Quality $Encoder $Options.quality
    $dimsOut = Get-OutputDimensions $FrameWidth $FrameHeight $Options.target_height ([bool]$Options.allow_huge); $outputHeight = [int]$dimsOut[1]

    $hasSourceInput = ($AudioPlan.enabled -or $SubtitlePlan.streams.Count -gt 0 -or $Media.chapters -gt 0)
    $fps = Get-JobValue $Job 'fps' $null
    if (-not $fps) { $fps = $Media.fps_rational }
    $pattern = 'frame_%08d.' + $FrameSet.extension

    $arguments = @(
        'ffmpeg', '-hide_banner', '-nostdin', '-y', '-benchmark',
        '-framerate', [string]$fps, '-start_number', [string]$FrameSet.indices[0],
        '-i', (Join-Path $FrameSet.directory $pattern)
    )
    if ($hasSourceInput) {
        $rangeStart = ConvertTo-DoubleSafe (Get-JobValue $Job 'range_start' 0.0) 0.0
        if ($rangeStart -gt 0) {
            $arguments += @('-ss', $rangeStart.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
        }
        $arguments += @('-i', (Get-JobSourcePath $Job))
    }

    $arguments += @('-map', '0:v:0')
    if ($AudioPlan.enabled) {
        foreach ($stream in $AudioPlan.streams) { $arguments += @('-map', ('1:' + $stream.source_index)) }
        for ($i = 0; $i -lt $AudioPlan.streams.Count; $i++) {
            $stream = $AudioPlan.streams[$i]
            $codec = @{ copy = 'copy'; aac = 'aac'; pcm = 'pcm_s24le' }[$stream.mode]
            $arguments += @(('-c:a:' + $i), $codec)
            if ($stream.mode -eq 'aac') {
                $arguments += @(('-b:a:' + $i), ([string]$Options.audio_bitrate + 'k'))
            }
        }
    } else {
        $arguments += '-an'
    }

    if ($SubtitlePlan.streams.Count -gt 0) {
        foreach ($stream in $SubtitlePlan.streams) { $arguments += @('-map', ('1:' + $stream.source_index)) }
        for ($i = 0; $i -lt $SubtitlePlan.streams.Count; $i++) {
            $arguments += @(('-c:s:' + $i), $SubtitlePlan.streams[$i].mode)
        }
    }
    if ($Media.chapters -gt 0) {
        $arguments += @('-map_chapters', '1')
    }

    $arguments += (Get-VideoCodecArgs $Encoder $qualityValue ([bool]$Options.ten_bit))

    $filters = @()
    $colorRange = Get-ColorValue $Job $Media.color_range 'color_range' -Height $outputHeight
    if ($null -ne $colorRange -and $colorRange.ToLowerInvariant() -eq 'pc') {
        $filters += 'scale=in_range=pc:out_range=tv'
        $colorRange = 'tv'
    }
    if ($null -ne $Options.target_height) {
        $filters += ('scale=-2:' + $Options.target_height + ':flags=lanczos')
    }
    if ($filters.Count -gt 0) { $arguments += @('-vf', ($filters -join ',')) }

    foreach ($pair in @(@('color_primaries', '-color_primaries'), @('color_trc', '-color_trc'), @('colorspace', '-colorspace'))) {
        $key = $pair[0]
        $flag = $pair[1]
        $value = Get-ColorValue $Job $Media[$key] $key -Height $outputHeight
        if ($value) { $arguments += @($flag, $value) }
    }
    if ($colorRange) { $arguments += @('-color_range', $colorRange) }

    $arguments += @('-metadata:s:v:0', 'rotate=0')
    if ($hasSourceInput) { $arguments += @('-map_metadata', '1') }
    if (@('mp4', 'mov') -contains $Preset.container) { $arguments += @('-movflags', '+faststart') }
    if ($Preset.codec -eq 'hevc' -and @('mp4', 'mov') -contains $Preset.container) { $arguments += @('-tag:v', 'hvc1') }
    if ($AudioPlan.enabled -or $SubtitlePlan.streams.Count -gt 0) {
        $durationValue = ConvertTo-DoubleSafe (Get-JobValue $Job 'duration' 0.0) 0.0
        if ($durationValue -le 0) {
            $durationValue = $FrameSet.count / [math]::Max($Media.fps_decimal, 1.0)
        }
        $arguments += @('-t', $durationValue.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments += $Output
    return $arguments
}

function Build-SegmentCommand {
    param(
        $Job,
        $FrameSet,
        $Media,
        $Preset,
        $Encoder,
        $Options,
        [string]$Output,
        [int]$FrameWidth,
        [int]$FrameHeight
    )
    $qualityValue = Resolve-Quality $Preset $Options.quality $Options.crf
    $Encoder = Apply-Quality $Encoder $Options.quality
    $dimsOut = Get-OutputDimensions $FrameWidth $FrameHeight $Options.target_height ([bool]$Options.allow_huge); $outputHeight = [int]$dimsOut[1]
    $fps = Get-JobValue $Job 'fps' $null
    if (-not $fps) { $fps = $Media.fps_rational }
    $pattern = 'frame_%08d.' + $FrameSet.extension
    $arguments = @(
        'ffmpeg', '-hide_banner', '-nostdin', '-y', '-benchmark',
        '-framerate', [string]$fps, '-start_number', [string]$FrameSet.indices[0],
        '-i', (Join-Path $FrameSet.directory $pattern),
        '-map', '0:v:0', '-an', '-sn', '-dn', '-frames:v', [string]$FrameSet.count
    )
    $arguments += (Get-VideoCodecArgs $Encoder $qualityValue ([bool]$Options.ten_bit))
    $filters = @()
    $colorRange = Get-ColorValue $Job $Media.color_range 'color_range' -Height $outputHeight
    if ($null -ne $colorRange -and $colorRange.ToLowerInvariant() -eq 'pc') {
        $filters += 'scale=in_range=pc:out_range=tv'
        $colorRange = 'tv'
    }
    if ($null -ne $Options.target_height) {
        $filters += ('scale=-2:' + $Options.target_height + ':flags=lanczos')
    }
    if ($filters.Count -gt 0) { $arguments += @('-vf', ($filters -join ',')) }
    foreach ($pair in @(@('color_primaries', '-color_primaries'), @('color_trc', '-color_trc'), @('colorspace', '-colorspace'))) {
        $key = $pair[0]
        $flag = $pair[1]
        $value = Get-ColorValue $Job $Media[$key] $key -Height $outputHeight
        if ($value) { $arguments += @($flag, $value) }
    }
    if ($colorRange) { $arguments += @('-color_range', $colorRange) }
    $arguments += @('-metadata:s:v:0', 'rotate=0')
    if ($Preset.codec -eq 'prores') {
        $arguments += @('-f', 'mov')
    } else {
        $arguments += @('-muxdelay', '0', '-muxpreload', '0', '-f', 'mpegts')
    }
    $arguments += $Output
    return $arguments
}

function Build-MuxCommand {
    param(
        $Job,
        $Media,
        $Preset,
        $AudioPlan,
        $SubtitlePlan,
        $Options,
        [string]$ConcatVideo,
        [string]$Output,
        [double]$Duration
    )
    $hasSource = ($AudioPlan.enabled -or $SubtitlePlan.streams.Count -gt 0 -or $Media.chapters -gt 0)
    $arguments = @('ffmpeg', '-hide_banner', '-nostdin', '-y', '-benchmark', '-i', $ConcatVideo)
    if ($hasSource) {
        $rangeStart = ConvertTo-DoubleSafe (Get-JobValue $Job 'range_start' 0.0) 0.0
        if ($rangeStart -gt 0) {
            $arguments += @('-ss', $rangeStart.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
        }
        $arguments += @('-i', (Get-JobSourcePath $Job))
    }
    $arguments += @('-map', '0:v:0')
    if ($AudioPlan.enabled) {
        foreach ($stream in $AudioPlan.streams) { $arguments += @('-map', ('1:' + $stream.source_index)) }
        for ($i = 0; $i -lt $AudioPlan.streams.Count; $i++) {
            $stream = $AudioPlan.streams[$i]
            $codec = @{ copy = 'copy'; aac = 'aac'; pcm = 'pcm_s24le' }[$stream.mode]
            $arguments += @(('-c:a:' + $i), $codec)
            if ($stream.mode -eq 'aac') {
                $arguments += @(('-b:a:' + $i), ([string]$Options.audio_bitrate + 'k'))
            }
        }
    } else {
        $arguments += '-an'
    }
    if ($SubtitlePlan.streams.Count -gt 0) {
        foreach ($stream in $SubtitlePlan.streams) { $arguments += @('-map', ('1:' + $stream.source_index)) }
        for ($i = 0; $i -lt $SubtitlePlan.streams.Count; $i++) {
            $arguments += @(('-c:s:' + $i), $SubtitlePlan.streams[$i].mode)
        }
    }
    if ($Media.chapters -gt 0) { $arguments += @('-map_chapters', '1') }
    $arguments += @('-c:v', 'copy')
    $arguments += @('-t', $Duration.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
    if ($hasSource) { $arguments += @('-map_metadata', '1') }
    $arguments += @('-metadata:s:v:0', 'rotate=0')
    if (@('mp4', 'mov') -contains $Preset.container) { $arguments += @('-movflags', '+faststart') }
    if ($Preset.codec -eq 'hevc' -and @('mp4', 'mov') -contains $Preset.container) { $arguments += @('-tag:v', 'hvc1') }
    $arguments += $Output
    return $arguments
}

function Repair-ColorTags {
    param([string]$Ffmpeg, [string]$Ffprobe, [string]$Path, [string]$Container, $Logger = $null)
    $info = Get-MediaInfo -Ffprobe $Ffprobe -Source $Path -Logger $Logger
    if ($info.color_primaries -eq 'bt709' -and $info.color_trc -eq 'bt709' -and $info.colorspace -eq 'bt709' -and $info.color_range -eq 'tv') {
        return
    }
    $directory = Split-Path -Parent $Path
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [IO.Path]::GetExtension($Path)
    $temporary = Join-Path $directory ($stem + '.colorfix' + $extension)
    $arguments = @(
        $Ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', $Path,
        '-map', '0:v', '-map', '0:a?', '-map', '0:s?', '-map', '0:t?', '-c', 'copy',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv'
    )
    if (@('mp4', 'mov') -contains $Container) { $arguments += @('-movflags', '+faststart') }
    $arguments += $temporary
    Invoke-Child -Arguments $arguments | Out-Null
    try {
        [IO.File]::Replace($temporary, $Path, $null)
    } catch {
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
}

function Test-Output {
    param(
        [string]$Ffprobe,
        [string]$Output,
        $Job,
        $Media,
        $Options,
        [int]$ExpectedWidth,
        [int]$ExpectedHeight,
        [bool]$ExpectedAudio,
        [int]$ExpectedSubs,
        $Logger = $null
    )
    try {
        $info = Get-MediaInfo -Ffprobe $Ffprobe -Source $Output -Logger $Logger
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new("Output is not a readable video: $Output", $ex.Message, 8)
    }
    $problems = @()
    if ($info.width -ne $ExpectedWidth -or $info.height -ne $ExpectedHeight) {
        $problems += ('dimensions ' + $info.width + 'x' + $info.height + ', expected ' + $ExpectedWidth + 'x' + $ExpectedHeight)
    }
    $expectedDuration = ConvertTo-DoubleSafe (Get-JobValue $Job 'duration' $Media.duration) $Media.duration
    $tolerance = [math]::Max(0.1, 1.0 / [math]::Max($info.fps_decimal, 1.0))
    if ([math]::Abs($info.duration - $expectedDuration) -gt $tolerance) {
        $problems += ('duration ' + $info.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + 's, expected ' + $expectedDuration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + 's')
    }
    $expectedFps = ConvertTo-DoubleSafe (Get-JobValue $Job 'fps_decimal' $Media.fps_decimal) $Media.fps_decimal
    if ($expectedFps -gt 0 -and [math]::Abs($info.fps_decimal - $expectedFps) -gt 0.02) {
        $problems += ('fps ' + $info.fps_decimal.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + ', expected ' + $expectedFps.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $hasAudio = $info.audio.Count -gt 0
    if ($hasAudio -ne $ExpectedAudio) {
        $problems += ('audio streams ' + $info.audio.Count + ', expected ' + $(if ($ExpectedAudio) { 'at least one' } else { 'none' }))
    }
    if ($info.subtitles.Count -ne $ExpectedSubs) {
        $problems += ('subtitle streams ' + $info.subtitles.Count + ', expected ' + $ExpectedSubs)
    }
    $preset = Resolve-Preset $Options.preset
    if ($preset.codec -eq 'prores') {
        $expectedPixFmt = 'yuv422p10le'
    } elseif ($Options.ten_bit) {
        $expectedPixFmt = 'yuv420p10le'
    } else {
        $expectedPixFmt = 'yuv420p'
    }
    if ($info.pix_fmt -ne $expectedPixFmt) {
        $problems += ('pixel format ' + $info.pix_fmt + ', expected ' + $expectedPixFmt)
    }
    if ($problems.Count -gt 0) {
        throw [PipelineException]::new('Output validation failed: ' + ($problems -join '; '), $null, 8)
    }
}

#endregion

#region Upscayl discovery and batching

function Get-ModelList {
    param([string]$ModelsDir)
    if (-not (Test-Path -LiteralPath $ModelsDir -PathType Container)) {
        throw [PipelineException]::new("Upscayl models directory not found: $ModelsDir", $null, 3)
    }
    $models = @()
    $params = Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.param' | Sort-Object Name
    foreach ($param in $params) {
        $weights = [IO.Path]::ChangeExtension($param.FullName, '.bin')
        if (Test-Path -LiteralPath $weights -PathType Leaf) {
            $models += @{ name = [IO.Path]::GetFileNameWithoutExtension($param.Name); param = $param.FullName; weights = $weights }
        }
    }
    if ($models.Count -eq 0) {
        throw [PipelineException]::new("No complete Upscayl models found in: $ModelsDir", 'Each model needs matching .param and .bin files.', 3)
    }
    return $models
}

function Find-NvidiaIcd {
    $base = 'C:\Windows\System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $null }
    $directories = Get-ChildItem -LiteralPath $base -Directory -Filter 'nv*' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($directory in $directories) {
        $candidate = Join-Path $directory.FullName 'nv-vk64.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Resolve-Icd {
    param($Config, [string]$Override = $null)
    $value = if ($null -ne $Override -and ([string]$Override).Trim()) { ([string]$Override).Trim() } else { ([string]$Config.icd).Trim() }
    if (-not $value -or $value.ToLowerInvariant() -eq 'none') { return $null }
    if ($value.ToLowerInvariant() -eq 'auto') { return (Find-NvidiaIcd) }
    $path = Resolve-AbsolutePath (Expand-HomePath $value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw [PipelineException]::new("Vulkan ICD JSON not found: $path", $null, 4)
    }
    return $path
}

function Get-UpscaylBinaryCandidates {
    $candidates = @()
    if ($env:UPSCAYL_BIN) { $candidates += $env:UPSCAYL_BIN }
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    $candidates += (Join-Path $programFiles 'Upscayl\resources\bin\upscayl-bin.exe')
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Upscayl\resources\bin\upscayl-bin.exe')
    }
    $found = Get-Command 'upscayl-bin' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { $found = Get-Command 'upscayl-bin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($found -and $found.Source) { $candidates += $found.Source }
    return $candidates
}

function Resolve-UpscaylBinary {
    param($Config)
    if ($Config.upscayl_bin) {
        $configured = Expand-HomePath ([string]$Config.upscayl_bin)
        if (Test-Path -LiteralPath $configured -PathType Container) {
            $configured = Join-Path $configured 'upscayl-bin.exe'
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) { return [IO.Path]::GetFullPath($configured) }
        throw [PipelineException]::new("Upscayl CLI not found: $configured", 'Set upscayl_bin in config.txt or pass --upscayl-bin.', 3)
    }
    foreach ($candidate in (Get-UpscaylBinaryCandidates)) {
        if (-not $candidate) { continue }
        $path = Expand-HomePath ([string]$candidate)
        if (Test-Path -LiteralPath $path -PathType Container) { $path = Join-Path $path 'upscayl-bin.exe' }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
    }
    throw [PipelineException]::new('Upscayl CLI not found.', 'Install Upscayl or set upscayl_bin in config.txt / --upscayl-bin.', 3)
}

function Resolve-ModelsDirectory {
    param($Config, [string]$Binary)
    $candidates = @()
    if ($Config.models_dir) { $candidates += [string]$Config.models_dir }
    if ($env:UPSCAYL_MODELS) { $candidates += $env:UPSCAYL_MODELS }
    $binaryParent = Split-Path -Parent $Binary
    $binaryRoot = Split-Path -Parent $binaryParent
    $candidates += (Join-Path $binaryRoot 'models')
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    $candidates += (Join-Path $programFiles 'Upscayl\resources\models')
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Upscayl\resources\models')
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $path = Expand-HomePath ([string]$candidate)
        if (Test-Path -LiteralPath $path -PathType Container) { return [IO.Path]::GetFullPath($path) }
    }
    throw [PipelineException]::new('Upscayl models directory not found.', 'Set models_dir in config.txt or pass --models-dir.', 3)
}

function Get-UpscaylPaths {
    param($Config)
    $binary = Resolve-UpscaylBinary $Config
    $models = Resolve-ModelsDirectory $Config $binary
    $null = Get-ModelList $models
    return @{ binary = $binary; models_dir = $models }
}

function Get-VramMb {
    $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($smi -and $smi.Source) {
        try {
            $result = Invoke-Child -Arguments @($smi.Source, '--query-gpu=memory.total', '--format=csv,noheader,nounits') -NoCheck
        } catch {
            $result = $null
        }
        if ($result -and $result.ExitCode -eq 0) {
            foreach ($line in ($result.StdOut -split "`r?`n")) {
                $parsed = 0
                if ([int]::TryParse($line.Trim(), [ref]$parsed)) { return $parsed }
            }
        }
    }
    $wmic = Get-Command 'wmic' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wmic -and $wmic.Source) {
        try {
            $result = Invoke-Child -Arguments @($wmic.Source, 'path', 'win32_VideoController', 'get', 'AdapterRAM') -NoCheck
            if ($result.ExitCode -eq 0) {
                $values = @()
                foreach ($line in ($result.StdOut -split "`r?`n")) {
                    $parsed = [int64]0
                    if ([int64]::TryParse($line.Trim(), [ref]$parsed)) { $values += $parsed }
                }
                if ($values.Count -gt 0) {
                    return [int](($values | Measure-Object -Maximum).Maximum / (1024 * 1024))
                }
            }
        } catch {
        }
    }
    return $null
}

function Resolve-Tile {
    param([string]$Requested, $VramMb)
    $value = ([string]$Requested).Trim().ToLowerInvariant()
    if ($value -eq 'auto') {
        if ($null -eq $VramMb) { return 256 }
        if ($VramMb -le 4096) { return 128 }
        if ($VramMb -le 8192) { return 256 }
        return 512
    }
    $tile = 0
    if (-not [int]::TryParse($value, [ref]$tile)) {
        throw [PipelineException]::new("Invalid tile size: $Requested", $null, 4)
    }
    if ($tile -lt 32) {
        throw [PipelineException]::new('Tile size must be at least 32', $null, 4)
    }
    return $tile
}

function Resolve-BatchSize {
    param([int]$Requested, [int]$FrameWidth, [int]$FrameHeight)
    if ($Requested -gt 0) { return $Requested }
    if (([int64]$FrameWidth * $FrameHeight) -gt 8000000) { return 50 }
    return 100
}

function Invoke-UpscaylSmoke {
    param($Paths, [string]$Model, [int]$Tile, $Icd, [string]$Ffmpeg, $Logger = $null)
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('upscayl-smoke-' + [guid]::NewGuid().ToString('n'))
    $source = Join-Path $tempDir 'in'
    $target = Join-Path $tempDir 'out'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    try {
        try {
            $make = Invoke-Child -Arguments @($Ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=gray:s=64x64', '-frames:v', '1', (Join-Path $source 'test.png')) -NoCheck
            if ($make.ExitCode -ne 0) {
                return @{ ok = $false; detail = ('test PNG failed: ' + (Get-TextTail $make.StdErr 5)) }
            }
        } catch {
            return @{ ok = $false; detail = ('test PNG failed: ' + (Get-PipelineException $_).Message) }
        }
        $envMap = $null
        if ($Icd) { $envMap = @{ 'VK_ICD_FILENAMES' = [string]$Icd } }
        $arguments = @(
            $Paths.binary, '-i', $source, '-o', $target, '-m', $Paths.models_dir,
            '-n', $Model, '-s', '2', '-g', '0', '-t', [string]$Tile, '-f', 'png', '-c', '0'
        )
        try {
            $null = Invoke-Child -Arguments $arguments -Environment $envMap -WorkingDirectory (Split-Path -Parent $Paths.binary)
        } catch {
            $ex = Get-PipelineException $_
            return @{ ok = $false; detail = $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length)) }
        }
        $output = Join-Path $target 'test.png'
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -le 0) {
            return @{ ok = $false; detail = 'Upscayl produced no output file' }
        }
        return @{ ok = $true; detail = 'OK' }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-MissingIndices {
    param([string]$SourceDir, [string]$OutputDir, [int]$Total)
    $source = Get-FrameGroups $SourceDir
    $output = Get-FrameGroups $OutputDir
    $missing = @()
    for ($index = 1; $index -le $Total; $index++) {
        $hasSource = $false
        if ($source.ContainsKey($index)) {
            foreach ($file in $source[$index]) {
                if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $hasSource = $true; break }
            }
        }
        if (-not $hasSource) { continue }
        $hasOutput = $false
        if ($output.ContainsKey($index)) {
            foreach ($file in $output[$index]) {
                if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $hasOutput = $true; break }
            }
        }
        if (-not $hasOutput) { $missing += $index }
    }
    return $missing
}

function Get-SourceFrameForIndex {
    param([string]$SourceDir, [int]$Index)
    $groups = Get-FrameGroups $SourceDir
    if (-not $groups.ContainsKey($Index)) { return $null }
    foreach ($file in $groups[$Index]) {
        if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { return $file.FullName }
    }
    return $null
}

function Find-OutputForStem {
    param([string]$OutputDir, [string]$Stem)
    foreach ($file in @(Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue)) {
        if ($file.BaseName -eq $Stem -and $file.Length -gt 0) { return $file.FullName }
    }
    return $null
}

function Link-OrCopy {
    param([string]$Source, [string]$Target)
    try {
        New-Item -ItemType HardLink -Path $Target -Target $Source -Force | Out-Null
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
}

function New-ProgressState {
    param([string]$Label, [int]$Total)
    return @{ label = $Label; total = $Total; done = 0; started = [DateTime]::UtcNow }
}

function Get-ProgressLine {
    param($Progress)
    $elapsed = [math]::Max(0.0, ([DateTime]::UtcNow - $Progress.started).TotalSeconds)
    $rate = if ($elapsed -gt 0) { $Progress.done / $elapsed } else { 0.0 }
    $eta = if ($rate -gt 0) { [math]::Max(0.0, ($Progress.total - $Progress.done) / $rate) } else { 0.0 }
    $percent = if ($Progress.total -gt 0) { $Progress.done / $Progress.total * 100.0 } else { 100.0 }
    $etaSeconds = [int][math]::Round($eta)
    $hours = [math]::Floor($etaSeconds / 3600)
    $minutes = [math]::Floor(($etaSeconds % 3600) / 60)
    $seconds = $etaSeconds % 60
    return ('{0}: {1}/{2} ({3:0.0}%) {4:0.00}/s ETA {5:00}:{6:00}:{7:00}' -f $Progress.label, $Progress.done, $Progress.total, $percent, $rate, $hours, $minutes, $seconds)
}

function Get-ProgressEta {
    param($Progress)
    $elapsed = [math]::Max(0.0, ([DateTime]::UtcNow - $Progress.started).TotalSeconds)
    if ($elapsed -le 0) { return 0.0 }
    $rate = $Progress.done / $elapsed
    if ($rate -le 0) { return 0.0 }
    return [math]::Max(0.0, ($Progress.total - $Progress.done) / $rate)
}

function Invoke-UpscaleFrames {
    param(
        $Job,
        $Paths,
        [string]$Model,
        [int]$Scale,
        [string]$OutputDir,
        [int]$Tile,
        [int]$BatchSize,
        [int]$Gpu,
        $Icd,
        [string]$Threads,
        [int]$Retry,
        $Logger = $null,
        $Progress = $null,
        [string]$SourceDir = $null,
        $TotalFrames = $null
    )
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    if (-not $SourceDir) { $SourceDir = Join-Path $Job.path 'frames' }
    $total = if ($null -ne $TotalFrames) { [int]$TotalFrames } else { Get-JobInt $Job 'frame_count' 0 }
    if ($total -le 0) {
        throw [PipelineException]::new("Job has no frame_count: $($Job.path)", $null, 4)
    }
    $batchSize = [math]::Max(1, [int]$BatchSize)
    $tile = [math]::Max(32, [int]$Tile)
    $attempt = 0
    $batchNumber = 1
    $etaWarned = $false
    $envMap = $null
    if ($Icd) { $envMap = @{ 'VK_ICD_FILENAMES' = [string]$Icd } }

    while ($true) {
        $missing = Get-MissingIndices -SourceDir $SourceDir -OutputDir $OutputDir -Total $total
        if ($missing.Count -eq 0) { break }
        $batch = @($missing | Select-Object -First $batchSize)
        $work = Join-Path $Job.path ('batch_{0:D4}' -f $batchNumber)
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        $incoming = Join-Path $work 'in'
        $outgoing = Join-Path $work 'out'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        New-Item -ItemType Directory -Path $outgoing -Force | Out-Null
        foreach ($index in $batch) {
            $source = Get-SourceFrameForIndex $SourceDir $index
            if (-not $source) {
                throw [PipelineException]::new("Missing source frame $('{0:D8}' -f $index) for job $($Job.path)", $null, 4)
            }
            Link-OrCopy $source (Join-Path $incoming ([IO.Path]::GetFileName($source)))
        }
        $arguments = @(
            $Paths.binary, '-i', $incoming, '-o', $outgoing, '-m', $Paths.models_dir,
            '-n', $Model, '-s', [string]$Scale, '-g', [string]$Gpu, '-t', [string]$tile,
            '-j', $Threads, '-f', 'png', '-c', '0'
        )
        try {
            $null = Invoke-Child -Arguments $arguments -Environment $envMap -WorkingDirectory (Split-Path -Parent $Paths.binary)
            $produced = @()
            foreach ($inputFile in @(Get-ChildItem -LiteralPath $incoming -File)) {
                $result = Find-OutputForStem $outgoing $inputFile.BaseName
                if (-not $result) {
                    throw [PipelineException]::new("Upscayl produced no output for $($inputFile.Name)", $null, 6)
                }
                $produced += $result
            }
            foreach ($result in $produced) {
                $target = Join-Path $OutputDir ([IO.Path]::GetFileName($result))
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                Move-Item -LiteralPath $result -Destination $target -Force
            }
        } catch {
            $ex = Get-PipelineException $_
            if ($attempt -lt $Retry) {
                $attempt++
                $tile = [math]::Max(64, [int][math]::Floor($tile / 2))
                $batchSize = [math]::Max(1, [int][math]::Floor($batchSize / 2))
                Write-Warn ("Upscayl batch failed; retrying with tile=$tile, batch=$batchSize")
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            $detail = $ex.Message
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
            throw [PipelineException]::new("Upscayl failed for job $([IO.Path]::GetFileName($Job.path))", $detail, 6)
        }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        $batchNumber++
        $attempt = 0
        if ($Progress) {
            $Progress.done = [math]::Min($Progress.total, $Progress.done + $batch.Count)
            Write-Info (Get-ProgressLine $Progress)
            $eta = Get-ProgressEta $Progress
            if (-not $etaWarned -and $eta -gt 12 * 3600) {
                $etaWarned = $true
                Write-Warn 'Estimated upscale time exceeds 12 hours; use a faster model (upscayl-lite-4x) or process the video in chunks.'
            } elseif (-not $etaWarned -and $eta -gt 3600) {
                $etaWarned = $true
                Write-Warn ('Estimated upscale time is ' + ($eta / 3600).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' hours.')
            }
        } else {
            Write-Info ('Upscaled batch of ' + $batch.Count + ' frames')
        }
    }

    $outputGroups = Get-FrameGroups $OutputDir
    $count = 0
    for ($index = 1; $index -le $total; $index++) {
        if (-not $outputGroups.ContainsKey($index)) { continue }
        foreach ($file in $outputGroups[$index]) {
            if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $count++; break }
        }
    }
    return $count
}

#endregion

#region Chunking

function Get-ChunkPlan {
    param([double]$Duration, [double]$Fps, [int]$ChunkSeconds)
    if ($ChunkSeconds -lt 10) {
        throw [PipelineException]::new('Chunk length must be at least 10 seconds', $null, 4)
    }
    if ($Duration -le 0 -or $Fps -le 0) { return @() }
    $totalFrames = [int](Round-HalfEven ($Duration * $Fps))
    $chunks = @()
    $start = 0.0
    $index = 1
    while ($start -lt $Duration - 1e-9) {
        $end = [math]::Min($Duration, $start + $ChunkSeconds)
        $startFrame = [int](Round-HalfEven ($start * $Fps)) + 1
        $endFrame = [int](Round-HalfEven ($end * $Fps))
        $frameCount = $endFrame - $startFrame + 1
        if ($frameCount -gt 0) {
            $chunks += @{ index = $index; start = $start; end = $end; start_frame = $startFrame; frame_count = $frameCount }
            $index++
        }
        $start = $end
    }
    $sum = 0
    foreach ($chunk in $chunks) { $sum += $chunk.frame_count }
    if ($sum -ne $totalFrames) {
        throw [PipelineException]::new('Internal chunk frame accounting mismatch', $null, 4)
    }
    return $chunks
}

function Write-ConcatList {
    param([string[]]$Segments, [string]$Path)
    $lines = @()
    foreach ($segment in $Segments) {
        $text = [IO.Path]::GetFullPath($segment).Replace("'", "'\''")
        $lines += ("file '" + $text + "'")
    }
    Write-TextAtomic $Path (($lines -join "`n") + "`n")
    return $Path
}

function Invoke-ConcatSegments {
    param([string]$Ffmpeg, [string[]]$Segments, [string]$Output, $Logger = $null)
    $listPath = [IO.Path]::ChangeExtension($Output, '.txt')
    $null = Write-ConcatList -Segments $Segments -Path $listPath
    $arguments = @(
        $Ffmpeg, '-hide_banner', '-nostdin', '-y', '-f', 'concat', '-safe', '0',
        '-i', $listPath, '-c', 'copy', '-fflags', '+genpts', $Output
    )
    try {
        Invoke-Child -Arguments $arguments | Out-Null
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new('Could not concatenate chunk segments.', $ex.Message, 7)
    }
}

#endregion

#region Pipeline orchestration

function Test-VideoFile {
    param([string]$Path)
    $extensions = @('.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.ts', '.m2ts', '.wmv', '.flv', '.mpg', '.mpeg', '.ogv')
    return ($extensions -contains ([IO.Path]::GetExtension($Path).ToLowerInvariant()))
}

function Test-SkipInputPath {
    param([string]$Path, [string]$WorkDir)
    $name = [IO.Path]::GetFileName($Path)
    if ($name.StartsWith('.')) { return $true }
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ($stem.ToLowerInvariant().EndsWith('_upscaled')) { return $true }
    if (Test-WithinPath $Path $WorkDir) { return $true }
    return $false
}

function Resolve-Inputs {
    param([string[]]$Arguments, $Config, [bool]$Recursive)
    $items = @($Arguments)
    if ($items.Count -eq 0) {
        $defaultInput = Join-Path $Config.tool_dir 'input'
        if (Test-Path -LiteralPath $defaultInput -PathType Container) {
            $items = @($defaultInput)
        } else {
            throw [PipelineException]::new('No input videos given.', 'Pass files/folders, or create an input/ folder next to the tool.', 2)
        }
    }

    $found = @()
    foreach ($raw in $items) {
        $text = [string]$raw
        $path = Expand-HomePath $text
        $candidates = @()
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $candidates = @(Get-Item -LiteralPath $path)
        } elseif (Test-Path -LiteralPath $path -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $path -File -Recurse:$Recursive -ErrorAction SilentlyContinue)
        } elseif ($text -match '[\*\?\[]') {
            $candidates = @(Get-ChildItem -Path $path -File -Recurse:$Recursive -ErrorAction SilentlyContinue)
        }
        foreach ($candidate in $candidates) {
            if ($candidate.PSIsContainer -ne $false) { continue }
            if (-not (Test-VideoFile $candidate.FullName)) { continue }
            if (Test-SkipInputPath $candidate.FullName $Config.work_dir) { continue }
            $found += [IO.Path]::GetFullPath($candidate.FullName)
        }
    }

    $unique = @($found | Sort-Object -Unique | Sort-Object { [IO.Path]::GetFileName($_).ToLowerInvariant() })
    if ($unique.Count -eq 0) {
        throw [PipelineException]::new('No supported video files found.', 'Supported: ' + (@('.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.ts', '.m2ts', '.wmv', '.flv', '.mpg', '.mpeg', '.ogv') -join ', '), 2)
    }
    return $unique
}

function Get-FpsOverride {
    param([string]$Value)
    $text = ([string]$Value).Trim()
    if ($text.Contains('/')) {
        $parts = $text.Split('/')
        if ($parts.Count -ne 2) { throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4) }
        $numerator = [int64]0
        $denominator = [int64]0
        if (-not [int64]::TryParse($parts[0], [ref]$numerator) -or -not [int64]::TryParse($parts[1], [ref]$denominator)) {
            throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4)
        }
        if ($numerator -le 0 -or $denominator -le 0) {
            throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4)
        }
        $a = $numerator
        $b = $denominator
        while ($b -ne 0) { $temp = $b; $b = $a % $b; $a = $temp }
        $fpsNum = [int64]($numerator / $a)
        $fpsDen = [int64]($denominator / $a)
        return @($fpsNum, $fpsDen)
    }
    $decimal = 0.0
    if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$decimal)) {
        throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4)
    }
    if ($decimal -le 0 -or [double]::IsNaN($decimal) -or [double]::IsInfinity($decimal)) {
        throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4)
    }
    $denominator = [int64]1
    $working = $text
    if ($working -match '[eE]') {
        $decimalValue = [decimal]$decimal
        $denominator = [int64]1000000
        $numerator = [int64][math]::Round($decimal * $denominator)
    } else {
        $dot = $working.IndexOf('.')
        if ($dot -ge 0) {
            $fraction = $working.Substring($dot + 1)
            $denominator = [int64][math]::Pow(10, $fraction.Length)
            $numerator = [int64][math]::Round($decimal * $denominator)
        } else {
            $numerator = [int64]$decimal
        }
    }
    if ($numerator -le 0 -or $denominator -le 0) {
        throw [PipelineException]::new("Invalid --fps value: $Value", $null, 4)
    }
    $a = $numerator
    $b = $denominator
    while ($b -ne 0) { $temp = $b; $b = $a % $b; $a = $temp }
    $fpsNum = [int64]($numerator / $a)
    $fpsDen = [int64]($denominator / $a)
    return @($fpsNum, $fpsDen)
}

function Test-JobHasFrames {
    param($Job)
    $groups = Get-FrameGroups (Join-Path $Job.path 'frames')
    foreach ($index in $groups.Keys) {
        foreach ($file in $groups[$index]) {
            if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { return $true }
        }
    }
    return $false
}

function Clear-SplitOutputs {
    param($Job)
    foreach ($name in @('frames', 'upscaled', 'sequence')) {
        $path = Join-Path $Job.path $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    foreach ($marker in @(Get-ChildItem -LiteralPath $Job.path -Filter '.done_*' -File -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $marker.FullName -Force
    }
    Set-JobValue $Job 'frame_count' 0
    Set-JobValue $Job 'upscaled_count' 0
    Save-Job $Job
}

function Get-SettingsDifferences {
    param($Job, $Media, [double]$Start, $End, $Options)
    $rangeEnd = if ($Options.end) { ([double]$End).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) } else { '' }
    $expected = [ordered]@{
        frame_format    = $Options.format.ToLowerInvariant()
        fps             = $Media.fps_rational
        range_start     = $Start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        range_end       = $rangeEnd
        denoise         = $Options.denoise
        tonemap         = $(if ($Options.tonemap) { '1' } else { '0' })
        png_compression = [string]$Options.png_compression
        jpeg_quality    = [string]$Options.jpeg_quality
    }
    $differences = @()
    foreach ($key in $expected.Keys) {
        if (-not $Job.data.Contains($key)) { continue }
        $existing = [string]$Job.data[$key]
        $value = [string]$expected[$key]
        $same = $false
        if (@('range_start', 'range_end') -contains $key) {
            $left = 0.0
            $right = 0.0
            $null = [double]::TryParse($existing, [ref]$left)
            $null = [double]::TryParse($value, [ref]$right)
            $same = ([math]::Abs($left - $right) -lt 0.001)
        } else {
            $same = ($existing -eq $value)
        }
        if (-not $same) { $differences += ($key + ': ' + $existing + ' -> ' + $value) }
    }
    return $differences
}

function Resolve-Scale {
    param($Media, $Options, $Job, $Config)
    $target = $Options.target_height
    if ($null -eq $target) {
        $rawTarget = Get-JobValue $Job 'target_height' $null
        if ($null -ne $rawTarget -and "$rawTarget" -ne '') { $target = [int]$rawTarget }
    }
    if ($null -ne $target -and ([int]$target % 2) -ne 0) { $target = [int]$target + 1 }
    $scale = $Options.scale
    if ($null -eq $scale) {
        $rawScale = Get-JobValue $Job 'scale' $null
        if ($null -ne $rawScale -and "$rawScale" -ne '') { $scale = [int]$rawScale }
    }
    if ($null -ne $target -and [int]$target -le $Media.height) {
        throw [PipelineException]::new("--target-height ($target) must be greater than the source height ($($Media.height))", $null, 4)
    }
    if ($null -eq $target) {
        if ($null -ne $scale) { return @([int]$scale, $null) }
        return @([int]$Config.default_scale, $null)
    }
    if ($null -ne $scale) {
        if ($Media.height * [int]$scale -lt [int]$target) {
            throw [PipelineException]::new("Scale ${scale}x gives $($Media.height * [int]$scale)px, below --target-height $target", $null, 4)
        }
        return @([int]$scale, [int]$target)
    }
    foreach ($candidate in @(2, 3, 4)) {
        if ($Media.height * $candidate -ge [int]$target) { return @($candidate, [int]$target) }
    }
    throw [PipelineException]::new("--target-height $target requires more than 4x from $($Media.height)px", $null, 4)
}

function Invoke-Split {
    param([string[]]$Inputs, $Config, $Options, $Logger, [bool]$DryRun = $false, [bool]$AssumeYes = $false)
    $jobs = @()
    foreach ($inputPath in $Inputs) {
        $source = [IO.Path]::GetFullPath($inputPath)
        $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $source -Logger $Logger
        if ($media.duration -le 0) {
            throw [PipelineException]::new("Could not determine a positive video duration: $source", $null, 4)
        }
        if ($Options.fps) {
            $fpsParts = Get-FpsOverride $Options.fps
            $media.fps_num = $fpsParts[0]
            $media.fps_den = $fpsParts[1]
            $media.fps_rational = ([string]$fpsParts[0] + '/' + [string]$fpsParts[1])
            $media.fps_decimal = [double]$fpsParts[0] / [double]$fpsParts[1]
            $media.fps_text = $media.fps_decimal.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        }

        $start = if ($Options.start) { Parse-TimeValue $Options.start } else { 0.0 }
        $end = if ($Options.end) { Parse-TimeValue $Options.end } else { $media.duration }
        if ($end -gt $media.duration + 0.001) {
            Write-Warn ("--end " + $end.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + "s exceeds source duration; clamping to " + $media.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + 's')
            $end = $media.duration
        }
        if ($start -ge $end) {
            throw [PipelineException]::new("--start ($($start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))s) must be before --end ($($end.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))s)", $null, 4)
        }
        $processedDuration = $end - $start

        $job = Find-OrCreateJob -WorkDir $Config.work_dir -Source $source -Logger $Logger -NoCreate:$DryRun
        $chunkMarkers = @(Get-ChildItem -LiteralPath $job.path -Filter '.done_chunk_*' -File -Force -ErrorAction SilentlyContinue)
        if ($chunkMarkers.Count -gt 0) {
            throw [PipelineException]::new("Job is chunked: $([IO.Path]::GetFileName($job.path))", 'Resume it with the run command, not split.', 4)
        }
        if (-not $DryRun) { Set-LogFile (Join-Path $job.path 'logs\split.log') }

        $hasFrames = Test-JobHasFrames $job
        if ($hasFrames -and (Test-JobSourceChanged $job) -and -not $Options.force) {
            throw [PipelineException]::new("Source changed since the job was created: $source", 'Use --force to rebuild the job.', 4)
        }
        if ($hasFrames -and -not $Options.force) {
            $differences = Get-SettingsDifferences -Job $job -Media $media -Start $start -End $end -Options $Options
            if ($differences.Count -gt 0) {
                throw [PipelineException]::new('Existing job was split with different settings.', ('Use --force to re-split. Differences: ' + ($differences -join '; ')), 4)
            }
        }
        if ($hasFrames -and $Options.force -and -not $DryRun) {
            if (-not $AssumeYes) {
                $answer = (Read-Host ("Clear existing frames for " + [IO.Path]::GetFileName($job.path) + '? [y/N]')).Trim().ToLowerInvariant()
                if (@('y', 'yes') -notcontains $answer) {
                    throw [PipelineException]::new('Aborted by user.', $null, 4)
                }
            }
            Clear-SplitOutputs $job
        }

        if ($null -ne $Options.target_height -and ([int]$Options.target_height % 2) -ne 0) {
            Write-Warn ("--target-height $($Options.target_height) is odd; rounding up to " + ([int]$Options.target_height + 1))
            $Options.target_height = [int]$Options.target_height + 1
        }
        $scaleInfo = Resolve-Scale -Media $media -Options $Options -Job $job -Config $Config
        $scale = $scaleInfo[0]
        $targetHeight = $scaleInfo[1]
        if ($media.hdr -and -not $Options.tonemap) {
            throw [PipelineException]::new('HDR source detected. Upscayl models are 8-bit SDR.', 'Re-run with --tonemap to convert HDR to SDR BT.709.', 4)
        }
        if (-not $media.hdr) {
            $pixFmt = $media.pix_fmt.ToLowerInvariant()
            if ($pixFmt.Contains('10') -or $pixFmt.Contains('12') -or $pixFmt.Contains('16')) {
                Write-Warn '10-bit SDR source: frames will be converted to 8-bit RGB for Upscayl.'
            }
        }
        if ($media.sample_aspect_ratio -and @('', '0:1', '1:1') -notcontains $media.sample_aspect_ratio) {
            Write-Warn ("Anamorphic source detected (SAR $($media.sample_aspect_ratio)); the output uses square pixels and may not preserve display aspect ratio.")
        }

        Update-JobFromMedia $job $media
        if ($Options.tonemap) {
            Set-JobValue $job 'color_primaries' 'bt709'
            Set-JobValue $job 'color_trc' 'bt709'
            Set-JobValue $job 'colorspace' 'bt709'
            Set-JobValue $job 'color_range' 'tv'
            Set-JobValue $job 'hdr' $false
        }
        Set-JobValue $job 'duration' $processedDuration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        Set-JobValue $job 'range_start' $start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        Set-JobValue $job 'range_end' $(if ($null -ne $Options.end) { $end.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) } else { '' })
        Set-JobValue $job 'scale' $scale
        Set-JobValue $job 'target_height' $(if ($null -ne $targetHeight) { $targetHeight } else { '' })
        Set-JobValue $job 'model' $Options.model
        Set-JobValue $job 'frame_format' $Options.format.ToLowerInvariant()
        Set-JobValue $job 'frame_pattern' (Get-FramePattern $Options.format)
        Set-JobValue $job 'chunk_seconds' 0
        Set-JobValue $job 'chunk_frames' 0
        Set-JobValue $job 'denoise' $Options.denoise
        Set-JobValue $job 'decode' $Options.decode
        Set-JobValue $job 'tonemap' $Options.tonemap
        Set-JobValue $job 'png_compression' $Options.png_compression
        Set-JobValue $job 'jpeg_quality' $Options.jpeg_quality
        if (-not $DryRun) { Save-Job $job }

        $expectedFrames = [int](Round-HalfEven ($processedDuration * $media.fps_decimal))
        $sampleBytes = Get-SampleFrameBytes -Source (Get-JobSourcePath $job) -Job $job -Media $media -Config $Config -Format $Options.format -Denoise $Options.denoise -Tonemap $Options.tonemap -Decode $Options.decode -Logger $Logger -Start $start -Duration $processedDuration
        $estimate = Get-DiskEstimate -SampleBytes $sampleBytes -FrameCount $expectedFrames -Scale $scale
        $estimate.free_bytes = Get-FreeBytes $Config.work_dir
        Write-Info ("Job " + [IO.Path]::GetFileName($job.path) + ': ' + (Format-Duration $processedDuration) + ', ' + $expectedFrames + ' frames, sample ' + (Format-Bytes $sampleBytes) + ', estimated ' + (Format-Bytes $estimate.total_bytes) + ', free ' + (Format-Bytes $estimate.free_bytes))
        Test-DiskEstimate -Estimate $estimate -Config $Config -Logger $Logger
        if ($DryRun) { continue }

        try {
            $count = Invoke-FrameExtraction -Job $job -Media $media -Config $Config -Format $Options.format -JpegQuality $Options.jpeg_quality -PngCompression $Options.png_compression -Denoise $Options.denoise -Tonemap $Options.tonemap -Decode $Options.decode -Start $start -End $end -Verify $Options.verify_frames -Logger $Logger
        } catch {
            $ex = Get-PipelineException $_
            if ($ex -is [PipelineException]) {
                Set-JobValue $job 'last_error' $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length))
                try { Save-Job $job } catch { }
            }
            throw
        }
        Set-JobValue $job 'frame_count' $count
        Set-JobValue $job 'upscaled_count' 0
        Set-JobValue $job 'last_error' ''
        Save-Job $job
        Set-JobMarker $job 'split'
        $jobs += $job
    }
    return $jobs
}

function Invoke-Upscale {
    param([object[]]$Jobs, $Config, $Options, $Logger, [bool]$DryRun = $false)
    $effective = @{}
    foreach ($key in $Config.Keys) { $effective[$key] = $Config[$key] }
    if ($Options.upscayl_bin) { $effective.upscayl_bin = $Options.upscayl_bin }
    if ($Options.models_dir) { $effective.models_dir = $Options.models_dir }
    $paths = Get-UpscaylPaths $effective
    $models = @(Get-ModelList $paths.models_dir)
    $names = @($models | ForEach-Object { $_.name })
    if ($names -notcontains $Options.model) {
        throw [PipelineException]::new("Upscayl model not found: $($Options.model)", ('Installed: ' + (($names | Sort-Object) -join ', ')), 4)
    }
    $tile = Resolve-Tile $Options.tile (Get-VramMb)
    $icd = Resolve-Icd $effective $Options.icd
    $results = @()
    foreach ($job in $Jobs) {
        $chunkMarkers = @(Get-ChildItem -LiteralPath $job.path -Filter '.done_chunk_*' -File -Force -ErrorAction SilentlyContinue)
        if ($chunkMarkers.Count -gt 0) {
            throw [PipelineException]::new("Job is chunked: $([IO.Path]::GetFileName($job.path))", 'Resume it with the run command.', 4)
        }
        $framesDir = Join-Path $job.path 'frames'
        if (-not (Test-Path -LiteralPath $framesDir -PathType Container)) {
            throw [PipelineException]::new("No frames found for job: $([IO.Path]::GetFileName($job.path))", 'Run split first.', 4)
        }
        $frameCount = Get-JobInt $job 'frame_count' 0
        if ($frameCount -le 0) {
            $frameFormat = Get-JobValue $job 'frame_format' 'png'
            $frameCount = Count-ContiguousFrames $framesDir $frameFormat
        }
        if ($frameCount -le 0) {
            throw [PipelineException]::new("Job has no frames: $([IO.Path]::GetFileName($job.path))", $null, 4)
        }
        $outputDir = if ($Options.upscaled_dir) { Resolve-AbsolutePath (Expand-HomePath $Options.upscaled_dir) } else { Join-Path $job.path 'upscaled' }
        $existing = $false
        if (Test-Path -LiteralPath $outputDir -PathType Container) {
            $existing = @(Get-ChildItem -LiteralPath $outputDir -File -ErrorAction SilentlyContinue).Count -gt 0
        }
        $modelChanged = ($(Get-JobValue $job 'model' '') -and (Get-JobValue $job 'model' '') -ne $Options.model)
        $scaleChanged = ((Get-JobInt $job 'scale' 0) -gt 0 -and (Get-JobInt $job 'scale' 0) -ne $Options.scale)
        if ($existing -and ($modelChanged -or $scaleChanged) -and -not $Options.force) {
            throw [PipelineException]::new('Existing upscaled frames use a different model or scale.', 'Use --force to clear them and upscale again.', 4)
        }
        if ($existing -and $Options.force -and ($modelChanged -or $scaleChanged)) {
            if (Test-Path -LiteralPath $outputDir) { Remove-Item -LiteralPath $outputDir -Recurse -Force }
            Clear-JobMarker $job 'upscale'
            Set-JobValue $job 'upscaled_count' 0
        }
        $width = Get-JobInt $job 'width' 1920
        $height = Get-JobInt $job 'height' 1080
        $batchSize = Resolve-BatchSize $Options.batch_size $width $height
        if ($DryRun) {
            Write-Info ("Would upscale " + [IO.Path]::GetFileName($job.path) + ": $frameCount frames with $($Options.model) at $($Options.scale)x, tile $tile, batch $batchSize")
            $results += $job
            continue
        }
        $progress = New-ProgressState 'upscale' $frameCount
        try {
            $count = Invoke-UpscaleFrames -Job $job -Paths $paths -Model $Options.model -Scale $Options.scale -OutputDir $outputDir -Tile $tile -BatchSize $batchSize -Gpu $Options.gpu -Icd $icd -Threads $Options.threads -Retry $Options.retry -Logger $Logger -Progress $progress
        } catch {
            $ex = Get-PipelineException $_
            if ($ex -is [PipelineException]) {
                Set-JobValue $job 'last_error' $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length))
                try { Save-Job $job } catch { }
            }
            throw
        }
        Set-JobValue $job 'model' $Options.model
        Set-JobValue $job 'scale' $Options.scale
        Set-JobValue $job 'tile' $tile
        Set-JobValue $job 'batch_size' $batchSize
        Set-JobValue $job 'upscaled_count' $count
        Set-JobValue $job 'upscaled_dir' $outputDir
        Set-JobValue $job 'last_error' ''
        Save-Job $job
        Set-JobMarker $job 'upscale'
        $results += $job
    }
    return $results
}

function Invoke-PrepareChunkJob {
    param([string]$Source, $Config, $Options, [int]$ChunkSeconds, $Logger)
    $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $Source -Logger $Logger
    if ($media.duration -le 0) {
        throw [PipelineException]::new("Could not determine video duration: $Source", $null, 4)
    }
    if ($Options.split.fps) {
        $fpsParts = Get-FpsOverride $Options.split.fps
        $media.fps_num = $fpsParts[0]
        $media.fps_den = $fpsParts[1]
        $media.fps_rational = ([string]$fpsParts[0] + '/' + [string]$fpsParts[1])
        $media.fps_decimal = [double]$fpsParts[0] / [double]$fpsParts[1]
        $media.fps_text = $media.fps_decimal.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    }
    $start = if ($Options.split.start) { Parse-TimeValue $Options.split.start } else { 0.0 }
    $end = if ($Options.split.end) { Parse-TimeValue $Options.split.end } else { $media.duration }
    $end = [math]::Min($end, $media.duration)
    if ($start -ge $end) {
        throw [PipelineException]::new('Trim range is empty', $null, 4)
    }
    $duration = $end - $start
    $job = Find-OrCreateJob -WorkDir $Config.work_dir -Source $Source -Logger $Logger
    Set-LogFile (Join-Path $job.path 'logs\run.log')
    if ($media.hdr -and -not $Options.split.tonemap) {
        throw [PipelineException]::new('HDR source detected. Upscayl models are 8-bit SDR.', 'Re-run with --tonemap to convert HDR to SDR BT.709.', 4)
    }
    Update-JobFromMedia $job $media
    if ($Options.split.tonemap) {
        Set-JobValue $job 'color_primaries' 'bt709'
        Set-JobValue $job 'color_trc' 'bt709'
        Set-JobValue $job 'colorspace' 'bt709'
        Set-JobValue $job 'color_range' 'tv'
        Set-JobValue $job 'hdr' $false
    }
    $scaleInfo = Resolve-Scale -Media $media -Options $Options.split -Job $job -Config $Config
    $scale = $scaleInfo[0]
    $target = $scaleInfo[1]
    $fps = if ($media.fps_decimal -gt 0) { $media.fps_decimal } else { 30.0 }
    $totalFrames = [int](Round-HalfEven ($duration * $fps))
    Set-JobValue $job 'duration' $duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $job 'range_start' $start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $job 'range_end' $(if ($Options.split.end) { $end.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) } else { '' })
    Set-JobValue $job 'scale' $scale
    Set-JobValue $job 'target_height' $(if ($null -ne $target) { $target } else { '' })
    Set-JobValue $job 'model' $Options.split.model
    Set-JobValue $job 'frame_format' $Options.split.format
    Set-JobValue $job 'frame_pattern' (Get-FramePattern $Options.split.format)
    Set-JobValue $job 'denoise' $Options.split.denoise
    Set-JobValue $job 'decode' $Options.split.decode
    Set-JobValue $job 'tonemap' $Options.split.tonemap
    Set-JobValue $job 'frame_count' $totalFrames
    Set-JobValue $job 'upscaled_count' 0
    Set-JobValue $job 'chunk_seconds' $ChunkSeconds
    Set-JobValue $job 'chunk_frames' ([int](Round-HalfEven ($ChunkSeconds * $fps)))
    Save-Job $job
    return @{ job = $job; media = $media; start = $start; end = $end; duration = $duration }
}

function Invoke-ChunkedRun {
    param([string]$Source, $Config, $Options, [int]$ChunkSeconds, $Logger)
    $prepared = Invoke-PrepareChunkJob -Source $Source -Config $Config -Options $Options -ChunkSeconds $ChunkSeconds -Logger $Logger
    $job = $prepared.job
    $media = $prepared.media
    $start = $prepared.start
    $duration = $prepared.duration
    $tempOutput = $null
    try {
        $preset = Resolve-Preset $Options.encode.preset
        $effective = @{}
        foreach ($key in $Config.Keys) { $effective[$key] = $Config[$key] }
        if ($Options.upscale.upscayl_bin) { $effective.upscayl_bin = $Options.upscale.upscayl_bin }
        if ($Options.upscale.models_dir) { $effective.models_dir = $Options.upscale.models_dir }
        $paths = Get-UpscaylPaths $effective
        $models = @(Get-ModelList $paths.models_dir)
        if (@($models | ForEach-Object { $_.name }) -notcontains $Options.upscale.model) {
            throw [PipelineException]::new("Upscayl model not found: $($Options.upscale.model)", $null, 4)
        }
        $tile = Resolve-Tile $Options.upscale.tile (Get-VramMb)
        $icd = Resolve-Icd $Config $Options.upscale.icd
        $chunks = @(Get-ChunkPlan -Duration $duration -Fps $(if ($media.fps_decimal -gt 0) { $media.fps_decimal } else { 30.0 }) -ChunkSeconds $ChunkSeconds)
        if ($chunks.Count -eq 0) {
            throw [PipelineException]::new('Chunk plan is empty', $null, 4)
        }
        $candidates = @(Get-EncoderCandidates $preset $Options.encode.encoder $Config.ffmpeg)
        $audioMode = if ($Options.encode.audio) { $Options.encode.audio } elseif ($Config.default_audio -ne 'auto') { $Config.default_audio } else { $preset.default_audio }
        $subsMode = if ($Options.encode.subs) { $Options.encode.subs } elseif ($Config.default_subs -ne 'auto') { $Config.default_subs } else { $preset.default_subs }
        $audioPlan = Get-AudioPlan -Media $media -Preset $preset -Mode $audioMode -Bitrate $Options.encode.audio_bitrate -AllAudio $Options.encode.all_audio
        if ($start -gt 0) {
            $newStreams = @()
            foreach ($stream in $audioPlan.streams) {
                if ($stream.mode -eq 'copy') { $newStreams += @{ source_index = $stream.source_index; mode = 'aac' } }
                else { $newStreams += $stream }
            }
            $audioPlan = @{ streams = $newStreams; enabled = $audioPlan.enabled }
        }
        $subtitlePlan = Get-SubtitlePlan -Media $media -Preset $preset -Mode $subsMode -Logger $Logger
        $finalOutput = Resolve-OutputPath -Job $job -Extension $preset.extension -Options $Options.encode -MultipleJobs $false
        $tempOutput = Join-Path (Split-Path -Parent $finalOutput) ([IO.Path]::GetFileNameWithoutExtension($finalOutput) + '.partial' + [IO.Path]::GetExtension($finalOutput))
        $outputParent = Split-Path -Parent $finalOutput
        if (-not (Test-Path -LiteralPath $outputParent)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
        $progress = New-ProgressState 'upscale' (Get-JobInt $job 'frame_count' 0)
        $expectedWidth = 0
        $expectedHeight = 0
        $segments = @()
        $chunksDir = Join-Path $job.path 'chunks'
        foreach ($chunk in $chunks) {
            if ((Get-FreeBytes $Config.work_dir) -lt ([int64]$Config.min_free_gb * 1024 * 1024 * 1024)) {
                throw [PipelineException]::new('Free space fell below the configured minimum before a chunk.', $null, 5)
            }
            $extension = if ($preset.codec -eq 'prores') { 'mov' } else { 'ts' }
            $segment = Join-Path $chunksDir ('chunk_{0:D4}.{1}' -f $chunk.index, $extension)
            $marker = Join-Path $job.path ('.done_chunk_{0:D4}' -f $chunk.index)
            $segments += $segment
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-Path -LiteralPath $segment -PathType Leaf) -and (Get-Item -LiteralPath $segment).Length -gt 0) {
                $progress.done = [math]::Min($progress.total, $progress.done + $chunk.frame_count)
                continue
            }
            $chunkDir = Join-Path $chunksDir ('chunk_{0:D4}' -f $chunk.index)
            if (Test-Path -LiteralPath $chunkDir) { Remove-Item -LiteralPath $chunkDir -Recurse -Force }
            $framesDir = Join-Path $chunkDir 'frames'
            $upscaledDir = Join-Path $chunkDir 'upscaled'
            New-Item -ItemType Directory -Path $framesDir -Force | Out-Null
            $splitCommand = Get-SplitCommand -Source (Get-JobSourcePath $job) -Media $media -OutputDir $framesDir -Start ($start + $chunk.start) -Duration ($chunk.end - $chunk.start) -FirstFrame 1 -Format $Options.split.format -JpegQuality $Options.split.jpeg_quality -PngCompression $Options.split.png_compression -Denoise $Options.split.denoise -Tonemap $Options.split.tonemap -Decode $Options.split.decode -FrameLimit $chunk.frame_count
            $splitCommand[0] = $Config.ffmpeg
            Invoke-Child -Arguments $splitCommand | Out-Null
            $null = Validate-FrameSet -Directory $framesDir -Expected $chunk.frame_count
            $batchWidth = (Get-JobInt $job 'width' 1920) * $(if ((Get-JobInt $job 'scale' 0) -gt 0) { Get-JobInt $job 'scale' 0 } else { $Options.upscale.scale })
            $batchHeight = (Get-JobInt $job 'height' 1080) * $(if ((Get-JobInt $job 'scale' 0) -gt 0) { Get-JobInt $job 'scale' 0 } else { $Options.upscale.scale })
            $null = Invoke-UpscaleFrames -Job $job -Paths $paths -Model $Options.upscale.model -Scale $Options.upscale.scale -OutputDir $upscaledDir -Tile $tile -BatchSize (Resolve-BatchSize $Options.upscale.batch_size $batchWidth $batchHeight) -Gpu $Options.upscale.gpu -Icd $icd -Threads $Options.upscale.threads -Retry $Options.upscale.retry -Logger $Logger -Progress $progress -SourceDir $framesDir -TotalFrames $chunk.frame_count
            $frameSet = Validate-FrameSet -Directory $upscaledDir -Expected $chunk.frame_count
            $dims = Get-FirstFrameDimensions -Ffprobe $Config.ffprobe -Path $frameSet.paths[0] -Logger $Logger
            $frameWidth = [int]$dims[0]
            $frameHeight = [int]$dims[1]
            $targetHeight = if ($Options.encode.target_height) { $Options.encode.target_height } elseif ((Get-JobInt $job 'target_height' 0) -gt 0) { Get-JobInt $job 'target_height' 0 } else { $null }
            $outDims = Get-OutputDimensions -FrameWidth $frameWidth -FrameHeight $frameHeight -TargetHeight $targetHeight -AllowHuge $Options.encode.allow_huge
            $expectedWidth = [int]$outDims[0]
            $expectedHeight = [int]$outDims[1]
            $segmentOptions = @{}
            foreach ($optionKey in $Options.encode.Keys) { $segmentOptions[$optionKey] = $Options.encode[$optionKey] }
            $segmentOptions.target_height = $targetHeight
            $segmentError = $null
            foreach ($candidate in $candidates) {
                $command = Build-SegmentCommand -Job $job -FrameSet $frameSet -Media $media -Preset $preset -Encoder $candidate -Options $segmentOptions -Output $segment -FrameWidth $frameWidth -FrameHeight $frameHeight
                $command[0] = $Config.ffmpeg
                try {
                    Invoke-Child -Arguments $command | Out-Null
                    $segmentError = $null
                    break
                } catch {
                    $segmentError = Get-PipelineException $_
                }
            }
            if ($null -ne $segmentError) {
                throw [PipelineException]::new("Chunk $($chunk.index) encode failed", $segmentError.Message, 7)
            }
            $segmentInfo = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $segment -Logger $Logger
            if ($segmentInfo.duration -le 0) {
                throw [PipelineException]::new("Chunk $($chunk.index) segment is invalid", $null, 7)
            }
            [IO.File]::WriteAllText($marker, '', (New-Object System.Text.UTF8Encoding($false)))
            if (-not $Options.encode.keep_chunks) {
                Remove-Item -LiteralPath $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($expectedWidth -eq 0 -and $segments.Count -gt 0) {
            $firstSegment = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $segments[0] -Logger $Logger
            $expectedWidth = $firstSegment.width
            $expectedHeight = $firstSegment.height
        }
        $concatOutput = Join-Path $chunksDir $(if ($preset.codec -eq 'prores') { 'concat.mov' } else { 'concat.ts' })
        Invoke-ConcatSegments -Ffmpeg $Config.ffmpeg -Segments $segments -Output $concatOutput -Logger $Logger
        $mux = Build-MuxCommand -Job $job -Media $media -Preset $preset -AudioPlan $audioPlan -SubtitlePlan $subtitlePlan -Options $Options.encode -ConcatVideo $concatOutput -Output $tempOutput -Duration $duration
        $mux[0] = $Config.ffmpeg
        Invoke-Child -Arguments $mux | Out-Null
        Repair-ColorTags -Ffmpeg $Config.ffmpeg -Ffprobe $Config.ffprobe -Path $tempOutput -Container $preset.container -Logger $Logger
        Test-Output -Ffprobe $Config.ffprobe -Output $tempOutput -Job $job -Media $media -Options $Options.encode -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight -ExpectedAudio $audioPlan.enabled -ExpectedSubs $subtitlePlan.streams.Count -Logger $Logger
        Move-Item -LiteralPath $tempOutput -Destination $finalOutput -Force
        $tempOutput = $null
        if (-not $Options.encode.keep_chunks) {
            Remove-Item -LiteralPath $chunksDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-JobValue $job 'preset' $preset.name
        Set-JobValue $job 'encoder' $Options.encode.encoder
        Set-JobValue $job 'audio' $audioMode
        Set-JobValue $job 'subs' $subsMode
        Set-JobValue $job 'last_error' ''
        Save-Job $job
        Set-JobMarker $job 'assemble'
        if ($Options.cleanup) { Clear-Intermediates $job }
        return @{ input_path = $Source; job = $job; output = $finalOutput; error = $null }
    } catch {
        if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }
        $ex = Get-PipelineException $_
        $message = if ($ex -is [PipelineException]) { $ex.ToString() } else { $ex.Message }
        Set-JobValue $job 'last_error' $message.Substring(0, [math]::Min(500, $message.Length))
        try { Save-Job $job } catch { }
        return @{ input_path = $Source; job = $job; output = $null; error = $message }
    }
}

function Invoke-RunAll {
    param([string[]]$Inputs, $Config, $Options, $Logger)
    if ($Inputs.Count -gt 1 -and $Options.encode.output) {
        $requestedOutput = Resolve-AbsolutePath (Expand-HomePath ([string]$Options.encode.output))
        $treatAsDirectory = (Test-Path -LiteralPath $requestedOutput -PathType Container) -or ([IO.Path]::GetExtension($requestedOutput) -eq '')
        if (-not $treatAsDirectory) {
            throw [PipelineException]::new('With multiple inputs, --output must be a directory.', 'Pass a directory (or omit --output).', 2)
        }
    }
    $results = @()
    foreach ($inputPath in $Inputs) {
        $chunkValue = ([string]$Options.chunk_seconds).Trim().ToLowerInvariant()
        if (@('0', 'auto') -notcontains $chunkValue) {
            $chunkSeconds = 0
            if (-not [int]::TryParse($chunkValue, [ref]$chunkSeconds)) {
                throw [PipelineException]::new("Invalid --chunk-seconds: $chunkValue", $null, 4)
            }
            $result = Invoke-ChunkedRun -Source $inputPath -Config $Config -Options $Options -ChunkSeconds $chunkSeconds -Logger $Logger
            $results += $result
            if ($result.error -and $Options.stop_on_error) {
                throw [PipelineException]::new($result.error, $null, 4)
            }
            continue
        }
        $job = $null
        try {
            $job = @(Invoke-Split -Inputs @($inputPath) -Config $Config -Options $Options.split -Logger $Logger)[0]
            $null = Invoke-Upscale -Jobs @($job) -Config $Config -Options $Options.upscale -Logger $Logger
            $outputs = @(Invoke-Assemble -Jobs @($job) -Config $config -Options $Options.encode -Logger $Logger)
            $output = if ($outputs.Count -gt 0) { $outputs[0] } else { $null }
            if ($Options.cleanup) {
                Invoke-Clean -Jobs @($job) -Config $Config -Frames $false -Upscaled $false -Chunks $false -Sequence $false -Batch $false -IncludeOutput $false -AllIntermediates $true -DryRun $false -Logger $Logger
            }
            $results += @{ input_path = $inputPath; job = $job; output = $output; error = $null }
        } catch {
            $ex = Get-PipelineException $_
            $message = if ($ex -is [PipelineException]) { $ex.ToString() } else { $ex.Message }
            if ($env:UPSCAYL_V2_DEBUG -eq '1') {
                Write-Err ('STACK: ' + $_.ScriptStackTrace)
                Write-Err ('DETAIL: ' + $_ | Out-String)
            }
            $results += @{ input_path = $inputPath; job = $job; output = $null; error = $message }
            if ($Options.stop_on_error) { throw }
        }
    }
    Write-Info (('{0,-32} {1,-8} {2}' -f 'INPUT', 'STATUS', 'OUTPUT'))
    foreach ($result in $results) {
        $status = if ($null -eq $result.error) { 'OK' } else { 'FAILED' }
        $outputText = if ($result.output) { [string]$result.output } elseif ($result.error) { $result.error } else { '-' }
        $name = [IO.Path]::GetFileName([string]$result.input_path)
        if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
        Write-Info (('{0,-32} {1,-8} {2}' -f $name, $status, $outputText))
    }
    return $results
}

function Resolve-Jobs {
    param([string[]]$Arguments, $Config, [bool]$AllJobs)
    if ($AllJobs) {
        if ($Arguments.Count -gt 0) {
            throw [PipelineException]::new('Use either job folders or --all/--all-jobs, not both.', $null, 2)
        }
        $jobs = @(Find-Jobs $Config.work_dir)
        if ($jobs.Count -eq 0) {
            throw [PipelineException]::new("No jobs found in: $($Config.work_dir)", $null, 2)
        }
        return $jobs
    }
    if ($Arguments.Count -eq 0) {
        throw [PipelineException]::new('No job folders given.', 'Pass a job folder or use --all.', 2)
    }
    $jobs = @()
    $seen = @{}
    foreach ($raw in $Arguments) {
        $job = Open-Job (Resolve-AbsolutePath $raw)
        $key = [IO.Path]::GetFullPath($job.path).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $jobs += $job
        }
    }
    return @($jobs | Sort-Object { [IO.Path]::GetFileName($_.path).ToLowerInvariant() })
}

function Get-DefaultOutputPath {
    param($Job, [string]$Extension)
    $source = Get-JobSourcePath $Job
    return (Join-Path $Job.path ('output\' + [IO.Path]::GetFileNameWithoutExtension($source) + '_upscaled.' + $Extension))
}

function Get-CollisionPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    for ($index = 1; $index -lt 10000; $index++) {
        $candidate = Join-Path (Split-Path -Parent $Path) ([IO.Path]::GetFileNameWithoutExtension($Path) + '_' + $index + [IO.Path]::GetExtension($Path))
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw [PipelineException]::new("Could not find a free output name for: $Path", $null, 4)
}

function Test-OutputPath {
    param([string]$Path, $Job, [string]$Extension)
    $resolved = [IO.Path]::GetFullPath($Path)
    if ((Test-SamePath $resolved (Get-JobSourcePath $Job))) {
        throw [PipelineException]::new('Output path is the source video; refusing to overwrite it.', 'Choose a different --output path.', 4)
    }
    foreach ($name in @('frames', 'upscaled', 'sequence', 'chunks')) {
        $directory = Join-Path $Job.path $name
        if (Test-WithinPath $resolved $directory) {
            throw [PipelineException]::new("Output must not be inside the job's intermediate folder: $directory", $null, 4)
        }
    }
    $expectedSuffix = '.' + $Extension.ToLowerInvariant()
    if ([IO.Path]::GetExtension($resolved).ToLowerInvariant() -ne $expectedSuffix) {
        $suffix = [IO.Path]::GetExtension($resolved)
        if (-not $suffix) { $suffix = '(none)' }
        throw [PipelineException]::new("Output extension $suffix does not match preset extension $expectedSuffix", $null, 4)
    }
    return $resolved
}

function Resolve-OutputPath {
    param($Job, [string]$Extension, $Options, [bool]$MultipleJobs)
    $source = Get-JobSourcePath $Job
    $defaultName = [IO.Path]::GetFileNameWithoutExtension($source) + '_upscaled.' + $Extension
    $requested = $Options.output
    if (-not $requested) {
        $default = Get-DefaultOutputPath $Job $Extension
        $path = if ((Test-Path -LiteralPath $default) -and -not $Options.force) { Get-CollisionPath $default } else { $default }
        return (Test-OutputPath $path $Job $Extension)
    }
    $requestedPath = Resolve-AbsolutePath (Expand-HomePath ([string]$requested))
    if ((Test-Path -LiteralPath $requestedPath -PathType Leaf) -and -not [IO.Path]::GetExtension($requestedPath)) {
        throw [PipelineException]::new("Output path is a file without a suffix, not a directory: $requestedPath", $null, 2)
    }
    $isDirectory = (Test-Path -LiteralPath $requestedPath -PathType Container) -or ([IO.Path]::GetExtension($requestedPath) -eq '')
    if ($MultipleJobs -and -not $isDirectory) {
        throw [PipelineException]::new('With multiple jobs, --output must be a directory.', 'Pass a directory (or omit --output).', 2)
    }
    if ($isDirectory) {
        $path = Join-Path $requestedPath $defaultName
        $path = if ((Test-Path -LiteralPath $path) -and -not $Options.force) { Get-CollisionPath $path } else { $path }
        return (Test-OutputPath $path $Job $Extension)
    }
    if ((Test-Path -LiteralPath $requestedPath) -and -not $Options.force) {
        throw [PipelineException]::new("Output already exists: $requestedPath", 'Use --force to overwrite it.', 4)
    }
    return (Test-OutputPath $requestedPath $Job $Extension)
}

function Clear-Intermediates {
    param($Job)
    foreach ($name in @('frames', 'upscaled', 'sequence', 'chunks')) {
        $path = Join-Path $Job.path $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    foreach ($batch in @(Get-ChildItem -LiteralPath $Job.path -Directory -Filter 'batch_*' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $batch.FullName -Recurse -Force
    }
}

function Invoke-Assemble {
    param([object[]]$Jobs, $Config, $Options, $Logger, [bool]$DryRun = $false)
    $preset = Resolve-Preset $Options.preset
    $outputs = @()
    $multiple = $Jobs.Count -gt 1
    foreach ($job in $Jobs) {
        $tempOutput = $null
        try {
            $jobOptions = @{}
            foreach ($key in $Options.Keys) { $jobOptions[$key] = $Options[$key] }
            if ($null -eq $jobOptions.target_height) {
                $storedTarget = Get-JobInt $job 'target_height' 0
                if ($storedTarget -gt 0) { $jobOptions.target_height = $storedTarget }
            }
            if ($jobOptions.ten_bit -and (Get-JobBool $job 'tonemap' $false)) {
                throw [PipelineException]::new('--10bit cannot be combined with a tonemapped job.', $null, 4)
            }
            if (-not $DryRun) { Set-LogFile (Join-Path $job.path 'logs\assemble.log') }
            if ((Test-JobSourceChanged $job) -and -not $Options.force) {
                throw [PipelineException]::new("Source changed since the job was created: $(Get-JobSourcePath $job)", 'Use --force only if the existing upscaled frames still match the source.', 4)
            }
            $chunkMarkers = @(Get-ChildItem -LiteralPath $job.path -Filter '.done_chunk_*' -File -Force -ErrorAction SilentlyContinue)
            if ($chunkMarkers.Count -gt 0) {
                throw [PipelineException]::new("Job is chunked: $([IO.Path]::GetFileName($job.path))", 'Resume it with the run command.', 4)
            }
            $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source (Get-JobSourcePath $job) -Logger $Logger
            $upscaledDir = if ($Options.upscaled_dir) {
                Resolve-AbsolutePath (Expand-HomePath $Options.upscaled_dir)
            } else {
                $stored = Get-JobValue $job 'upscaled_dir' ''
                if ($stored) { Resolve-AbsolutePath (Expand-HomePath $stored) } else { Join-Path $job.path 'upscaled' }
            }
            if (-not (Test-Path -LiteralPath $upscaledDir -PathType Container)) {
                throw [PipelineException]::new("No upscaled frames found: $upscaledDir", 'Run Upscayl on the frames folder first, or pass --upscaled-dir.', 4)
            }
            $rawFrames = Get-FrameGroups $upscaledDir -Recursive
            $hasAny = $false
            foreach ($index in $rawFrames.Keys) {
                foreach ($file in $rawFrames[$index]) {
                    if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $hasAny = $true; break }
                }
                if ($hasAny) { break }
            }
            if (-not $hasAny) {
                throw [PipelineException]::new("No upscaled frames found: $upscaledDir", 'Run Upscayl on the frames folder first, or pass --upscaled-dir.', 4)
            }

            $storedCount = Get-JobInt $job 'frame_count' 0
            $expectedArg = if ($storedCount -gt 0) { $storedCount } else { $null }
            $frameSet = Validate-FrameSet -Directory $upscaledDir -Expected $expectedArg -Pick $Options.pick -Verify:$Options.verify_frames
            $normalized = if ($DryRun) { $frameSet } else { Build-FrameSequence -FrameSet $frameSet -Job $job -Logger $Logger }
            $dims = Get-FirstFrameDimensions -Ffprobe $Config.ffprobe -Path $normalized.paths[0] -Logger $Logger
            $frameWidth = [int]$dims[0]
            $frameHeight = [int]$dims[1]
            $outDims = Get-OutputDimensions -FrameWidth $frameWidth -FrameHeight $frameHeight -TargetHeight $jobOptions.target_height -AllowHuge $jobOptions.allow_huge
            $expectedWidth = [int]$outDims[0]
            $expectedHeight = [int]$outDims[1]

            $audioMode = if ($Options.audio) { $Options.audio } elseif ($Config.default_audio -ne 'auto') { $Config.default_audio } else { $preset.default_audio }
            $subsMode = if ($Options.subs) { $Options.subs } elseif ($Config.default_subs -ne 'auto') { $Config.default_subs } else { $preset.default_subs }
            $audioPlan = Get-AudioPlan -Media $media -Preset $preset -Mode $audioMode -Bitrate $Options.audio_bitrate -AllAudio $Options.all_audio
            $rangeStart = ConvertTo-DoubleSafe (Get-JobValue $job 'range_start' 0.0) 0.0
            if ($rangeStart -gt 0) {
                $hasCopy = $false
                foreach ($stream in $audioPlan.streams) { if ($stream.mode -eq 'copy') { $hasCopy = $true } }
                if ($hasCopy) {
                    Write-Warn 'Trimming active: copied audio is re-encoded as AAC for a sample-accurate start.'
                    $newStreams = @()
                    foreach ($stream in $audioPlan.streams) {
                        if ($stream.mode -eq 'copy') { $newStreams += @{ source_index = $stream.source_index; mode = 'aac' } }
                        else { $newStreams += $stream }
                    }
                    $audioPlan = @{ streams = $newStreams; enabled = $audioPlan.enabled }
                }
                if ($media.chapters -gt 0) {
                    Write-Warn 'Chapters come from the source and may not be shifted for the trimmed range.'
                }
            }
            $subtitlePlan = Get-SubtitlePlan -Media $media -Preset $preset -Mode $subsMode -Logger $Logger
            $candidates = @(Get-EncoderCandidates $preset $Options.encoder $Config.ffmpeg)
            $finalOutput = Resolve-OutputPath -Job $job -Extension $preset.extension -Options $jobOptions -MultipleJobs $multiple

            if ($DryRun) {
                Write-Info ("Would assemble " + [IO.Path]::GetFileName($job.path) + ' -> ' + $finalOutput)
                $outputs += $finalOutput
                continue
            }

            $tempOutput = Join-Path (Split-Path -Parent $finalOutput) ([IO.Path]::GetFileNameWithoutExtension($finalOutput) + '.partial' + [IO.Path]::GetExtension($finalOutput))
            $outputParent = Split-Path -Parent $finalOutput
            try {
                if (-not (Test-Path -LiteralPath $outputParent)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
            } catch {
                throw [PipelineException]::new("Could not create output directory: $outputParent", $_.Exception.Message, 4)
            }
            Clear-JobMarker $job 'assemble'
            $lastError = $null
            for ($index = 0; $index -lt $candidates.Count; $index++) {
                $candidate = $candidates[$index]
                $command = Build-AssembleCommand -Job $job -FrameSet $normalized -Media $media -Preset $preset -Encoder $candidate -AudioPlan $audioPlan -SubtitlePlan $subtitlePlan -Options $jobOptions -Output $tempOutput -FrameWidth $frameWidth -FrameHeight $frameHeight
                $command[0] = $Config.ffmpeg
                try {
                    Invoke-Child -Arguments $command | Out-Null
                    $lastError = $null
                    break
                } catch {
                    $lastError = Get-PipelineException $_
                    if ($Options.encoder -eq 'auto' -and $index -lt $candidates.Count - 1) {
                        Write-Warn ("Encoder " + $candidate.video_codec + ' failed; trying the next encoder.')
                        continue
                    }
                    throw [PipelineException]::new("Encoding failed for: $(Get-JobSourcePath $job)", $lastError.Message, 7)
                }
            }
            if ($null -ne $lastError) {
                throw [PipelineException]::new("Encoding failed for: $(Get-JobSourcePath $job)", $lastError.Message, 7)
            }

            Repair-ColorTags -Ffmpeg $Config.ffmpeg -Ffprobe $Config.ffprobe -Path $tempOutput -Container $preset.container -Logger $Logger
            Test-Output -Ffprobe $Config.ffprobe -Output $tempOutput -Job $job -Media $media -Options $jobOptions -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight -ExpectedAudio $audioPlan.enabled -ExpectedSubs $subtitlePlan.streams.Count -Logger $Logger
            Move-Item -LiteralPath $tempOutput -Destination $finalOutput -Force
            $tempOutput = $null
            $sequence = Join-Path $job.path 'sequence'
            if (Test-Path -LiteralPath $sequence) { Remove-Item -LiteralPath $sequence -Recurse -Force -ErrorAction SilentlyContinue }
            Set-JobValue $job 'upscaled_count' $frameSet.count
            Set-JobValue $job 'preset' $preset.name
            Set-JobValue $job 'encoder' $Options.encoder
            Set-JobValue $job 'encoder_codec' $candidate.video_codec
            Set-JobValue $job 'audio' $audioMode
            Set-JobValue $job 'audio_bitrate' $Options.audio_bitrate
            Set-JobValue $job 'all_audio' $Options.all_audio
            Set-JobValue $job 'subs' $subsMode
            Set-JobValue $job 'ten_bit' $Options.ten_bit
            Set-JobValue $job 'target_height' $(if ($jobOptions.target_height) { $jobOptions.target_height } else { '' })
            Set-JobValue $job 'last_error' ''
            Save-Job $job
            Set-JobMarker $job 'assemble'
            if ($Options.cleanup) { Clear-Intermediates $job }
            $outputs += $finalOutput
        } catch {
            if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
                Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
            }
            $ex = Get-PipelineException $_
            $message = if ($ex -is [PipelineException]) { $ex.Message } else { $ex.Message }
            Set-JobValue $job 'last_error' $message.Substring(0, [math]::Min(500, $message.Length))
            try { Save-Job $job } catch { }
            throw
        }
    }
    return $outputs
}

function Invoke-Status {
    param($Config, $Logger, [bool]$VerboseOutput = $false)
    $jobs = @(Find-Jobs $Config.work_dir)
    if ($jobs.Count -eq 0) {
        Write-Info ("No jobs found in: " + $Config.work_dir)
        return
    }
    Write-Info (('{0,-24} {1,-10} {2,7} {3,9}  {4}' -f 'JOB', 'STAGE', 'FRAMES', 'UPSCALED', 'OUTPUT'))
    foreach ($job in $jobs) {
        $frameFormat = Get-JobValue $job 'frame_format' 'png'
        $frames = Count-ContiguousFrames (Join-Path $job.path 'frames') $frameFormat
        $upscaled = 0
        $groups = Get-FrameGroups (Join-Path $job.path 'upscaled') -Recursive
        foreach ($index in $groups.Keys) {
            foreach ($file in $groups[$index]) {
                if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $upscaled++ }
            }
        }
        $outputDir = Join-Path $job.path 'output'
        $outputs = @()
        if (Test-Path -LiteralPath $outputDir -PathType Container) {
            $outputs = @(Get-ChildItem -LiteralPath $outputDir -File | Sort-Object Name)
        }
        $outputText = '-'
        if ($outputs.Count -gt 0) {
            $outputText = $outputs[0].Name + ' (' + (Format-Bytes $outputs[0].Length) + ')'
        }
        if ((Test-JobMarker $job 'assemble') -and $outputs.Count -gt 0) {
            $stage = 'done'
        } elseif (Get-JobValue $job 'last_error' '') {
            $stage = 'failed'
        } elseif (@(Get-ChildItem -LiteralPath $job.path -Filter '.done_chunk_*' -File -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $stage = 'chunk'
        } elseif ($upscaled -gt 0) {
            $stage = 'assemble'
        } elseif ($frames -gt 0) {
            $stage = 'upscale'
        } elseif (Test-JobMarker $job 'split') {
            $stage = 'split'
        } else {
            $stage = 'empty'
        }
        $jobId = [IO.Path]::GetFileName($job.path)
        if ($jobId.Length -gt 24) { $jobId = $jobId.Substring(0, 24) }
        Write-Info (('{0,-24} {1,-10} {2,7} {3,9}  {4}' -f $jobId, $stage, $frames, $upscaled, $outputText))
        if ($VerboseOutput) {
            Write-Info ('  path: ' + $job.path)
            Write-Info ('  source: ' + (Get-JobSourcePath $job))
            $settings = @()
            foreach ($key in @('scale', 'target_height', 'model', 'frame_format', 'decode', 'preset')) {
                $value = Get-JobValue $job $key ''
                if ($value) { $settings += ($key + '=' + $value) }
            }
            Write-Info ('  settings: ' + ($settings -join ', '))
        }
    }
}

function Invoke-Clean {
    param(
        [object[]]$Jobs,
        $Config,
        [bool]$Frames,
        [bool]$Upscaled,
        [bool]$Chunks,
        [bool]$Sequence,
        [bool]$Batch,
        [bool]$IncludeOutput,
        [bool]$AllIntermediates,
        [bool]$DryRun,
        $Logger
    )
    foreach ($job in $Jobs) {
        $null = Ensure-WithinPath $job.path $Config.work_dir
        if (-not (Test-Path -LiteralPath (Join-Path $job.path 'job.txt') -PathType Leaf)) {
            throw [PipelineException]::new("Not a job folder: $($job.path)", $null, 4)
        }
        $targets = @{}
        if ($AllIntermediates) {
            $Frames = $true; $Upscaled = $true; $Chunks = $true; $Sequence = $true; $Batch = $true
        }
        if ($Frames) { $targets[(Join-Path $job.path 'frames')] = $true }
        if ($Upscaled) { $targets[(Join-Path $job.path 'upscaled')] = $true }
        if ($Chunks) { $targets[(Join-Path $job.path 'chunks')] = $true }
        if ($Sequence) { $targets[(Join-Path $job.path 'sequence')] = $true }
        if ($Batch) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $job.path -Directory -Filter 'batch_*' -ErrorAction SilentlyContinue)) {
                $targets[$directory.FullName] = $true
            }
        }
        if ($IncludeOutput) { $targets[(Join-Path $job.path 'output')] = $true }

        $source = [IO.Path]::GetFullPath((Get-JobSourcePath $job))
        foreach ($target in @($targets.Keys | Sort-Object)) {
            $resolvedTarget = Ensure-WithinPath $target $job.path
            if ((Test-SamePath $source $resolvedTarget) -or (Test-WithinPath $source $resolvedTarget)) {
                throw [PipelineException]::new("Refusing to delete a folder that contains the source video: $resolvedTarget", $null, 4)
            }
            if (-not (Test-Path -LiteralPath $resolvedTarget)) { continue }
            if ($DryRun) {
                Write-Info ('Would delete: ' + $resolvedTarget)
                continue
            }
            Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
            Write-Info ('Deleted: ' + $resolvedTarget)
        }

        if (-not $DryRun) {
            if ($Frames) { Clear-JobMarker $job 'split' }
            if ($Upscaled) { Clear-JobMarker $job 'upscale' }
            if ($IncludeOutput) { Clear-JobMarker $job 'assemble' }
        }
    }
}

#endregion

#region Doctor

function Get-FirstLine {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim()) { return $line.Trim() }
    }
    return ''
}

function New-CheckResult {
    param([string]$Name, [string]$Status, [string]$Detail)
    return @{ name = $Name; status = $Status; detail = $Detail }
}

function Test-FfmpegDoctor {
    param($Config, $Logger)
    $results = @()
    foreach ($pair in @(@('ffmpeg', $Config.ffmpeg, 'ffmpeg version'), @('ffprobe', $Config.ffprobe, 'ffprobe version'))) {
        $name = $pair[0]
        $path = $pair[1]
        $marker = $pair[2]
        $result = Invoke-Child -Arguments @($path, '-version') -NoCheck
        $first = Get-FirstLine $result.StdOut
        if ($result.ExitCode -ne 0 -or -not $first.ToLowerInvariant().Contains($marker)) {
            $detail = if ($first) { $first } elseif (Get-FirstLine $result.StdErr) { Get-FirstLine $result.StdErr } else { 'exit code ' + $result.ExitCode }
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) }
            $results += (New-CheckResult $name 'FAIL' $detail)
        } else {
            $detail = if ($first.Length -gt 160) { $first.Substring(0, 160) } else { $first }
            $results += (New-CheckResult $name 'OK' $detail)
        }
    }
    $filters = Invoke-Child -Arguments @($Config.ffmpeg, '-hide_banner', '-filters') -NoCheck
    if ($filters.ExitCode -eq 0) {
        if ($filters.StdOut.Contains('zscale')) {
            $results += (New-CheckResult 'zscale' 'OK' 'available for --tonemap')
        } else {
            $results += (New-CheckResult 'zscale' 'WARN' 'missing; --tonemap is unavailable')
        }
    } else {
        $results += (New-CheckResult 'zscale' 'WARN' 'could not inspect filters')
    }
    $results += (New-CheckResult 'glob' 'INFO' 'not required by this pipeline')
    return $results
}

function Test-EncodersDoctor {
    param($Config, $Logger)
    $available = Get-AvailableEncoders $Config.ffmpeg
    if ($available.Count -eq 0) {
        return @(New-CheckResult 'encoders' 'FAIL' 'no encoders reported')
    }
    $results = @()
    $required = [ordered]@{ libx264 = 'required H.264 fallback' }
    $presetSpecific = [ordered]@{ libx265 = 'required for HEVC presets'; prores_ks = 'required for mov-prores' }
    $optional = [ordered]@{ h264_nvenc = 'NVIDIA H.264'; hevc_nvenc = 'NVIDIA HEVC'; h264_amf = 'AMD H.264'; hevc_amf = 'AMD HEVC' }
    foreach ($name in $required.Keys) {
        if ($available.ContainsKey($name)) { $results += (New-CheckResult $name 'OK' $required[$name]) }
        else { $results += (New-CheckResult $name 'FAIL' ('missing: ' + $required[$name])) }
    }
    foreach ($name in $presetSpecific.Keys) {
        if ($available.ContainsKey($name)) { $results += (New-CheckResult $name 'OK' $presetSpecific[$name]) }
        else { $results += (New-CheckResult $name 'WARN' ('missing: ' + $presetSpecific[$name])) }
    }
    foreach ($name in $optional.Keys) {
        if ($available.ContainsKey($name)) { $results += (New-CheckResult $name 'OK' $optional[$name]) }
        else { $results += (New-CheckResult $name 'WARN' ('missing: ' + $optional[$name])) }
    }
    return $results
}

function Test-EncoderSmokeDoctor {
    param($Config, $Logger)
    $available = Get-AvailableEncoders $Config.ffmpeg
    $results = @()
    foreach ($name in @('libx264', 'libx265', 'prores_ks', 'h264_nvenc', 'hevc_nvenc', 'h264_amf', 'hevc_amf')) {
        if (-not $available.ContainsKey($name)) { continue }
        $command = @(
            $Config.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', 'color=c=gray:s=256x256', '-frames:v', '1',
            '-c:v', $name, '-f', 'null', '-'
        )
        $result = Invoke-Child -Arguments $command -NoCheck
        if ($result.ExitCode -eq 0) {
            $results += (New-CheckResult ('smoke_' + $name) 'OK' '1-frame encode')
        } else {
            $detail = Get-FirstLine $result.StdErr
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) }
            $results += (New-CheckResult ('smoke_' + $name) 'FAIL' $detail)
        }
    }
    return $results
}

function Test-WorkDirDoctor {
    param($Config, $WorkDir, $Logger)
    $path = if ($WorkDir) { Resolve-AbsolutePath $WorkDir } else { $Config.work_dir }
    try {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $probe = Join-Path $path ('.doctor-' + $PID + '.tmp')
        [IO.File]::WriteAllText($probe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $probe -Force
    } catch {
        return @(New-CheckResult 'work_dir' 'FAIL' ('not writable: ' + $_.Exception.Message))
    }
    $free = Get-FreeBytes $path
    if ($free -lt ([int64]$Config.min_free_gb * 1024 * 1024 * 1024)) {
        return @(New-CheckResult 'work_dir' 'FAIL' ((Format-Bytes $free) + ' free, need ' + $Config.min_free_gb + ' GiB'))
    }
    return @(New-CheckResult 'work_dir' 'OK' ((Format-Bytes $free) + ' free'))
}

function Test-UpscaylDoctor {
    param($Config, [bool]$SkipSmoke, $Logger)
    try {
        $paths = Get-UpscaylPaths $Config
    } catch {
        $ex = Get-PipelineException $_
        return @(New-CheckResult 'upscayl' 'WARN' $ex.Message)
    }
    $results = @(
        (New-CheckResult 'upscayl' 'OK' $paths.binary),
        (New-CheckResult 'upscayl_models' 'OK' $paths.models_dir)
    )
    try {
        $models = @(Get-ModelList $paths.models_dir)
        $results += (New-CheckResult 'upscayl_models' 'OK' ($models.Count.ToString() + ' model(s)'))
    } catch {
        $results += (New-CheckResult 'upscayl_models' 'WARN' (Get-PipelineException $_).Message)
        return $results
    }
    if ($SkipSmoke) {
        $results += (New-CheckResult 'upscayl_smoke' 'OK' 'skipped')
        return $results
    }
    try {
        $icd = Resolve-Icd $Config $null
    } catch {
        $results += (New-CheckResult 'upscayl_icd' 'WARN' $_.Exception.Message)
        $icd = $null
    }
    $smoke = Invoke-UpscaylSmoke -Paths $paths -Model $models[0].name -Tile 128 -Icd $icd -Ffmpeg $Config.ffmpeg -Logger $Logger
    if (-not $smoke.ok -and -not $icd) {
        $nvidia = Find-NvidiaIcd
        if ($nvidia) {
            $retry = Invoke-UpscaylSmoke -Paths $paths -Model $models[0].name -Tile 128 -Icd $nvidia -Ffmpeg $Config.ffmpeg -Logger $Logger
            if ($retry.ok) {
                $results += (New-CheckResult 'upscayl_smoke' 'FAIL' 'fails with the default Vulkan ICD; forcing the NVIDIA ICD works. Set icd=<nv-vk64.json> or update the AMD driver.')
                return $results
            }
            $smoke = $retry
        }
    }
    $results += (New-CheckResult 'upscayl_smoke' $(if ($smoke.ok) { 'OK' } else { 'FAIL' }) $smoke.detail)
    return $results
}

function Invoke-Doctor {
    param($Config, $WorkDir, [bool]$SkipUpscaylSmoke, [bool]$VerboseOutput, $Logger)
    $results = @()
    $results += (Test-FfmpegDoctor $Config $Logger)
    $results += (Test-EncodersDoctor $Config $Logger)
    $results += (Test-EncoderSmokeDoctor $Config $Logger)
    $results += (Test-WorkDirDoctor $Config $WorkDir $Logger)
    $results += (Test-UpscaylDoctor $Config $SkipUpscaylSmoke $Logger)

    if ($VerboseOutput) {
        Write-Info ('config: ' + $Config.config_path)
        Write-Info ('ffmpeg: ' + $Config.ffmpeg)
        Write-Info ('ffprobe: ' + $Config.ffprobe)
    }
    Write-Info (('{0,-6} {1,-16} {2}' -f 'STATUS', 'NAME', 'DETAIL'))
    foreach ($result in $results) {
        Write-Info (('{0,-6} {1,-16} {2}' -f $result.status, $result.name, $result.detail))
    }
    $diskFailed = $false
    $upscaylFailed = $false
    $requiredFailed = $false
    foreach ($result in $results) {
        if ($result.name -eq 'work_dir' -and $result.status -eq 'FAIL') { $diskFailed = $true }
        if ($result.name.StartsWith('upscayl') -and $result.status -eq 'FAIL') { $upscaylFailed = $true }
        if ($result.status -eq 'FAIL') {
            if (@('ffmpeg', 'ffprobe', 'libx264') -contains $result.name) { $requiredFailed = $true }
            if ($result.name.StartsWith('smoke_')) { $requiredFailed = $true }
        }
    }
    if ($diskFailed) { return 5 }
    if ($requiredFailed) { return 3 }
    if ($upscaylFailed) { return 6 }
    return 0
}

#endregion

#region Menu

function Ask-Value {
    param([string]$Label, [string]$Default = '')
    $suffix = if ($Default) { ' [' + $Default + ']' } else { '' }
    $value = (Read-Host ($Label + $suffix)).Trim()
    if ($value) { return $value }
    return $Default
}

function Write-MenuError {
    param($ErrorRecord)
    $ex = Get-PipelineException $ErrorRecord
    if ($ex -is [PipelineException]) { [Console]::Out.WriteLine($ex.ToString()) }
    else { [Console]::Out.WriteLine($ex.Message) }
}

function Invoke-Menu {
    param($Config, $Logger)
    while ($true) {
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('Upscayl Video Pipeline')
        [Console]::Out.WriteLine('1) Run all (split + upscale + assemble)')
        [Console]::Out.WriteLine('2) Split video(s)')
        [Console]::Out.WriteLine('3) Upscale a job')
        [Console]::Out.WriteLine('4) Assemble a job')
        [Console]::Out.WriteLine('5) Status')
        [Console]::Out.WriteLine('6) Doctor')
        [Console]::Out.WriteLine('7) Clean a job')
        [Console]::Out.WriteLine('8) Settings')
        [Console]::Out.WriteLine('9) Exit')
        $choice = ''
        try {
            $choice = (Read-Host 'Choose [9]').Trim()
        } catch {
            return 0
        }
        if (-not $choice) { $choice = '9' }
        if (@('9', 'q', 'quit', 'exit') -contains $choice) { return 0 }
        if (@('1', '2', '3', '4', '5', '6', '7', '8') -notcontains $choice) {
            [Console]::Out.WriteLine('Invalid choice.')
            continue
        }
        if ($null -eq $Config) {
            [Console]::Out.WriteLine('Configuration is not loaded.')
            continue
        }

        try {
            if ($choice -eq '1') {
                $target = Ask-Value 'Video file or folder'
                if (-not $target) { continue }
                $model = Ask-Value 'Model' $Config.default_model
                $preset = Ask-Value ('Preset ' + (((Get-Presets).Keys | Sort-Object) -join '/')) $Config.default_preset
                if (-not (Get-Presets).ContainsKey($preset)) {
                    [Console]::Out.WriteLine('Unknown preset.')
                    continue
                }
                $audio = Ask-Value 'Audio auto/copy/aac/pcm/none' 'auto'
                $subs = Ask-Value 'Subtitles auto/copy/convert/none' 'auto'
                $cleanup = @('y', 'yes') -contains (Ask-Value 'Delete intermediates after success? y/N' 'n').ToLowerInvariant()
                $scale = $Config.default_scale
                $split = @{
                    fps = $null; start = $null; end = $null; format = 'png';
                    jpeg_quality = 1; png_compression = 3; denoise = 'none';
                    tonemap = $false; decode = 'auto'; scale = $scale;
                    target_height = $null; model = $model; verify_frames = $false;
                    recursive = $false; force = $false
                }
                $upscale = @{
                    model = $model; scale = $scale; gpu = 0; tile = 'auto';
                    batch_size = 0; threads = '1:2:2'; icd = $null;
                    upscayl_bin = $null; models_dir = $null; upscaled_dir = $null;
                    retry = 1; force = $false
                }
                $encode = @{
                    preset = $preset; encoder = $Config.default_encoder; quality = 'balanced';
                    crf = $null; audio = $(if ($audio -eq 'auto') { $null } else { $audio });
                    audio_bitrate = 192; all_audio = $false;
                    subs = $(if ($subs -eq 'auto') { $null } else { $subs });
                    ten_bit = $false; target_height = $null; cleanup = $cleanup;
                    output = $null; upscaled_dir = $null; pick = 'error';
                    verify_frames = $false; allow_huge = $false; force = $false; keep_chunks = $false
                }
                $inputs = Resolve-Inputs -Arguments @($target) -Config $Config -Recursive $false
                $null = Invoke-RunAll -Inputs $inputs -Config $Config -Options @{
                    split = $split; upscale = $upscale; encode = $encode;
                    cleanup = $cleanup; stop_on_error = $false; chunk_seconds = 'auto'
                } -Logger $Logger
            } elseif ($choice -eq '2') {
                $target = Ask-Value 'Video file or folder'
                if (-not $target) { continue }
                $format = Ask-Value 'Frame format png/jpg' 'png'
                if (@('png', 'jpg') -notcontains $format) {
                    [Console]::Out.WriteLine('Frame format must be png or jpg.')
                    continue
                }
                $scaleText = Ask-Value 'Scale 2/3/4' ([string]$Config.default_scale)
                $scale = 0
                if (-not [int]::TryParse($scaleText, [ref]$scale) -or @(2, 3, 4) -notcontains $scale) {
                    [Console]::Out.WriteLine('Scale must be 2, 3, or 4.')
                    continue
                }
                $options = @{
                    fps = $null; start = $null; end = $null; format = $format;
                    jpeg_quality = 1; png_compression = 3; denoise = 'none';
                    tonemap = $false; decode = 'auto'; scale = $scale;
                    target_height = $null; model = $Config.default_model;
                    verify_frames = $false; recursive = $false; force = $false
                }
                $inputs = Resolve-Inputs -Arguments @($target) -Config $Config -Recursive $false
                $null = Invoke-Split -Inputs $inputs -Config $Config -Options $options -Logger $Logger
            } elseif ($choice -eq '3') {
                $jobPath = Ask-Value 'Job folder'
                if (-not $jobPath) { continue }
                $model = Ask-Value 'Model' $Config.default_model
                $scaleText = Ask-Value 'Scale 2/3/4' ([string]$Config.default_scale)
                $scale = 0
                if (-not [int]::TryParse($scaleText, [ref]$scale) -or @(2, 3, 4) -notcontains $scale) {
                    [Console]::Out.WriteLine('Scale must be 2, 3, or 4.')
                    continue
                }
                $jobs = Resolve-Jobs -Arguments @($jobPath) -Config $Config -AllJobs $false
                $options = @{
                    model = $model; scale = $scale; gpu = 0; tile = 'auto';
                    batch_size = 0; threads = '1:2:2'; icd = $null;
                    upscayl_bin = $null; models_dir = $null; upscaled_dir = $null;
                    retry = 1; force = $false
                }
                $null = Invoke-Upscale -Jobs $jobs -Config $Config -Options $options -Logger $Logger
            } elseif ($choice -eq '4') {
                $jobPath = Ask-Value 'Job folder'
                if (-not $jobPath) { continue }
                $preset = Ask-Value ('Preset ' + (((Get-Presets).Keys | Sort-Object) -join '/')) $Config.default_preset
                if (-not (Get-Presets).ContainsKey($preset)) {
                    [Console]::Out.WriteLine('Unknown preset.')
                    continue
                }
                $encoder = Ask-Value 'Encoder auto/nvidia/amd/cpu' $Config.default_encoder
                if (@('auto', 'nvidia', 'amd', 'cpu') -notcontains $encoder) {
                    [Console]::Out.WriteLine('Unknown encoder.')
                    continue
                }
                $audio = Ask-Value 'Audio auto/copy/aac/pcm/none' 'auto'
                $subs = Ask-Value 'Subtitles auto/copy/convert/none' 'auto'
                $options = @{
                    preset = $preset; encoder = $encoder; quality = 'balanced'; crf = $null;
                    audio = $(if ($audio -eq 'auto') { $null } else { $audio }); audio_bitrate = 192;
                    all_audio = $false; subs = $(if ($subs -eq 'auto') { $null } else { $subs });
                    ten_bit = $false; target_height = $null; cleanup = $false;
                    output = $null; upscaled_dir = $null; pick = 'error';
                    verify_frames = $false; allow_huge = $false; force = $false; keep_chunks = $false
                }
                $jobs = Resolve-Jobs -Arguments @($jobPath) -Config $Config -AllJobs $false
                $null = Invoke-Assemble -Jobs $jobs -Config $Config -Options $options -Logger $Logger
            } elseif ($choice -eq '5') {
                Invoke-Status -Config $Config -Logger $Logger
            } elseif ($choice -eq '6') {
                $null = Invoke-Doctor -Config $Config -WorkDir $null -SkipUpscaylSmoke $true -VerboseOutput $false -Logger $Logger
            } elseif ($choice -eq '7') {
                $jobPath = Ask-Value 'Job folder'
                if (-not $jobPath) { continue }
                $answer = (Read-Host 'Delete all intermediate frames for this job? [y/N]').Trim().ToLowerInvariant()
                if (@('y', 'yes') -notcontains $answer) {
                    [Console]::Out.WriteLine('Cancelled.')
                    continue
                }
                $jobs = Resolve-Jobs -Arguments @($jobPath) -Config $Config -AllJobs $false
                Invoke-Clean -Jobs $jobs -Config $Config -Frames $false -Upscaled $false -Chunks $false -Sequence $false -Batch $false -IncludeOutput $false -AllIntermediates $true -DryRun $false -Logger $Logger
            } elseif ($choice -eq '8') {
                [Console]::Out.WriteLine('Config: ' + $Config.config_path)
                [Console]::Out.WriteLine('FFmpeg: ' + $Config.ffmpeg)
                [Console]::Out.WriteLine('Upscayl: ' + $(if ($Config.upscayl_bin) { $Config.upscayl_bin } else { 'auto' }))
                [Console]::Out.WriteLine('Models: ' + $(if ($Config.models_dir) { $Config.models_dir } else { 'auto' }))
                [Console]::Out.WriteLine('Work dir: ' + $Config.work_dir)
                [Console]::Out.WriteLine('Model/scale/preset: ' + $Config.default_model + ' / ' + $Config.default_scale + ' / ' + $Config.default_preset)
                [Console]::Out.WriteLine('Chunking/cleanup: auto / ' + $Config.cleanup)
            }
        } catch {
            Write-MenuError $_
        }
    }
    return 0
}

#endregion

#region Command line

function Show-Help {
    [Console]::Out.WriteLine('usage: upscayl-video <command> [options]')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('Upscayl Video Pipeline V2 - split, upscale with Upscayl, assemble.')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('commands:')
    [Console]::Out.WriteLine('  doctor    Check FFmpeg, encoders, Upscayl, and the work directory')
    [Console]::Out.WriteLine('  split     Extract frames from videos')
    [Console]::Out.WriteLine('  upscale   Upscale frames with the Upscayl CLI')
    [Console]::Out.WriteLine('  assemble  Reassemble upscaled frames into a video')
    [Console]::Out.WriteLine('  run       Split, upscale, and assemble in one pass')
    [Console]::Out.WriteLine('  status    Show jobs and their progress')
    [Console]::Out.WriteLine('  clean     Delete selected intermediate directories')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('global options:')
    [Console]::Out.WriteLine('  --work-dir DIR  --config FILE  --ffmpeg PATH  --ffprobe PATH')
    [Console]::Out.WriteLine('  --verbose  --quiet  --yes  --force  --dry-run  --version  --help')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('Use "upscayl-video <command> --help" for command options.')
}

function Get-CommandOptionsSpec {
    param([string]$Command)
    $spec = @{
        'work-dir' = @{ kind = 'value' }
        'config'   = @{ kind = 'value' }
        'ffmpeg'   = @{ kind = 'value' }
        'ffprobe'  = @{ kind = 'value' }
        'verbose'  = @{ kind = 'flag' }
        'quiet'    = @{ kind = 'flag' }
        'yes'      = @{ kind = 'flag' }
        'force'    = @{ kind = 'flag' }
        'dry-run'  = @{ kind = 'flag' }
        'help'     = @{ kind = 'flag' }
        'version'  = @{ kind = 'flag' }
    }
    $add = {
        param([string]$Name, [string]$Kind, [string]$Dest = $null, [array]$Choices = $null, [bool]$Int = $false)
        $spec[$Name] = @{ kind = $Kind; dest = $(if ($Dest) { $Dest } else { $Name.Replace('-', '_') }); choices = $Choices; int = $Int }
    }
    switch ($Command) {
        'split' {
            & $add 'fps' 'value'
            & $add 'start' 'value'
            & $add 'end' 'value'
            & $add 'format' 'value' $null @('png', 'jpg')
            & $add 'jpeg-quality' 'value' $null $null $true
            & $add 'png-compression' 'value' $null $null $true
            & $add 'denoise' 'value' $null @('none', 'light', 'medium', 'strong')
            & $add 'tonemap' 'flag'
            & $add 'decode' 'value' $null @('cpu', 'gpu', 'auto')
            & $add 'scale' 'value' $null @(2, 3, 4) $true
            & $add 'target-height' 'value' $null $null $true
            & $add 'model' 'value'
            & $add 'verify-frames' 'flag'
            & $add 'recursive' 'flag'
        }
        'upscale' {
            & $add 'all' 'flag'
            & $add 'model' 'value'
            & $add 'scale' 'value' $null @(2, 3, 4) $true
            & $add 'gpu' 'value' $null $null $true
            & $add 'tile' 'value'
            & $add 'batch-size' 'value' $null $null $true
            & $add 'threads' 'value'
            & $add 'icd' 'value'
            & $add 'upscayl-bin' 'value'
            & $add 'models-dir' 'value'
            & $add 'upscaled-dir' 'value'
            & $add 'retry' 'value' $null $null $true
        }
        'assemble' {
            & $add 'all' 'flag'
            & $add 'preset' 'value' $null @('mp4-h264', 'mp4-hevc', 'mkv-hevc', 'mov-prores')
            & $add 'encoder' 'value' $null @('auto', 'nvidia', 'amd', 'cpu')
            & $add 'quality' 'value' $null @('fast', 'balanced', 'quality')
            & $add 'crf' 'value' $null $null $true
            & $add 'audio' 'value' $null @('auto', 'copy', 'aac', 'pcm', 'none')
            & $add 'audio-bitrate' 'value' $null $null $true
            & $add 'all-audio' 'flag'
            & $add 'subs' 'value' $null @('auto', 'copy', 'convert', 'none')
            & $add '10bit' 'flag' 'ten_bit'
            & $add 'target-height' 'value' $null $null $true
            & $add 'cleanup' 'flag'
            & $add 'keep-chunks' 'flag'
            & $add 'output' 'value'
            & $add 'upscaled-dir' 'value'
            & $add 'pick' 'value' $null @('error', 'newest', 'largest')
            & $add 'verify-frames' 'flag'
            & $add 'allow-huge' 'flag'
            & $add 'tonemap' 'flag'
        }
        'run' {
            & $add 'fps' 'value'
            & $add 'start' 'value'
            & $add 'end' 'value'
            & $add 'format' 'value' $null @('png', 'jpg')
            & $add 'jpeg-quality' 'value' $null $null $true
            & $add 'png-compression' 'value' $null $null $true
            & $add 'denoise' 'value' $null @('none', 'light', 'medium', 'strong')
            & $add 'tonemap' 'flag'
            & $add 'decode' 'value' $null @('cpu', 'gpu', 'auto')
            & $add 'scale' 'value' $null @(2, 3, 4) $true
            & $add 'target-height' 'value' $null $null $true
            & $add 'model' 'value'
            & $add 'verify-frames' 'flag'
            & $add 'recursive' 'flag'
            & $add 'gpu' 'value' $null $null $true
            & $add 'tile' 'value'
            & $add 'batch-size' 'value' $null $null $true
            & $add 'threads' 'value'
            & $add 'icd' 'value'
            & $add 'upscayl-bin' 'value'
            & $add 'models-dir' 'value'
            & $add 'upscaled-dir' 'value'
            & $add 'retry' 'value' $null $null $true
            & $add 'preset' 'value' $null @('mp4-h264', 'mp4-hevc', 'mkv-hevc', 'mov-prores')
            & $add 'encoder' 'value' $null @('auto', 'nvidia', 'amd', 'cpu')
            & $add 'quality' 'value' $null @('fast', 'balanced', 'quality')
            & $add 'crf' 'value' $null $null $true
            & $add 'audio' 'value' $null @('auto', 'copy', 'aac', 'pcm', 'none')
            & $add 'audio-bitrate' 'value' $null $null $true
            & $add 'all-audio' 'flag'
            & $add 'subs' 'value' $null @('auto', 'copy', 'convert', 'none')
            & $add '10bit' 'flag' 'ten_bit'
            & $add 'cleanup' 'flag'
            & $add 'output' 'value'
            & $add 'pick' 'value' $null @('error', 'newest', 'largest')
            & $add 'allow-huge' 'flag'
            & $add 'stop-on-error' 'flag'
            & $add 'chunk-seconds' 'value'
        }
        'clean' {
            & $add 'frames' 'flag'
            & $add 'upscaled' 'flag'
            & $add 'chunks' 'flag'
            & $add 'batch' 'flag'
            & $add 'all-intermediates' 'flag'
            & $add 'include-output' 'flag'
            & $add 'all-jobs' 'flag'
        }
        'doctor' {
            & $add 'skip-upscayl-smoke' 'flag'
        }
        'status' {
        }
    }
    return $spec
}

function Read-CommandLine {
    param([string[]]$Tokens, $Spec)
    $options = @{}
    $positionals = @()
    $index = 0
    $endOfOptions = $false
    while ($index -lt $Tokens.Count) {
        $token = [string]$Tokens[$index]
        if ($endOfOptions) { $positionals += $token; $index++; continue }
        if ($token -eq '--') { $endOfOptions = $true; $index++; continue }
        if ($token -eq '-h') {
            $options['help'] = '1'
            $index++
            continue
        }
        if ($token.StartsWith('--')) {
            $nameValue = $token.Substring(2)
            $equals = $nameValue.IndexOf('=')
            $name = $nameValue
            $inline = $null
            if ($equals -ge 0) {
                $name = $nameValue.Substring(0, $equals)
                $inline = $nameValue.Substring($equals + 1)
            }
            if (-not $Spec.ContainsKey($name)) {
                throw [PipelineException]::new("unrecognized argument: --$name", 'Run with --help for usage.', 2)
            }
            $entry = $Spec[$name]
            $dest = $entry.dest
            if (-not $dest) { $dest = $name.Replace('-', '_') }
            if ($entry.kind -eq 'flag') {
                if ($null -ne $inline) {
                    throw [PipelineException]::new("argument --$name`: ignored explicit argument '$inline'", $null, 2)
                }
                $options[$dest] = '1'
                $index++
                continue
            }
            $value = $inline
            if ($null -eq $value) {
                if ($index + 1 -ge $Tokens.Count) {
                    throw [PipelineException]::new("argument --$name`: expected one argument", $null, 2)
                }
                $value = [string]$Tokens[$index + 1]
                $index++
            }
            if ($entry.int) {
                $parsed = 0
                if (-not [int]::TryParse($value, [ref]$parsed)) {
                    throw [PipelineException]::new("argument --$name`: invalid integer value: '$value'", $null, 2)
                }
                if ($entry.choices -and $entry.choices -notcontains $parsed) {
                    throw [PipelineException]::new("argument --$name`: invalid choice: $parsed", ('choose from: ' + ($entry.choices -join ', ')), 2)
                }
                $options[$dest] = $parsed
            } else {
                if ($entry.choices -and $entry.choices -notcontains $value) {
                    throw [PipelineException]::new("argument --$name`: invalid choice: '$value'", ('choose from: ' + ($entry.choices -join ', ')), 2)
                }
                $options[$dest] = $value
            }
            $index++
            continue
        }
        if ($token.StartsWith('-') -and $token -ne '-') {
            throw [PipelineException]::new("unrecognized argument: $token", 'Run with --help for usage.', 2)
        }
        $positionals += $token
        $index++
    }
    return @{ options = $options; positionals = $positionals }
}

function Get-OptionValue {
    param($Options, [string]$Key, $Default = $null)
    if ($Options.ContainsKey($Key)) { return $Options[$Key] }
    return $Default
}

function Invoke-Main {
    param([string[]]$Argv)

    $globalValueOptions = @('work-dir', 'config', 'ffmpeg', 'ffprobe')
    $globalFlagOptions = @('verbose', 'quiet', 'yes', 'force', 'dry-run')
    $command = $null
    $commandIndex = -1
    $index = 0
    while ($index -lt $Argv.Count) {
        $token = [string]$Argv[$index]
        if ($token -eq '--') {
            throw [PipelineException]::new('the following arguments are required: command', $null, 2)
        }
        if ($token -eq '-h' -or $token -eq '--help') {
            if (-not $command) { Show-Help; return 0 }
            Show-Help
            return 0
        }
        if ($token -eq '--version') {
            [Console]::Out.WriteLine($script:ProgramName + ' ' + $script:V2Version)
            return 0
        }
        if ($token.StartsWith('--')) {
            $nameValue = $token.Substring(2)
            $equals = $nameValue.IndexOf('=')
            $name = if ($equals -ge 0) { $nameValue.Substring(0, $equals) } else { $nameValue }
            if ($globalValueOptions -contains $name) {
                if ($equals -lt 0) { $index++ }
                $index++
                continue
            }
            if ($globalFlagOptions -contains $name) {
                $index++
                continue
            }
            throw [PipelineException]::new("unrecognized argument: --$name", 'Run with --help for usage.', 2)
        }
        if ($token.StartsWith('-') -and $token -ne '-') {
            throw [PipelineException]::new("unrecognized argument: $token", 'Run with --help for usage.', 2)
        }
        $command = $token
        $commandIndex = $index
        break
    }

    $validCommands = @('doctor', 'split', 'upscale', 'assemble', 'run', 'status', 'clean')
    if (-not $command) {
        if ($Argv.Count -eq 0) {
            if ([Console]::IsInputRedirected) {
                Show-Help
                return 2
            }
            try {
                $config = Get-Config -ConfigPath $null -ToolDir $script:ToolDir
            } catch {
                $ex = Get-PipelineException $_
                Write-Err $ex.ToString()
                return $ex.ExitCode
            }
            return (Invoke-Menu $config (New-Logger))
        }
        throw [PipelineException]::new('the following arguments are required: command', 'Run with --help for usage.', 2)
    }
    if ($validCommands -notcontains $command) {
        throw [PipelineException]::new("invalid choice: '$command'", ('choose from: ' + ($validCommands -join ', ')), 2)
    }

    $remaining = @()
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        if ($i -eq $commandIndex) { continue }
        $remaining += $Argv[$i]
    }
    $spec = Get-CommandOptionsSpec $command
    $parsed = Read-CommandLine -Tokens $remaining -Spec $spec
    $opts = $parsed.options
    if ($opts.ContainsKey('version')) {
        [Console]::Out.WriteLine($script:ProgramName + ' ' + $script:V2Version)
        return 0
    }
    if ($opts.ContainsKey('help')) {
        Show-Help
        return 0
    }
    if ((@('status', 'doctor') -contains $command) -and $parsed.positionals.Count -gt 0) {
        throw [PipelineException]::new('unrecognized arguments: ' + ($parsed.positionals -join ' '), 'Run with --help for usage.', 2)
    }

    $logger = New-Logger -VerboseOutput ([bool]$opts.ContainsKey('verbose')) -Quiet ([bool]$opts.ContainsKey('quiet'))
    $overrides = @{}
    foreach ($key in @('work_dir', 'ffmpeg', 'ffprobe')) {
        if ($opts.ContainsKey($key)) { $overrides[$key] = [string]$opts[$key] }
    }
    $config = Get-Config -ConfigPath $(if ($opts.ContainsKey('config')) { $opts['config'] } else { $null }) -Overrides $overrides -ToolDir $script:ToolDir
    $force = $opts.ContainsKey('force')
    $dryRun = $opts.ContainsKey('dry_run')
    $yes = $opts.ContainsKey('yes')

    if ($command -eq 'split') {
        $options = @{
            fps = (Get-OptionValue $opts 'fps' $null)
            start = (Get-OptionValue $opts 'start' $null)
            end = (Get-OptionValue $opts 'end' $null)
            format = (Get-OptionValue $opts 'format' 'png')
            jpeg_quality = (Get-OptionValue $opts 'jpeg_quality' 1)
            png_compression = (Get-OptionValue $opts 'png_compression' 3)
            denoise = (Get-OptionValue $opts 'denoise' 'none')
            tonemap = $opts.ContainsKey('tonemap')
            decode = (Get-OptionValue $opts 'decode' 'auto')
            scale = (Get-OptionValue $opts 'scale' $null)
            target_height = (Get-OptionValue $opts 'target_height' $null)
            model = $(if ($opts.ContainsKey('model')) { $opts['model'] } else { $config.default_model })
            verify_frames = $opts.ContainsKey('verify_frames')
            recursive = $opts.ContainsKey('recursive')
            force = $force
        }
        $inputs = Resolve-Inputs -Arguments $parsed.positionals -Config $config -Recursive $options.recursive
        $jobs = @(Invoke-Split -Inputs $inputs -Config $config -Options $options -Logger $logger -DryRun $dryRun -AssumeYes $yes)
        if ($jobs.Count -gt 0) { Write-Info ("Split complete: " + $jobs.Count + ' job(s)') }
        return 0
    }

    if ($command -eq 'upscale') {
        $jobs = Resolve-Jobs -Arguments $parsed.positionals -Config $config -AllJobs $opts.ContainsKey('all')
        $options = @{
            model = $(if ($opts.ContainsKey('model')) { $opts['model'] } else { $config.default_model })
            scale = $(if ($opts.ContainsKey('scale')) { $opts['scale'] } else { $config.default_scale })
            gpu = $(if ($opts.ContainsKey('gpu')) { $opts['gpu'] } else { $config.gpu })
            tile = $(if ($opts.ContainsKey('tile')) { $opts['tile'] } else { $config.tile })
            batch_size = $(if ($opts.ContainsKey('batch_size')) { $opts['batch_size'] } else { $config.batch_size })
            threads = (Get-OptionValue $opts 'threads' '1:2:2')
            icd = (Get-OptionValue $opts 'icd' $null)
            upscayl_bin = $(if ($opts.ContainsKey('upscayl_bin')) { $opts['upscayl_bin'] } else { $null })
            models_dir = $(if ($opts.ContainsKey('models_dir')) { $opts['models_dir'] } else { $null })
            upscaled_dir = $(if ($opts.ContainsKey('upscaled_dir')) { $opts['upscaled_dir'] } else { $null })
            retry = (Get-OptionValue $opts 'retry' 1)
            force = $force
        }
        $result = @(Invoke-Upscale -Jobs $jobs -Config $config -Options $options -Logger $logger -DryRun $dryRun)
        Write-Info ("Upscaled " + $result.Count + ' job(s)')
        return 0
    }

    if ($command -eq 'assemble') {
        if ($opts.ContainsKey('tonemap')) {
            throw [PipelineException]::new('--tonemap is a split-stage option; re-split with --tonemap instead.', $null, 4)
        }
        $jobs = Resolve-Jobs -Arguments $parsed.positionals -Config $config -AllJobs $opts.ContainsKey('all')
        $options = @{
            preset = $(if ($opts.ContainsKey('preset')) { $opts['preset'] } else { $config.default_preset })
            encoder = $(if ($opts.ContainsKey('encoder')) { $opts['encoder'] } else { $config.default_encoder })
            quality = (Get-OptionValue $opts 'quality' 'balanced')
            crf = (Get-OptionValue $opts 'crf' $null)
            audio = (Get-OptionValue $opts 'audio' $null)
            audio_bitrate = (Get-OptionValue $opts 'audio_bitrate' 192)
            all_audio = $opts.ContainsKey('all_audio')
            subs = (Get-OptionValue $opts 'subs' $null)
            ten_bit = $opts.ContainsKey('ten_bit')
            target_height = (Get-OptionValue $opts 'target_height' $null)
            cleanup = $opts.ContainsKey('cleanup')
            output = $(if ($opts.ContainsKey('output')) { $opts['output'] } else { $null })
            upscaled_dir = $(if ($opts.ContainsKey('upscaled_dir')) { $opts['upscaled_dir'] } else { $null })
            pick = (Get-OptionValue $opts 'pick' 'error')
            verify_frames = $opts.ContainsKey('verify_frames')
            allow_huge = $opts.ContainsKey('allow_huge')
            force = $force
            keep_chunks = $opts.ContainsKey('keep_chunks')
        }
        $outputs = @(Invoke-Assemble -Jobs $jobs -Config $config -Options $options -Logger $logger -DryRun $dryRun)
        if ($outputs.Count -gt 0) { Write-Info ("Assembled " + $outputs.Count + ' video(s)') }
        return 0
    }

    if ($command -eq 'run') {
        $inputs = Resolve-Inputs -Arguments $parsed.positionals -Config $config -Recursive $opts.ContainsKey('recursive')
        $split = @{
            fps = (Get-OptionValue $opts 'fps' $null)
            start = (Get-OptionValue $opts 'start' $null)
            end = (Get-OptionValue $opts 'end' $null)
            format = (Get-OptionValue $opts 'format' 'png')
            jpeg_quality = (Get-OptionValue $opts 'jpeg_quality' 1)
            png_compression = (Get-OptionValue $opts 'png_compression' 3)
            denoise = (Get-OptionValue $opts 'denoise' 'none')
            tonemap = $opts.ContainsKey('tonemap')
            decode = (Get-OptionValue $opts 'decode' 'auto')
            scale = (Get-OptionValue $opts 'scale' $null)
            target_height = (Get-OptionValue $opts 'target_height' $null)
            model = $(if ($opts.ContainsKey('model')) { $opts['model'] } else { $config.default_model })
            verify_frames = $opts.ContainsKey('verify_frames')
            recursive = $opts.ContainsKey('recursive')
            force = $force
        }
        $upscale = @{
            model = $(if ($opts.ContainsKey('model')) { $opts['model'] } else { $config.default_model })
            scale = $(if ($opts.ContainsKey('scale')) { $opts['scale'] } else { $config.default_scale })
            gpu = $(if ($opts.ContainsKey('gpu')) { $opts['gpu'] } else { $config.gpu })
            tile = $(if ($opts.ContainsKey('tile')) { $opts['tile'] } else { $config.tile })
            batch_size = $(if ($opts.ContainsKey('batch_size')) { $opts['batch_size'] } else { $config.batch_size })
            threads = (Get-OptionValue $opts 'threads' '1:2:2')
            icd = (Get-OptionValue $opts 'icd' $null)
            upscayl_bin = $(if ($opts.ContainsKey('upscayl_bin')) { $opts['upscayl_bin'] } else { $null })
            models_dir = $(if ($opts.ContainsKey('models_dir')) { $opts['models_dir'] } else { $null })
            upscaled_dir = $(if ($opts.ContainsKey('upscaled_dir')) { $opts['upscaled_dir'] } else { $null })
            retry = (Get-OptionValue $opts 'retry' 1)
            force = $force
        }
        $encode = @{
            preset = $(if ($opts.ContainsKey('preset')) { $opts['preset'] } else { $config.default_preset })
            encoder = $(if ($opts.ContainsKey('encoder')) { $opts['encoder'] } else { $config.default_encoder })
            quality = (Get-OptionValue $opts 'quality' 'balanced')
            crf = (Get-OptionValue $opts 'crf' $null)
            audio = (Get-OptionValue $opts 'audio' $null)
            audio_bitrate = (Get-OptionValue $opts 'audio_bitrate' 192)
            all_audio = $opts.ContainsKey('all_audio')
            subs = (Get-OptionValue $opts 'subs' $null)
            ten_bit = $opts.ContainsKey('ten_bit')
            target_height = (Get-OptionValue $opts 'target_height' $null)
            cleanup = $opts.ContainsKey('cleanup')
            output = $(if ($opts.ContainsKey('output')) { $opts['output'] } else { $null })
            upscaled_dir = $(if ($opts.ContainsKey('upscaled_dir')) { $opts['upscaled_dir'] } else { $null })
            pick = (Get-OptionValue $opts 'pick' 'error')
            verify_frames = $opts.ContainsKey('verify_frames')
            allow_huge = $opts.ContainsKey('allow_huge')
            force = $force
            keep_chunks = $false
        }
        $results = Invoke-RunAll -Inputs $inputs -Config $config -Options @{
            split = $split; upscale = $upscale; encode = $encode;
            cleanup = $encode.cleanup; stop_on_error = $opts.ContainsKey('stop_on_error');
            chunk_seconds = (Get-OptionValue $opts 'chunk_seconds' 'auto')
        } -Logger $logger
        $failed = @($results | Where-Object { $_.error })
        if ($failed.Count -gt 0) { return 1 }
        return 0
    }

    if ($command -eq 'status') {
        Invoke-Status -Config $config -Logger $logger -VerboseOutput $opts.ContainsKey('verbose')
        return 0
    }

    if ($command -eq 'clean') {
        $jobs = Resolve-Jobs -Arguments $parsed.positionals -Config $config -AllJobs $opts.ContainsKey('all_jobs')
        Invoke-Clean -Jobs $jobs -Config $config -Frames $opts.ContainsKey('frames') -Upscaled $opts.ContainsKey('upscaled') -Chunks $opts.ContainsKey('chunks') -Sequence $false -Batch $opts.ContainsKey('batch') -IncludeOutput $opts.ContainsKey('include_output') -AllIntermediates $opts.ContainsKey('all_intermediates') -DryRun $dryRun -Logger $logger
        return 0
    }

    if ($command -eq 'doctor') {
        $workDir = Get-OptionValue $opts 'work_dir' $null
        return (Invoke-Doctor -Config $config -WorkDir $workDir -SkipUpscaylSmoke $opts.ContainsKey('skip_upscayl_smoke') -VerboseOutput $opts.ContainsKey('verbose') -Logger $logger)
    }

    throw [PipelineException]::new('unsupported command', $null, 2)
}

function New-Logger {
    param([bool]$VerboseOutput = $false, [bool]$Quiet = $false)
    $script:Verbose = $VerboseOutput
    $script:Quiet = $Quiet
    return @{ verbose = $VerboseOutput; quiet = $Quiet }
}

#endregion

if ($env:UPSCAYL_V2_LIB -eq '1') {
    return
}

try {
    exit (Invoke-Main -Argv $args)
} catch {
    $ex = Get-PipelineException $_
    if ($ex -is [PipelineException]) {
        Write-Err $ex.ToString()
        exit $ex.ExitCode
    }
    Write-Err ($ex.Message)
    if ($script:Verbose -or $env:UPSCAYL_V2_DEBUG -eq '1') { Write-Err ($_ | Out-String); Write-Err $_.ScriptStackTrace }
    exit 1
}






