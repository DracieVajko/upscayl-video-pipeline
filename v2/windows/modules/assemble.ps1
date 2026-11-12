# Upscayl Video Pipeline V2 - assemble module.
# Output path resolution, publishing and frame reconstruction.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Pipeline orchestration

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
        $resolved = Resolve-AbsolutePath $raw
        if ((Test-Path -LiteralPath $resolved -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $resolved 'job.txt') -PathType Leaf)) {
            $nested = @(Find-Jobs $resolved)
            if ($nested.Count -gt 0) {
                foreach ($job in $nested) {
                    $key = [IO.Path]::GetFullPath($job.path).ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $jobs += $job
                    }
                }
                continue
            }
        }
        $job = Open-Job $resolved
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

function Publish-AndPurge {
    param($Job, [string]$Output, $Config, $Logger)
    $jobRoot = [IO.Path]::GetFullPath($Job.path)
    $sep = [IO.Path]::DirectorySeparatorChar
    $target = $Output
    $inside = $false
    try {
        $outFull = [IO.Path]::GetFullPath($Output)
        $inside = $outFull.Equals($jobRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $outFull.StartsWith($jobRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        Write-DebugLog ("Could not resolve the output path: {0}" -f $_.Exception.Message)
    }

    if ($inside) {
        $outputRoot = [IO.Path]::GetFullPath($Config.output_dir)
        if ($outputRoot.Equals($jobRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $outputRoot.StartsWith($jobRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [PipelineException]::new("output_dir must be outside the job folder: $outputRoot", 'Point output_dir at a separate folder, for example output.', 4)
        }
        if (-not (Test-Path -LiteralPath $Config.output_dir -PathType Container)) {
            New-Item -ItemType Directory -Path $Config.output_dir -Force | Out-Null
        }
        $name = [IO.Path]::GetFileName($Output)
        $target = Join-Path $Config.output_dir $name
        $index = 1
        while (Test-Path -LiteralPath $target) {
            $target = Join-Path $Config.output_dir ([IO.Path]::GetFileNameWithoutExtension($name) + '_' + $index + [IO.Path]::GetExtension($name))
            $index++
        }
        try {
            Move-Item -LiteralPath $Output -Destination $target -Force -ErrorAction Stop
        } catch {
            throw [PipelineException]::new("Could not move the output to ${target}: $($_.Exception.Message)", 'The job folder was kept.', 7)
        }
        Write-Info ("Output moved: " + $target)
    }

    try {
        $script:LogFile = ''
        Remove-Item -LiteralPath $Job.path -Recurse -Force -ErrorAction Stop
        Write-Info ("Removed work folder: " + $Job.path)
    } catch {
        Write-Info ("Could not remove the work folder " + $Job.path + ": " + $_.Exception.Message)
    }
    return $target
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

function Complete-ChunkedAssemble {
    param(
        $Job,
        $Config,
        $Options,
        $Preset,
        $Logger,
        [bool]$DryRun = $false,
        [bool]$MultipleJobs = $false
    )

    $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source (Get-JobSourcePath $Job) -Logger $Logger
    $duration = ConvertTo-DoubleSafe (Get-JobValue $Job 'duration' $media.duration) $media.duration
    $fps = ConvertTo-DoubleSafe (Get-JobValue $Job 'fps_decimal' $media.fps_decimal) $media.fps_decimal
    $chunkSeconds = Get-JobInt $Job 'chunk_seconds' 0
    if ($chunkSeconds -le 0) {
        throw [PipelineException]::new("Chunked job has no chunk length: $([IO.Path]::GetFileName($Job.path))", 'Resume it with the run command.', 4)
    }
    $chunks = @(Get-ChunkPlan -Duration $duration -Fps $fps -ChunkSeconds $chunkSeconds)
    $segments = @()
    foreach ($chunk in $chunks) {
        $segment = $null
        foreach ($suffix in @('.ts', '.mov')) {
            $candidate = Join-Path (Join-Path $Job.path 'chunks') ('chunk_{0:D4}{1}' -f $chunk.index, $suffix)
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Get-Item -LiteralPath $candidate).Length -gt 0) {
                $segment = $candidate
                break
            }
        }
        $marker = Join-Path $Job.path ('.done_chunk_{0:D4}' -f $chunk.index)
        if (-not $segment -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            throw [PipelineException]::new("Chunk $($chunk.index) is incomplete: $([IO.Path]::GetFileName($Job.path))", 'Resume the job with the run command.', 4)
        }
        $segments += $segment
    }
    if ($segments.Count -eq 0) {
        throw [PipelineException]::new("No chunk segments found: $($Job.path)", 'Resume the job with the run command.', 4)
    }

    $jobPreset = Resolve-Preset (Get-JobValue $Job 'preset' $Options.preset)
    if ($jobPreset.codec -ne $Preset.codec) {
        throw [PipelineException]::new("Chunked job was encoded as $($jobPreset.codec); use a matching preset instead of $($Preset.name).", $null, 4)
    }
    $firstInfo = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $segments[0] -Logger $Logger
    if ($firstInfo.duration -le 0 -or $firstInfo.width -le 0 -or $firstInfo.height -le 0) {
        throw [PipelineException]::new("Invalid chunk segment: $($segments[0])", $null, 4)
    }
    $expectedWidth = $firstInfo.width
    $expectedHeight = $firstInfo.height

    $audioMode = if ($Options.audio) { $Options.audio } elseif ($Config.default_audio -ne 'auto') { $Config.default_audio } else { $Preset.default_audio }
    $subsMode = if ($Options.subs) { $Options.subs } elseif ($Config.default_subs -ne 'auto') { $Config.default_subs } else { $Preset.default_subs }
    $audioPlan = Get-AudioPlan -Media $media -Preset $Preset -Mode $audioMode -Bitrate $Options.audio_bitrate -AllAudio $Options.all_audio
    $rangeStart = ConvertTo-DoubleSafe (Get-JobValue $Job 'range_start' 0.0) 0.0
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
    $subtitlePlan = Get-SubtitlePlan -Media $media -Preset $Preset -Mode $subsMode -Logger $Logger
    $finalOutput = Resolve-OutputPath -Job $Job -Extension $Preset.extension -Options $Options -MultipleJobs $MultipleJobs
    if ($DryRun) {
        Write-Info ("Would assemble chunked " + [IO.Path]::GetFileName($Job.path) + " (" + $segments.Count + ' segment(s)) -> ' + $finalOutput)
        return $finalOutput
    }
    if ($Options.upscaled_dir) {
        Write-Warn '--upscaled-dir is ignored for a chunked job.'
    }

    $tempOutput = Join-Path (Split-Path -Parent $finalOutput) ([IO.Path]::GetFileNameWithoutExtension($finalOutput) + '.partial' + [IO.Path]::GetExtension($finalOutput))
    $reportOutput = Split-Path -Parent $finalOutput
    if (-not (Test-Path -LiteralPath $reportOutput)) { New-Item -ItemType Directory -Path $reportOutput -Force | Out-Null }
    try {
        Clear-JobMarker $Job 'assemble'
        $concatName = if ([IO.Path]::GetExtension($segments[0]).ToLowerInvariant() -eq '.mov') { 'concat.mov' } else { 'concat.ts' }
        $concatOutput = Invoke-ConcatSegments -Ffmpeg $Config.ffmpeg -Segments $segments -Output (Join-Path (Join-Path $Job.path 'chunks') $concatName) -Logger $Logger
        $mux = Build-MuxCommand -Job $Job -Media $media -Preset $Preset -AudioPlan $audioPlan -SubtitlePlan $subtitlePlan -Options $Options -ConcatVideo $concatOutput -Output $tempOutput -Duration $duration
        $mux[0] = $Config.ffmpeg
        Invoke-Child -Arguments $mux | Out-Null
        Repair-ColorTags -Ffmpeg $Config.ffmpeg -Ffprobe $Config.ffprobe -Path $tempOutput -Container $Preset.container -Logger $Logger
        Test-Output -Ffprobe $Config.ffprobe -Output $tempOutput -Job $Job -Media $media -Options $Options -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight -ExpectedAudio $audioPlan.enabled -ExpectedSubs $subtitlePlan.streams.Count -Logger $Logger
        Move-Item -LiteralPath $tempOutput -Destination $finalOutput -Force
        if (-not $Options.keep_chunks) {
            $chunksDir = Join-Path $Job.path 'chunks'
            if (Test-Path -LiteralPath $chunksDir) { Remove-Item -LiteralPath $chunksDir -Recurse -Force }
        }
        Set-JobValue $Job 'preset' $Preset.name
        Set-JobValue $Job 'encoder' $Options.encoder
        Set-JobValue $Job 'audio' $audioMode
        Set-JobValue $Job 'subs' $subsMode
        Set-JobValue $Job 'last_error' ''
        Save-Job $Job
        Set-JobMarker $Job 'assemble'
        if ($Options.cleanup) { $finalOutput = Publish-AndPurge $Job $finalOutput $Config $Logger }
        return $finalOutput
    } catch {
        if (Test-Path -LiteralPath $tempOutput) { Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue }
        throw
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
                $outputs += (Complete-ChunkedAssemble -Job $job -Config $Config -Options $jobOptions -Preset $preset -Logger $Logger -DryRun $DryRun -MultipleJobs $multiple)
                continue
            }
            $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source (Get-JobSourcePath $job) -Logger $Logger
            $upscaledDir = if ($Options.upscaled_dir) {
                Resolve-AbsolutePath (Expand-HomePath $Options.upscaled_dir)
            } else {
                Get-JobUpscaledDir $job
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
            if ($Options.cleanup) { $finalOutput = Publish-AndPurge $job $finalOutput $Config $Logger }
            $outputs += $finalOutput
        } catch {
            if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
                Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
            }
            $ex = Get-PipelineException $_
            $message = if ($ex -is [PipelineException]) { $ex.Message } else { $ex.Message }
            Set-JobValue $job 'last_error' $message.Substring(0, [math]::Min(500, $message.Length))
            try { Save-Job $job } catch { Write-DebugLog ("Could not record last_error: {0}" -f $_.Exception.Message) }
            throw
        }
    }
    return $outputs
}
