# Upscayl Video Pipeline V2 - run module.
# Upscaling orchestration, chunked runs and the all-in-one run.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Pipeline orchestration

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
        $framesDir = Get-JobFramesDir $job
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
        $outputDir = if ($Options.upscaled_dir) { Resolve-AbsolutePath (Expand-HomePath $Options.upscaled_dir) } else { Get-JobUpscaledDir $job }
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
            $count = Invoke-UpscaleFrames -Job $job -Paths $paths -Model $Options.model -Scale $Options.scale -OutputDir $outputDir -Tile $tile -BatchSize $batchSize -Gpu $Options.gpu -Icd $icd -Threads $Options.threads -Retry $Options.retry -Logger $Logger -Progress $progress -AssumeYes $Options.assume_yes
        } catch {
            $ex = Get-PipelineException $_
            if ($ex -is [PipelineException]) {
                Set-JobValue $job 'last_error' $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length))
                try { Save-Job $job } catch { Write-DebugLog ("Could not record last_error: {0}" -f $_.Exception.Message) }
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
            $null = Invoke-UpscaleFrames -Job $job -Paths $paths -Model $Options.upscale.model -Scale $Options.upscale.scale -OutputDir $upscaledDir -Tile $tile -BatchSize (Resolve-BatchSize $Options.upscale.batch_size $batchWidth $batchHeight) -Gpu $Options.upscale.gpu -Icd $icd -Threads $Options.upscale.threads -Retry $Options.upscale.retry -Logger $Logger -Progress $progress -SourceDir $framesDir -TotalFrames $chunk.frame_count -AssumeYes $Options.upscale.assume_yes
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
        $concatOutput = Invoke-ConcatSegments -Ffmpeg $Config.ffmpeg -Segments $segments -Output $concatOutput -Logger $Logger
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
        if ($Options.cleanup) { $finalOutput = Publish-AndPurge $job $finalOutput $Config $Logger }
        return @{ input_path = $Source; job = $job; output = $finalOutput; error = $null }
    } catch {
        if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }
        $ex = Get-PipelineException $_
        $message = if ($ex -is [PipelineException]) { $ex.ToString() } else { $ex.Message }
        Set-JobValue $job 'last_error' $message.Substring(0, [math]::Min(500, $message.Length))
        try { Save-Job $job } catch { Write-DebugLog ("Could not record last_error: {0}" -f $_.Exception.Message) }
        return @{ input_path = $Source; job = $job; output = $null; error = $message }
    }
}

function Get-AutoChunkSeconds {
    param([string]$InputPath, $Config, $Options, $Logger)

    $source = Resolve-AbsolutePath (Expand-HomePath $InputPath)
    $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $source -Logger $Logger
    if ($media.duration -le 0) { return 0 }
    $start = if ($Options.split.start) { Parse-TimeValue $Options.split.start } else { 0.0 }
    $end = if ($Options.split.end) { Parse-TimeValue $Options.split.end } else { $media.duration }
    $end = [math]::Min($end, $media.duration)
    $duration = $end - $start
    if ($duration -le 0) { return 0 }
    $job = Find-OrCreateJob -WorkDir $Config.work_dir -Source $source -Logger $Logger -NoCreate
    $markers = @(Get-ChildItem -LiteralPath $job.path -Filter '.done_chunk_*' -File -Force -ErrorAction SilentlyContinue)
    if ($markers.Count -gt 0) {
        $stored = Get-JobInt $job 'chunk_seconds' 0
        if ($stored -gt 0) { return $stored }
        return 60
    }
    if (Test-JobHasFrames $job) { return 0 }
    $scaleInfo = Resolve-Scale -Media $media -Options $Options.split -Job $job -Config $Config
    $frames = [int](Round-HalfEven ($duration * $media.fps_decimal))
    $sample = Get-SampleFrameBytes -Source (Get-JobSourcePath $job) -Job $job -Media $media -Config $Config -Format $Options.split.format -Denoise $Options.split.denoise -Tonemap $Options.split.tonemap -Decode $Options.split.decode -Logger $Logger -Start $start -Duration $duration
    $estimate = Get-DiskEstimate -SampleBytes $sample -FrameCount $frames -Scale ([int]$scaleInfo[0])
    $estimate.free_bytes = Get-FreeBytes $Config.work_dir
    Write-Info ('Auto-chunk estimate: ' + (Format-Duration $duration) + ', ' + $frames + ' frames, estimated ' + (Format-Bytes $estimate.total_bytes) + ', free ' + (Format-Bytes $estimate.free_bytes))
    $cap = [int64]$Config.max_work_gb * 1024 * 1024 * 1024
    $floor = [int64]$Config.min_free_gb * 1024 * 1024 * 1024
    if ($estimate.total_bytes -gt $cap -or ($estimate.free_bytes - $estimate.total_bytes) -lt $floor) {
        Write-Info 'Automatic chunking enabled; using 60s chunks.'
        return 60
    }
    return 0
}

