# Test-V2.ps1 -- plain PowerShell test harness for the V2 Windows implementation.
# No Pester dependency. Exits nonzero when any assertion fails.

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -ceq "$Actual") {
        $script:Passed++
    } else {
        $script:Failed++
        $script:Failures += "$Name`: expected [$Expected], got [$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
    } else {
        $script:Failed++
        $script:Failures += "$Name`: condition was false"
    }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Name)
    if ($Actual -match $Pattern) {
        $script:Passed++
    } else {
        $script:Failed++
        $script:Failures += "$Name`: [$Actual] did not match [$Pattern]"
    }
}

$script:TestDir = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:TestDir)
$script:Script = Join-Path $script:RepoRoot 'v2\windows\UpscaylVideo.ps1'

Assert-True (Test-Path -LiteralPath $script:Script) 'UpscaylVideo.ps1 exists'

if (Test-Path -LiteralPath $script:Script) {
    $env:UPSCAYL_V2_LIB = '1'
    . $script:Script
    $env:UPSCAYL_V2_LIB = $null

    # --- sanitize_job_id ---
    Assert-Equal 'video' (Sanitize-JobId '') 'sanitize empty'
    Assert-Equal 'video' (Sanitize-JobId '   ') 'sanitize spaces'
    Assert-Equal 'a_b' (Sanitize-JobId 'a  b') 'sanitize whitespace'
    Assert-Equal 'a_b' (Sanitize-JobId 'a__b') 'sanitize repeated underscore'
    Assert-Equal 'a_b' (Sanitize-JobId 'a<b') 'sanitize invalid char'
    Assert-Equal 'CON_' (Sanitize-JobId 'CON') 'sanitize reserved name'
    Assert-Equal ('x' * 80) (Sanitize-JobId ('x' * 200)) 'sanitize truncation'
    Assert-Equal 'žluťoučký' (Sanitize-JobId 'žluťoučký') 'sanitize unicode preserved'

    # --- parse_time ---
    Assert-Equal 5 (Parse-TimeValue '5') 'parse_time seconds'
    Assert-Equal 65 (Parse-TimeValue '1:05') 'parse_time mm:ss'
    Assert-Equal 3661.5 (Parse-TimeValue '1:01:01.5') 'parse_time hh:mm:ss'
    $threw = $false
    try { Parse-TimeValue '1:99' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'parse_time rejects 1:99'

    # --- fps rational ---
    $fps = Get-NormalizedFps '30000/1001' '60/1'
    Assert-Equal '30000/1001' $fps.Rational 'fps rational'
    Assert-Equal '29.970' $fps.Text 'fps decimal'
    $fps = Get-NormalizedFps '0/0' '25/1'
    Assert-Equal '25/1' $fps.Rational 'fps fallback to r_frame_rate'
    $fps = Get-NormalizedFps '0/0' '0/0'
    Assert-Equal '30/1' $fps.Rational 'fps default 30'

    # --- format helpers ---
    Assert-Equal '00:00:07.532' (Format-Duration 7.532) 'duration format'
    Assert-Equal '1.0 KiB' (Format-Bytes 1024) 'bytes KiB'
    Assert-Equal '1.5 MiB' (Format-Bytes (1572864)) 'bytes MiB'

    # --- key=value files ---
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("v2test-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $kvPath = Join-Path $temp 'job.txt'
        [IO.File]::WriteAllText($kvPath, "version=1`nsource=C:\a b\c=d.mov`n# comment`n`nempty=`n", (New-Object System.Text.UTF8Encoding($false)))
        $kv = Read-KvFile $kvPath
        Assert-Equal '1' $kv['version'] 'kv version'
        Assert-Equal 'C:\a b\c=d.mov' $kv['source'] 'kv value with spaces and equals'
        Assert-Equal '' $kv['empty'] 'kv empty value'
        Assert-True (-not $kv.Contains('# comment')) 'kv skips comments'
        $kv['later'] = 'x'
        Write-KvFile $kvPath $kv
        $again = Read-KvFile $kvPath
        Assert-Equal 'x' $again['later'] 'kv write roundtrip'
        Assert-Equal 'C:\a b\c=d.mov' $again['source'] 'kv preserve value'

        # --- config parsing ---
        $cfgPath = Join-Path $temp 'config.txt'
        [IO.File]::WriteAllText($cfgPath, "default_scale=3`nwork_dir=relative work`ndefault_preset=mkv-hevc`ncleanup=1`n", (New-Object System.Text.UTF8Encoding($false)))
        $cfg = Get-Config -ConfigPath $cfgPath -ToolDir $temp
        Assert-Equal 3 $cfg.default_scale 'config scale'
        Assert-Equal 'mkv-hevc' $cfg.default_preset 'config preset'
        Assert-Equal $true $cfg.cleanup 'config cleanup bool'
        Assert-Equal (Join-Path $temp 'relative work') $cfg.work_dir 'config work_dir relative to config'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ThrowsCode {
    param([scriptblock]$Action, [int]$Code, [string]$Name)
    try {
        & $Action | Out-Null
        $script:Failed++
        $script:Failures += "$Name`: expected exit code $Code, nothing was thrown"
    } catch {
        $ex = Get-PipelineException $_
        if ($ex -is [PipelineException] -and $ex.ExitCode -eq $Code) {
            $script:Passed++
        } else {
            $script:Failed++
            $script:Failures += "$Name`: expected exit code $Code, got [$($ex.GetType().Name)] $($ex.Message)"
        }
    }
}

    # --- fps override ---
    $fpsOverride = Get-FpsOverride '29.97'
    Assert-Equal '2997/100' ($fpsOverride[0].ToString() + '/' + $fpsOverride[1]) 'fps override 29.97'
    $fpsOverride = Get-FpsOverride '30000/1001'
    Assert-Equal '30000/1001' ($fpsOverride[0].ToString() + '/' + $fpsOverride[1]) 'fps override rational'
    Assert-ThrowsCode { Get-FpsOverride 'abc' } 4 'fps override rejects text'

    # --- output dimensions ---
    $dims = Get-OutputDimensions -FrameWidth 640 -FrameHeight 480 -TargetHeight 240 -AllowHuge $false
    Assert-Equal '320x240' ($dims[0].ToString() + 'x' + $dims[1]) 'dimensions target 240'
    Assert-ThrowsCode { Get-OutputDimensions -FrameWidth 640 -FrameHeight 480 -TargetHeight 720 -AllowHuge $false } 4 'dimensions rejects target above frame'
    Assert-ThrowsCode { Get-OutputDimensions -FrameWidth 9000 -FrameHeight 100 -TargetHeight $null -AllowHuge $false } 4 'dimensions rejects >8192'

    # --- chunk plan ---
    $chunks = @(Get-ChunkPlan -Duration 12 -Fps 30 -ChunkSeconds 10)
    Assert-Equal 2 $chunks.Count 'chunk count'
    Assert-Equal 300 $chunks[0].frame_count 'chunk 1 frames'
    Assert-Equal 60 $chunks[1].frame_count 'chunk 2 frames'
    Assert-Equal 301 $chunks[1].start_frame 'chunk 2 start frame'
    Assert-ThrowsCode { Get-ChunkPlan -Duration 12 -Fps 30 -ChunkSeconds 5 } 4 'chunk rejects <10s'

    # --- tile and batch ---
    Assert-Equal 128 (Resolve-Tile 'auto' 4096) 'tile 4 GiB'
    Assert-Equal 256 (Resolve-Tile 'auto' 8192) 'tile 8 GiB'
    Assert-Equal 512 (Resolve-Tile 'auto' 12288) 'tile 12 GiB'
    Assert-Equal 256 (Resolve-Tile 'auto' $null) 'tile unknown'
    Assert-Equal 128 (Resolve-Tile '128' $null) 'tile explicit'
    Assert-ThrowsCode { Resolve-Tile '16' $null } 4 'tile rejects below 32'
    Assert-Equal 50 (Resolve-BatchSize 0 4000 3000) 'batch >8MP'
    Assert-Equal 100 (Resolve-BatchSize 0 1920 1080) 'batch normal'
    Assert-Equal 7 (Resolve-BatchSize 7 4000 3000) 'batch explicit'

    # --- audio planning ---
    $media = @{
        audio = @(
            @{ index = 1; codec_name = 'aac'; channels = 2; bit_rate = 128000; language = $null; title = $null; duration = 5.0 },
            @{ index = 3; codec_name = 'opus'; channels = 2; bit_rate = 96000; language = $null; title = $null; duration = 5.0 }
        )
    }
    $mp4 = Resolve-Preset 'mp4-h264'
    $plan = Get-AudioPlan -Media $media -Preset $mp4 -Mode 'auto' -Bitrate 192 -AllAudio $true
    Assert-Equal 2 $plan.streams.Count 'audio auto all count'
    Assert-Equal 'copy' $plan.streams[0].mode 'audio auto copies aac'
    Assert-Equal 'aac' $plan.streams[1].mode 'audio auto encodes opus'
    $plan = Get-AudioPlan -Media $media -Preset $mp4 -Mode 'copy' -Bitrate 192 -AllAudio $false
    Assert-Equal 'copy' $plan.streams[0].mode 'audio copy first track'
    Assert-ThrowsCode { Get-AudioPlan -Media $media -Preset $mp4 -Mode 'copy' -Bitrate 192 -AllAudio $true } 4 'audio copy rejects opus'
    $plan = Get-AudioPlan -Media $media -Preset $mp4 -Mode 'none' -Bitrate 192 -AllAudio $true
    Assert-True (-not $plan.enabled) 'audio none disabled'
    Assert-ThrowsCode { Get-AudioPlan -Media $media -Preset $mp4 -Mode 'pcm' -Bitrate 192 -AllAudio $false } 4 'pcm rejected in mp4'

    # --- subtitle planning ---
    $subsMedia = @{
        subtitles = @(
            @{ index = 2; codec_name = 'subrip' },
            @{ index = 4; codec_name = 'hdmv_pgs_subtitle' }
        )
    }
    $plan = Get-SubtitlePlan -Media $subsMedia -Preset $mp4 -Mode 'auto'
    Assert-Equal 1 $plan.streams.Count 'subs auto mp4 keeps text'
    Assert-Equal 'mov_text' $plan.streams[0].mode 'subs auto mp4 converts'
    Assert-Equal 1 $plan.dropped.Count 'subs auto mp4 drops pgs'
    $mkv = Resolve-Preset 'mkv-hevc'
    $movTextMedia = @{ subtitles = @(@{ index = 2; codec_name = 'mov_text' }) }
    $plan = Get-SubtitlePlan -Media $movTextMedia -Preset $mkv -Mode 'auto'
    Assert-Equal 'subrip' $plan.streams[0].mode 'subs auto mkv converts mov_text'
    Assert-ThrowsCode { Get-SubtitlePlan -Media $movTextMedia -Preset $mkv -Mode 'copy' } 4 'subs copy rejects mov_text in mkv'

    # --- color fallback ---
    $fakeJob = @{ path = 'x'; data = [ordered]@{} }
    Assert-Equal 'smpte170m' (Get-ColorValue $fakeJob 'gbr' 'colorspace' -Height 240) 'color gbr falls back to sd'
    Assert-Equal 'bt709' (Get-ColorValue $fakeJob 'gbr' 'colorspace' -Height 1080) 'color gbr falls back to hd'
    Assert-Equal 'tv' (Get-ColorValue $fakeJob 'weird' 'color_range' -Height 240) 'color range invalid to tv'
    Assert-Equal 'pc' (Get-ColorValue $fakeJob 'pc' 'color_range' -Height 240) 'color range pc kept'

    # --- segment command honors target height ---
    $segJob = @{ path = 'x'; data = [ordered]@{ fps = '30/1' } }
    $segMedia = @{
        fps_rational = '30/1'; fps_den = 1; fps_decimal = 30.0
        color_primaries = 'bt709'; color_trc = 'bt709'; colorspace = 'bt709'
        color_range = 'tv'; chapters = 0
    }
    $segFrames = @{ directory = 'frames'; extension = 'png'; indices = @(1); paths = @('frames/frame_00000001.png'); count = 1 }
    $segOptions = @{
        quality = 'balanced'; crf = $null; target_height = 240; ten_bit = $false
        allow_huge = $false; preset = 'mp4-h264'
    }
    $segChoice = @{ family = 'cpu'; video_codec = 'libx264'; quality_args = @() }
    $segCommand = Build-SegmentCommand -Job $segJob -FrameSet $segFrames -Media $segMedia -Preset (Resolve-Preset 'mp4-h264') -Encoder $segChoice -Options $segOptions -Output 'chunk.ts' -FrameWidth 640 -FrameHeight 480
    Assert-True (@($segCommand) -contains '-vf') 'segment has filters'
    Assert-True (@($segCommand) -contains 'scale=-2:240:flags=lanczos') 'segment honors target height'
    Assert-True (@($segCommand) -contains 'mpegts') 'segment uses mpegts'

    # --- encoder candidates ---
    $ffmpeg = 'C:\FFMPEG\ffmpeg.exe'
    if (Test-Path -LiteralPath $ffmpeg) {
        $candidates = @(Get-EncoderCandidates $mp4 'auto' $ffmpeg)
        Assert-True ($candidates.Count -ge 1) 'encoder candidates non-empty'
        $forced = @(Get-EncoderCandidates $mp4 'cpu' $ffmpeg)
        Assert-Equal 'libx264' $forced[0].video_codec 'encoder cpu forced'
    }

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
exit 0

