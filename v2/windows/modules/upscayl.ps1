# Upscayl Video Pipeline V2 - upscayl module.
# Upscayl discovery, model lists, batching and frame upscaling.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Upscayl discovery and batching

function Get-ModelList {
    param([string]$ModelsDir)
    if (-not (Test-Path -LiteralPath $ModelsDir -PathType Container)) {
        throw [PipelineException]::new("Upscayl models directory not found: $ModelsDir", $null, 3)
    }
    $models = @()
    $params = Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.param' | Sort-Object Name
    foreach ($param in $params) {
        $weights = [IO.Path]::ChangeExtension($param.FullName, '.bin')
        if (Test-Path -LiteralPath $weights -PathType Leaf) {
            $models += @{ name = [IO.Path]::GetFileNameWithoutExtension($param.Name); param = $param.FullName; weights = $weights }
        }
    }
    if ($models.Count -eq 0) {
        throw [PipelineException]::new("No complete Upscayl models found in: $ModelsDir", 'Each model needs matching .param and .bin files.', 3)
    }
    return $models
}

function Find-NvidiaIcd {
    $base = 'C:\Windows\System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $null }
    $directories = Get-ChildItem -LiteralPath $base -Directory -Filter 'nv*' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($directory in $directories) {
        $candidate = Join-Path $directory.FullName 'nv-vk64.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Resolve-Icd {
    param($Config, [string]$Override = $null)
    $value = if ($null -ne $Override -and ([string]$Override).Trim()) { ([string]$Override).Trim() } else { ([string]$Config.icd).Trim() }
    if (-not $value -or $value.ToLowerInvariant() -eq 'none') { return $null }
    if ($value.ToLowerInvariant() -eq 'auto') { return (Find-NvidiaIcd) }
    $path = Resolve-AbsolutePath (Expand-HomePath $value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw [PipelineException]::new("Vulkan ICD JSON not found: $path", $null, 4)
    }
    return $path
}

function Get-UpscaylBinaryCandidates {
    $candidates = @()
    if ($env:UPSCAYL_BIN) { $candidates += $env:UPSCAYL_BIN }
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    $candidates += (Join-Path $programFiles 'Upscayl\resources\bin\upscayl-bin.exe')
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Upscayl\resources\bin\upscayl-bin.exe')
    }
    $found = Get-Command 'upscayl-bin' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { $found = Get-Command 'upscayl-bin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($found -and $found.Source) { $candidates += $found.Source }
    return $candidates
}

function Resolve-UpscaylBinary {
    param($Config)
    if ($Config.upscayl_bin) {
        $configured = Expand-HomePath ([string]$Config.upscayl_bin)
        if (Test-Path -LiteralPath $configured -PathType Container) {
            $configured = Join-Path $configured 'upscayl-bin.exe'
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) { return [IO.Path]::GetFullPath($configured) }
        throw [PipelineException]::new("Upscayl CLI not found: $configured", 'Set upscayl_bin in config.txt or pass --upscayl-bin.', 3)
    }
    foreach ($candidate in (Get-UpscaylBinaryCandidates)) {
        if (-not $candidate) { continue }
        $path = Expand-HomePath ([string]$candidate)
        if (Test-Path -LiteralPath $path -PathType Container) { $path = Join-Path $path 'upscayl-bin.exe' }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
    }
    throw [PipelineException]::new('Upscayl CLI not found.', 'Install Upscayl or set upscayl_bin in config.txt / --upscayl-bin.', 3)
}

function Resolve-ModelsDirectory {
    param($Config, [string]$Binary)
    $candidates = @()
    if ($Config.models_dir) { $candidates += [string]$Config.models_dir }
    if ($env:UPSCAYL_MODELS) { $candidates += $env:UPSCAYL_MODELS }
    $binaryParent = Split-Path -Parent $Binary
    $binaryRoot = Split-Path -Parent $binaryParent
    $candidates += (Join-Path $binaryRoot 'models')
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    $candidates += (Join-Path $programFiles 'Upscayl\resources\models')
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Upscayl\resources\models')
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $path = Expand-HomePath ([string]$candidate)
        if (Test-Path -LiteralPath $path -PathType Container) { return [IO.Path]::GetFullPath($path) }
    }
    throw [PipelineException]::new('Upscayl models directory not found.', 'Set models_dir in config.txt or pass --models-dir.', 3)
}

