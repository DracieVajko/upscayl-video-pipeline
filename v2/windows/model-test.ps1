param($VideoPath, $ConfigDir = '.', $Frames = 3, $Seed = 42, $Scale = 2, $ModelsDir = $null)

# Manifest-only stub: it records the inputs and the candidate models but does
# not run Upscayl yet. Use V1 (`upscayl-video model-test`) for a real report.

$video = [IO.Path]::GetFullPath($VideoPath)
$workDir = Join-Path ([IO.Path]::GetFullPath($ConfigDir)) 'work'
New-Item -ItemType Directory -Force $workDir | Out-Null

$configFile = Join-Path $ConfigDir 'config.txt'
$modelsDir = $null
if ($ModelsDir) { $modelsDir = [IO.Path]::GetFullPath($ModelsDir) }
if (-not $modelsDir -and (Test-Path $configFile)) {
    $mdLine = Select-String $configFile -Pattern '^models_dir=' |
        ForEach-Object { $_.Line.Substring('models_dir='.Length) } |
        Select-Object -First 1
    $modelsDir = if ($mdLine) {
        [IO.Path]::GetFullPath(($mdLine -replace '\r', '').Trim())
    } else {
        Join-Path (Split-Path $ConfigDir -Parent) 'models'
    }
}
if (-not $modelsDir) { $modelsDir = Join-Path (Split-Path $ConfigDir -Parent) 'models' }

$models = @()
if (Test-Path $modelsDir) {
    $models = @(Get-ChildItem -Path $modelsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'standard|real|lite' -or $_.Name -like '*4x*' })
    if ($models.Count -eq 0) {
        $models = @(Get-ChildItem -Path $modelsDir -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 5)
    }
}

$testDir = Join-Path $workDir ('_model_tests' +
    [IO.Path]::GetFileNameWithoutExtension($video) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $testDir | Out-Null

$manifest = @(
    "video=$video"
    "seed=$Seed"
    "frames=$Frames"
    "models=$($models.Count)"
    "scale=$Scale"
    "models_dir=$modelsDir"
    'status=stub'
    'report='
    'note=V2 model-test does not run Upscayl yet; use V1 for a real comparison report.'
)
Set-Content -LiteralPath (Join-Path $testDir 'test.txt') -Value $manifest -Encoding UTF8 -Force

Write-Host ("V2 model-test stub: {0} candidate model(s), {1} frame(s) planned -> {2}" -f $models.Count, $Frames, $testDir)
Write-Host 'No Upscayl runs were performed. Use V1 model-test for a real HTML report.'