function Invoke-RunAll {
    param([string[]]$Inputs, $Config, $Options, $Logger, [bool]$DryRun = $false)
    if ($Inputs.Count -gt 1 -and $Options.encode.output) {
        $requestedOutput = Resolve-AbsolutePath (Expand-HomePath ([string]$Options.encode.output))
        $treatAsDirectory = (Test-Path -LiteralPath $requestedOutput -PathType Container) -or ([IO.Path]::GetExtension($requestedOutput) -eq '')
        if (-not $treatAsDirectory) {
            throw [PipelineException]::new('With multiple inputs, --output must be a directory.', 'Pass a directory (or omit --output).', 2)
        }
    }
    if ($DryRun) {
        $previewPreset = Resolve-Preset $Options.encode.preset
        $dryResults = @()
        foreach ($inputPath in $Inputs) {
            $jobs = @(Invoke-Split -Inputs @($inputPath) -Config $Config -Options $Options.split -Logger $Logger -DryRun $true -KeepDryRunJob $true)
            $job = $jobs[0]
            $duration = ConvertTo-DoubleSafe (Get-JobValue $job 'duration' 0.0) 0.0
            $fps = ConvertTo-DoubleSafe (Get-JobValue $job 'fps_decimal' 0.0) 0.0
            $frames = [int](Round-HalfEven ($duration * $fps))
            $scale = Get-JobInt $job 'scale' 0
            if ($scale -le 0) { $scale = $Options.upscale.scale }
            $chunkValue = ([string]$Options.chunk_seconds).Trim().ToLowerInvariant()
            if (@('0', 'auto') -notcontains $chunkValue) {
                $chunkSeconds = [int]$chunkValue
                if ($chunkSeconds -lt 10) { $chunkSeconds = 10 }
                $chunks = @(Get-ChunkPlan -Duration $duration -Fps $fps -ChunkSeconds $chunkSeconds)
                Write-Info ("Would process " + $frames + " frames in " + $chunks.Count + " chunks of " + $chunkSeconds + 's')
            } elseif ($chunkValue -eq 'auto') {
                Write-Info ("Would decide automatic chunking for " + $frames + ' frames from the disk estimate')
            }
            Write-Info ("Would upscale " + $frames + " frames with " + $Options.upscale.model + ' at ' + $scale + 'x')
            $output = Resolve-OutputPath -Job $job -Extension $previewPreset.extension -Options $Options.encode -MultipleJobs ($Inputs.Count -gt 1)
            Write-Info ('Would assemble -> ' + $output)
            $dryResults += @{ input_path = $inputPath; job = $job; output = $null; error = $null }
        }
        Write-Info (('{0,-32} {1,-8} {2}' -f 'INPUT', 'STATUS', 'OUTPUT'))
        foreach ($result in $dryResults) {
            $name = [IO.Path]::GetFileName([string]$result.input_path)
            if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
            Write-Info (('{0,-32} {1,-8} {2}' -f $name, 'DRY', '-'))
        }
        return $dryResults
    }
    $results = @()
    foreach ($inputPath in $Inputs) {
        $chunkValue = ([string]$Options.chunk_seconds).Trim().ToLowerInvariant()
        $chunkSeconds = 0
        if ($chunkValue -eq 'auto') {
            $chunkSeconds = Get-AutoChunkSeconds -InputPath $inputPath -Config $Config -Options $Options -Logger $Logger
        } elseif ($chunkValue -ne '0') {
            if (-not [int]::TryParse($chunkValue, [ref]$chunkSeconds)) {
                throw [PipelineException]::new("Invalid --chunk-seconds: $chunkValue", $null, 4)
            }
            if ($chunkSeconds -lt 10) {
                Write-Warn ("--chunk-seconds $chunkSeconds is below the minimum; using 10 seconds.")
                $chunkSeconds = 10
            }
        }
        if ($chunkSeconds -gt 0) {
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
