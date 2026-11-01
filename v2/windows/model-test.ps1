param($VideoPath, $ConfigDir = '.', $Frames = 3, $Seed = 42, $Scale = 2, $ModelsDir = $null)

$video = [IO.Path]::GetFullPath($VideoPath)
$workDir = Join-Path ([IO.Path]::GetFullPath($ConfigDir)) 'work'
New-Item -ItemType Directory -Force $workDir | Out-Null

# Discover models
$configFile = Join-Path $ConfigDir 'config.txt'
$modelsDir = $null
if ($ModelsDir) { $modelsDir = [IO.Path]::GetFullPath($ModelsDir) }
if (-not $modelsDir -and (Test-Path $configFile)) {
    $mdLine = Select-String $configFile -Pattern '^models_dir=' | ForEach-Object { $_.Line.Substring('models_dir='.Length) } | Select-Object -First 1
    $modelsDir = if ($mdLine) { [IO.Path]::GetFullPath(($mdLine -replace '\r', '').Trim()) } else { Join-Path (Split-Path $ConfigDir -Parent) 'models' }
}
if (-not $modelsDir) { $modelsDir = Join-Path (Split-Path $ConfigDir -Parent) 'models' }

$models = @()
if (Test-Path $modelsDir) {
    $models = @(Get-ChildItem -Path $modelsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'standard|real|lite' -or $_.Name -like '*4x*' })
    if ($models.Count -eq 0) { $models = @(Get-ChildItem -Path $modelsDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 5) }
}

# Basic manifest
$testDir = Join-Path $workDir ('_model_tests' + [IO.Path]::GetFileNameWithoutExtension($video) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $testDir | Out-Null
"video=$video`nseed=$Seed`nframes=$Frames`nmodels=$($models.Count)`nscale=$Scale`nreport=$testDir\report.html`nmodels_dir=$modelsDir" | Out-File (Join-Path $testDir 'test.txt') -Encoding UTF8 -Force
Write-Host "V2 model-test (basic): $($models.Count) models, $Frames frames -> $testDir"
