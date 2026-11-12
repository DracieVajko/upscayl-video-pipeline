# Upscayl Video Pipeline V2 - core module.
# Logging, process invocation and shared error handling.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

#region Logging and process helpers

function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Set-LogFile {
    param([string]$Path)
    if (-not $Path) {
        $script:LogFile = $null
        return
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $script:LogFile = $Path
}

function Write-LogFileLine {
    param([string]$Level, [string]$Message)
    if (-not $script:LogFile) { return }
    $line = (Get-Timestamp) + ' [' + $Level + '] ' + $Message + [Environment]::NewLine
    [IO.File]::AppendAllText($script:LogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Info {
    param([string]$Message)
    if ($script:Quiet) {
        Write-LogFileLine 'INFO' $Message
        return
    }
    Write-LogFileLine 'INFO' $Message
    [Console]::Out.WriteLine($Message)
}

function Write-Warn {
    param([string]$Message)
    if ($script:Quiet) {
        Write-LogFileLine 'WARN' $Message
        return
    }
    Write-LogFileLine 'WARN' $Message
    [Console]::Error.WriteLine($Message)
}

function Write-Err {
    param([string]$Message)
    Write-LogFileLine 'ERROR' $Message
    [Console]::Error.WriteLine($Message)
}

function Write-DebugLog {
    param([string]$Message)
    if ($script:Verbose) {
        Write-LogFileLine 'DEBUG' $Message
        [Console]::Out.WriteLine($Message)
    } else {
        Write-LogFileLine 'DEBUG' $Message
    }
}

function Quote-DisplayArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -match '[\s"'']') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Quote-CommandLineArg {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($char)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Child {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment = $null,
        [string]$WorkingDirectory = $null,
        [switch]$NoCheck
    )

    $display = ($Arguments | ForEach-Object { Quote-DisplayArg $_ }) -join ' '
    $extra = ''
    if ($WorkingDirectory) { $extra += '  (cwd=' + $WorkingDirectory + ')' }
    if ($Environment) {
        $pairs = @()
        foreach ($key in ($Environment.Keys | Sort-Object)) {
            $pairs += ($key + '=' + $Environment[$key])
        }
        $extra += '  (env ' + ($pairs -join ' ') + ')'
    }
    Write-DebugLog ('$ ' + $display + $extra)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Arguments[0]
    $argList = @()
    for ($i = 1; $i -lt $Arguments.Count; $i++) {
        $argList += (Quote-CommandLineArg $Arguments[$i])
    }
    $startInfo.Arguments = ($argList -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    $result = [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
    if (-not $NoCheck -and $exitCode -ne 0) {
        $tail = Get-TextTail ($stderr + $stdout) 50
        $message = 'Command failed with exit code ' + $exitCode + ': ' + $display
        if ($tail) { $message += [Environment]::NewLine + $tail }
        throw [PipelineException]::new($message, $null, 1)
    }
    return $result
}

function Get-TextTail {
    param([string]$Text, [int]$Lines = 50)
    if (-not $Text) { return '' }
    $all = $Text -split "`r?`n"
    if ($all.Count -le $Lines) { return $Text.TrimEnd() }
    return (($all[($all.Count - $Lines)..($all.Count - 1)]) -join [Environment]::NewLine).TrimEnd()
}

function Get-PipelineException {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex -is [PipelineException]) { return $ex }
        if ($ex.InnerException) { $ex = $ex.InnerException } else { break }
    }
    return $ErrorRecord.Exception
}
