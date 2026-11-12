# Upscayl Video Pipeline V2 - config module.
# Configuration file loading and tool resolution.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Configuration

function Get-DefaultConfigValues {
    return [ordered]@{
        ffmpeg          = 'ffmpeg'
        ffprobe         = 'ffprobe'
        upscayl_bin     = 'auto'
        models_dir      = 'auto'
        work_dir        = 'work'
        output_dir      = 'output'
        input_dir       = 'input'
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

    $outputOrigin = if ($overrideKeys.ContainsKey('output_dir')) { (Get-Location).Path } else { $configDir }
    $outputDir = Expand-HomePath $merged['output_dir']
    if (-not [IO.Path]::IsPathRooted($outputDir)) { $outputDir = Join-Path $outputOrigin $outputDir }
    $outputDir = [IO.Path]::GetFullPath($outputDir)

    $inputOrigin = if ($overrideKeys.ContainsKey('input_dir')) { (Get-Location).Path } else { $configDir }
    $inputDir = Expand-HomePath $merged['input_dir']
    if (-not [IO.Path]::IsPathRooted($inputDir)) { $inputDir = Join-Path $inputOrigin $inputDir }
    $inputDir = [IO.Path]::GetFullPath($inputDir)

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
        output_dir      = $outputDir
        input_dir       = $inputDir
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
