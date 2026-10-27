# Run-Parity.ps1 -- cross-version parity matrix for V1 (Python) and V2 (PowerShell).
# Generates media, runs both versions on the same jobs, and compares the outputs.

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Add-Pass([string]$Name) {
    $script:Passed++
    Write-Host "PASS  $Name"
}

function Add-Fail([string]$Name, [string]$Detail) {
    $script:Failed++
    $script:Failures += "$Name`: $Detail"
    Write-Host "FAIL  $Name  ($Detail)"
}

function Assert-True([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { Add-Pass $Name } else { Add-Fail $Name $Detail }
}

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -eq "$Actual") { Add-Pass $Name }
    else { Add-Fail $Name "expected [$Expected], got [$Actual]" }
}

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:V1 = Join-Path $script:RepoRoot 'upscayl-video.py'
$script:V2 = Join-Path $script:RepoRoot 'v2\windows\UpscaylVideo.ps1'
$script:Ffmpeg = 'C:\FFMPEG\ffmpeg.exe'
$script:Ffprobe = 'C:\FFMPEG\ffprobe.exe'

if (-not (Test-Path -LiteralPath $script:Ffmpeg)) {
    $found = Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $script:Ffmpeg = $found.Source } else { throw 'ffmpeg not found' }
}
if (-not (Test-Path -LiteralPath $script:Ffprobe)) {
    $found = Get-Command ffprobe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $script:Ffprobe = $found.Source } else { throw 'ffprobe not found' }
}
$python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'python not found (required to run V1)' }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('uvp-parity-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$script:TempRoot = $tempRoot

function Invoke-Process {
    param([string]$File, [string[]]$Arguments, [string]$Name)
    $output = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit $LASTEXITCODE`n$($output | Out-String)"
    }
    return $output
}

function Invoke-V1 { param([string[]]$Arguments) Invoke-Process $python.Source (@('upscayl-video.py') + $Arguments) 'V1' }
function Invoke-V2 { param([string[]]$Arguments) Invoke-Process 'powershell.exe' (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:V2) + $Arguments) 'V2' }

function Get-MediaInfo {
    param([string]$Path)
    $json = & $script:Ffprobe -v error -print_format json -show_format -show_streams -count_frames $Path
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for $Path" }
    $data = $json | ConvertFrom-Json
    $video = @($data.streams | Where-Object { $_.codec_type -eq 'video' })[0]
    $audio = @($data.streams | Where-Object { $_.codec_type -eq 'audio' })
    $subs = @($data.streams | Where-Object { $_.codec_type -eq 'subtitle' })
    return [pscustomobject]@{
        Width = [int]$video.width
        Height = [int]$video.height
        Frames = [int]$video.nb_read_frames
        Duration = [double]$data.format.duration
        Audio = $audio.Count
        Subtitles = $subs.Count
        ColorPrimaries = $video.color_primaries
        ColorTransfer = $video.color_transfer
        ColorSpace = $video.color_space
        ColorRange = $video.color_range
        PixFmt = $video.pix_fmt
    }
}

function Compare-Outputs {
    param([string]$Name, [string[]]$Paths)
    $infos = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Add-Fail "$Name exists" "missing output: $path"
            return
        }
        $infos += (Get-MediaInfo $path)
    }
    $reference = $infos[0]
    foreach ($info in $infos) {
        if ($info.Width -ne $reference.Width -or $info.Height -ne $reference.Height) {
            Add-Fail "$Name dimensions" "$($reference.Width)x$($reference.Height) vs $($info.Width)x$($info.Height)"; return
        }
        if ($info.Frames -ne $reference.Frames) {
            Add-Fail "$Name frames" "$($reference.Frames) vs $($info.Frames)"; return
        }
        if ([math]::Abs($info.Duration - $reference.Duration) -gt 0.1) {
            Add-Fail "$Name duration" "$($reference.Duration) vs $($info.Duration)"; return
        }
        if ($info.Audio -ne $reference.Audio) {
            Add-Fail "$Name audio streams" "$($reference.Audio) vs $($info.Audio)"; return
        }
        if ($info.Subtitles -ne $reference.Subtitles) {
            Add-Fail "$Name subtitle streams" "$($reference.Subtitles) vs $($info.Subtitles)"; return
        }
        if ($info.ColorPrimaries -ne 'bt709' -or $info.ColorTransfer -ne 'bt709' -or $info.ColorSpace -ne 'bt709' -or $info.ColorRange -ne 'tv') {
            Add-Fail "$Name color tags" "$($info.ColorPrimaries)/$($info.ColorTransfer)/$($info.ColorSpace)/$($info.ColorRange)"; return
        }
    }
    Add-Pass "$Name (w=$($reference.Width) h=$($reference.Height) frames=$($reference.Frames) audio=$($reference.Audio) subs=$($reference.Subtitles))"
}

function Get-JobValues {
    param([string]$JobDir)
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath (Join-Path $JobDir 'job.txt') -Encoding UTF8)) {
        $index = $line.IndexOf('=')
        if ($index -lt 0) { continue }
        $values[$line.Substring(0, $index)] = $line.Substring($index + 1)
    }
    return $values
}

function Compare-Jobs {
    param([string]$Name, [string]$LeftJob, [string]$RightJob)
    $left = Get-JobValues $LeftJob
    $right = Get-JobValues $RightJob
    $ignore = @('created', 'updated')
    $keys = @($left.Keys | Where-Object { $ignore -notcontains $_ }) + @($right.Keys | Where-Object { $ignore -notcontains $_ })
    foreach ($key in ($keys | Sort-Object -Unique)) {
        if (-not $left.ContainsKey($key) -or -not $right.ContainsKey($key)) {
            Add-Fail "$Name key $key" 'present in only one job.txt'; return
        }
        if ($left[$key] -ne $right[$key]) {
            Add-Fail "$Name value $key" "$($left[$key]) vs $($right[$key])"; return
        }
    }
    Add-Pass "$Name job.txt keys and values"
}

function New-Fixtures {
    $root = $script:TempRoot
    $clip = Join-Path $root 'clip.mp4'
    Invoke-Process $script:Ffmpeg @(
        '-hide_banner','-loglevel','error','-y',
        '-f','lavfi','-i','testsrc2=size=160x120:rate=30',
        '-f','lavfi','-i','sine=frequency=440:sample_rate=48000',
        '-t','2','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p',
        '-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv',
        '-c:a','aac','-b:a','96k','-shortest',$clip
    ) 'fixture clip'

    $srt = Join-Path $root 'subs.srt'
    Set-Content -LiteralPath $srt -Encoding ASCII -Value @(
        '1','00:00:00,200 --> 00:00:00,800','Hello','',
        '2','00:00:01,000 --> 00:00:01,600','World',''
    )
    $chapters = Join-Path $root 'chapters.txt'
    Set-Content -LiteralPath $chapters -Encoding ASCII -Value @(
        ';FFMETADATA1','[CHAPTER]','TIMEBASE=1/1000','START=0','END=1000','title=One',
        '[CHAPTER]','TIMEBASE=1/1000','START=1000','END=2000','title=Two'
    )
    $subs = Join-Path $root 'clip_subs.mkv'
    Invoke-Process $script:Ffmpeg @(
        '-hide_banner','-loglevel','error','-y','-i',$clip,'-i',$srt,'-i',$chapters,
        '-map','0:v','-map','0:a','-map','1:s','-map_metadata','2',
        '-c:v','copy','-c:a','libmp3lame','-b:a','128k','-c:s','srt',$subs
    ) 'fixture subtitles'

    $odd = Join-Path $root 'odd.mkv'
    Invoke-Process $script:Ffmpeg @(
        '-hide_banner','-loglevel','error','-y',
        '-f','lavfi','-i','testsrc2=size=322x242:rate=30',
        '-vf','format=rgb24,crop=321:241','-t','1',
        '-c:v','ffv1','-pix_fmt','bgr0',$odd
    ) 'fixture odd'
    return @($clip, $subs, $odd)
}

clear
$fixtures = New-Fixtures
foreach ($fixture in $fixtures) {
    $name = [IO.Path]::GetFileNameWithoutExtension($fixture)
    $root = Join-Path $script:TempRoot ("case-" + $name)
    New-Item -ItemType Directory -Path $root | Out-Null
    $v1work = Join-Path $root 'v1work'
    $v2work = Join-Path $root 'v2work'
    $out = Join-Path $root 'out'
    New-Item -ItemType Directory -Path $out | Out-Null
    $common = @('--decode','cpu','--ffmpeg',$script:Ffmpeg,'--ffprobe',$script:Ffprobe)
    $encode = @('--preset','mp4-h264','--encoder','cpu','--audio','auto','--subs','auto','--ffmpeg',$script:Ffmpeg,'--ffprobe',$script:Ffprobe)

    Invoke-V1 (@('split',$fixture,'--work-dir',$v1work) + $common) | Out-Null
    Invoke-V2 (@('split',$fixture,'--work-dir',$v2work) + $common) | Out-Null
    $v1job = Get-ChildItem -LiteralPath $v1work -Directory | Select-Object -First 1
    $v2job = Get-ChildItem -LiteralPath $v2work -Directory | Select-Object -First 1
    Compare-Jobs "$name split" $v1job.FullName $v2job.FullName

    $v1Frames = Join-Path $v1job.FullName 'frames'
    $v2Frames = Join-Path $v2job.FullName 'frames'
    Invoke-V1 (@('assemble',$v1job.FullName,'--upscaled-dir',$v1Frames,'--output',(Join-Path $out 'v1-v1.mp4'),'--force') + $encode) | Out-Null
    Invoke-V2 (@('assemble',$v1job.FullName,'--upscaled-dir',$v1Frames,'--output',(Join-Path $out 'v2-v1.mp4'),'--force') + $encode) | Out-Null
    Invoke-V2 (@('assemble',$v2job.FullName,'--upscaled-dir',$v2Frames,'--output',(Join-Path $out 'v2-v2.mp4'),'--force') + $encode) | Out-Null
    Invoke-V1 (@('assemble',$v2job.FullName,'--upscaled-dir',$v2Frames,'--output',(Join-Path $out 'v1-v2.mp4'),'--force') + $encode) | Out-Null

    Compare-Outputs "$name cross-version" @(
        (Join-Path $out 'v1-v1.mp4'),
        (Join-Path $out 'v2-v1.mp4'),
        (Join-Path $out 'v2-v2.mp4'),
        (Join-Path $out 'v1-v2.mp4')
    )
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "FAIL: $_" }
    Write-Host "Artifacts: $tempRoot"
    exit 1
}
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
exit 0
