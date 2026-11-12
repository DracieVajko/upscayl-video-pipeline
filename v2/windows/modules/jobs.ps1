# Upscayl Video Pipeline V2 - jobs module.
# The job.txt contract: read, write and discover jobs.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Jobs

function New-JobData {
    param([string]$JobId, [string]$Source)
    $data = [ordered]@{}
    $data['version'] = '1'
    $data['job_id'] = $JobId
    $data['source'] = $Source
    $data['created'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $data['frame_pattern'] = ''
    $data['upscaled_dir'] = ''
    $data['frame_count'] = '0'
    $data['upscaled_count'] = '0'
    $data['chunk_seconds'] = '0'
    $data['chunk_frames'] = '0'
    $data['preset'] = ''
    $data['encoder'] = ''
    $data['audio'] = ''
    $data['audio_bitrate'] = ''
    $data['all_audio'] = '0'
    $data['subs'] = ''
    $data['ten_bit'] = '0'
    $data['target_height'] = ''
    return $data
}

function Get-JobSourceFromFolder {
    param([string]$Path)
    $sourceFile = Join-Path $Path 'source.txt'
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        $value = (Read-TextUtf8 $sourceFile).Trim()
        if ($value) { return $value }
    }
    $jobFile = Join-Path $Path 'job.txt'
    if (Test-Path -LiteralPath $jobFile -PathType Leaf) {
        $data = Read-KvFile $jobFile
        if ($data.Contains('source')) { return [string]$data['source'] }
    }
    return $null
}

function New-JobObject {
    param([string]$Path, $Data)
    return @{ path = $Path; data = $Data }
}

function Open-Job {
    param([string]$Path)
    $resolved = Resolve-AbsolutePath $Path
    $jobFile = Join-Path $resolved 'job.txt'
    if (-not (Test-Path -LiteralPath $resolved -PathType Container) -or -not (Test-Path -LiteralPath $jobFile -PathType Leaf)) {
        throw [PipelineException]::new("Not a job folder (missing job.txt): $resolved", $null, 4)
    }
    $data = Read-KvFile $jobFile
    if (-not $data.Contains('source') -or -not $data['source']) {
        $fallback = Get-JobSourceFromFolder $resolved
        if ($fallback) { $data['source'] = $fallback }
        else { throw [PipelineException]::new("Job has no source path: $resolved", $null, 4) }
    }
    return (New-JobObject $resolved $data)
}

function Get-JobSourcePath {
    param($Job)
    $value = [string]$Job.data['source']
    if (-not $value) { throw [PipelineException]::new("Job has no source path: $($Job.path)", $null, 4) }
    return (Expand-HomePath $value)
}

function Write-JobSourceFile {
    param($Job)
    $path = [string]$Job.path
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Write-TextAtomic (Join-Path $path 'source.txt') ([IO.Path]::GetFullPath((Get-JobSourcePath $Job)) + "`n")
}

