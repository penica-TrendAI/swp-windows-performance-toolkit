#Requires -Version 5.1
<#
.SYNOPSIS
Export xperf reports for an existing Windows Performance Recorder trace.
.DESCRIPTION
Use a new output directory outside the repository. Process reports can contain
user paths and command lines. Some reports require events absent from light profiles.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TracePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$XperfPath,
    [switch]$IncludeCpu,
    [ValidateRange(0,86400)][int]$InitialWindowSeconds = 0
)
$ErrorActionPreference = 'Stop'
$trace = Get-Item -LiteralPath $TracePath
if ($trace.PSIsContainer -or $trace.Extension -ne '.etl' -or $trace.Length -eq 0) {
    throw 'Choose a nonempty ETL trace file.'
}
if (!$XperfPath) {
    $installed = Get-Command xperf.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $XperfPath = if ($installed) { $installed.Source } else {
        Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Windows Performance Toolkit\xperf.exe'
    }
}
$xperf = Get-Item -LiteralPath $XperfPath
if ($xperf.PSIsContainer -or $xperf.Name -ne 'xperf.exe') { throw 'Supply the Windows Performance Toolkit xperf.exe path.' }
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw "Choose a new output directory: $out" }
$null = New-Item -ItemType Directory -Path $out

$reports = [ordered]@{
    TraceStats = @('tracestats','-timespan')
    Processes = @('process','-withcmdline')
    Disk = @('diskio','-summary')
    DiskTimeline = @('diskio','-util')
    System = @('sysconfig','-memory','-cpu','-disk','-build')
}
if ($IncludeCpu) {
    $reports.Cpu = @('profile','-detail')
    $reports.CpuTimeline = @('profile','-util')
}
if ($InitialWindowSeconds) {
    $range = @('-range','0',([long]$InitialWindowSeconds * 1000000).ToString([cultureinfo]::InvariantCulture))
    $reports.DiskInitial = @('diskio','-summary') + $range
    if ($IncludeCpu) {
        $reports.CpuInitial = @('profile','-detail') + $range
        $reports.ContextSwitchInitial = @('cswitch','-process') + $range
    }
}
$arguments = @('-i',$trace.FullName,'-tle','-target','machine')
foreach ($name in $reports.Keys) {
    $arguments += @('-a') + $reports[$name] + @('-ao',(Join-Path $out "$name.txt"))
}
& $xperf.FullName @arguments 1> (Join-Path $out 'xperf-stdout.txt') 2> (Join-Path $out 'xperf-stderr.txt')
if ($LASTEXITCODE -ne 0) { throw "xperf exited with $LASTEXITCODE. Inspect the logs in $out." }
foreach ($name in $reports.Keys) {
    $file = Get-Item -LiteralPath (Join-Path $out "$name.txt") -ErrorAction SilentlyContinue
    if (!$file -or !$file.Length) { Write-Warning "No report data for $name. Review the trace providers and xperf logs." }
}
Write-Output "Reports saved in $out"
