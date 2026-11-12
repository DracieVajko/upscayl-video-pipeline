# Upscayl Video Pipeline V2 - cli module.
# Option specification, command line parsing and dispatch.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Command line

function Show-Help {
    [Console]::Out.WriteLine('usage: upscayl-video <command> [options]')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('Upscayl Video Pipeline V2 - split, upscale with Upscayl, assemble.')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('commands:')
    [Console]::Out.WriteLine('  doctor     Check FFmpeg, encoders, Upscayl, and the work directory')
    [Console]::Out.WriteLine('  split      Extract frames from videos')
    [Console]::Out.WriteLine('  split-all  Split every video in the input directory')
    [Console]::Out.WriteLine('  upscale    Upscale frames with the Upscayl CLI')
    [Console]::Out.WriteLine('  assemble   Reassemble upscaled frames into a video')
    [Console]::Out.WriteLine('  finish     Assemble the workspace jobs and publish them')
    [Console]::Out.WriteLine('  run        Split, upscale, and assemble in one pass')
    [Console]::Out.WriteLine('  model-test Compare the Upscayl models on sample frames')
    [Console]::Out.WriteLine('  status     Show jobs and their progress')
    [Console]::Out.WriteLine('  clean      Delete selected intermediate directories')
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
        'output-dir' = @{ kind = 'value' }
        'input-dir' = @{ kind = 'value' }
        'config'   = @{ kind = 'value' }
        'ffmpeg'   = @{ kind = 'value' }
        'ffprobe'  = @{ kind = 'value' }
        'verbose'  = @{ kind = 'flag' }
        'quiet'    = @{ kind = 'flag' }
        'yes'      = @{ kind = 'flag' }
        'force'    = @{ kind = 'flag' }
        'dry-run'  = @{ kind = 'flag' }
        'max-work-gb' = @{ kind = 'value'; int = $true }
        'min-free-gb' = @{ kind = 'value'; int = $true }
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
        'split-all' {
            & $add 'format' 'value' $null @('png', 'jpg')
            & $add 'png-compression' 'value' $null $null $true
            & $add 'jpeg-quality' 'value' $null $null $true
            & $add 'denoise' 'value' $null @('none', 'light', 'medium', 'strong')
            & $add 'decode' 'value' $null @('cpu', 'gpu', 'auto')
            & $add 'tonemap' 'flag'
            & $add 'no-tonemap' 'flag'
            & $add 'scale' 'value' $null @(2, 3, 4) $true
            & $add 'model' 'value'
        }
        'model-test' {
            & $add 'video' 'value'
            & $add 'frames' 'value' $null $null $true
            & $add 'seed' 'value' $null $null $true
            & $add 'scale' 'value' $null @(2, 3, 4) $true
            & $add 'models-dir' 'value'
            & $add 'open' 'flag'
        }
        'finish' {
            & $add 'all' 'flag'
            & $add 'job' 'value'
            & $add 'profile' 'value' $null @('default', 'fast', 'quality')
            & $add 'preset' 'value' $null @('mp4-h264', 'mp4-hevc', 'mkv-hevc', 'mov-prores')
            & $add 'encoder' 'value' $null @('auto', 'nvidia', 'amd', 'cpu')
            & $add 'quality' 'value' $null @('fast', 'balanced', 'quality')
            & $add 'crf' 'value' $null $null $true
            & $add 'audio' 'value' $null @('auto', 'copy', 'aac', 'pcm', 'none')
            & $add 'audio-bitrate' 'value' $null $null $true
            & $add 'all-audio' 'flag'
            & $add 'subs' 'value' $null @('auto', 'copy', 'convert', 'none')
            & $add '10bit' 'flag' 'ten_bit'
            & $add 'keep' 'flag'
            & $add 'resume' 'flag'
            & $add 'ffmpeg-args' 'value' $null $null $false
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
            & $add 'keep-chunks' 'flag'
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

$script:BlockedFfmpegFlags = @(
    '-i', '-map', '-filter_complex', '-lavfi', '-vf', '-af', '-filter',
    '-ss', '-t', '-to', '-c', '-codec', '-y', '-n', '-f', '-vn', '-an',
    '-sn', '-dn', '-map_metadata', '-map_chapters', '-frames', '-r', '-s',
    '-aspect', '-pix_fmt',
    # Alias spellings of the blocked structural flags.
    '-vcodec', '-acodec', '-scodec', '-dcodec', '-vframes', '-aframes'
)

function Get-ValidatedFfmpegArgs {
    param($Value)
    $text = [string]$Value
    if (-not $text.Trim()) { return @() }
    $tokens = @($text -split '\s+' | Where-Object { $_ })
    $blocked = @()
    foreach ($token in $tokens) {
        if (-not $token.StartsWith('-')) { continue }
        $base = ($token -split ':', 2)[0]
        if ($script:BlockedFfmpegFlags -contains $base) { $blocked += $token }
    }
    if ($blocked.Count -gt 0) {
        throw [PipelineException]::new(
            'Blocked FFmpeg arguments: ' + ($blocked -join ', '),
            'Input, mapping, filters, and overwrite flags are controlled by the pipeline.',
            4)
    }
    return $tokens
}

function Invoke-Main {
    param([string[]]$Argv)

    $globalValueOptions = @('work-dir', 'output-dir', 'input-dir', 'config', 'ffmpeg', 'ffprobe')
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

    $validCommands = @('doctor', 'split', 'split-all', 'upscale', 'assemble', 'finish', 'run', 'status', 'clean', 'model-test')
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
    foreach ($key in @('work_dir', 'output_dir', 'input_dir', 'ffmpeg', 'ffprobe', 'max_work_gb', 'min_free_gb')) {
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
            assume_yes = $yes
        }
        $result = @(Invoke-Upscale -Jobs $jobs -Config $config -Options $options -Logger $logger -DryRun $dryRun)
        Write-Info ("Upscaled " + $result.Count + ' job(s)')
        return 0
    }

    if ($command -eq 'split-all') {
        $tonemap = if ($opts.ContainsKey('tonemap')) { $true } elseif ($opts.ContainsKey('no_tonemap')) { $false } else { $null }
        $options = @{
            format = (Get-OptionValue $opts 'format' 'png')
            png_compression = (Get-OptionValue $opts 'png_compression' 1)
            jpeg_quality = (Get-OptionValue $opts 'jpeg_quality' 1)
            denoise = (Get-OptionValue $opts 'denoise' 'none')
            decode = (Get-OptionValue $opts 'decode' 'auto')
            tonemap = $tonemap
            scale = (Get-OptionValue $opts 'scale' $config.default_scale)
            model = (Get-OptionValue $opts 'model' $config.default_model)
        }
        Invoke-SplitAll -Config $config -Options $options -Logger $logger -DryRun $dryRun
        return 0
    }

    if ($command -eq 'finish') {
        $jobs = @()
        if ($opts.ContainsKey('job')) {
            $jobs = @(Resolve-Jobs -Arguments @($opts['job']) -Config $config -AllJobs $false)
        } elseif ($opts.ContainsKey('all')) {
            $jobs = @(Resolve-Jobs -Arguments @() -Config $config -AllJobs $true)
        } else {
            $jobs = @(Select-Jobs $config $logger)
        }
        if ($jobs.Count -eq 0) { return 0 }
        if ($opts.ContainsKey('resume')) {
            $jobs = @($jobs | Where-Object { -not (Test-Path (Join-Path $_.path 'checkpoint')) })
        }
        $options = @{
            profile = (Get-OptionValue $opts 'profile' 'default')
            preset = (Get-OptionValue $opts 'preset' $null)
            encoder = (Get-OptionValue $opts 'encoder' $null)
            quality = (Get-OptionValue $opts 'quality' $null)
            crf = (Get-OptionValue $opts 'crf' $null)
            audio = (Get-OptionValue $opts 'audio' $null)
            audio_bitrate = (Get-OptionValue $opts 'audio_bitrate' 192)
            all_audio = $opts.ContainsKey('all_audio')
            subs = (Get-OptionValue $opts 'subs' $null)
            ten_bit = $opts.ContainsKey('ten_bit')
            keep = $opts.ContainsKey('keep')
            ffmpeg_args = if ($opts.ContainsKey('ffmpeg_args')) { @(Get-ValidatedFfmpegArgs $opts['ffmpeg_args']) } else { @() }
        }
        $result = Invoke-Finish -Jobs $jobs -Config $config -Options $options -Logger $logger -DryRun $dryRun
        if ($result -eq 0 -and -not $dryRun) {
            foreach ($job in $jobs) {
                $ckpt = Join-Path $job.path 'checkpoint'
                'completed=' + (Get-Date -Format 'o') | Set-Content -LiteralPath $ckpt -Encoding UTF8 -Force
            }
        }
        return $result
    }

    if ($command -eq 'model-test') {
        $videoArg = if ($opts.ContainsKey('video')) { $opts['video'] } else { $null }
        if (-not $videoArg) { throw [PipelineException]::new('--video is required for model-test.', $null, 2) }
        $scriptDir = [IO.Path]::GetDirectoryName($script:ProgramPath)
        $modelTestScript = Join-Path $scriptDir 'model-test.ps1'
        if (-not (Test-Path $modelTestScript)) { $modelTestScript = Join-Path $scriptDir '..\windows\model-test.ps1' }
        $arguments = @('-File', $modelTestScript, '-VideoPath', $videoArg)
        if ($opts.ContainsKey('frames')) { $arguments += @('-Frames', $opts['frames']) }
        if ($opts.ContainsKey('seed')) { $arguments += @('-Seed', $opts['seed']) }
        if ($opts.ContainsKey('scale')) { $arguments += @('-Scale', $opts['scale']) }
        if ($opts.ContainsKey('models-dir')) { $arguments += @('-ConfigDir', (Join-Path (Split-Path $videoArg) '..')) }
        $proc = Start-Process -FilePath 'powershell' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        return $proc.ExitCode
    }

    if ($command -eq 'assemble') {
        if ($opts.ContainsKey('quality') -and $opts.ContainsKey('crf')) {
            throw [PipelineException]::new('--quality and --crf are mutually exclusive.', $null, 4)
        }
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
        if ($opts.ContainsKey('quality') -and $opts.ContainsKey('crf')) {
            throw [PipelineException]::new('--quality and --crf are mutually exclusive.', $null, 4)
        }
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
            assume_yes = $yes
        }
        $runCleanup = $opts.ContainsKey('cleanup') -or $config.cleanup
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
            cleanup = $runCleanup
            output = $(if ($opts.ContainsKey('output')) { $opts['output'] } else { $null })
            upscaled_dir = $(if ($opts.ContainsKey('upscaled_dir')) { $opts['upscaled_dir'] } else { $null })
            pick = (Get-OptionValue $opts 'pick' 'error')
            verify_frames = $opts.ContainsKey('verify_frames')
            allow_huge = $opts.ContainsKey('allow_huge')
            force = $force
            keep_chunks = $opts.ContainsKey('keep_chunks')
        }
        $results = Invoke-RunAll -Inputs $inputs -Config $config -Options @{
            split = $split; upscale = $upscale; encode = $encode;
            cleanup = $runCleanup; stop_on_error = $opts.ContainsKey('stop_on_error');
            chunk_seconds = (Get-OptionValue $opts 'chunk_seconds' 'auto')
        } -Logger $logger -DryRun $dryRun
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