function Get-UpscaylPaths {
    param($Config)
    $binary = Resolve-UpscaylBinary $Config
    $models = Resolve-ModelsDirectory $Config $binary
    if ([IO.Path]::GetFileName($models).ToLowerInvariant() -ne 'models') {
        throw [PipelineException]::new("Upscayl model directory must be named 'models': $models", 'Rename the folder or create a folder named models containing matching .param/.bin files.', 3)
    }
    $null = Get-ModelList $models
    return @{ binary = $binary; models_dir = $models }
}

function Get-VramMb {
    $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($smi -and $smi.Source) {
        try {
            $result = Invoke-Child -Arguments @($smi.Source, '--query-gpu=memory.total', '--format=csv,noheader,nounits') -NoCheck
        } catch {
            $result = $null
        }
        if ($result -and $result.ExitCode -eq 0) {
            foreach ($line in ($result.StdOut -split "`r?`n")) {
                $parsed = 0
                if ([int]::TryParse($line.Trim(), [ref]$parsed)) { return $parsed }
            }
        }
    }
    $wmic = Get-Command 'wmic' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wmic -and $wmic.Source) {
        try {
            $result = Invoke-Child -Arguments @($wmic.Source, 'path', 'win32_VideoController', 'get', 'AdapterRAM') -NoCheck
            if ($result.ExitCode -eq 0) {
                $values = @()
                foreach ($line in ($result.StdOut -split "`r?`n")) {
                    $parsed = [int64]0
                    if ([int64]::TryParse($line.Trim(), [ref]$parsed)) { $values += $parsed }
                }
                if ($values.Count -gt 0) {
                    return [int](($values | Measure-Object -Maximum).Maximum / (1024 * 1024))
                }
            }
        } catch {
            Write-DebugLog ("Could not detect the VRAM size: {0}" -f $_.Exception.Message)
        }
    }
    return $null
}

function Resolve-Tile {
    param([string]$Requested, $VramMb)
    $value = ([string]$Requested).Trim().ToLowerInvariant()
    if ($value -eq 'auto') {
        if ($null -eq $VramMb) { return 256 }
        if ($VramMb -le 4096) { return 128 }
        if ($VramMb -le 8192) { return 256 }
        return 512
    }
    $tile = 0
    if (-not [int]::TryParse($value, [ref]$tile)) {
        throw [PipelineException]::new("Invalid tile size: $Requested", $null, 4)
    }
    if ($tile -lt 32) {
        throw [PipelineException]::new('Tile size must be at least 32', $null, 4)
    }
    return $tile
}

function Resolve-BatchSize {
    param([int]$Requested, [int]$FrameWidth, [int]$FrameHeight)
    if ($Requested -gt 0) { return $Requested }
    if (([int64]$FrameWidth * $FrameHeight) -gt 8000000) { return 50 }
    return 100
}

function Invoke-UpscaylSmoke {
    param($Paths, [string]$Model, [int]$Tile, $Icd, [string]$Ffmpeg, $Logger = $null)
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('upscayl-smoke-' + [guid]::NewGuid().ToString('n'))
    $source = Join-Path $tempDir 'in'
    $target = Join-Path $tempDir 'out'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    try {
        try {
            $make = Invoke-Child -Arguments @($Ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=gray:s=64x64', '-frames:v', '1', (Join-Path $source 'test.png')) -NoCheck
            if ($make.ExitCode -ne 0) {
                return @{ ok = $false; detail = ('test PNG failed: ' + (Get-TextTail $make.StdErr 5)) }
            }
        } catch {
            return @{ ok = $false; detail = ('test PNG failed: ' + (Get-PipelineException $_).Message) }
        }
        $envMap = $null
        if ($Icd) { $envMap = @{ 'VK_ICD_FILENAMES' = [string]$Icd } }
        $arguments = @(
            $Paths.binary, '-i', $source, '-o', $target, '-m', $Paths.models_dir,
            '-n', $Model, '-s', '2', '-g', '0', '-t', [string]$Tile, '-f', 'png', '-c', '0'
        )
        try {
            $null = Invoke-Child -Arguments $arguments -Environment $envMap -WorkingDirectory (Split-Path -Parent $Paths.binary)
        } catch {
            $ex = Get-PipelineException $_
            return @{ ok = $false; detail = $ex.Message.Substring(0, [math]::Min(500, $ex.Message.Length)) }
        }
        $output = Join-Path $target 'test.png'
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -le 0) {
            return @{ ok = $false; detail = 'Upscayl produced no output file' }
        }
        return @{ ok = $true; detail = 'OK' }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-MissingIndices {
    param([string]$SourceDir, [string]$OutputDir, [int]$Total)
    $source = Get-FrameGroups $SourceDir
    $output = Get-FrameGroups $OutputDir
    $missing = @()
    for ($index = 1; $index -le $Total; $index++) {
        $hasSource = $false
        if ($source.ContainsKey($index)) {
            foreach ($file in $source[$index]) {
                if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $hasSource = $true; break }
            }
        }
        if (-not $hasSource) { continue }
        $hasOutput = $false
        if ($output.ContainsKey($index)) {
            foreach ($file in $output[$index]) {
                if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $hasOutput = $true; break }
            }
        }
        if (-not $hasOutput) { $missing += $index }
    }
    return $missing
}

