# Upscayl Video Pipeline V2 - menu module.
# Interactive menu.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

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

function Select-Model {
    param($Config, $Logger)
    $modelHints = @{
        'upscayl-standard-4x' = 'general-purpose default'
        'upscayl-lite-4x' = 'fastest, good for long videos'
        'remacri-4x' = 'live-action detail'
        'ultramix-balanced-4x' = 'balanced live-action'
        'ultrasharp-4x' = 'sharp; may over-sharpen compressed sources'
        'high-fidelity-4x' = 'conservative, less hallucination'
        'digital-art-4x' = 'anime and illustrations'
    }
    $choices = New-Object System.Collections.ArrayList
    $seen = @{}
    $addDirectory = {
        param($Directory)
        if (-not $Directory) { return }
        try {
            foreach ($model in @(Get-ModelList $Directory)) {
                if ($seen.ContainsKey($model.name)) { continue }
                $seen[$model.name] = $true
                [void]$choices.Add(@{ name = $model.name; dir = $Directory })
            }
        } catch {
            Write-DebugLog ("Skipping model directory {0}: {1}" -f $Directory, $_.Exception.Message)
        }
    }
    try {
        $paths = Get-UpscaylPaths $Config
        & $addDirectory $paths.models_dir
        $standard = Join-Path (Split-Path -Parent (Split-Path -Parent $paths.binary)) 'models'
        if (Test-Path -LiteralPath $standard -PathType Container) { & $addDirectory $standard }
    } catch {
        Write-DebugLog ("Skipping the standard model directory: {0}" -f $_.Exception.Message)
    }
    if ($Config.models_dir) { & $addDirectory $Config.models_dir }
    if ($Config.upscayl_bin) {
        $standard = Join-Path (Split-Path -Parent (Split-Path -Parent $Config.upscayl_bin)) 'models'
        if (Test-Path -LiteralPath $standard -PathType Container) { & $addDirectory $standard }
    }
    if ($choices.Count -eq 0) {
        return @{ name = (Ask-Value 'Model' $Config.default_model); dir = $null }
    }
    Write-Info 'Models:'
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $hint = if ($modelHints.ContainsKey($choices[$i].name)) { $modelHints[$choices[$i].name] } else { 'custom' }
        Write-Info ("  " + ($i + 1) + ') ' + $choices[$i].name + ' - ' + $hint)
        Write-Info ('     ' + $choices[$i].dir)
    }
    $names = @($choices | ForEach-Object { $_.name })
    $defaultName = if ($names -contains $Config.default_model) { $Config.default_model } else { $choices[0].name }
    $answer = Ask-Value 'Model number or name' $defaultName
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $choices.Count) {
        return $choices[$number - 1]
    }
    foreach ($choice in $choices) {
        if ($choice.name -eq $answer) { return $choice }
    }
    return @{ name = $answer; dir = $null }
}

