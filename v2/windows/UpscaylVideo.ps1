#requires -Version 5.1
<#
.SYNOPSIS
    Upscayl Video Pipeline V2 - native Windows implementation.

.DESCRIPTION
    No Python, Node, or jq. Uses FFmpeg/ffprobe and Upscayl's own CLI.
    Reads and writes the same job.txt/config.txt contract as V1.
#>

$ErrorActionPreference = 'Stop'
$script:V2Version = '0.3.4'
$script:ProgramName = 'upscayl-video'
$script:ToolDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:LogFile = $null
$script:Verbose = $false
$script:Quiet = $false

# Load the implementation modules in dependency order.
$script:ModuleDir = Join-Path $PSScriptRoot 'modules'
$script:Modules = @(
    'errors.ps1',
    'core.ps1',
    'paths.ps1',
    'config.ps1',
    'media.ps1',
    'jobs.ps1',
    'frames.ps1',
    'encode.ps1',
    'upscayl.ps1',
    'chunking.ps1',
    'split.ps1',
    'run.ps1',
    'assemble.ps1',
    'admin.ps1',
    'doctor.ps1',
    'menu.ps1',
    'cli.ps1'
)
foreach ($module in $script:Modules) {
    . (Join-Path $script:ModuleDir $module)
}

if ($env:UPSCAYL_V2_LIB -eq '1') {
    return
}

try {
    exit (Invoke-Main -Argv $args)
} catch {
    $ex = Get-PipelineException $_
    if ($ex -is [PipelineException]) {
        Write-Err $ex.ToString()
        exit $ex.ExitCode
    }
    Write-Err ($ex.Message)
    if ($script:Verbose -or $env:UPSCAYL_V2_DEBUG -eq '1') { Write-Err ($_ | Out-String); Write-Err $_.ScriptStackTrace }
    exit 1
}
