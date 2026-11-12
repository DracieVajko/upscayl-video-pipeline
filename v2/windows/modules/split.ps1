# Upscayl Video Pipeline V2 - split module.
# Input resolution and frame extraction.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

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
        [void][decimal]$decimal
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
    $groups = Get-FrameGroups (Get-JobFramesDir $Job)
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
    param([string[]]$Inputs, $Config, $Options, $Logger, [bool]$DryRun = $false, [bool]$AssumeYes = $false, [bool]$KeepDryRunJob = $false)
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
        if ($DryRun) {
            if ($KeepDryRunJob) { $jobs += $job }
            continue
        }

        try {
            $count = Invoke-FrameExtraction -Job $job -Media $media -Config $Config -Format $Options.format -JpegQuality $Options.jpeg_quality -PngCompression $Options.png_compression -Denoise $Options.denoise -Tonemap $Options.tonemap -Decode $Options.decode -Start $start -End $end -Verify $Options.verify_frames -Logger $Logger
        } catch {
            $ex = Get-PipelineException $_
            if ($ex -is [PipelineException]) {
                Set-JobValue $job 'last_error' $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length))
                try { Save-Job $job } catch { Write-DebugLog ("Could not record last_error: {0}" -f $_.Exception.Message) }
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
