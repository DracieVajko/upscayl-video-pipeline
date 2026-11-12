# Upscayl Video Pipeline V2 - chunking module.
# Chunk planning and segment concatenation.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Chunking

function Get-ChunkPlan {
    param([double]$Duration, [double]$Fps, [int]$ChunkSeconds)
    if ($ChunkSeconds -lt 10) {
        throw [PipelineException]::new('Chunk length must be at least 10 seconds', $null, 4)
    }
    if ($Duration -le 0 -or $Fps -le 0) { return @() }
    $totalFrames = [int](Round-HalfEven ($Duration * $Fps))
    $chunks = @()
    $start = 0.0
    $index = 1
    while ($start -lt $Duration - 1e-9) {
        $end = [math]::Min($Duration, $start + $ChunkSeconds)
        $startFrame = [int](Round-HalfEven ($start * $Fps)) + 1
        $endFrame = [int](Round-HalfEven ($end * $Fps))
        $frameCount = $endFrame - $startFrame + 1
        if ($frameCount -gt 0) {
            $chunks += @{ index = $index; start = $start; end = $end; start_frame = $startFrame; frame_count = $frameCount }
            $index++
        }
        $start = $end
    }
    $sum = 0
    foreach ($chunk in $chunks) { $sum += $chunk.frame_count }
    if ($sum -ne $totalFrames) {
        throw [PipelineException]::new('Internal chunk frame accounting mismatch', $null, 4)
    }
    return $chunks
}

function Write-ConcatList {
    param([string[]]$Segments, [string]$Path)
    $lines = @()
    foreach ($segment in $Segments) {
        $text = [IO.Path]::GetFullPath($segment).Replace("'", "'\''")
        $lines += ("file '" + $text + "'")
    }
    Write-TextAtomic $Path (($lines -join "`n") + "`n")
    return $Path
}

function Invoke-ConcatSegments {
    param([string]$Ffmpeg, [string[]]$Segments, [string]$Output, $Logger = $null)
    $listPath = [IO.Path]::ChangeExtension($Output, '.txt')
    $null = Write-ConcatList -Segments $Segments -Path $listPath
    $arguments = @(
        $Ffmpeg, '-hide_banner', '-nostdin', '-y', '-f', 'concat', '-safe', '0',
        '-i', $listPath, '-c', 'copy', '-fflags', '+genpts', $Output
    )
    try {
        Invoke-Child -Arguments $arguments | Out-Null
        return $Output
    } catch {
        $first = Get-PipelineException $_
    }
    $fallback = [IO.Path]::ChangeExtension($Output, '.mkv')
    $fallbackList = [IO.Path]::ChangeExtension($fallback, '.txt')
    $null = Write-ConcatList -Segments $Segments -Path $fallbackList
    $fallbackArguments = @(
        $Ffmpeg, '-hide_banner', '-nostdin', '-y', '-f', 'concat', '-safe', '0',
        '-i', $fallbackList, '-c', 'copy', '-fflags', '+genpts', $fallback
    )
    try {
        Invoke-Child -Arguments $fallbackArguments | Out-Null
        Write-Warn ('Chunk concatenation failed in ' + [IO.Path]::GetExtension($Output) + '; used Matroska fallback: ' + $fallback)
        return $fallback
    } catch {
        $second = Get-PipelineException $_
        throw [PipelineException]::new('Could not concatenate chunk segments.', ($first.Message + [Environment]::NewLine + 'Matroska fallback: ' + $second.Message), 7)
    }
}