function Get-SourceFrameForIndex {
    param([string]$SourceDir, [int]$Index)
    $groups = Get-FrameGroups $SourceDir
    if (-not $groups.ContainsKey($Index)) { return $null }
    foreach ($file in $groups[$Index]) {
        if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { return $file.FullName }
    }
    return $null
}

function Find-OutputForStem {
    param([string]$OutputDir, [string]$Stem)
    foreach ($file in @(Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue)) {
        if ($file.BaseName -eq $Stem -and $file.Length -gt 0) { return $file.FullName }
    }
    return $null
}

function Link-OrCopy {
    param([string]$Source, [string]$Target)
    try {
        New-Item -ItemType HardLink -Path $Target -Target $Source -Force | Out-Null
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
}

function New-ProgressState {
    param([string]$Label, [int]$Total)
    return @{ label = $Label; total = $Total; done = 0; started = [DateTime]::UtcNow }
}

function Get-ProgressLine {
    param($Progress)
    $elapsed = [math]::Max(0.0, ([DateTime]::UtcNow - $Progress.started).TotalSeconds)
    $rate = if ($elapsed -gt 0) { $Progress.done / $elapsed } else { 0.0 }
    $eta = if ($rate -gt 0) { [math]::Max(0.0, ($Progress.total - $Progress.done) / $rate) } else { 0.0 }
    $percent = if ($Progress.total -gt 0) { $Progress.done / $Progress.total * 100.0 } else { 100.0 }
    $etaSeconds = [int][math]::Round($eta)
    $hours = [math]::Floor($etaSeconds / 3600)
    $minutes = [math]::Floor(($etaSeconds % 3600) / 60)
    $seconds = $etaSeconds % 60
    return ('{0}: {1}/{2} ({3:0.0}%) {4:0.00}/s ETA {5:00}:{6:00}:{7:00}' -f $Progress.label, $Progress.done, $Progress.total, $percent, $rate, $hours, $minutes, $seconds)
}

function Get-ProgressEta {
    param($Progress)
    $elapsed = [math]::Max(0.0, ([DateTime]::UtcNow - $Progress.started).TotalSeconds)
    if ($elapsed -le 0) { return 0.0 }
    $rate = $Progress.done / $elapsed
    if ($rate -le 0) { return 0.0 }
    return [math]::Max(0.0, ($Progress.total - $Progress.done) / $rate)
}

function Invoke-UpscaleFrames {
    param(
        $Job,
        $Paths,
        [string]$Model,
        [int]$Scale,
        [string]$OutputDir,
        [int]$Tile,
        [int]$BatchSize,
        [int]$Gpu,
        $Icd,
        [string]$Threads,
        [int]$Retry,
        $Logger = $null,
        $Progress = $null,
        [string]$SourceDir = $null,
        $TotalFrames = $null,
        [bool]$AssumeYes = $true
    )
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    if (-not $SourceDir) { $SourceDir = Get-JobFramesDir $Job }
    $total = if ($null -ne $TotalFrames) { [int]$TotalFrames } else { Get-JobInt $Job 'frame_count' 0 }
    if ($total -le 0) {
        throw [PipelineException]::new("Job has no frame_count: $($Job.path)", $null, 4)
    }
    $batchSize = [math]::Max(1, [int]$BatchSize)
    $tile = [math]::Max(32, [int]$Tile)
    $attempt = 0
    $batchNumber = 1
    $etaWarned = $false
    $envMap = $null
    if ($Icd) { $envMap = @{ 'VK_ICD_FILENAMES' = [string]$Icd } }

    while ($true) {
        $missing = Get-MissingIndices -SourceDir $SourceDir -OutputDir $OutputDir -Total $total
        if ($missing.Count -eq 0) { break }
        $batch = @($missing | Select-Object -First $batchSize)
        $work = Join-Path $Job.path ('batch_{0:D4}' -f $batchNumber)
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        $incoming = Join-Path $work 'in'
        $outgoing = Join-Path $work 'out'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        New-Item -ItemType Directory -Path $outgoing -Force | Out-Null
        foreach ($index in $batch) {
            $source = Get-SourceFrameForIndex $SourceDir $index
            if (-not $source) {
                throw [PipelineException]::new("Missing source frame $('{0:D8}' -f $index) for job $($Job.path)", $null, 4)
            }
            Link-OrCopy $source (Join-Path $incoming ([IO.Path]::GetFileName($source)))
        }
        $arguments = @(
            $Paths.binary, '-i', $incoming, '-o', $outgoing, '-m', $Paths.models_dir,
            '-n', $Model, '-s', [string]$Scale, '-g', [string]$Gpu, '-t', [string]$tile,
            '-j', $Threads, '-f', 'png', '-c', '0'
        )
        try {
            $null = Invoke-Child -Arguments $arguments -Environment $envMap -WorkingDirectory (Split-Path -Parent $Paths.binary)
            $produced = @()
            foreach ($inputFile in @(Get-ChildItem -LiteralPath $incoming -File)) {
                $result = Find-OutputForStem $outgoing $inputFile.BaseName
                if (-not $result) {
                    throw [PipelineException]::new("Upscayl produced no output for $($inputFile.Name)", $null, 6)
                }
                $produced += $result
            }
            foreach ($result in $produced) {
                $target = Join-Path $OutputDir ([IO.Path]::GetFileName($result))
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                Move-Item -LiteralPath $result -Destination $target -Force
            }
        } catch {
            $ex = Get-PipelineException $_
            if ($attempt -lt $Retry) {
                $attempt++
                $tile = [math]::Max(64, [int][math]::Floor($tile / 2))
                $batchSize = [math]::Max(1, [int][math]::Floor($batchSize / 2))
                Write-Warn ("Upscayl batch failed; retrying with tile=$tile, batch=$batchSize")
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            $detail = $ex.Message
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
            throw [PipelineException]::new("Upscayl failed for job $([IO.Path]::GetFileName($Job.path))", $detail, 6)
        }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        $batchNumber++
        $attempt = 0
        if ($Progress) {
            $Progress.done = [math]::Min($Progress.total, $Progress.done + $batch.Count)
            Write-Info (Get-ProgressLine $Progress)
            $eta = Get-ProgressEta $Progress
            if (-not $etaWarned -and $eta -gt 3600) {
                $etaWarned = $true
                if ($eta -gt 12 * 3600) {
                    Write-Warn 'Estimated upscale time exceeds 12 hours; use a faster model (upscayl-lite-4x) or process the video in chunks.'
                } else {
                    Write-Warn ('Estimated upscale time is ' + ($eta / 3600).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' hours.')
                }
                if (-not $AssumeYes) {
                    if ([Console]::IsInputRedirected) {
                        throw [PipelineException]::new(('Estimated upscale time is ' + ($eta / 3600).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' hours.'), 'Re-run with --yes to continue.', 4)
                    }
                    $answer = (Read-Host 'Continue? [y/N]').Trim().ToLowerInvariant()
                    if (@('y', 'yes') -notcontains $answer) {
                        throw [PipelineException]::new('Aborted by user.', $null, 4)
                    }
                }
            }
        } else {
            Write-Info ('Upscaled batch of ' + $batch.Count + ' frames')
        }
    }

    $outputGroups = Get-FrameGroups $OutputDir
    $count = 0
    for ($index = 1; $index -le $total; $index++) {
        if (-not $outputGroups.ContainsKey($index)) { continue }
        foreach ($file in $outputGroups[$index]) {
            if ($file.PSIsContainer -eq $false -and $file.Length -gt 0) { $count++; break }
        }
    }
    return $count
}
