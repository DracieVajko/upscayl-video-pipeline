# Upscayl Video Pipeline V2 - admin module.
# split-all, finish, status and clean.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Pipeline orchestration

function Invoke-SplitAll {
    param($Config, $Options, $Logger, [bool]$DryRun = $false)
    $inputDir = $Config.input_dir
    if (-not (Test-Path -LiteralPath $inputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
    }
    $extensions = @('.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v', '.mts', '.m2ts')
    $videos = @(Get-ChildItem -LiteralPath $inputDir -Recurse -File |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object FullName)
    if ($videos.Count -eq 0) {
        throw [PipelineException]::new("No videos found in: $inputDir", 'Put the original videos in the input folder and run again.', 2)
    }
    Write-Info ('Inputs: ' + $videos.Count + ' - work: ' + $Config.work_dir)
    if ($DryRun) { Write-Info 'Dry run: nothing written.'; return }

    $created = @()
    foreach ($video in $videos) {
        Write-Info ('Splitting: ' + $video.Name)
        $media = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $video.FullName -Logger $Logger
        $tonemap = if ($null -ne $Options.tonemap) { [bool]$Options.tonemap } else { [bool]$media.hdr }
        if ($media.hdr -and -not $tonemap) {
            throw [PipelineException]::new('HDR source detected. Upscayl models are 8-bit SDR.', 'Re-run with --tonemap.', 4)
        }
        $split = @{
            fps = $null; start = $null; end = $null; format = $Options.format;
            jpeg_quality = $Options.jpeg_quality; png_compression = $Options.png_compression;
            denoise = $Options.denoise; tonemap = $tonemap; decode = $Options.decode;
            scale = $Options.scale; target_height = $null; model = $Options.model;
            verify_frames = $false; recursive = $false; force = $false
        }
        $job = @(Invoke-Split -Inputs @($video.FullName) -Config $Config -Options $split -Logger $Logger)[0]
        $frames = Get-JobFramesDir $job
        if (-not (Get-JobValue $job 'frames_dir' '')) {
            $batch = Join-Path $job.path 'batch00001'
            $incoming = Join-Path $batch 'in'
            if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force }
            New-Item -ItemType Directory -Path $batch -Force | Out-Null
            Move-Item -LiteralPath $frames -Destination $incoming
            Set-JobValue $job 'frames_dir' 'batch00001/in'
            Set-JobValue $job 'upscaled_dir' 'batch00001/out'
            Set-JobValue $job 'layout' 'batches'
            Save-Job $job
            # Clean old directories to avoid duplication
            $oldFrames = Join-Path $job.path 'frames'
            $oldUpscaled = Join-Path $job.path 'upscaled'
            if (Test-Path -LiteralPath $oldFrames) { Remove-Item -LiteralPath $oldFrames -Recurse -Force }
            if (Test-Path -LiteralPath $oldUpscaled) { Remove-Item -LiteralPath $oldUpscaled -Recurse -Force }
        }
        New-Item -ItemType Directory -Path (Join-Path $job.path 'batch00001\out') -Force | Out-Null

        $audioDir = Join-Path $job.path 'audio'
        New-Item -ItemType Directory -Path $audioDir -Force | Out-Null
        $info = @()
        if ($media.audio.Count -eq 0) {
            $info += 'tracks=0'
            Set-JobValue $job 'audio_tracks' 0
        } else {
            $info += ('tracks=' + $media.audio.Count)
            $number = 1
            foreach ($stream in $media.audio) {
                $target = Join-Path $audioDir ('track{0:D2}.mka' -f $number)
                $arguments = @($Config.ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', (Get-JobSourcePath $job),
                    '-map', ('0:' + $stream.index), '-vn', '-sn', '-dn', '-c', 'copy', $target)
                try { Invoke-Child -Arguments $arguments | Out-Null }
                catch {
                    $arguments = @($Config.ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', (Get-JobSourcePath $job),
                        '-map', ('0:' + $stream.index), '-vn', '-sn', '-dn', '-c:a', 'flac', $target)
                    Invoke-Child -Arguments $arguments | Out-Null
                }
                $info += @('', ('track={0:D2}' -f $number), ('index=' + $stream.index),
                    ('codec=' + $stream.codec_name), ('channels=' + $stream.channels),
                    ('language=' + $stream.language), ('title=' + $stream.title),
                    ('file=track{0:D2}.mka' -f $number))
                $number++
            }
            Set-JobValue $job 'audio_tracks' $media.audio.Count
        }
        Save-Job $job
        Set-Content -LiteralPath (Join-Path $audioDir 'info.txt') -Value ($info -join "`n") -Encoding UTF8
        $created += $job
    }

    $rows = @()
    foreach ($job in @(Find-Jobs $Config.work_dir)) {
        $rows += [pscustomobject]@{
            job = [IO.Path]::GetFileName($job.path)
            source = Get-JobSourcePath $job
            frames = Get-JobValue $job 'frame_count' ''
            in = Get-JobFramesDir $job
            out = Get-JobUpscaledDir $job
            audio_tracks = Get-JobValue $job 'audio_tracks' 0
        }
    }
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path (Join-Path $Config.work_dir 'manifest.csv') -NoTypeInformation -Encoding UTF8
        $lines = @('Upscayl Video Pipeline - workspace', '',
            'Point the Upscayl GUI at:', '  Input:  <job>\batch00001\in',
            '  Output: <job>\batch00001\out', '', 'Then run: UpscaylVideo.bat finish --all', '', 'Jobs:')
        foreach ($job in $created) {
            $lines += ('  ' + [IO.Path]::GetFileName($job.path) + ': ' + $job.path)
        }
        Set-Content -LiteralPath (Join-Path $Config.work_dir 'README-UPScayl.txt') -Value ($lines -join "`n") -Encoding UTF8
    }
    Write-Info ('Split complete: ' + $created.Count + ' job(s)')
}