function Select-Jobs {
    param($Config, $Logger)
    $target = Ask-Value 'Job folder or work dir' ''
    if (-not $target) { return @() }
    $path = Resolve-AbsolutePath $target
    if (Test-Path -LiteralPath (Join-Path $path 'job.txt') -PathType Leaf) {
        return @(Resolve-Jobs -Arguments @($path) -Config $Config -AllJobs $false)
    }
    $jobs = @(Find-Jobs $path)
    if ($jobs.Count -eq 0) {
        Write-Info ("No jobs found in: " + $path)
        return @()
    }
    Write-Info 'Jobs:'
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        Write-Info ("  " + ($i + 1) + ') ' + [IO.Path]::GetFileName($jobs[$i].path) + ' <- ' + (Get-JobSourcePath $jobs[$i]))
    }
    $answer = (Ask-Value "Job number or 'a' for all" 'a').ToLowerInvariant()
    if (@('a', 'all') -contains $answer) { return $jobs }
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $jobs.Count) {
        return @($jobs[$number - 1])
    }
    Write-Info 'Invalid job selection.'
    return @()
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
                $inputs = Resolve-Inputs -Arguments @($target) -Config $Config -Recursive $false
                try {
                    $firstMedia = Get-MediaInfo -Ffprobe $Config.ffprobe -Source $inputs[0] -Logger $Logger
                } catch {
                    [Console]::Out.WriteLine((Get-PipelineException $_).Message)
                    continue
                }
                $tonemap = $false
                if ($firstMedia.hdr) {
                    $answer = (Ask-Value 'HDR source detected; tonemap to SDR BT.709? y/N' 'n').ToLowerInvariant()
                    if (@('y', 'yes') -notcontains $answer) {
                        [Console]::Out.WriteLine('Aborted: HDR requires --tonemap.')
                        continue
                    }
                    $tonemap = $true
                }
                $modelChoice = Select-Model $Config $Logger
                $model = $modelChoice.name
                $modelDir = $modelChoice.dir
                $preset = Ask-Value ('Preset ' + (((Get-Presets).Keys | Sort-Object) -join '/')) $Config.default_preset
                if (-not (Get-Presets).ContainsKey($preset)) {
                    [Console]::Out.WriteLine('Unknown preset.')
                    continue
                }
                $audio = Ask-Value 'Audio auto/copy/aac/pcm/none' 'auto'
                $subs = Ask-Value 'Subtitles auto/copy/convert/none' 'auto'
                $cleanupDefault = if ($Config.cleanup) { 'y' } else { 'n' }
                $cleanup = @('y', 'yes') -contains (Ask-Value 'Delete intermediates after success? y/N' $cleanupDefault).ToLowerInvariant()
                $scale = $Config.default_scale
                $split = @{
                    fps = $null; start = $null; end = $null; format = 'png';
                    jpeg_quality = 1; png_compression = 3; denoise = 'none';
                    tonemap = $tonemap; decode = 'auto'; scale = $scale;
                    target_height = $null; model = $model; verify_frames = $false;
                    recursive = $false; force = $false
                }
                $upscale = @{
                    model = $model; scale = $scale; gpu = 0; tile = 'auto';
                    batch_size = 0; threads = '1:2:2'; icd = $null;
                    upscayl_bin = $null; models_dir = $(if ($modelDir) { $modelDir } else { $null }); upscaled_dir = $null;
                    retry = 1; force = $false; assume_yes = $false
                }
                $encode = @{
                    preset = $preset; encoder = $Config.default_encoder; quality = 'balanced';
                    crf = $null; audio = $(if ($audio -eq 'auto') { $null } else { $audio });
                    audio_bitrate = 192; all_audio = $false;
                    subs = $(if ($subs -eq 'auto') { $null } else { $subs });
                    ten_bit = $false; target_height = $null; cleanup = $cleanup;
                    output = $null; upscaled_dir = $null; pick = 'error';
                    verify_frames = $false; allow_huge = $false; force = $false; keep_chunks = $false; ffmpeg_args = @()
                }
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
                $jobs = @(Select-Jobs $Config $Logger)
                if ($jobs.Count -eq 0) { continue }
                $modelChoice = Select-Model $Config $Logger
                $model = $modelChoice.name
                $modelDir = $modelChoice.dir
                $scaleText = Ask-Value 'Scale 2/3/4' ([string]$Config.default_scale)
                $scale = 0
                if (-not [int]::TryParse($scaleText, [ref]$scale) -or @(2, 3, 4) -notcontains $scale) {
                    [Console]::Out.WriteLine('Scale must be 2, 3, or 4.')
                    continue
                }
                Write-Info 'Note: upscale writes frames only; audio and subtitles are muxed by Assemble or Run all.'
                $options = @{
                    model = $model; scale = $scale; gpu = 0; tile = 'auto';
                    batch_size = 0; threads = '1:2:2'; icd = $null;
                    upscayl_bin = $null; models_dir = $(if ($modelDir) { $modelDir } else { $null }); upscaled_dir = $null;
                    retry = 1; force = $false; assume_yes = $false
                }
                $null = Invoke-Upscale -Jobs $jobs -Config $Config -Options $options -Logger $Logger
            } elseif ($choice -eq '4') {
                $jobs = @(Select-Jobs $Config $Logger)
                if ($jobs.Count -eq 0) { continue }
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
                    verify_frames = $false; allow_huge = $false; force = $false; keep_chunks = $false; ffmpeg_args = @()
                }
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