function Save-Job {
    param($Job)
    $Job.data['updated'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Write-KvFile (Join-Path $Job.path 'job.txt') $Job.data
    Write-JobSourceFile $Job
}

function Get-JobValue {
    param($Job, [string]$Key, $Default = $null)
    if ($Job.data.Contains($Key)) {
        $value = $Job.data[$Key]
        if ($null -eq $value) { return $Default }
        return $value
    }
    return $Default
}

function Get-JobFramesDir {
    param($Job)
    $value = [string](Get-JobValue $Job 'frames_dir' '')
    if ($value) {
        if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
        return [IO.Path]::GetFullPath((Join-Path $Job.path $value))
    }
    return (Join-Path $Job.path 'frames')
}

function Get-JobUpscaledDir {
    param($Job)
    $value = [string](Get-JobValue $Job 'upscaled_dir' '')
    if ($value) {
        if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
        return [IO.Path]::GetFullPath((Join-Path $Job.path $value))
    }
    return (Join-Path $Job.path 'upscaled')
}

function Set-JobValue {
    param($Job, [string]$Key, $Value)
    if ($Value -is [bool]) {
        $Job.data[$Key] = $(if ($Value) { '1' } else { '0' })
    } else {
        $Job.data[$Key] = [string]$Value
    }
}

function Get-JobInt {
    param($Job, [string]$Key, [int]$Default = 0)
    $raw = Get-JobValue $Job $Key $null
    if ($null -eq $raw -or "$raw" -eq '') { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-JobBool {
    param($Job, [string]$Key, [bool]$Default = $false)
    $raw = Get-JobValue $Job $Key $null
    if ($null -eq $raw -or "$raw" -eq '') { return $Default }
    return (@('1', 'true', 'yes', 'on') -contains ([string]$raw).Trim().ToLowerInvariant())
}

function Set-JobMarker {
    param($Job, [string]$Stage)
    $path = Join-Path $Job.path ('.done_' + $Stage)
    [IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding($false)))
}

function Test-JobMarker {
    param($Job, [string]$Stage)
    return (Test-Path -LiteralPath (Join-Path $Job.path ('.done_' + $Stage)) -PathType Leaf)
}

function Clear-JobMarker {
    param($Job, [string]$Stage)
    $path = Join-Path $Job.path ('.done_' + $Stage)
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Update-JobFromMedia {
    param($Job, $Media)
    Set-JobValue $Job 'source' ([IO.Path]::GetFullPath($Media.source))
    Set-JobValue $Job 'source_size' $Media.source_size
    Set-JobValue $Job 'source_mtime' $Media.source_mtime
    Set-JobValue $Job 'source_duration' $Media.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $Job 'duration' $Media.duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    Set-JobValue $Job 'fps' $Media.fps_rational
    Set-JobValue $Job 'fps_decimal' $Media.fps_text
    Set-JobValue $Job 'width' $Media.width
    Set-JobValue $Job 'height' $Media.height
    Set-JobValue $Job 'pix_fmt' $Media.pix_fmt
    Set-JobValue $Job 'color_primaries' $(if ($Media.color_primaries) { $Media.color_primaries } else { 'unknown' })
    Set-JobValue $Job 'color_trc' $(if ($Media.color_trc) { $Media.color_trc } else { 'unknown' })
    Set-JobValue $Job 'colorspace' $(if ($Media.colorspace) { $Media.colorspace } else { 'unknown' })
    Set-JobValue $Job 'color_range' $(if ($Media.color_range) { $Media.color_range } else { 'unknown' })
    Set-JobValue $Job 'rotation' $Media.rotation
    Set-JobValue $Job 'hdr' $Media.hdr
}

function Find-OrCreateJob {
    param(
        [string]$WorkDir,
        [string]$Source,
        $Logger = $null,
        [switch]$NoCreate
    )
    $workDirPath = [IO.Path]::GetFullPath($WorkDir)
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $baseId = Sanitize-JobId ([IO.Path]::GetFileNameWithoutExtension($sourcePath))
    if (-not $NoCreate) {
        if (-not (Test-Path -LiteralPath $workDirPath)) { New-Item -ItemType Directory -Path $workDirPath -Force | Out-Null }
    }

    $candidate = Join-Path $workDirPath $baseId
    $suffix = 2
    while (Test-Path -LiteralPath $candidate) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $existingSource = Get-JobSourceFromFolder $candidate
            $same = $false
            if ($existingSource) {
                try { $same = (Test-SamePath $existingSource $sourcePath) } catch { $same = $false }
            }
            if ($same) {
                $jobFile = Join-Path $candidate 'job.txt'
                if (Test-Path -LiteralPath $jobFile -PathType Leaf) {
                    $job = Open-Job $candidate
                } else {
                    $data = New-JobData ([IO.Path]::GetFileName($candidate)) $sourcePath
                    $job = New-JobObject $candidate $data
                }
                if (-not $NoCreate) { Write-JobSourceFile $job }
                if ($Logger) { Write-DebugLog ("Reusing job: " + $candidate) }
                return $job
            }
        }
        $candidate = Join-Path $workDirPath ($baseId + '_' + $suffix)
        $suffix++
    }

    $data = New-JobData ([IO.Path]::GetFileName($candidate)) $sourcePath
    $job = New-JobObject $candidate $data
    if (-not $NoCreate) {
        New-Item -ItemType Directory -Path $candidate -Force | Out-Null
        Write-JobSourceFile $job
        if ($Logger) { Write-DebugLog ("Created job: " + $candidate) }
    }
    return $job
}

function Test-JobSourceChanged {
    param($Job)
    $data = $Job.data
    if (-not $data.Contains('source_size') -or -not $data.Contains('source_mtime')) { return $true }
    $source = Get-JobSourcePath $Job
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $true }
    $item = Get-Item -LiteralPath $source
    $size = [int64]$item.Length
    $mtime = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    $storedSize = [int64]0
    $storedMtime = [int64]0
    if (-not [int64]::TryParse([string]$data['source_size'], [ref]$storedSize)) { return $true }
    if (-not [int64]::TryParse([string]$data['source_mtime'], [ref]$storedMtime)) { return $true }
    return ($storedSize -ne $size -or $storedMtime -ne $mtime)
}

function Find-Jobs {
    param([string]$WorkDir)
    $jobs = @()
    $resolved = [IO.Path]::GetFullPath($WorkDir)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return $jobs }
    $children = Get-ChildItem -LiteralPath $resolved -Directory | Sort-Object { $_.Name.ToLowerInvariant() }
    foreach ($child in $children) {
        if (-not (Test-Path -LiteralPath (Join-Path $child.FullName 'job.txt') -PathType Leaf)) { continue }
        try {
            $jobs += (Open-Job $child.FullName)
        } catch {
            continue
        }
    }
    return $jobs
}
