# Upscayl Video Pipeline V2 - media module.
# Media probing (ffprobe) helpers.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Probing

function Get-JsonValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $value = $property.Value
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and $value -eq '') { return $Default }
    return $value
}

function ConvertTo-IntSafe {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-DoubleSafe {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Get-CleanText {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if (-not $text -or $text.ToLowerInvariant() -eq 'unknown') { return $null }
    return $text
}

function Get-RotationValue {
    param($Video)
    $sideData = Get-JsonValue $Video 'side_data_list' $null
    if ($sideData) {
        foreach ($item in @($sideData)) {
            $rotation = Get-JsonValue $item 'rotation' $null
            if ($null -ne $rotation) {
                $value = ConvertTo-IntSafe $rotation 0
                return ((($value % 360) + 360) % 360)
            }
        }
    }
    $tags = Get-JsonValue $Video 'tags' $null
    if ($tags) {
        $rotate = Get-JsonValue $tags 'rotate' $null
        if ($null -ne $rotate) {
            $value = ConvertTo-IntSafe $rotate 0
            return ((($value % 360) + 360) % 360)
        }
    }
    return 0
}

function Get-TagDuration {
    param($Value)
    if (-not $Value) { return $null }
    try { return (Parse-TimeValue ([string]$Value)) } catch { return $null }
}

function ConvertTo-StreamInfo {
    param($Stream)
    $tags = Get-JsonValue $Stream 'tags' $null
    $duration = ConvertTo-DoubleSafe (Get-JsonValue $Stream 'duration' 0.0) 0.0
    if (-not $duration -and $tags) {
        $fromTag = Get-TagDuration (Get-JsonValue $tags 'DURATION' $null)
        if ($null -ne $fromTag) { $duration = $fromTag }
    }
    $language = $null
    $title = $null
    if ($tags) {
        $language = Get-JsonValue $tags 'language' $null
        $title = Get-JsonValue $tags 'title' $null
    }
    $channels = $null
    if ($null -ne (Get-JsonValue $Stream 'channels' $null)) {
        $channels = ConvertTo-IntSafe (Get-JsonValue $Stream 'channels' 0) 0
    }
    $bitRate = $null
    if ($null -ne (Get-JsonValue $Stream 'bit_rate' $null)) {
        $bitRate = ConvertTo-IntSafe (Get-JsonValue $Stream 'bit_rate' 0) 0
    }
    return @{
        index      = (ConvertTo-IntSafe (Get-JsonValue $Stream 'index' 0) 0)
        codec_name = [string](Get-JsonValue $Stream 'codec_name' 'unknown')
        channels   = $channels
        bit_rate   = $bitRate
        language   = $language
        title      = $title
        duration   = $duration
    }
}

function Get-LastVideoEnd {
    param([string]$Ffprobe, [string]$Source, [double]$FormatDuration, $Logger = $null)
    if ($FormatDuration -le 0) { return $null }
    $start = [math]::Max(0.0, $FormatDuration - 2.0)
    $arguments = @(
        $Ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'packet=pts_time,duration_time',
        '-of', 'csv=p=0', '-read_intervals', ($start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + '%+2.0'),
        $Source
    )
    try {
        $result = Invoke-Child -Arguments $arguments -NoCheck
    } catch {
        return $null
    }
    if ($result.ExitCode -ne 0) { return $null }
    $lastEnd = $null
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $parts = $line.Split(',')
        if ($parts.Count -lt 1 -or -not $parts[0].Trim()) { continue }
        $pts = ConvertTo-DoubleSafe $parts[0].Trim() 0.0
        $duration = 0.0
        if ($parts.Count -gt 1) { $duration = ConvertTo-DoubleSafe $parts[1].Trim() 0.0 }
        $end = $pts + $duration
        # Packets are emitted in decode order; track the maximum end, not the
        # last line, so B-frames do not shrink the reported duration.
        if ($null -eq $lastEnd -or $end -gt $lastEnd) { $lastEnd = $end }
    }
    return $lastEnd
}

function Get-MediaInfo {
    param([string]$Ffprobe, [string]$Source, $Logger = $null)

    $arguments = @(
        $Ffprobe, '-v', 'error', '-print_format', 'json',
        '-show_format', '-show_streams', '-show_chapters', '-count_packets', $Source
    )
    try {
        $result = Invoke-Child -Arguments $arguments
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new("ffprobe failed for: $Source", $ex.Message, 4)
    }
    try {
        $data = $result.StdOut | ConvertFrom-Json
    } catch {
        throw [PipelineException]::new("ffprobe returned invalid JSON for: $Source", $_.Exception.Message, 4)
    }

    $video = $null
    foreach ($stream in @($data.streams)) {
        if ($stream.codec_type -eq 'video') { $video = $stream; break }
    }
    if ($null -eq $video) {
        throw [PipelineException]::new("No video stream found in: $Source", $null, 4)
    }

    $fps = Get-NormalizedFps ([string](Get-JsonValue $video 'avg_frame_rate' '')) ([string](Get-JsonValue $video 'r_frame_rate' ''))
    $packetCount = ConvertTo-IntSafe (Get-JsonValue $video 'nb_read_packets' (Get-JsonValue $video 'nb_frames' 0)) 0
    $duration = ConvertTo-DoubleSafe (Get-JsonValue $video 'duration' 0.0) 0.0
    if ($duration -le 0 -and $packetCount -gt 0 -and $fps.Den -gt 0) {
        $duration = ($packetCount * $fps.Den) / $fps.Num
    }
    if ($duration -le 0) {
        $formatInfo = Get-JsonValue $data 'format' $null
        $duration = ConvertTo-DoubleSafe (Get-JsonValue $formatInfo 'duration' 0.0) 0.0
    }

    $width = ConvertTo-IntSafe (Get-JsonValue $video 'width' 0) 0
    $height = ConvertTo-IntSafe (Get-JsonValue $video 'height' 0) 0
    if ($width -le 0 -or $height -le 0) {
        throw [PipelineException]::new("Invalid video dimensions in: $Source", $null, 4)
    }

    $audio = @()
    $subtitles = @()
    foreach ($stream in @($data.streams)) {
        if ($stream.codec_type -eq 'audio') { $audio += (ConvertTo-StreamInfo $stream) }
        if ($stream.codec_type -eq 'subtitle') { $subtitles += (ConvertTo-StreamInfo $stream) }
    }

    $chapters = 0
    if ($null -ne $data.chapters) { $chapters = @($data.chapters).Count }

    $item = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
    $sourceSize = 0
    $sourceMtime = 0
    if ($item) {
        $sourceSize = [int64]$item.Length
        $sourceMtime = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    $colorTrc = Get-CleanText (Get-JsonValue $video 'color_transfer' $null)
    $sampleAspect = Get-CleanText (Get-JsonValue $video 'sample_aspect_ratio' $null)
    $media = @{
        source              = [IO.Path]::GetFullPath($Source)
        duration            = $duration
        fps_num             = $fps.Num
        fps_den             = $fps.Den
        fps_rational        = $fps.Rational
        fps_decimal         = $fps.Decimal
        fps_text            = $fps.Text
        width               = $width
        height              = $height
        pix_fmt             = [string](Get-JsonValue $video 'pix_fmt' 'unknown')
        video_index         = (ConvertTo-IntSafe (Get-JsonValue $video 'index' 0) 0)
        audio               = $audio
        subtitles           = $subtitles
        chapters            = $chapters
        color_primaries     = (Get-CleanText (Get-JsonValue $video 'color_primaries' $null))
        color_trc           = $colorTrc
        colorspace          = (Get-CleanText (Get-JsonValue $video 'color_space' $null))
        color_range         = (Get-CleanText (Get-JsonValue $video 'color_range' $null))
        rotation            = (Get-RotationValue $video)
        hdr                 = (@('smpte2084', 'arib-std-b67') -contains ([string]$colorTrc).ToLowerInvariant())
        source_size         = $sourceSize
        source_mtime        = $sourceMtime
        nb_frames           = $(if ($packetCount -gt 0) { $packetCount } else { $null })
        sample_aspect_ratio = $sampleAspect
    }

    $streamDuration = ConvertTo-DoubleSafe (Get-JsonValue $video 'duration' 0.0) 0.0
    if ($streamDuration -le 0 -and $packetCount -le 0) {
        $formatInfo = Get-JsonValue $data 'format' $null
        $formatDuration = ConvertTo-DoubleSafe (Get-JsonValue $formatInfo 'duration' 0.0) 0.0
        $end = Get-LastVideoEnd -Ffprobe $Ffprobe -Source $Source -FormatDuration $formatDuration -Logger $Logger
        if ($null -ne $end -and $end -gt 0) { $media.duration = $end }
    }
    return $media
}

function Get-FirstFrameDimensions {
    param([string]$Ffprobe, [string]$Path, $Logger = $null)
    $arguments = @(
        $Ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height', '-of', 'csv=p=0', $Path
    )
    try {
        $result = Invoke-Child -Arguments $arguments
    } catch {
        $ex = Get-PipelineException $_
        throw [PipelineException]::new("Could not read frame dimensions: $Path", $ex.Message, 4)
    }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $parts = $line.Split(',')
        if ($parts.Count -ge 2) {
            $width = 0
            $height = 0
            if ([int]::TryParse($parts[0].Trim(), [ref]$width) -and [int]::TryParse($parts[1].Trim(), [ref]$height)) {
                return @($width, $height)
            }
        }
    }
    throw [PipelineException]::new("Could not parse frame dimensions: $Path", $null, 4)
}
