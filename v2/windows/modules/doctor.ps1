# Upscayl Video Pipeline V2 - doctor module.
# Environment checks.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

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