function Invoke-Finish {
    param([object[]]$Jobs, $Config, $Options, $Logger, [bool]$DryRun = $false)
    $done = 0; $skipped = 0; $failed = 0
    foreach ($job in $Jobs) {
        $upscaledDir = Get-JobUpscaledDir $job
        $framesDir = Get-JobFramesDir $job
        $inFrames = @(Get-ChildItem -LiteralPath $framesDir -Recurse -File -Filter 'frame_*' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 }).Count
        $upscaledDir = Get-JobUpscaledDir $job
        $count = @(Get-ChildItem -LiteralPath $upscaledDir -Recurse -File -Filter 'frame_*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 }).Count
        if ($Options.resume) {
            if ($inFrames -gt 0 -and $count -ge $inFrames) {
                Write-Info ('Resume: job ' + [IO.Path]::GetFileName($job.path) + ' complete (' + $count + '/' + $inFrames + ') — skipping')
                $skipped++
                continue
            }
            if (Test-Path (Join-Path $job.path 'checkpoint')) {
                Write-Info ('Resume: skipping completed job ' + [IO.Path]::GetFileName($job.path))
                $skipped++
                continue
            }
        }
        if ($count -eq 0) {
            Write-Info ('Skipping ' + [IO.Path]::GetFileName($job.path) + ': no upscaled frames')
            $skipped++
            continue
        }
        $profileName = $Options.profile
        $preset = if ($Options.preset) { $Options.preset } elseif ($profileName -eq 'quality') { 'mp4-hevc' } elseif ($profileName -eq 'fast') { 'mp4-h264' } else { $Config.default_preset }
        $quality = if ($Options.quality) { $Options.quality } elseif ($profileName -eq 'quality') { 'quality' } elseif ($profileName -eq 'fast') { 'fast' } else { 'balanced' }
        $encoder = if ($Options.encoder) { $Options.encoder } elseif ($profileName -eq 'fast') { 'auto' } else { $Config.default_encoder }
        $encode = @{
            preset = $preset; encoder = $encoder; quality = $quality; crf = $Options.crf;
            audio = $Options.audio; audio_bitrate = $Options.audio_bitrate; all_audio = $Options.all_audio;
            subs = $Options.subs; ten_bit = $Options.ten_bit; target_height = $null;
            cleanup = (-not $Options.keep); output = $null; upscaled_dir = $null; pick = 'error';
            verify_frames = $false; allow_huge = $false; force = $false; keep_chunks = $false; ffmpeg_args = @()
        }
        try {
            Write-Info ('Assembling ' + [IO.Path]::GetFileName($job.path) + ' (' + $count + ' frames)')
            $outputs = @(Invoke-Assemble -Jobs @($job) -Config $Config -Options $encode -Logger $Logger -DryRun $DryRun)
            if ($outputs.Count -gt 0) { Write-Info ('Output: ' + $outputs[0]) }
            $done++
        } catch {
            $ex = Get-PipelineException $_
            Write-Err ([IO.Path]::GetFileName($job.path) + ': ' + $ex.Message)
            $failed++
        }
    }
    $remaining = @(Find-Jobs $Config.work_dir)
    if ($remaining.Count -eq 0) {
        foreach ($name in @('manifest.csv', 'README-UPScayl.txt')) {
            $path = Join-Path $Config.work_dir $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
    Write-Info ('Finished: ' + $done + ' - skipped: ' + $skipped + ' - failed: ' + $failed)
    if ($failed -gt 0) { return 1 }
    return 0
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
        $frames = Count-ContiguousFrames (Get-JobFramesDir $job) $frameFormat
        $upscaled = 0
        $groups = Get-FrameGroups (Get-JobUpscaledDir $job) -Recursive
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
        if ($Frames) { $targets[(Get-JobFramesDir $job)] = $true }
        if ($Upscaled) { $targets[(Get-JobUpscaledDir $job)] = $true }
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
