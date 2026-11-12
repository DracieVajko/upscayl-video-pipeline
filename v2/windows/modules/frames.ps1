# Upscayl Video Pipeline V2 - frames module.
# Frame set handling and disk estimates.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

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
        $timings = [regex]::Matches($result.StdErr, 'bench:.*?rtime=([0-9.]+)')
        if ($timings.Count -eq 0) { return $null }
        return [double]::Parse($timings[$timings.Count - 1].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
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

    $framesDir = Get-JobFramesDir $Job
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
