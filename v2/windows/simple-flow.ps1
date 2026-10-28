param($VideoPath, $OutputDir = 'output', $Scale = 2, $WorkDir = 'work')
$video = [IO.Path]::GetFullPath($VideoPath)
$outDir = [IO.Path]::GetFullPath($OutputDir)
$workDir = [IO.Path]::GetFullPath($WorkDir)
New-Item -ItemType Directory -Force $workDir | Out-Null
New-Item -ItemType Directory -Force $outDir | Out-Null
Write-Host "Simple flow: VIDEO=$video WORK=$workDir OUTPUT=$outDir SCALE=$Scale"
# After upscayl + ffmpeg: clean work intermediates, keep original + output
if (Test-Path $workDir) {
    Get-ChildItem $workDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Done. Original: $video. Output: $outDir. Work cleaned: $workDir."
