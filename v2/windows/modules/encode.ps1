# Upscayl Video Pipeline V2 - encode module.
# Presets, encoder selection, audio and subtitle plans, encode commands.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

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
        $profileValue = @{ fast = '1'; balanced = '2'; quality = '3' }[$level]
        return @{ family = $Choice.family; video_codec = $Choice.video_codec; quality_args = @($profileValue) }
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
        $profileValue = if ($Choice.quality_args.Count -gt 0) { $Choice.quality_args[0] } else { '3' }
        return @('-c:v', 'prores_ks', '-profile:v', [string]$profileValue, '-vendor', 'apl0', '-pix_fmt', 'yuv422p10le')
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
    if ($Options.ffmpeg_args -and $Options.ffmpeg_args.Count -gt 0) {
        $arguments += $Options.ffmpeg_args
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
