param($VideoPath, $ConfigDir = '.', $Frames = 3, $Seed = 42, $Scale = 2)

$video = [IO.Path]::GetFullPath($VideoPath)
$workDir = Join-Path ([IO.Path]::GetFullPath($ConfigDir)) 'work'
$outputDir = Join-Path ([IO.Path]::GetFullPath($ConfigDir)) 'output'
New-Item -ItemType Directory -Force (Join-Path $workDir '_model_tests') | Out-Null

# Discover models from config or default
$configFile = Join-Path $ConfigDir 'config.txt'
$modelsDir = ""
if (Test-Path $configFile) {
    $modelsDir = (Select-String -Path $configFile -Pattern '^models_dir=' | ForEach-Object { $_.Line.Substring('models_dir='.Length) }) -replace '\r',''
    if (-not $modelsDir) { $modelsDir = (Join-Path (Split-Path $ConfigDir -Parent) 'models') }
}
if (-not $modelsDir -or -not (Test-Path $modelsDir)) {
    $modelsDir = Join-Path (Split-Path $ConfigDir -Parent) 'models'
}
if (Test-Path $modelsDir) {
    $models = Get-ChildItem -Path $modelsDir -Directory | Select-Object -Property @{N='name';E={$_.Name}}, @{N='path';E={$_.FullName}} | Where-Object { $_.name -like '*standard*' -or $_.name -like '*real*' }
} else {
    $models = @()
}

$testDir = Join-Path $workDir ('_model_tests' + [IO.Path]::GetFileNameWithoutExtension($video) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $testDir | Out-Null

# Basic manifest
"video=$video`nseed=$Seed`nframes=$Frames`nmodels=$($models.Count)`nscale=$Scale`nreport=$testDir\report.html" | Out-File (Join-Path $testDir 'test.txt') -Encoding utf8
Write-Host "V2 model-test (basic): $($models.Count) models, $Frames frames -> $testDir"
