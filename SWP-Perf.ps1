#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
One-file Windows SWP performance collection, diagnostics, verified packaging and cleanup.
.DESCRIPTION
Save as C:\Program Files\SWP-PerfTools\SWP-Perf.ps1. No companion scripts needed. Revision 2026-11-26.
Run in elevated 64-bit Windows PowerShell. Opening the script on the desktop shows the collector window. Explicit stages run directly.
Headless invocations without a stage show Help.
In the customer kit, run -Stage InstallTools from the extracted folder first.
InstallTools also installs the two bundled sign-in profiles and this script.
Record baseline timings, verify tool permissions, disable this computer's agent
self-protection through the console, and confirm no unrelated WPR/Procmon capture.

PRIMARY SEQUENCE (reboot, login and first application launches in the same pass):
  .\SWP-Perf.ps1 -Stage Prepare
  # Reboot manually; log in and launch the agreed applications; record timings.
  .\SWP-Perf.ps1 -Stage StopTrace
  .\SWP-Perf.ps1 -Stage FinishAndPackage

FinishAndPackage waits for the CMD metrics task, copies tool/agent/debug evidence,
requests dsa_control -d, restores the original INI, exports logs and creates a ZIP.
The native agent diagnostic is distinct from the CMD metrics and GUI support tool.
Diagnostic failures are recorded explicitly; a verified outer ZIP can still contain
incomplete collection. If a diagnostic controller is still running, packaging stops.

OTHER ACTIONS:
  InstallTools   Extract and verify the bundled Trend CMD and GUI tools.
  Finish          Same collection/diagnostics/restoration; no outer ZIP.
  Diagnostics     Request a fresh agent diagnostic and copy available raw debug logs.
  Package         Package the entire existing case, including a CLI diagnostic attempt
                  if none was recorded. Never automatically deletes evidence.
  CollectContext  Export selected login tasks; copy administrator-selected PS1/VBS and console exports.
  Status          Show task, case and trace-restoration/diagnostic state.
  PrepareB        Prepare optional Procmon boot repeat after Phase A; manually enable
                  Procmon boot logging, reboot/reproduce, save PML and close Procmon.
  SaveDebug       Copy an early raw debug snapshot; use -Pass PassB for optional pass.
  FinishB         Wait/copy optional Pass B, diagnostic request, restore INI; no ZIP.
  RestoreTrace    Restore the original INI without deleting case data.
  Cleanup         PASS C: DELETE ALL C:\SWP-Perf after restoring available saved settings.
                  Retain Program Files tools, installed agent data and Windows logs.
                  Disable Procmon boot logging/close its GUI before this action.
                  Add -KeepEvidence to restore settings while retaining case files.

Restore original self-protection/inheritance manually in the management console
following diagnostics/restoration. Transfer the outer ZIP and checksum BEFORE Cleanup.
The default archive directory is C:\SWP-Handoff. Root cleanup verifies every external case handoff.
Persistent AM debug has NO automatic timer; Finish/RestoreTrace/Cleanup restores it.
The DSA sampling duration is 900 seconds; task lifetime is capped at 45 minutes.
Optional -IncludeNetwork applies only to Prepare; omit it for the default lighter trace.
-AllowDiagTrackMiniLogger applies only to Prepare. It permits the recognized
DiagTrackMiniLogger background ETW sessions only when WPR reports it is not recording.
Confirm no other boot trace is armed before using this option. No sessions are stopped.
-SkipDiagnostics explicitly omits automatic CLI diagnostics. -AgentFolder and
-DiagnosticFolder accept verified non-default installed/output locations.
-ArtifactWaitSeconds sets the diagnostic inactivity wait (default 600 seconds).
-DiagnosticTimeoutMinutes caps each CLI wait and publication attempt (default 30 minutes).
Diagnostics resumes a pending named archive. RecoverAndPackage retrieves evidence after a failed WPR save.
-Scenario SignOutSignIn arms a machine-wide same-boot capture after a signed timed control.
CollectContext uses -LoginTask (default \IntuneDriveMapping), explicit -LoginScriptPath
PS1/VBS files and -PolicyExportFolder for administrator-exported XML/CSV/JSON.
Complete Operator-notes.json with actual ISO timestamps including timezone offsets.
Packaging distinguishes required artifacts from integrity and unverified trace coverage.

Use the script that armed a recording to stop it. Older case files can be packaged separately.
Prepare allocates the next numbered case from local cases and default handoffs.
Later actions use the unique active case; supply -Case to select a case explicitly. A renamed case works for restoration/cleanup;
record that change and use its current path. Archives contain every existing case file,
not just metrics, including raw debug rotations and the generated agent ZIP if obtained.
If that package contains debug.xml, a standalone copy is included too; no assumption
is made that every agent diagnostic contains this file.

SOURCES:
https://docs.trendmicro.com/en-US/documentation/article/trend-micro-cloud-one-workload-security-diagnostic
https://success.trendmicro.com/en-US/solution/KA-0004561
https://success.trendmicro.com/en-US/solution/KA-0012444
https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options
#>
[CmdletBinding()]
param(
    [Alias('Action')]
    [ValidateSet('Gui','Help','InstallTools','Prepare','StopTrace','Finish','FinishAndPackage','Status',
        'PrepareB','SaveDebug','FinishB','RestoreTrace','Diagnostics','Package','CollectContext','Cleanup','RecoverAndPackage','CaptureMetrics')]
    [string]$Stage = 'Gui',
    [ValidatePattern('^C:\\SWP-Perf\\CASE-[A-Za-z0-9_-]+$')]
    [string]$Case = 'C:\SWP-Perf\CASE-01',
    [ValidateSet('PassA','PassB')]
    [string]$Pass = 'PassA',
    [ValidateSet('Reboot','SignOutSignIn')][string]$Scenario = 'Reboot',
    [ValidateSet('Standard','LargerBuffers')][string]$WprBuffers = 'Standard',
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [string]$AffectedUser,
    [string]$AmspDebug = 'C:\Program Files\Trend Micro\AMSP\debug',
    [string]$AgentFolder = '',
    [string]$DiagnosticFolder = '',
    [string]$ArchiveDirectory = 'C:\SWP-Handoff',
    [ValidateRange(1,120)]
    [int]$DiagnosticTimeoutMinutes = 30,
    [switch]$SkipDiagnostics,
    [switch]$IncludeNetwork,
    [switch]$AllowDiagTrackMiniLogger,
    [ValidateRange(0,600)]
    [int]$ArtifactWaitSeconds = 600,
    [string[]]$LoginTask = @('\IntuneDriveMapping'),
    [string[]]$LoginScriptPath = @(),
    [string]$PolicyExportFolder = '',
    [switch]$KeepEvidence
)
$ErrorActionPreference = 'Stop'
$ToolRoot = Join-Path $env:ProgramFiles 'SWP-PerfTools'
$ToolFolder = Join-Path $ToolRoot 'DSASupportTool'
$Executable = Join-Path $ToolFolder 'DSASupportTool_CMD.exe'
$ConfigPath = Join-Path $ToolFolder 'DSTool.json'
$StatePath = Join-Path $Case 'Cleanup\PhaseA-state.json'
if (-not $AgentFolder) { $AgentFolder = Join-Path $env:ProgramFiles 'Trend Micro\Deep Security Agent' }
if (-not $DiagnosticFolder) { $DiagnosticFolder = Join-Path $env:ProgramData 'Trend Micro\Deep Security Agent\diag' }
$Channels = @(
    'Microsoft-Windows-GroupPolicy/Operational'
    'Microsoft-Windows-User Profile Service/Operational'
    'Microsoft-Windows-Diagnostics-Performance/Operational'
    'Microsoft-Windows-Shell-Core/Operational'
    'Microsoft-Windows-Winlogon/Operational'
    'Microsoft-Windows-TaskScheduler/Operational'
)

function Assert-LocalEvidencePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?]') { throw "Expected an explicit local drive path: $Path" }
    $Full = [IO.Path]::GetFullPath($Path)
    $Cursor = $Full
    while ($Cursor) {
        if (Test-Path -LiteralPath $Cursor) {
            if ((Get-Item -LiteralPath $Cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Evidence path contains a link or junction: $Cursor"
            }
        }
        $Parent = Split-Path -Path $Cursor -Parent
        if (-not $Parent -or $Parent -eq $Cursor) { break }
        $Cursor = $Parent
    }
    return $Full
}

function Write-TaskXml {
    param([string]$Xml, [string]$Path)
    [xml]$Document = $Xml
    $Settings = [Xml.XmlWriterSettings]::new()
    $Settings.Encoding = [Text.UTF8Encoding]::new($true)
    $Settings.Indent = $true
    $Writer = [Xml.XmlWriter]::Create($Path, $Settings)
    try { $Document.Save($Writer) } finally { $Writer.Dispose() }
}

function Get-RegularEvidenceFiles {
    param([string]$Root)
    $Full = Assert-LocalEvidencePath -Path $Root
    $Pending = [Collections.Generic.Stack[string]]::new()
    $Pending.Push($Full)
    while ($Pending.Count) {
        foreach ($Item in (Get-ChildItem -LiteralPath $Pending.Pop() -Force -ErrorAction Stop)) {
            if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Evidence tree contains a link or junction: $($Item.FullName)" }
            if ($Item.PSIsContainer) { $Pending.Push($Item.FullName) } else { $Item }
        }
    }
}

function Get-AMTraceSetting {
    param([string]$Path)
    $Values = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($Line in (Get-Content -LiteralPath $Path)) {
            if ($Line -match '^\s*Trace\s*=\s*(.*)$') { $Values += $Matches[1].Trim() }
        }
    }
    $Debug = $false
    foreach ($Token in ($Values -split ',')) {
        foreach ($Target in @('AM','AMSP','dsp.am.service')) {
            if ($Token.Trim() -and $Target -like $Token.Trim()) { $Debug = $true }
        }
    }
    [pscustomobject]@{ Path=$Path; TraceValues=$Values; AMDebugRequested=$Debug; MultipleDirectives=($Values.Count -gt 1) }
}

function Save-RestoredTraceAssessment {
    param([string]$Case, [string]$Ini)
    $Assessment = Get-AMTraceSetting -Path $Ini
    $Assessment | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Case 'Cleanup\PersistentAMTrace\Restored-trace-assessment.json') -Encoding UTF8
    if ($Assessment.AMDebugRequested) {
        Write-Warning 'The original INI is restored but still requests AM debug logging. Debug was already enabled before this test. Review the intended production state with its owner; this script will not delete a pre-existing INI.'
    }
}

function Get-WprSaveAssessment {
    param([string]$Etl, [int]$ExitCode, [string]$OutputText)
    $Counts = @([regex]::Matches($OutputText, '(?i)(?:dropped\s+([\d,]+)\s+events|([\d,]+)\s+events\s+(?:were\s+)?lost)') | ForEach-Object {
        $Value = if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
        [long]($Value.Replace(',',''))
    })
    $LossLanguage = $OutputText -match '(?i)drop\w*\s+.*events|events.*\blost\b|lost.*events'
    $Count = if ($Counts.Count) { ($Counts | Measure-Object -Maximum).Maximum } else { $null }
    $Saved = $ExitCode -eq 0 -and (Test-Path -LiteralPath $Etl -PathType Leaf) -and (Get-Item -LiteralPath $Etl).Length -gt 0
    $Status = if (-not $Saved) { 'SaveFailed' } elseif ($Count -gt 0) { 'SavedWithEventLoss' } elseif ($LossLanguage -and -not $Counts.Count) { 'SavedLossCountUnparsed' } else { 'SavedCoverageUnverified' }
    [pscustomobject]@{
        AssessedAt=(Get-Date -Format o); Etl=$Etl; ExitCode=$ExitCode; Saved=$Saved; Status=$Status
        EtlLength=$(if ($Saved) { (Get-Item -LiteralPath $Etl).Length } else { $null })
        EtlLastWriteTimeUtc=$(if ($Saved) { (Get-Item -LiteralPath $Etl).LastWriteTimeUtc.ToString('o') } else { $null })
        ReportedDroppedEvents=$Count; LossMessageDetected=$LossLanguage
        CompleteCoverageVerified=$false; BootMarkersVerified=$false
        Note='Save success and absence of a recognized warning do not prove zero loss or complete boot/login coverage.'
    }
}

function Get-DiagnosticResponsePath {
    param([string]$Text)
    $Folders = [regex]::Matches($Text, '(?im)^\s*path\s*=\s*(.+?)\s*$')
    $Names = [regex]::Matches($Text, '(?im)^\s*file\s+name\s*=\s*(.+?)\s*$')
    if (-not $Folders.Count -or -not $Names.Count) { return $null }
    $Folder = $Folders[$Folders.Count-1].Groups[1].Value.Trim().Trim('"')
    $Name = $Names[$Names.Count-1].Groups[1].Value.Trim().Trim('"')
    if ($Name -notmatch '^[^\\/:*?"<>|]+\.zip$' -or $Name -in @('.','..')) { throw 'Diagnostic response contains an invalid ZIP filename.' }
    Assert-LocalEvidencePath -Path (Join-Path $Folder $Name)
}

function Get-ReadableFreshZip {
    param([string[]]$Paths, [hashtable]$Before, [datetime]$SinceUtc, [string]$ErrorLog)
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Path in ($Paths | Select-Object -Unique)) {
        $Zip = $null
        try {
            $Full = Assert-LocalEvidencePath -Path $Path
            if (-not $Seen.Add($Full)) { continue }
            $File = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($File.PSIsContainer -or $File.Length -eq 0) { throw 'File is empty or is a directory.' }
            $Stamp = "$($File.Length):$($File.LastWriteTimeUtc.Ticks)"
            if (($Before.ContainsKey($File.FullName) -and $Before[$File.FullName] -eq $Stamp) -or
                $File.LastWriteTimeUtc -lt $SinceUtc) { throw 'File is stale for this request.' }
            $Zip = [IO.Compression.ZipFile]::OpenRead($File.FullName)
            if (-not @($Zip.Entries | Where-Object { $_.Name }).Count) { throw 'ZIP contains no files.' }
            $File
        } catch {
            "$(Get-Date -Format o) | $Path | $($_.Exception.Message)" | Add-Content -LiteralPath $ErrorLog -Encoding UTF8
        } finally { if ($Zip) { $Zip.Dispose() } }
    }
}

function Read-MetricsText {
    param([string]$Text, [string]$Source)
    # Real agent payloads contain nested keys PS5 ConvertFrom-Json cannot represent.
    # Parse into case-sensitive dictionaries and return only the required metadata.
    $Serializer = $null
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Add-Type -AssemblyName System.Web.Extensions
        $Serializer = [Web.Script.Serialization.JavaScriptSerializer]::new()
        $Serializer.MaxJsonLength = 64MB
        $Serializer.RecursionLimit = 256
    }
    function Convert-MetricsJson {
        param([string]$Json)
        if ($Serializer) { return $Serializer.DeserializeObject($Json) }
        return (ConvertFrom-Json -InputObject $Json -AsHashtable -ErrorAction Stop)
    }
    try { $Records = @(Convert-MetricsJson -Json $Text) }
    catch {
        $Records = @()
        $LineNumber = 0
        foreach ($Line in ($Text -split '\r?\n')) {
            $LineNumber++
            if (-not $Line.Trim()) { continue }
            try { $Records += @(Convert-MetricsJson -Json $Line) }
            catch { throw "Invalid metrics JSON in $Source at line $LineNumber." }
        }
    }
    foreach ($Record in $Records) {
        if ($Record -is [Collections.IDictionary] -and $Record['eventType'] -eq 'Metrics') {
            [pscustomobject]@{ eventType=$Record['eventType']; time=$Record['time']; hostname=$Record['hostname'] }
        }
    }
}

function Get-ToolMetricsAssessment {
    param([string[]]$Paths, [datetime]$SinceUtc=[datetime]::MinValue,
        [datetime]$ThroughUtc=(Get-Date).ToUniversalTime(), [datetime]$RequiredEndUtc=[datetime]::MinValue,
        [string]$ExpectedComputer=$env:COMPUTERNAME)
    if ($SinceUtc -ne [datetime]::MinValue) { $SinceUtc = $SinceUtc.ToUniversalTime() }
    $ThroughUtc = $ThroughUtc.ToUniversalTime()
    if ($RequiredEndUtc -ne [datetime]::MinValue) { $RequiredEndUtc = $RequiredEndUtc.ToUniversalTime() }
    $Times = [Collections.Generic.SortedSet[long]]::new()
    $Errors = [Collections.Generic.List[string]]::new()
    $Sources = [Collections.Generic.List[string]]::new()
    $Counters = @{ Total=0; Outside=0; OtherComputer=0; UnknownComputer=0 }
    function Add-MetricsText {
        param([string]$Text, [string]$Label)
        foreach ($Record in (Read-MetricsText -Text $Text -Source $Label)) {
            $Counters.Total++
            if ([string]$Record.time -notmatch '^\d{13}$') { throw "Unrecognized Unix-millisecond metric timestamp in $Label." }
            $Time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Record.time).UtcDateTime
            if (($SinceUtc -ne [datetime]::MinValue -and $Time -lt $SinceUtc.AddMilliseconds(-1)) -or $Time -gt $ThroughUtc.AddSeconds(5)) { $Counters.Outside++; continue }
            if (-not $Record.hostname) { $Counters.UnknownComputer++; continue }
            elseif ($ExpectedComputer -and $Record.hostname -ne $ExpectedComputer) { $Counters.OtherComputer++; continue }
            [void]$Times.Add([long]$Record.time)
        }
    }
    foreach ($Path in ($Paths | Select-Object -Unique)) {
        $Zip = $null
        try {
            $File = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($File.Extension -eq '.zip') {
                $Zip = [IO.Compression.ZipFile]::OpenRead($File.FullName)
                $Entries = @($Zip.Entries | Where-Object { $_.FullName -match '(^|[/\\])[^/\\]*_jsonRecords\.json$' -and $_.Length -gt 0 })
                if (-not $Entries.Count) { throw 'No nonempty *_jsonRecords.json entries in metrics ZIP.' }
                foreach ($Entry in $Entries) {
                    if ($Entry.Length -gt 64MB) { throw "Metrics entry exceeds the 64 MB parsing limit: $($Entry.FullName)" }
                    $Reader = [IO.StreamReader]::new($Entry.Open(), [Text.Encoding]::UTF8, $true)
                    try { Add-MetricsText -Text $Reader.ReadToEnd() -Label "$Path :: $($Entry.FullName)" }
                    finally { $Reader.Dispose() }
                }
            } else {
                if ($File.Name -notlike '*_jsonRecords.json' -or $File.Length -eq 0 -or $File.Length -gt 64MB) { throw 'Not a nonempty supported metrics-record file (maximum 64 MB).' }
                Add-MetricsText -Text ([IO.File]::ReadAllText($File.FullName)) -Label $Path
            }
            $Sources.Add($File.FullName)
        } catch { $Errors.Add("$Path | $($_.Exception.Message)") }
        finally { if ($Zip) { $Zip.Dispose() } }
    }
    $Sorted = @($Times)
    $Gaps = @(for ($Index=1; $Index -lt $Sorted.Count; $Index++) { ($Sorted[$Index]-$Sorted[$Index-1])/1000.0 })
    $Median = $null; $Maximum = $null
    if ($Gaps.Count) {
        $Ordered = @($Gaps | Sort-Object); $Middle = [int][math]::Floor($Ordered.Count/2)
        $Median = if ($Ordered.Count % 2) { $Ordered[$Middle] } else { ($Ordered[$Middle-1]+$Ordered[$Middle])/2 }
        $Maximum = ($Ordered | Measure-Object -Maximum).Maximum
    }
    $First = if ($Sorted.Count) { [DateTimeOffset]::FromUnixTimeMilliseconds($Sorted[0]).UtcDateTime } else { $null }
    $Last = if ($Sorted.Count) { [DateTimeOffset]::FromUnixTimeMilliseconds($Sorted[-1]).UtcDateTime } else { $null }
    $InitialGap = if ($First -and $SinceUtc -ne [datetime]::MinValue) { [math]::Max(0,($First-$SinceUtc).TotalSeconds) } else { $null }
    $EndGap = if ($Last -and $RequiredEndUtc -ne [datetime]::MinValue) { [math]::Max(0,($RequiredEndUtc-$Last).TotalSeconds) } else { $null }
    $Cadence = if ($Sorted.Count -lt 3) { 'InsufficientSamples' } elseif ($Median -ge 2.5 -and $Median -le 7.5) { 'ObservedNearFiveSeconds' } else { 'NotNearFiveSeconds' }
    $inside=$null
    if($SinceUtc -ne [datetime]::MinValue -and $RequiredEndUtc -ne [datetime]::MinValue) {
        $lo=([datetimeoffset]$SinceUtc).ToUnixTimeMilliseconds()
        $hi=([datetimeoffset]$RequiredEndUtc).ToUnixTimeMilliseconds()
        $inside=@($Sorted | Where-Object {$_ -ge $lo -and $_ -le $hi}).Count
    }
    $Issues = @()
    if (-not $Sorted.Count) { $Issues += 'No current-window metrics records verified.' }
    if ($Cadence -ne 'ObservedNearFiveSeconds') { $Issues += "Sampling cadence: $Cadence." }
    if ($Maximum -gt 10) { $Issues += "Metrics contain a gap of $Maximum seconds." }
    if ($InitialGap -gt 10) { $Issues += "Initial metrics gap: $([math]::Round($InitialGap,3)) seconds after the requested start; the agent may not yet have been ready." }
    if ($EndGap -gt 10) { $Issues += "Metrics end $([math]::Round($EndGap,3)) seconds before the reproduction end." }
    if ($Counters.OtherComputer) { $Issues += 'Metrics from another computer were rejected.' }
    if ($Counters.UnknownComputer) { $Issues += 'Some metric records have no hostname; identity is unverified.' }
    if ($SinceUtc -eq [datetime]::MinValue -or $RequiredEndUtc -eq [datetime]::MinValue) { $Issues += 'Reproduction window is not fully recorded; time coverage needs review.' }
    if ($Errors.Count) { $Issues += 'One or more metrics sources could not be validated; inspect SourceErrors.' }
    [pscustomobject]@{
        AssessedAt=(Get-Date -Format o); ExpectedComputer=$ExpectedComputer
        WindowStartUtc= $(if ($SinceUtc -ne [datetime]::MinValue) { $SinceUtc.ToString('o') } else { $null })
        RequiredEndUtc= $(if ($RequiredEndUtc -ne [datetime]::MinValue) { $RequiredEndUtc.ToString('o') } else { $null })
        ArtifactRecordsVerified=($Sorted.Count -gt 0); SamplesDuringReproduction=$inside; UniqueSampleTimes=$Sorted.Count; TotalMetricRecords=$Counters.Total
        RejectedOutsideWindow=$Counters.Outside; RejectedOtherComputer=$Counters.OtherComputer
        FirstSampleUtc= $(if ($First) { $First.ToString('o') } else { $null })
        LastSampleUtc= $(if ($Last) { $Last.ToString('o') } else { $null })
        MedianIntervalSeconds=$Median; MaximumGapSeconds=$Maximum; InitialGapSeconds=$InitialGap; EndGapSeconds=$EndGap
        ObservedSpanSeconds=$(if ($First -and $Last) { ($Last-$First).TotalSeconds })
        ConfiguredDurationSeconds=900
        CollectionDurationStatus=$(if ($First -and $Last -and ($Last-$First).TotalSeconds -ge 890) { 'Covered' } else { 'PartialOrUnknown' })
        CadenceStatus=$Cadence; Sources=@($Sources.ToArray()); SourceErrors=@($Errors.ToArray()); EvidenceGaps=@($Issues)
    }
}

function Write-CollectorConfig {
    param($Config, [string]$Path)
    $json = $Config | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $bytes = [IO.File]::ReadAllBytes($Path)
    $readback = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bytes[0] -ne 123 -or ($readback | ConvertTo-Json -Depth 32) -cne $json) {
        throw 'The vendor configuration did not round-trip as UTF-8 without a BOM.'
    }
}

function Get-MetricsTaskArguments {
    param([string]$CasePath,[string]$Phase,[string]$Id)
    if ($CasePath -notmatch '^C:\\SWP-Perf\\CASE-[A-Za-z0-9_-]+$' -or $Phase -notin 'PassA','PassB' -or $Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid metrics task identity.' }
    '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}\SWP-Perf.ps1" -Stage CaptureMetrics -Case "{1}" -Pass {2} -RunId {3}' -f $ToolRoot,$CasePath,$Phase,$Id
}

function Test-MetricsTaskAction {
    param($Task,$PhaseState,[string]$CasePath,[string]$Phase)
    if (!$Task -or @($Task.Actions).Count -ne 1) { return $false }
    $a = $Task.Actions[0]
    if (!$PhaseState.RunId) { return $false }
    ($PhaseState.ComputerName -eq $env:COMPUTERNAME -and
        $a.Execute.Trim('"') -eq "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -and
        $a.WorkingDirectory -eq $ToolFolder -and
        $a.Arguments -eq (Get-MetricsTaskArguments $CasePath $Phase $PhaseState.RunId))
}

function Register-MetricsTask {
    param([string]$Phase)
    $params = @{
        Action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $ToolFolder -Argument (Get-MetricsTaskArguments $Case $Phase $State.RunId)
        Principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Description = "SWP DSA collection for $($State.RunId)"
    }
    if ($State.Scenario -ne 'SignOutSignIn') { $params.Trigger = New-ScheduledTaskTrigger -AtStartup }
    $null = Register-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -InputObject (New-ScheduledTask @params) -ErrorAction Stop
    Write-TaskXml -Xml (Export-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\') -Path "$Case\Trend\$Phase-DSAMetrics-task.xml"
}

function Copy-NewMetricBatches {
    param([string]$Source,[string]$Destination,[datetime]$SinceUtc,[hashtable]$Copied,[string]$LiveFolder)
    if (!(Test-Path -LiteralPath $Source -PathType Container)) { return }
    foreach ($f in (Get-RegularEvidenceFiles $Source)) {
        $rel = $f.FullName.Substring($Source.Length+1)
        if ($rel -notmatch '^\d{8}-\d{6}\\\d{6}_jsonRecords\.json$' -or $f.LastWriteTimeUtc -lt $SinceUtc.AddSeconds(-2) -or $f.Length -lt 1 -or $f.Length -gt 64MB) { continue }
        $version = "$($f.Length)/$($f.LastWriteTimeUtc.Ticks)"
        if ($Copied[$rel] -eq $version) { continue }
        $dir = Join-Path $Destination $f.Directory.Name
        $null = Assert-LocalEvidencePath $dir
        $null = New-Item $dir -ItemType Directory -Force
        $target = Join-Path $dir $f.Name
        $tmp = "$target.partial"
        try {
            $inputFile=[IO.File]::Open($f.FullName,'Open','Read','Read')
            try {
                if ($inputFile.Length -ne $f.Length) {continue}
                $outputFile=[IO.File]::Open($tmp,'Create','Write','None')
                try {$inputFile.CopyTo($outputFile)} finally {$outputFile.Dispose()}
            } finally {$inputFile.Dispose()}
            if ((Get-Item -LiteralPath $tmp).Length -ne $f.Length) { continue }
            $records = @(Read-MetricsText ([IO.File]::ReadAllText($tmp)) $rel)
            if (!$records.Count) { continue }
            $earliest = ([datetimeoffset]$SinceUtc.ToUniversalTime()).ToUnixTimeMilliseconds() - 5000
            $latest = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 5000
            $current = $false
            foreach ($record in $records) {
                if ($record.hostname -eq $env:COMPUTERNAME -and [string]$record.time -match '^\d{13}$' -and
                    [long]$record.time -ge $earliest -and [long]$record.time -le $latest) { $current = $true; break }
            }
            if (!$current) {
                $Copied[$rel] = $version
                [pscustomobject]@{Source=$rel;Reason='No current host/time sample';Bytes=$f.Length} |
                    ConvertTo-Json -Compress | Add-Content -LiteralPath "$Destination\Skipped-batches.jsonl" -Encoding UTF8
                continue
            }
            $hash = (Get-FileHash -LiteralPath $tmp).Hash
            if ($LiveFolder) {
                $liveFile = Join-Path $LiveFolder $rel
                if ((Test-Path -LiteralPath $liveFile -PathType Leaf) -and (Get-FileHash -LiteralPath $liveFile).Hash -eq $hash) { continue }
            }
            if (Test-Path -LiteralPath $target) {
                if ((Get-FileHash -LiteralPath $target).Hash -ne $hash) {
                    $target = Join-Path $dir ($hash + '-' + $f.Name)
                }
            }
            if (!(Test-Path -LiteralPath $target)) { [IO.File]::Move($tmp,$target) }
            $Copied[$rel] = $version
            [pscustomobject]@{Source=$rel;Name=$target.Substring($Destination.Length+1);Bytes=$f.Length;SHA256=$hash;SavedUtc=[datetime]::UtcNow.ToString('o')} |
                ConvertTo-Json -Compress | Add-Content -LiteralPath "$Destination\Batches.jsonl" -Encoding UTF8
        } catch { $_.Exception.Message | Add-Content -LiteralPath "$Destination\Retry-errors.txt" -Encoding UTF8 }
        finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
    }
}

function Invoke-MetricsWorker {
    Read-CollectionState -Pass $Pass
    if ($State.ComputerName -ne $env:COMPUTERNAME -or $RunId -ne $State.RunId) { throw 'Metrics case identity has changed.' }
    if ((Get-FileHash -LiteralPath $ConfigPath).Hash -ne $State.ConfigAppliedHash) { throw 'Installed metrics JSON changed.' }
    $dest = Assert-LocalEvidencePath (Join-Path $Case "Trend\LiveMetrics\$Pass\$RunId")
    $null = New-Item -ItemType Directory -Path $dest -Force
    $started = [datetime]::UtcNow
    $marker = Join-Path $dest 'Collector-start.txt'
    try { $stream = [IO.File]::Open($marker,'CreateNew','Write','None') } catch [IO.IOException] {
        if (Test-Path -LiteralPath $marker) { Write-Host 'This run already started.'; return }
        throw
    }
    $stream.Dispose()
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') | Set-Content -LiteralPath (Join-Path $dest 'BootUtc.txt')
    $started.ToString('o') | Set-Content -LiteralPath $marker
    $copied = @{}
    $source = Join-Path $ToolFolder 'DSA_Metrics'
    $process = Start-Process -FilePath $Executable -WorkingDirectory $ToolFolder -PassThru -NoNewWindow
    try {
        $null = $process.Handle
        while (!$process.HasExited) {
            Copy-NewMetricBatches $source $dest $started $copied
            $null = $process.WaitForExit(1500)
        }
        $process.WaitForExit()
        Copy-NewMetricBatches $source $dest $started $copied
        $code = $process.ExitCode
        [pscustomobject]@{RunId=$RunId;StartUtc=$started.ToString('o');EndUtc=[datetime]::UtcNow.ToString('o');ExitCode=$code;Batches=$copied.Count} |
            ConvertTo-Json | Set-Content -LiteralPath "$dest\Collector-result.json" -Encoding UTF8
        if ($code -ne 0) { throw "DSA tool exited with code $code." }
    } finally { $process.Dispose() }
}

function Copy-ToolMetrics {
    param([string]$PassFolder, [datetime]$SinceUtc, [datetime]$RequiredEndUtc=[datetime]::MinValue)
    $Destination = Join-Path $PassFolder 'VerifiedToolMetrics'
    New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    $LogPath = Join-Path $ToolFolder 'logs\DSA_SupportTool.log'
    $Candidates = @()
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        foreach ($Line in (Get-Content -LiteralPath $LogPath)) {
            if ($Line -match 'Metrics Collection DONE! The logfile is ([A-Za-z]:\\.+?\.zip)(?:\.|\s|$)') {
                $Reported = $Matches[1]
                $LogTime = [datetime]::MinValue
                $Stamp = [regex]::Match($Line, '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3}').Value
                if ($Stamp -and [datetime]::TryParseExact($Stamp,'yyyy-MM-dd HH:mm:ss,fff',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$LogTime) -and $LogTime.ToUniversalTime() -lt $SinceUtc) { continue }
                $Candidates += $Reported
            }
        }
    }
    $Candidates += @(Get-ChildItem -LiteralPath $ToolFolder -Filter 'DSTool-METRICS-*.zip' -Recurse -File -Force | Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc.AddSeconds(-2) } | Select-Object -ExpandProperty FullName)
    $Unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Candidates = @($Candidates | Where-Object { $Unique.Add($_) })
    $Candidates | Set-Content -LiteralPath "$Destination\Reported-archive-paths.txt" -Encoding UTF8
    $Deadline = (Get-Date).AddSeconds([math]::Min(30,$ArtifactWaitSeconds))
    $Ready = @()
    do {
        $Ready = @(Get-ReadableFreshZip -Paths $Candidates -Before @{} -SinceUtc $SinceUtc -ErrorLog "$Destination\Archive-lookup-errors.txt")
        if ($Ready.Count -or -not $Candidates.Count -or (Get-Date) -ge $Deadline) { break }
        Start-Sleep -Seconds 2
    } while ($true)
    $Copied = @()
    $Index = 0
    foreach ($File in $Ready) {
        $Index++
        $Folder = Join-Path $Destination ("Archive-$Index")
        New-Item -ItemType Directory -Path $Folder | Out-Null
        $Target = Join-Path $Folder $File.Name
        $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $File.FullName -Destination $Target -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ne $Hash) { throw 'Metrics archive copy hash mismatch.' }
        [pscustomobject]@{ Source=$File.FullName; CopiedZip=$Target; SHA256=$Hash } | ConvertTo-Json | Set-Content -LiteralPath "$Folder\Source.json" -Encoding UTF8
        $Zip = [IO.Compression.ZipFile]::OpenRead($Target)
        try { $Zip.Entries | Select-Object FullName,Length | Export-Csv -LiteralPath "$Target.inventory.csv" -NoTypeInformation }
        finally { $Zip.Dispose() }
        $Copied += $Target
    }
    $live = if ($State.RunId) { Join-Path $Case "Trend\LiveMetrics\$Pass\$($State.RunId)" }
    $Loose = Join-Path $ToolFolder 'DSA_Metrics'
    if (Test-Path -LiteralPath $Loose -PathType Container) {
        $looseTarget=Join-Path $Destination 'LooseMetrics'
        $null=New-Item -Path $looseTarget -ItemType Directory -Force
        Copy-NewMetricBatches $Loose $looseTarget $SinceUtc @{} $live
        $Copied += @(Get-RegularEvidenceFiles $looseTarget | Where-Object Name -like '*_jsonRecords.json' | Select-Object -ExpandProperty FullName)
    }
    if ($State.RunId) {
        $live = Join-Path $Case "Trend\LiveMetrics\$Pass\$($State.RunId)"
        if (Test-Path -LiteralPath $live) { $Copied += @(Get-RegularEvidenceFiles $live | Where-Object Name -like '*_jsonRecords.json' | Select-Object -ExpandProperty FullName) }
    }
    $Assessment = Get-ToolMetricsAssessment -Paths $Copied -SinceUtc $SinceUtc -RequiredEndUtc $RequiredEndUtc
    if ($Candidates.Count -gt $Ready.Count) { $Assessment.EvidenceGaps += 'A metrics archive named by the tool could not be copied; see archive lookup errors.' }
    $Assessment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$Destination\Metrics-assessment.json" -Encoding UTF8
    foreach ($Gap in $Assessment.EvidenceGaps) { Write-Warning $Gap }
    return $Assessment
}

function Save-LoginContext {
    $Root = Join-Path $Case 'Context'
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $Destination = Join-Path $Root (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $Items = @()
    $Index = 0
    foreach ($TaskId in $LoginTask) {
        $Index++
        try {
            if ($TaskId -notmatch '^\\[^*?]+$' -or $TaskId.EndsWith('\')) { throw 'Use an explicit task path such as \IntuneDriveMapping.' }
            $Slash = $TaskId.LastIndexOf('\'); $Name = $TaskId.Substring($Slash+1); $Folder = $TaskId.Substring(0,$Slash+1)
            $Selected = @(Get-ScheduledTask -TaskName $Name -TaskPath $Folder -ErrorAction Stop | Where-Object { $_.TaskName -eq $Name -and $_.TaskPath -eq $Folder })
            if ($Selected.Count -ne 1) { throw 'The exact selected task was not found uniquely.' }
            $Task = $Selected[0]
            $Target = Join-Path $Destination ("LoginTask-$Index.xml")
            Write-TaskXml -Xml (Export-ScheduledTask -TaskName $Name -TaskPath $Folder) -Path $Target
            $Items += [pscustomobject]@{ Kind='Task'; Source=$TaskId; File=$Target; Status='Copied'; SHA256=(Get-FileHash -LiteralPath $Target).Hash; Error=$null }
        } catch { $Items += [pscustomobject]@{ Kind='Task'; Source=$TaskId; File=$null; Status='Failed'; SHA256=$null; Error=$_.Exception.Message } }
    }
    foreach ($Source in $LoginScriptPath) {
        $Index++
        try {
            $Full = Assert-LocalEvidencePath -Path $Source
            $File = Get-Item -LiteralPath $Full -Force -ErrorAction Stop
            if ($File.PSIsContainer -or $File.Extension -notin @('.ps1','.vbs')) { throw 'Only explicitly selected PS1/VBS regular files can be collected.' }
            $Target = Join-Path $Destination ("Script-$Index-" + $File.Name)
            $Hash = (Get-FileHash -LiteralPath $Full).Hash
            Copy-Item -LiteralPath $Full -Destination $Target
            if ((Get-FileHash -LiteralPath $Target).Hash -ne $Hash) { throw 'Script copy hash mismatch.' }
            $Items += [pscustomobject]@{ Kind='Script'; Source=$Full; File=$Target; Status='Copied'; SHA256=$Hash; Error=$null }
        } catch { $Items += [pscustomobject]@{ Kind='Script'; Source=$Source; File=$null; Status='Failed'; SHA256=$null; Error=$_.Exception.Message } }
    }
    if ($PolicyExportFolder) {
        try {
            $Full = Assert-LocalEvidencePath -Path $PolicyExportFolder
            if ($Full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Full).TrimEnd('\')) { throw 'Select a dedicated console-export folder, not a drive root.' }
            if (-not (Test-Path -LiteralPath $Full -PathType Container)) { throw 'Console-export folder not found.' }
            if ($Destination.StartsWith($Full.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'The console-export source must not contain the context destination.' }
            $Exports = @(Get-RegularEvidenceFiles -Root $Full | Where-Object Extension -in @('.xml','.csv','.json'))
            if (-not $Exports.Count) { throw 'No XML, CSV or JSON console-export files found.' }
            foreach ($File in $Exports) {
                $null = Assert-LocalEvidencePath -Path $File.FullName
                $Relative = $File.FullName.Substring($Full.TrimEnd('\').Length+1)
                $Target = Join-Path "$Destination\PolicyExports" $Relative
                New-Item -ItemType Directory -Path (Split-Path $Target) -Force | Out-Null
                $Hash = (Get-FileHash -LiteralPath $File.FullName).Hash
                Copy-Item -LiteralPath $File.FullName -Destination $Target
                if ((Get-FileHash -LiteralPath $Target).Hash -ne $Hash) { throw 'Policy export copy hash mismatch.' }
                $Items += [pscustomobject]@{ Kind='PolicyExport'; Source=$File.FullName; File=$Target; Status='Copied'; SHA256=$Hash; Error=$null }
            }
        } catch { $Items += [pscustomobject]@{ Kind='PolicyExport'; Source=$PolicyExportFolder; File=$null; Status='Failed'; SHA256=$null; Error=$_.Exception.Message } }
    }
    foreach ($Item in ($Items | Where-Object Status -eq 'Copied')) {
        $Item | Add-Member -NotePropertyName RelativeFile -NotePropertyValue $Item.File.Substring($Destination.Length+1)
    }
    [pscustomobject]@{ CollectedAt=(Get-Date -Format o); Items=@($Items); FullPolicyMembershipVerified=$false; Note='Administrator must confirm that console exports include the effective configuration and every assigned exclusion list. Script definitions are copied, never executed.' } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$Destination\Context-manifest.json" -Encoding UTF8
    foreach ($Item in ($Items | Where-Object Status -eq 'Failed')) { Write-Warning "Context not collected: $($Item.Source): $($Item.Error)" }
}

function Initialize-ScanReader {
    if ('SwpScanReader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Linq;
using System.Collections.Generic;
using System.Text.RegularExpressions;

public sealed class SwpScan {
    public string StartLocal, EndLocal, Thread, Path;
    public long EngineMicroseconds;
}
public sealed class SwpScanReader {
    sealed class Row {
        public string Stamp, Thread, Path, Duration;
        public bool Start;
        public int Sequence;
    }
    static readonly Regex Header = new Regex(@"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d\.\d{3}),\[(\d+:\d+)\]", RegexOptions.Compiled);
    static readonly Regex Duration = new Regex(@"<<< SCANFILE:\s*scan time \(microsecond\)\s*=\s*(0x[0-9a-fA-F]+|\d+)", RegexOptions.Compiled);
    public readonly List<SwpScan> Pairs = new List<SwpScan>();
    public readonly List<string> Errors = new List<string>();
    public int UnmatchedStarts, UnmatchedEnds;
    public string FirstRecord, LastRecord;
    public void Read(string[] paths, string from, string through, bool tail) {
        var rows = new List<Row>();
        var counts = new Dictionary<string,int>(StringComparer.Ordinal);
        foreach (string path in paths) {
            var fileCounts = new Dictionary<string,int>(StringComparer.Ordinal);
            try {
                using (var stream = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite | FileShare.Delete)) {
                    int first=stream.ReadByte(), second=stream.ReadByte();
                    var encoding = second==0 || first==255 ? Encoding.Unicode : Encoding.UTF8;
                    stream.Position = tail ? Math.Max(0L, (stream.Length-8388608L)/2*2) : 0;
                    using (var reader = new StreamReader(stream,encoding,true,65536)) {
                        string line;
                        while ((line=reader.ReadLine())!=null) {
                            if(line.Length<24 || line[4]!='/' || line[10]!=' ') continue;
                            if(String.CompareOrdinal(line,0,from,0,23)<0 || String.CompareOrdinal(line,0,through,0,23)>0) continue;
                            string stamp=line.Substring(0,23);
                            if(FirstRecord==null || String.CompareOrdinal(stamp,FirstRecord)<0) FirstRecord=stamp;
                            if(LastRecord==null || String.CompareOrdinal(stamp,LastRecord)>0) LastRecord=stamp;
                            if(line.IndexOf("SCANFILE:",StringComparison.Ordinal)<0) continue;
                            Match h=Header.Match(line);
                            if(!h.Success) continue;
                            const string begin=">>> SCANFILE: ";
                            int pos=line.IndexOf(begin,StringComparison.Ordinal);
                            var row=new Row {Stamp=stamp,Thread=h.Groups[2].Value,Start=pos>=0,Sequence=rows.Count};
                            if(row.Start) {
                                int end=line.LastIndexOf(",[",StringComparison.Ordinal);
                                pos+=begin.Length;
                                row.Path=(end>pos ? line.Substring(pos,end-pos) : line.Substring(pos)).Trim();
                            } else {
                                Match m=Duration.Match(line);
                                if(!m.Success) continue;
                                row.Duration=m.Groups[1].Value;
                            }
                            string key=row.Stamp+"|"+row.Thread+"|"+(row.Start ? "S"+row.Path : "E"+row.Duration);
                            int local, max;
                            fileCounts.TryGetValue(key,out local); fileCounts[key]=++local;
                            counts.TryGetValue(key,out max);
                            if(local<=max) continue;
                            counts[key]=local; rows.Add(row);
                        }
                    }
                }
            } catch(Exception ex) { Errors.Add(path+": "+ex.Message); }
        }
        var pending = new Dictionary<string,Row>();
        foreach(var r in rows.OrderBy(x=>x.Stamp,StringComparer.Ordinal).ThenBy(x=>x.Sequence)) {
            if(r.Start) {
                if(pending.ContainsKey(r.Thread)) UnmatchedStarts++;
                pending[r.Thread]=r;
            } else {
                Row begin;
                if(!pending.TryGetValue(r.Thread,out begin)) {UnmatchedEnds++; continue;}
                pending.Remove(r.Thread);
                long us=r.Duration.StartsWith("0x") ? Convert.ToInt64(r.Duration.Substring(2),16) : long.Parse(r.Duration,CultureInfo.InvariantCulture);
                Pairs.Add(new SwpScan {StartLocal=begin.Stamp,EndLocal=r.Stamp,Thread=r.Thread,Path=begin.Path,EngineMicroseconds=us});
            }
        }
        UnmatchedStarts+=pending.Count;
    }
}

'@
}

function Confirm-WarmScanControl {
    Initialize-ScanReader
    $since = (Get-Date).AddSeconds(-1).ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
    $dir = Join-Path $ToolRoot ('ScanControl-'+[guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $dir -ItemType Directory
    $file = Join-Path $dir ('whoami-'+[guid]::NewGuid().ToString('N')+'.exe')
    try {
        $src = Join-Path $env:windir 'System32\whoami.exe'
        if ((Get-AuthenticodeSignature -LiteralPath $src).Status -ne 'Valid') { throw 'Signed control executable could not be verified.' }
        Copy-Item -LiteralPath $src -Destination $file
        & $file | Out-Null
        $until=(Get-Date).AddSeconds(65)
        do {
            $logs = @(Get-ChildItem -LiteralPath $AmspDebug -Filter 'Amsp_LocalDebugLog*.log' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3 -ExpandProperty FullName)
            $reader = New-Object SwpScanReader
            $reader.Read([string[]]$logs,$since,'9999/12/31 23:59:59.999',$true)
            $control = @($reader.Pairs | Where-Object { $_.Path -eq $file -or $_.Path -eq ('\\?\'+$file) })
            if ($control.Count) { $control | ConvertTo-Json | Set-Content -LiteralPath "$Case\Trend\Warm-control.json" -Encoding UTF8; return }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $until)
        throw 'The signed control did not produce a paired AMSP scan. Keep the session signed in, inspect the case and use recovery.'
    } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; [IO.Directory]::Delete($dir,$false) }
}

function Save-SignInMilestones {
    param([string]$PassName = 'PassA')
    $start = if ($State.Scenario -eq 'SignOutSignIn') { Parse-StateDateTime $State.ArmedAtUtc } else { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    $end = if ($PassName -eq 'PassB') { Parse-StateDateTime $State.ReproductionEndUtc } else { Parse-StateDateTime $State.TraceStopRequestedAtUtc }
    $account = $State.AffectedUser
    $shells = @(Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object {
        $_.UserName -eq $account -and $_.StartTime.ToUniversalTime() -ge $start.ToUniversalTime() -and $_.StartTime.ToUniversalTime() -le $end.ToUniversalTime()
    })
    $logons = @()
    if ($shells.Count -eq 1) {
        $parts = $account.Split('\',2)
        $logons = @(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624;StartTime=$start.ToLocalTime();EndTime=$shells[0].StartTime} -ErrorAction SilentlyContinue | ForEach-Object {
            $xml = [xml]$_.ToXml(); $d=@{}
            foreach ($fld in $xml.Event.EventData.Data) { $d[$fld.Name]=$fld.'#text' }
            if ($parts.Count -eq 2 -and $d.TargetUserName -eq $parts[1] -and $d.TargetDomainName -eq $parts[0] -and $d.LogonType -in '2','10','11','12') {
                [pscustomobject]@{Utc=$_.TimeCreated.ToUniversalTime().ToString('o');Id=$d.TargetLogonId;Record=$_.RecordId;Type=$d.LogonType;Linked=$d.TargetLinkedLogonId}
            }
        })
    }
    # A split admin token can generate linked 4624 records for the same interactive authentication.
    $unique=@()
    if ($logons.Count -eq 1) { $unique=$logons }
    elseif ($logons.Count -eq 2 -and $logons[0].Linked -eq $logons[1].Id -and
        $logons[1].Linked -eq $logons[0].Id -and $logons[0].Type -eq $logons[1].Type -and
        [math]::Abs(((Parse-StateDateTime $logons[0].Utc)-(Parse-StateDateTime $logons[1].Utc)).TotalSeconds) -lt 1) {
        $unique=@($logons|Sort-Object Record|Select-Object -First 1)
    }
    $sessionMatch=$false
    $localEvents=@()
    if($shells.Count -eq 1) {
        $localEvents=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational';Id=21;StartTime=$start.ToLocalTime();EndTime=$end.ToLocalTime()} -ErrorAction SilentlyContinue | ForEach-Object {
            $xml=[xml]$_.ToXml(); $eventData=$xml.Event.UserData.EventXML
            if($eventData.User -eq $account -and [string]$eventData.SessionID -eq [string]$shells[0].SessionId){$_.TimeCreated}
        })
        $sessionMatch=$localEvents.Count -eq 1 -and $unique.Count -eq 1
    }
    $r = [ordered]@{Account=$account;AuthenticatedUtc=$null;ExplorerUtc=$null;Session=$null;SessionCorroborated=$sessionMatch;Logons=$logons;ExplorerCount=$shells.Count;TimeZone=(Get-TimeZone).Id}
    if($sessionMatch){$r.AuthenticatedUtc=$unique[0].Utc; $r.ExplorerUtc=$shells[0].StartTime.ToUniversalTime().ToString('o'); $r.Session=$shells[0].SessionId}
    $path = if ($PassName -eq 'PassB') { "$Case\Procmon\SignIn-milestones.json" } else { "$Case\WPR\SignIn-milestones.json" }
    $r | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-ScanCoverage {
    param($Files,[datetime]$FromUtc,[datetime]$ToUtc,[string]$PassName='PassA')
    $unknown='Per-file AMSP scan timings during sign-in were not verified.'
    $r=[ordered]@{Status='Unverified';Message=$unknown;SignInPairs=$null;AfterSignInPairs=$null;CapturedPairs=0;CredentialToDesktopPairs=$null;AppWindows=@();FirstRecordLocal=$null;LastRecordLocal=$null;FirstPairLocal=$null;LastPairLocal=$null;UnmatchedStarts=0;UnmatchedEnds=0;Errors=@()}
    if($FromUtc -eq [datetime]::MinValue -or $ToUtc -eq [datetime]::MinValue){return [pscustomobject]$r}
    $fmt='yyyy/MM/dd HH:mm:ss.fff';$ci=[cultureinfo]::InvariantCulture
    try {
        $markPath = if ($PassName -eq 'PassB') { "$Case\Procmon\SignIn-milestones.json" } else { "$Case\WPR\SignIn-milestones.json" }
        $mark=Get-Content -LiteralPath $markPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $tz=[TimeZoneInfo]::FindSystemTimeZoneById($mark.TimeZone)
        function LocalStamp($v){[TimeZoneInfo]::ConvertTimeFromUtc((Parse-StateDateTime $v).ToUniversalTime(),$tz).ToString($fmt,$ci)}
        $debugRoot = "$Case\Trend\AMDebug\"
        $paths=@($Files|Where-Object {
            $_.Name -like 'Amsp_LocalDebugLog*.log' -and $_.FullName.StartsWith($debugRoot,[StringComparison]::OrdinalIgnoreCase) -and
                (($_.FullName.Substring($debugRoot.Length) -like 'PassB-*') -eq ($PassName -eq 'PassB'))
        }|Sort-Object LastWriteTimeUtc|Select-Object -ExpandProperty FullName)
        Initialize-ScanReader
        $reader=New-Object SwpScanReader
        $reader.Read([string[]]$paths,(LocalStamp $FromUtc.AddSeconds(-2)),(LocalStamp $ToUtc.AddMinutes(5)),$false)
        $r.FirstRecordLocal=$reader.FirstRecord;$r.LastRecordLocal=$reader.LastRecord;$r.Errors=@($reader.Errors.ToArray())
        $r.UnmatchedStarts=$reader.UnmatchedStarts;$r.UnmatchedEnds=$reader.UnmatchedEnds
        if($reader.Pairs.Count){$r.FirstPairLocal=$reader.Pairs[0].StartLocal;$r.LastPairLocal=$reader.Pairs[$reader.Pairs.Count-1].EndLocal}
        $r.CapturedPairs=$reader.Pairs.Count
        $authStart=$null;$shellStart=$null
        if($mark.SessionCorroborated -and $mark.AuthenticatedUtc -and $mark.ExplorerUtc) {
            $lo=LocalStamp $mark.AuthenticatedUtc; $hi=LocalStamp $mark.ExplorerUtc
            $rows=@($reader.Pairs|Where-Object {$_.StartLocal -ge $lo -and $_.EndLocal -le $hi})
            $r.SignInPairs=$rows.Count
            $authStart=$lo;$shellStart=$hi
            $r.AfterSignInPairs=@($reader.Pairs | Where-Object {$_.StartLocal -gt $hi}).Count
            if (!$rows.Count -and $r.AfterSignInPairs) {$r.Message='AMSP timed scans were recorded after Explorer started. Per-file timings during sign-in were not verified.'}
            if($rows.Count){$r.Status='Observed';$r.Message='Paired scans observed between authentication and Explorer.'}
        }
        $notes=Get-Content -LiteralPath (Get-TimingNotesPath $Case $PassName) -Raw | ConvertFrom-Json
        if($notes.CredentialSubmittedAt -and $notes.DesktopReadyAt) {
            $lo=LocalStamp $notes.CredentialSubmittedAt;$hi=LocalStamp $notes.DesktopReadyAt
            $r.CredentialToDesktopPairs=@($reader.Pairs|Where-Object {$_.StartLocal -ge $lo -and $_.EndLocal -le $hi}).Count
        }
        foreach($app in @($notes.Applications|Where-Object {$_.Name -and $_.LaunchAt -and $_.ReadyAt})) {
            $lo=LocalStamp $app.LaunchAt;$hi=LocalStamp $app.ReadyAt
            $r.AppWindows+=@([pscustomobject]@{Name=$app.Name;Pairs=@($reader.Pairs|Where-Object {$_.StartLocal -ge $lo -and $_.EndLocal -le $hi}).Count})
        }
        $csv = if ($PassName -eq 'PassB') { "$Case\Trend\PassB-Timed-scans.csv" } else { "$Case\Trend\Timed-scans.csv" }
        $reader.Pairs | Select-Object StartLocal,EndLocal,Thread,Path,EngineMicroseconds,
            @{Name='EngineMilliseconds';Expression={$_.EngineMicroseconds/1000.0}},
            @{Name='InAuthenticatedSignIn';Expression={if($authStart -and $shellStart){$_.StartLocal -ge $authStart -and $_.EndLocal -le $shellStart}}} | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    } catch { $r.Errors+= $_.Exception.Message }
    [pscustomobject]$r
}

function Assert-CaseTrace {
    param($Owner,[switch]$BeforeBoot)
    if (!$Owner.Armed -or $Owner.TraceSaved -or $Owner.ComputerName -ne $env:COMPUTERNAME -or $Owner.RunId -notmatch '^[a-f0-9]{32}$' -or $Owner.Scenario -notin 'Reboot','SignOutSignIn') {
        throw 'WPR ownership cannot be verified. Preserve the session and use RecoverAndPackage.'
    }
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $before=(Parse-StateDateTime $Owner.PreparedBoot).ToUniversalTime()
    if($Owner.Scenario -eq 'SignOutSignIn' -and $boot -ne $before){throw 'A restart occurred after preparing the same-boot case.'}
    if(!$BeforeBoot -and $Owner.Scenario -eq 'Reboot' -and $boot -le $before){throw 'The recorded restart has not occurred.'}
    if ($Owner.Scenario -eq 'Reboot' -and $boot -gt $before) {
        $bootFile=Join-Path $Case "Trend\LiveMetrics\PassA\$($Owner.RunId)\BootUtc.txt"
        # Event delivery and the startup task can lag an early interactive sign-in.
        $deadline=[datetime]::UtcNow.AddSeconds(8)
        $confirmed=$false
        $armed=(Parse-StateDateTime $Owner.PreparedAt).ToLocalTime()
        do {
            $stamp=Get-Content -LiteralPath $bootFile -Raw -ErrorAction SilentlyContinue
            if ($stamp -and $stamp.Trim()) {
                if ($boot -ne (Parse-StateDateTime $stamp.Trim()).ToUniversalTime()) {throw 'Another reboot occurred after the metrics task started.'}
                $confirmed=$true;break
            }
            $starts=@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12;StartTime=$armed} -ErrorAction SilentlyContinue)
            if($starts.Count -gt 1){throw 'Multiple boots occurred since preparation.'}
            if($starts.Count -eq 1 -and [math]::Abs(($starts[0].TimeCreated.ToUniversalTime()-$boot).TotalSeconds) -lt 30){$confirmed=$true;break}
            Start-Sleep -Milliseconds 350
        }while([datetime]::UtcNow -lt $deadline)
        if(!$confirmed){throw 'The new boot is not yet identifiable. Retry StopTrace as soon as the system boot event or startup-task marker is available.'}
    }
    if($Owner.RecordedBootUtc -and $boot -ne (Parse-StateDateTime $Owner.RecordedBootUtc).ToUniversalTime()){throw 'The recorded boot no longer matches.'}
}

function Start-EarlySnapshot {
    $installed = Join-Path $ToolRoot 'SWP-Perf.ps1'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -Stage SaveDebug -Pass PassA -Case "{1}"' -f $installed,$Case) -PassThru -NoNewWindow -RedirectStandardOutput "$Case\WPR\Early-copy-output.txt" -RedirectStandardError "$Case\WPR\Early-copy-error.txt"
}

function Get-TimingNotesPath {
    param([string]$CasePath, [string]$PassName)
    if ($PassName -eq 'PassB') { return (Join-Path $CasePath 'Procmon\Operator-notes.json') }
    Join-Path $CasePath 'Operator-notes.json'
}

function Get-OperatorNotesAssessment {
    param([datetime]$WindowStartUtc=[datetime]::MinValue, [datetime]$WindowEndUtc=[datetime]::MinValue, [string]$PassName='PassA')
    $Path = Get-TimingNotesPath $Case $PassName
    $Missing = @()
    try {
        $Notes = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($Name in @('CredentialSubmittedAt','DesktopReadyAt')) {
            if (-not $Notes.$Name -or $Notes.$Name -notmatch 'T.*(Z|[+-]\d\d:\d\d)$') { $Missing += $Name }
            else { $null = [datetimeoffset]::Parse($Notes.$Name,[Globalization.CultureInfo]::InvariantCulture) }
        }
        $Applications = @($Notes.Applications | Where-Object { $_.Name -or $_.LaunchAt -or $_.ReadyAt })
        foreach ($n in 'CredentialSubmittedAt','DesktopReadyAt') {
            if (!$Notes.$n) { continue }
            $time = [datetimeoffset]::Parse($Notes.$n).UtcDateTime
            if (($WindowStartUtc -ne [datetime]::MinValue -and $time -lt $WindowStartUtc.AddSeconds(-1)) -or
                ($WindowEndUtc -ne [datetime]::MinValue -and $time -gt $WindowEndUtc.AddSeconds(1))) { $Missing += "$n is outside the recorded reproduction" }
        }
        foreach ($App in $Applications) {
            if (-not $App.Name -or -not $App.LaunchAt -or -not $App.ReadyAt) { $Missing += 'Incomplete application timing entry'; continue }
            foreach ($Name in @('LaunchAt','ReadyAt')) {
                if ($App.$Name -notmatch 'T.*(Z|[+-]\d\d:\d\d)$') { $Missing += "Application $($App.Name): $Name needs a timezone offset" }
            }
            $Launch = [datetimeoffset]::Parse($App.LaunchAt,[Globalization.CultureInfo]::InvariantCulture)
            $Ready = [datetimeoffset]::Parse($App.ReadyAt,[Globalization.CultureInfo]::InvariantCulture)
            if ($Ready -lt $Launch) { $Missing += "Application $($App.Name): ready precedes launch" }
            if (($WindowStartUtc -ne [datetime]::MinValue -and $Launch.UtcDateTime -lt $WindowStartUtc.AddSeconds(-1)) -or
                ($WindowEndUtc -ne [datetime]::MinValue -and $Ready.UtcDateTime -gt $WindowEndUtc.AddSeconds(1))) { $Missing += "Application $($App.Name): timing is outside the recorded $PassName reproduction window" }
        }
        if ($Notes.CredentialSubmittedAt -and $Notes.DesktopReadyAt -and [datetimeoffset]::Parse($Notes.DesktopReadyAt) -lt [datetimeoffset]::Parse($Notes.CredentialSubmittedAt)) { $Missing += 'Desktop ready precedes credential submission' }
    } catch { $Missing += "Structured timing notes unavailable or invalid: $($_.Exception.Message)" }
    [pscustomobject]@{ Status=$(if ($Missing.Count) { 'Incomplete' } else { 'Filled' }); MissingFields=@($Missing); Path=$Path }
}

function Get-PmlEvidenceGaps {
    param([string]$Folder, [string]$RunId)
    $manifest = Join-Path $Folder 'PassB-segments.csv'
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) { return 'Pass B Procmon segment inventory is missing. The saved capture cannot be verified.' }
    try {
        $segments = @(Import-Csv -LiteralPath $manifest)
        if (!$segments.Count) { return 'Pass B Procmon inventory contains no segments.' }
        $names = @{}
        foreach ($segment in $segments) {
            if (!$segment.Name -or [IO.Path]::GetFileName($segment.Name) -ne $segment.Name -or
                $segment.Name -notlike '*.pml' -or $segment.SHA256 -notmatch '^[a-f0-9]{64}$' -or
                $names.ContainsKey($segment.Name) -or ($RunId -and $segment.RunId -ne $RunId)) { throw 'Invalid segment identity.' }
            $names[$segment.Name] = $true
            $path = Assert-LocalEvidencePath (Join-Path $Folder $segment.Name)
            $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if (!$file -or $file.Length -ne [long]$segment.Bytes -or $file.Length -le 0 -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $segment.SHA256) {
                "Pass B Procmon segment missing or changed: $($segment.Name)"
            }
        }
        foreach ($file in (Get-ChildItem -LiteralPath $Folder -File -Filter '*.pml')) {
            if (!$names.ContainsKey($file.Name)) { "Pass B Procmon segment outside the finish inventory: $($file.Name)" }
        }
    } catch { "Pass B Procmon inventory could not be verified: $($_.Exception.Message)" }
}

function Export-PassEvents {
    param([string]$Folder)
    $items = foreach ($channel in (@('System','Application') + $Channels | Where-Object { $_ } | Select-Object -Unique)) {
        $status = 'Failed'; $detail = ''; $size = 0
        $target = Join-Path $Folder (($channel -replace '[/\\]', '-') + '.evtx')
        try {
            $output = & wevtutil.exe epl $channel $target /ow:true 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($output -join ' ') }
            $size = (Get-Item -LiteralPath $target -ErrorAction Stop).Length
            if (!$size) { throw 'Empty export.' }
            $status = 'Exported'
        } catch {
            $detail = $_.Exception.Message
            try { $null = Get-WinEvent -ListLog $channel -ErrorAction Stop }
            catch {
                if ($_.FullyQualifiedErrorId -like 'NoMatchingLogsFound*' -or $_.Exception -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException]) { $status = 'Unavailable' }
            }
        }
        [pscustomobject]@{Channel=$channel;Status=$status;Bytes=$size;Detail=$detail}
    }
    $items | Export-Csv -LiteralPath (Join-Path $Folder 'Channel-exports.csv') -NoTypeInformation -Encoding UTF8
}

function Get-EventEvidenceGaps {
    param([string]$Folder, [string]$PassName)
    $manifest = Join-Path $Folder 'Channel-exports.csv'
    $legacyError = Get-Item -LiteralPath (Join-Path $Folder 'Export-errors.txt') -ErrorAction SilentlyContinue
    if ($legacyError -and $legacyError.Length) { "$PassName recorded event-export errors. Review the saved Export-errors.txt." }
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) {
        "$PassName event export manifest missing. Individual channel results are unverified."
        return
    }
    try {
        $entries = @(Import-Csv -LiteralPath $manifest)
        foreach ($channel in (@('System','Application') + $Channels | Where-Object { $_ } | Select-Object -Unique)) {
            $row = @($entries | Where-Object Channel -eq $channel)
            if ($row.Count -ne 1) { "$PassName missing or ambiguous event export result: $channel"; continue }
            if ($row[0].Status -eq 'Unavailable' -and $channel -notin 'Application','System') { continue }
            $file = Get-Item -LiteralPath (Join-Path $Folder (($channel -replace '[/\\]', '-') + '.evtx')) -ErrorAction SilentlyContinue
            if ($row[0].Status -ne 'Exported' -or !$file -or !$file.Length -or $file.Length -ne [long]$row[0].Bytes) {
                "$PassName event export failed, missing or changed: $channel ($($row[0].Status))."
            }
        }
    } catch { "$PassName event export manifest is unreadable: $($_.Exception.Message)" }
}

function Get-CaseEvidenceAssessment {
    $Gaps = [Collections.Generic.List[string]]::new()
    $CaseFiles = @(Get-RegularEvidenceFiles -Root $Case)
    foreach ($Relative in @('WPR\PassA-BootLoginApps.etl','Events\System.evtx','Events\Application.evtx')) {
        $Path = Join-Path $Case $Relative
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) { $Gaps.Add("Missing or empty: $Relative") }
    }
    $QualityPath = Join-Path $Case 'WPR\Trace-quality.json'
    $Quality = $null
    if (Test-Path -LiteralPath $QualityPath) {
        try {
            $Quality = Get-Content -LiteralPath $QualityPath -Raw | ConvertFrom-Json
            if (-not $Quality.Saved -or $Quality.Status -in @('SaveFailed','SavedWithEventLoss','SavedLossCountUnparsed')) {
                $Gaps.Add("WPR quality: $($Quality.Status); reported event loss: $($Quality.ReportedDroppedEvents)")
            }
            $EtlPath = Join-Path $Case 'WPR\PassA-BootLoginApps.etl'
            if ($Quality.EtlLength -and (Test-Path -LiteralPath $EtlPath -PathType Leaf)) {
                $Etl = Get-Item -LiteralPath $EtlPath
                if ($Etl.Length -ne $Quality.EtlLength -or $Etl.LastWriteTimeUtc -ne (Parse-StateDateTime $Quality.EtlLastWriteTimeUtc).ToUniversalTime()) { $Gaps.Add('ETL changed since the WPR save assessment.') }
            }
        } catch { $Gaps.Add('WPR quality record is unreadable.') }
    } else { $Gaps.Add('No machine-readable WPR quality assessment; inspect save output manually.') }
    $MetricResults = @()
    foreach ($PassName in @('PassA','PassB')) {
        $PhasePath = Join-Path $Case ("Cleanup\Phase{0}-state.json" -f $PassName.Substring(4))
        if ($PassName -eq 'PassB' -and -not (Test-Path -LiteralPath $PhasePath)) { continue }
        $Phase = $null
        $Start = [datetime]::MinValue; $End = [datetime]::MinValue; $Through = (Get-Date).ToUniversalTime()
        $Computer = $env:COMPUTERNAME
        try {
            if (Test-Path -LiteralPath $PhasePath) {
                $Phase = Get-Content -LiteralPath $PhasePath -Raw | ConvertFrom-Json
                if ($Phase.Scenario -eq 'SignOutSignIn' -and $Phase.ArmedAtUtc) { $Start=(Parse-StateDateTime $Phase.ArmedAtUtc).ToUniversalTime() }
                elseif ($Phase.RecordedBootUtc) { $Start = (Parse-StateDateTime $Phase.RecordedBootUtc).ToUniversalTime() }
                elseif ($Phase.PreparedAt) { $Start = (Parse-StateDateTime $Phase.PreparedAt).ToUniversalTime() }
                if ($Phase.TraceStopRequestedAtUtc) { $End = (Parse-StateDateTime $Phase.TraceStopRequestedAtUtc).ToUniversalTime() }
                elseif ($Phase.ReproductionEndUtc) { $End = (Parse-StateDateTime $Phase.ReproductionEndUtc).ToUniversalTime() }
                if ($Phase.FinishedAtUtc) { $Through = (Parse-StateDateTime $Phase.FinishedAtUtc).ToUniversalTime() }
                if ($Phase.ComputerName) { $Computer = $Phase.ComputerName }
            }
        } catch { $Gaps.Add("$PassName state unreadable; metric coverage cannot be established.") }
        $Paths = @($CaseFiles | Where-Object {
            if (-not ($_.Name -like '*_jsonRecords.json' -or $_.Name -like 'DSTool-METRICS-*.zip')) { return $false }
            $relative = $_.FullName.Substring($Case.Length+1)
            $passPattern = [regex]::Escape($PassName)
            if ($Phase.RunId -and $relative -match ('^Trend\\LiveMetrics\\'+$passPattern+'\\'+[regex]::Escape($Phase.RunId)+'\\')) { return $true }
            $relative -match ('^Trend\\'+$passPattern+'(?:-Retry-[^\\]+)?\\VerifiedToolMetrics\\(?:Archive-\d+|LooseMetrics)\\')
        } | Select-Object -ExpandProperty FullName)
        $Metrics = Get-ToolMetricsAssessment -Paths $Paths -SinceUtc $Start -ThroughUtc $Through -RequiredEndUtc $End -ExpectedComputer $Computer
        $Metrics | Add-Member -NotePropertyName Pass -NotePropertyValue $PassName
        if ($Phase.RunId -and $Metrics.CollectionDurationStatus -ne 'Covered') {
            $Metrics.EvidenceGaps += 'The configured 900-second collection interval was not fully verified. See ObservedSpanSeconds and SamplesDuringReproduction.'
        }
        $MetricResults += $Metrics
        foreach ($Gap in $Metrics.EvidenceGaps) { $Gaps.Add("$PassName metrics: $Gap") }
        $eventFolder = if ($PassName -eq 'PassA') { "$Case\Events" } else { "$Case\Events\PassB" }
        foreach ($gap in (Get-EventEvidenceGaps $eventFolder $PassName)) { $Gaps.Add($gap) }
        if ($PassName -eq 'PassB') {
            foreach ($gap in (Get-PmlEvidenceGaps "$Case\Procmon" $Phase.RunId)) { $Gaps.Add($gap) }
            if (!$Phase.Finished) { $Gaps.Add('Pass B has not finished.') }
            if ($Phase.ReproductionEndSource -in 'FinishB','Recovery') { $Gaps.Add('Pass B used the finish or recovery time as the window end. Use the operator notes to locate the end of the symptom.') }
            $bScan = Get-ScanCoverage $CaseFiles $Start $End 'PassB'
            $bNotes = Get-OperatorNotesAssessment $Start $End 'PassB'
            if ($bScan.Status -ne 'Observed' -or $bScan.Errors.Count) { $Gaps.Add("Pass B scan coverage: $($bScan.Message) Review the Pass B milestones and inputs.") }
            if ($bNotes.Status -ne 'Filled') { $Gaps.Add('Pass B operator notes: ' + ($bNotes.MissingFields -join '; ')) }
        }
    }
    $NotesStart = if ($MetricResults[0].WindowStartUtc) { (Parse-StateDateTime $MetricResults[0].WindowStartUtc).ToUniversalTime() } else { [datetime]::MinValue }
    $NotesEnd = if ($MetricResults[0].RequiredEndUtc) { (Parse-StateDateTime $MetricResults[0].RequiredEndUtc).ToUniversalTime() } else { [datetime]::MinValue }
    $scan = Get-ScanCoverage $CaseFiles $NotesStart $NotesEnd
    if ($scan.Status -ne 'Observed') { $Gaps.Add($scan.Message) }
    if ($scan.Errors.Count) { $Gaps.Add('AMSP timing data contains unreadable or missing inputs.') }
    $Notes = Get-OperatorNotesAssessment -WindowStartUtc $NotesStart -WindowEndUtc $NotesEnd
    if ($Notes.Status -ne 'Filled') { $Gaps.Add('Operator timing notes are incomplete: ' + ($Notes.MissingFields -join '; ')) }
    $DiagPath = Join-Path $Case 'Trend\FinalDiagnostics\Last-diagnostic-status.json'
    if (Test-Path -LiteralPath $DiagPath) {
        try {
            $Diag = Get-Content -LiteralPath $DiagPath -Raw | ConvertFrom-Json
            $CopiedZip = $Diag.CopiedZip
            if ($Diag.RelativeCopiedZip) {
                if ([IO.Path]::IsPathRooted($Diag.RelativeCopiedZip) -or @($Diag.RelativeCopiedZip -split '[/\\]' | Where-Object { $_ -eq '..' }).Count) { throw 'Invalid relative diagnostic path.' }
                $CopiedZip = Join-Path $Case $Diag.RelativeCopiedZip
            }
            if ($Diag.Status -ne 'Succeeded') { $Gaps.Add("Fresh agent diagnostic not verified: $($Diag.Status); $($Diag.Message)") }
            elseif (-not $CopiedZip -or -not ([IO.Path]::GetFullPath($CopiedZip)).StartsWith($Case.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $CopiedZip -PathType Leaf) -or (Get-FileHash -LiteralPath $CopiedZip).Hash -ne $Diag.SHA256) { $Gaps.Add('Recorded diagnostic ZIP is missing, outside the case, or its hash changed.') }
        } catch { $Gaps.Add('Diagnostic status is unreadable or invalid.') }
    } else { $Gaps.Add('No successful fresh agent diagnostic recorded (possibly explicitly skipped).') }
    $Recovery = Join-Path $Case 'Cleanup\PersistentAMTrace'
    try {
        $TraceState = Get-Content -LiteralPath "$Recovery\State.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($TraceState.Restored -ne $true) { $Gaps.Add('Original INI restoration has not been recorded as completed.') }
        if (Test-Path -LiteralPath "$Recovery\Restored-trace-assessment.json") {
            $Trace = Get-Content -LiteralPath "$Recovery\Restored-trace-assessment.json" -Raw | ConvertFrom-Json
            if ($Trace.AMDebugRequested) { $Gaps.Add('Restored original INI still requests AM debug logging; owner review required.') }
        } else { $Gaps.Add('Restored logging state has not been assessed.') }
    } catch { $Gaps.Add('INI recovery state is missing or unreadable; restoration cannot be verified.') }
    if (-not @($CaseFiles | Where-Object { $_.Name -like 'Amsp_LocalDebugLog*.log' -and $_.Length -gt 0 -and $_.FullName.StartsWith((Join-Path $Case 'Trend\AMDebug')+'\',[StringComparison]::OrdinalIgnoreCase) }).Count) {
        $Gaps.Add('No nonempty raw AMSP debug snapshot verified. Inspect whether login records were overwritten.')
    }
    foreach ($File in ($CaseFiles | Where-Object { $_.Name -in @('Collection-errors.txt','Early-debug-copy-error.txt','Fallback-debug-copy-error.txt') -and $_.Length -gt 0 })) {
        $Gaps.Add("Collection errors require review: $($File.FullName.Substring($Case.Length+1))")
    }
    $Latest = @{}
    foreach ($Manifest in ($CaseFiles | Where-Object Name -eq 'Context-manifest.json' | Sort-Object FullName)) {
        try {
            $Data = Get-Content -LiteralPath $Manifest.FullName -Raw | ConvertFrom-Json
            foreach ($Item in $Data.Items) { $Latest[$Item.Kind+'|'+$Item.Source] = [pscustomobject]@{ Item=$Item; Directory=$Manifest.Directory.FullName } }
        } catch { $Gaps.Add('A context manifest is unreadable; inspect Context exports.') }
    }
    $Context = @()
    foreach ($Saved in $Latest.Values) {
        $Item = $Saved.Item
        try {
            if ($Item.Status -ne 'Copied') { throw $Item.Error }
            $Path = $Item.File
            if ($Item.RelativeFile) {
                if ([IO.Path]::IsPathRooted($Item.RelativeFile) -or @($Item.RelativeFile -split '[/\\]' | Where-Object { $_ -eq '..' }).Count) { throw 'Invalid relative context path.' }
                $Path = Join-Path $Saved.Directory $Item.RelativeFile
            }
            if (-not $Path -or -not ([IO.Path]::GetFullPath($Path)).StartsWith($Saved.Directory+'\',[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path).Hash -ne $Item.SHA256) { throw 'Copied context file missing, outside its snapshot, or hash changed.' }
            $Context += $Item
        } catch { $Gaps.Add("Context not verified: $($Item.Source); $($_.Exception.Message)") }
    }
    if (-not @($Context | Where-Object Kind -eq 'Task').Count) { $Gaps.Add('No selected login-task XML verified. Supply the relevant task with CollectContext.') }
    if (-not @($Context | Where-Object Kind -eq 'Script').Count) { $Gaps.Add('No administrator-selected login PS1/VBS definitions verified.') }
    if (-not @($Context | Where-Object Kind -eq 'PolicyExport').Count) { $Gaps.Add('No effective policy/exclusion-list console exports verified. GetConfiguration.xml list names do not supply their members.') }
    [pscustomobject]@{
        AssessedAt=(Get-Date -Format o); Status=$(if ($Gaps.Count) { 'EvidenceGapsRemain' } else { 'RequiredArtifactsVerified' })
        SignInScans=$scan; PassBSignInScans=$bScan; Metrics=$MetricResults[0]; MetricsByPass=$MetricResults; Wpr=$Quality; OperatorNotes=$Notes; PassBOperatorNotes=$bNotes; EvidenceGaps=@($Gaps.ToArray())
        Interpretation='Artifact checks do not establish a root cause, validate boot markers, confirm console/self-protection state, or confirm that exports include every effective exclusion-list member.'
    }
}

function Save-State {
    $temp=$StatePath+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    [IO.File]::WriteAllText($temp,($script:State|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($StatePath)){
        [IO.File]::Replace($temp,$StatePath,$temp+'.previous')
        [IO.File]::Delete($temp+'.previous')
    } else {[IO.File]::Move($temp,$StatePath)}
}
function Parse-StateDateTime {
    param([object]$DateString)
    if ($DateString -is [datetime]) { return $DateString }
    if ($DateString -is [datetimeoffset]) { return $DateString.UtcDateTime }
    if ($DateString -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        return [datetimeoffset]::Parse($DateString,[cultureinfo]::InvariantCulture).UtcDateTime
    }
    $formats = @(
        'o',  # ISO 8601
        'dd/MM/yyyy HH.mm.ss',  # European format with dots
        'MM/dd/yyyy HH:mm:ss',  # US format
        'yyyy-MM-dd HH:mm:ss'   # ISO format with time
    )
    foreach ($format in $formats) {
        try {
            return [datetime]::ParseExact($DateString, $format, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch { }
    }
    throw "Could not parse DateTime: $DateString"
}
function Save-NativeEvidence {
    param([string]$Exe, [string[]]$Arguments, [string]$Output)
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | Out-File -LiteralPath $Output
    "Exit code: $LASTEXITCODE" | Add-Content -LiteralPath $Output
}
function Copy-EvidenceFolder {
    param([string]$Source, [string]$Target, [string]$Log)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source missing: $Source. Verify its location; do not label it collected."
    }
    & robocopy.exe $Source $Target /E /COPY:DAT /DCOPY:T /R:1 /W:1 /XJ /NP "/LOG:$Log"
    $Result = $LASTEXITCODE
    "$Source -> $Target; robocopy=$Result" | Add-Content "$Case\Trend\Automated-copy-results.txt"
    if ($Result -ge 8) { throw "Copy errors: $Log. Preserve partial evidence; correct errors before proceeding." }
}
function Save-AMDebug {
    param([string]$Label)
    $Dest = Join-Path "$Case\Trend\AMDebug" ($Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $Dest | Out-Null
    if (!(Test-Path -LiteralPath $AmspDebug -PathType Container)){throw "Missing AMSP debug source: $AmspDebug"}
    $files=@(Get-ChildItem -LiteralPath $AmspDebug -Filter 'Amsp_LocalDebugLog*.log' -File | Sort-Object LastWriteTimeUtc -Descending)
    if ($State.PreparedAt) {
        $from=(Parse-StateDateTime $State.PreparedAt).ToUniversalTime().AddSeconds(-5)
        $previous=$files | Where-Object LastWriteTimeUtc -lt $from | Select-Object -First 1
        $files=@($files | Where-Object {$_.Name -eq 'Amsp_LocalDebugLog.log' -or $_.LastWriteTimeUtc -ge $from -or $_.Name -eq $previous.Name})
    }
    if (!$files.Count){throw 'No AMSP debug generations found.'}
    $names=@($files | Select-Object -ExpandProperty Name)
    $files | Select-Object Name,Length,LastWriteTimeUtc | Export-Csv -LiteralPath "$Dest\AMSP-generations.csv" -NoTypeInformation
    & robocopy.exe $AmspDebug "$Dest\AMSPDebug" @names /COPY:DAT /R:1 /W:1 /XJ /NP "/LOG:$Dest\AMSP-copy.log"
    if($LASTEXITCODE -ge 8){throw "AMSP log copy failed: $Dest\AMSP-copy.log"}
    $AgentLogs = Join-Path $env:ProgramData 'Trend Micro\Deep Security Agent'
    & robocopy.exe $AgentLogs "$Dest\AgentLogs" 'ds_agent*.log' /COPY:DAT /R:1 /W:1 /NP "/LOG:$Dest\Agent-copy.log"
    $Result = $LASTEXITCODE
    if ($Result -ge 8) { throw "Agent log copy failed: $Dest\Agent-copy.log" }
    $diag=Join-Path $AgentLogs 'diag'
    if(Test-Path -LiteralPath $diag -PathType Container){
        & robocopy.exe $diag "$Dest\AgentLogs\diag" 'ds_agent*.log' /COPY:DAT /R:1 /W:1 /XJ /NP "/LOG:$Dest\Agent-diag-copy.log"
        if($LASTEXITCODE -ge 8){throw "Diagnostic agent log copy failed: $Dest\Agent-diag-copy.log"}
    }
    $counts = foreach ($folder in $AgentLogs,$diag) {
        $copied = if ($folder -eq $diag) { "$Dest\AgentLogs\diag" } else { "$Dest\AgentLogs" }
        $matches = @(Get-ChildItem -LiteralPath $folder -File -Filter 'ds_agent*.log' -ErrorAction SilentlyContinue)
        $saved = @(Get-ChildItem -LiteralPath $copied -File -Filter 'ds_agent*.log' -ErrorAction SilentlyContinue)
        [pscustomobject]@{Source=$folder;Matched=$matches.Count;Copied=$saved.Count;NewestFileUtc=($saved | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty LastWriteTimeUtc)}
    }
    $counts | Export-Csv -LiteralPath "$Dest\Agent-log-sources.csv" -NoTypeInformation -Encoding UTF8
    if (!(($counts | Measure-Object -Property Copied -Sum).Sum)) {
        'No general ds_agent logs copied from the agent or its diag folder.' | Set-Content -LiteralPath "$Dest\Collection-errors.txt"
    }
    Get-Date -Format o | Out-File "$Dest\Snapshot-time.txt"
}

function Enable-PersistentAMTrace {
    param([string]$Case)
    $Ini = Join-Path $env:SystemRoot 'ds_agent.ini'
    $StateFolder = Join-Path $Case 'Cleanup\PersistentAMTrace'
    $StateFile = Join-Path $StateFolder 'State.json'
    $Backup = Join-Path $StateFolder 'ds_agent.ini.original'
    
    $Principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as administrator.'
    }
    $Service = Get-Service -Name 'ds_agent' -ErrorAction Stop
    if ($Service.Status -ne 'Running') { throw 'Resolve the stopped agent service before this test.' }
    $Task = Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($Task -and $Task.State -eq 'Running') { throw 'Wait for the DSA metrics task to finish.' }
    if (Test-Path -LiteralPath $StateFolder) {
        throw "State folder already exists: $StateFolder. Do not overwrite the original backup; use C3 to restore first and use a new case for another setup."
    }
    
    # A second case must not back up another test's temporary Trace configuration.
    $CaseRoot = Split-Path -Path $Case -Parent
    if (Test-Path -LiteralPath $CaseRoot) {
        $OtherStates = @(Get-ChildItem -LiteralPath $CaseRoot -Filter 'State.json' -Recurse -File |
            Where-Object { $_.Directory.Name -eq 'PersistentAMTrace' })
        foreach ($OtherState in $OtherStates) {
            $Previous = Get-Content -LiteralPath $OtherState.FullName -Raw | ConvertFrom-Json
            if ($Previous.Restored -ne $true) {
                throw "Restore the earlier logging change before setup: $($OtherState.FullName)"
            }
        }
    }
    
    $BeforeTrace = Get-AMTraceSetting -Path $Ini
    if ($BeforeTrace.AMDebugRequested) { Write-Warning 'AM debug is already requested by the original INI. Exact restoration will retain it; obtain a normal-logging baseline separately.' }
    $Existed = Test-Path -LiteralPath $Ini
    $OriginalHash = $null
    $Text = ''
    $Encoding = [Text.Encoding]::Default
    [byte[]]$Bom = @()
    if ($Existed) {
        $Item = Get-Item -LiteralPath $Ini -Force
        if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The INI path is not a regular file. Review it manually.'
        }
        [byte[]]$Bytes = [IO.File]::ReadAllBytes($Ini)
        $OriginalHash = (Get-FileHash -LiteralPath $Ini -Algorithm SHA256).Hash
        $Skip = 0
        if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
            $Encoding = [Text.Encoding]::GetEncoding(12000); $Skip = 4
        } elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255) {
            $Encoding = [Text.Encoding]::GetEncoding(12001); $Skip = 4
        } elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
            $Encoding = [Text.Encoding]::UTF8; $Skip = 3
        } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
            $Encoding = [Text.Encoding]::Unicode; $Skip = 2
        } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
            $Encoding = [Text.Encoding]::BigEndianUnicode; $Skip = 2
        }
        if ($Skip -gt 0) { [byte[]]$Bom = $Bytes[0..($Skip - 1)] }
        $Text = $Encoding.GetString($Bytes, $Skip, $Bytes.Length - $Skip)
        # Refuse an encoding conversion that would alter the original bytes.
        [byte[]]$RoundTrip = @($Bom) + @($Encoding.GetBytes($Text))
        if ([Convert]::ToBase64String($Bytes) -ne [Convert]::ToBase64String($RoundTrip)) {
            throw 'INI encoding could not be preserved. Review manually; no changes made.'
        }
    }
    
    if ($Text -match '\x00|(?m)^\s*\[') {
        throw 'Sectioned or unsupported INI format. Review manually; no changes made.'
    }
    $Pattern = [regex]::new('(?im)^[ \t]*Trace[ \t]*=[^\r\n]*')
    $TraceLines = $Pattern.Matches($Text)
    if ($TraceLines.Count -gt 1) { throw 'Multiple Trace settings found. Review manually; no changes made.' }
    $NewLine = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n")) { "`n" } else { "`r`n" }
    
    if ($TraceLines.Count -eq 1) {
        $Line = $TraceLines[0]
        $Value = ($Line.Value -split '=', 2)[1].Trim()
        if ($Value -and $Value -notmatch '^[A-Za-z0-9_.*+\-]+([ \t]*,[ \t]*[A-Za-z0-9_.*+\-]+)*$') {
            throw 'Trace uses comments or complex syntax. Review manually; no changes made.'
        }
        $Tokens = @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($Tokens -notcontains '*') {
            foreach ($Token in @('AM', 'AMSP', 'dsp.am.*')) {
                if ($Tokens -notcontains $Token) { $Tokens += $Token }
            }
            $Prefix = $Line.Value.Substring(0, $Line.Value.IndexOf('=') + 1)
            $Replacement = $Prefix + ($Tokens -join ',')
            $Text = $Text.Substring(0, $Line.Index) + $Replacement + $Text.Substring($Line.Index + $Line.Length)
        }
    } else {
        if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += $NewLine }
        $Text += 'Trace=AM,AMSP,dsp.am.*' + $NewLine
    }
    [byte[]]$UpdatedBytes = @($Bom) + @($Encoding.GetBytes($Text))
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { $AppliedHash = ([BitConverter]::ToString($Hasher.ComputeHash($UpdatedBytes))).Replace('-', '') }
    finally { $Hasher.Dispose() }
    
    New-Item -ItemType Directory -Path $StateFolder -ErrorAction Stop | Out-Null
    if ($Existed) {
        Copy-Item -LiteralPath $Ini -Destination $Backup -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash -ne $OriginalHash) {
            throw 'Backup verification failed. INI not changed.'
        }
        if ((Get-FileHash -LiteralPath $Ini -Algorithm SHA256).Hash -ne $OriginalHash) {
            throw 'INI changed during preparation. INI not changed by this script; review before retrying.'
        }
    } elseif (Test-Path -LiteralPath $Ini) {
        throw 'INI appeared during preparation. Review before retrying.'
    }
    $State = [pscustomobject]@{
        IniPath = $Ini
        OriginallyExisted = [bool]$Existed
        OriginalAMDebugRequested = $BeforeTrace.AMDebugRequested
        OriginalHash = $OriginalHash
        AppliedHash = $AppliedHash
        PreparedAt = (Get-Date -Format o)
        Restored = $false
    }
    # Save recovery information before writing the changed configuration.
    $State | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    @(Get-OriginalDebugValues) | ConvertTo-Json | Set-Content -LiteralPath "$StateFolder\Registry-before.json" -Encoding UTF8
    [IO.File]::WriteAllBytes($Ini, $UpdatedBytes)
    if ((Get-FileHash -LiteralPath $Ini -Algorithm SHA256).Hash -ne $AppliedHash) {
        throw 'Changed INI verification failed. Preserve the backup and use C3 to review recovery.'
    }
    Copy-Item -LiteralPath $Ini -Destination (Join-Path $StateFolder 'ds_agent.ini.collection')
    Restart-Service -Name 'ds_agent' -ErrorAction Stop
    Get-Service -Name 'ds_agent' | Format-List Name, Status
    Get-Date -Format o | Out-File (Join-Path $StateFolder 'Enabled-at.txt')
    Write-Host "Original-file state saved in: $StateFolder"
    Write-Host 'Verify fresh AMSP debug entries, then continue with the planned recorded reboot.'
}

function Restore-PersistentAMTrace {
    param([string]$Case)
    if ((Test-DiagnosticMonitorActive $Case) -or (Test-DiagnosticPending $Case)) { throw 'Agent diagnostic publication is pending. Resume Diagnostics before restoring the service.' }
    $StateFolder = Join-Path $Case 'Cleanup\PersistentAMTrace'
    $StateFile = Join-Path $StateFolder 'State.json'
    $Backup = Join-Path $StateFolder 'ds_agent.ini.original'
    $Ini = Join-Path $env:SystemRoot 'ds_agent.ini'
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw 'Original INI state is missing. Do not delete or overwrite ds_agent.ini by guessing.'
    }
    $State = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if ($State.IniPath -ne $Ini) { throw 'Saved INI path does not match this computer.' }
    if ($State.Restored -eq $true) {
        $Expected = if ($State.OriginallyExisted) { $State.OriginalHash } else { $null }
        $Actual = if (Test-Path -LiteralPath $Ini -PathType Leaf) { (Get-FileHash -LiteralPath $Ini).Hash } else { $null }
        if ($Actual -ne $Expected) { throw 'INI changed after restoration. Preserve saved state and review before cleanup.' }
        Confirm-DebugRestoration $Case
        Save-RestoredTraceAssessment -Case $Case -Ini $Ini
        Write-Host 'Original INI already restored and verified.'; return
    }
    $CurrentHash = if (Test-Path -LiteralPath $Ini -PathType Leaf) {
        (Get-FileHash -LiteralPath $Ini -Algorithm SHA256).Hash
    } else { $null }
    $AlreadyOriginal = if ($State.OriginallyExisted) {
        $CurrentHash -and $CurrentHash -eq $State.OriginalHash
    } else { -not (Test-Path -LiteralPath $Ini) }
    if (-not $AlreadyOriginal -and $CurrentHash -ne $State.AppliedHash) {
        throw 'INI differs from the test configuration. Preserve both versions and review before restoration.'
    }
    if ($State.OriginallyExisted) {
        if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) { throw 'Original INI backup missing.' }
        if ((Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash -ne $State.OriginalHash) {
            throw 'Original INI backup hash does not match. Stop for review.'
        }
        if (-not $AlreadyOriginal) { Copy-Item -LiteralPath $Backup -Destination $Ini -Force }
        if ((Get-FileHash -LiteralPath $Ini -Algorithm SHA256).Hash -ne $State.OriginalHash) {
            throw 'Original INI restoration verification failed.'
        }
    } elseif (-not $AlreadyOriginal) {
        Remove-Item -LiteralPath $Ini -Force
    }
    Restart-Service -Name 'ds_agent' -ErrorAction Stop
    Confirm-DebugRestoration $Case
    $State.Restored = $true
    $State | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue (Get-Date -Format o) -Force
    $State | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Get-Service -Name 'ds_agent' | Format-List Name, Status
    Save-RestoredTraceAssessment -Case $Case -Ini $Ini
    Write-Host 'Original INI state restored. Restore the recorded self-protection settings next.'
}



function Get-WprPath { (Get-Command wpr.exe -ErrorAction Stop).Source }
function Read-CollectionState {
    param([string]$Pass = 'PassA', [switch]$RequireReboot)
    $script:StatePath = Join-Path $Case ("Cleanup\Phase{0}-state.json" -f $Pass.Substring(4))
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw "Collection state missing: $StatePath. Do not rerun Prepare over an existing collection." }
    $script:State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $script:AmspDebug = $State.AmspDebug
    if ($State.ComputerName -and $State.ComputerName -ne $env:COMPUTERNAME) { throw 'Case belongs to another computer.' }
    if ($RequireReboot -and $State.Scenario -ne 'SignOutSignIn') {
        $Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        if ($Boot -le (Parse-StateDateTime $State.PreparedBoot).ToUniversalTime()) { throw 'The prepared pass has not been rebooted yet.' }
        if ($Pass -eq 'PassB') { Assert-PassBBoot $Boot }
    }
}
function Assert-CollectorsStopped {
    $Task = Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($Task -and $Task.State -in @('Running','Queued')) { throw 'DSA metrics task is still running or queued. Run Finish first.' }
    $Tools = @(Get-Process | Where-Object { $_.ProcessName -match '^(DSASupportTool.*|procmon.*|wprui|xperf)$' })
    if ($Tools.Count) { throw 'Close diagnostic GUIs/collectors before diagnostics or packaging.' }
    $Record = Join-Path $Case 'Trend\FinalDiagnostics\Last-diagnostic-status.json'
    if (Test-Path -LiteralPath $Record) {
        $Last = Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json
        if ($Last.Status -in @('Running','TimedOut')) {
            $Controller = Get-Process -Id $Last.ProcessId -ErrorAction SilentlyContinue
            if ($Controller -and [math]::Abs(($Controller.StartTime.ToUniversalTime() - [datetime]::Parse($Last.ProcessStartedAt).ToUniversalTime()).TotalSeconds) -lt 2) {
                throw "Prior diagnostic controller is still running (PID $($Last.ProcessId)). Wait for it before another diagnostic or package."
            }
        }
    }
}
function Show-Status {
    Write-Host "Case: $Case"
    Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object TaskName, State | Format-Table
    Get-ScheduledTaskInfo -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue | Format-List LastRunTime, LastTaskResult
    foreach ($Relative in @('Cleanup\PhaseA-state.json','Cleanup\PhaseB-state.json','Cleanup\PersistentAMTrace\State.json','Trend\FinalDiagnostics\Last-diagnostic-status.json')) {
        $File = Join-Path $Case $Relative
        if (Test-Path -LiteralPath $File) { Write-Host "`n$Relative"; Get-Content -LiteralPath $File | Out-Host }
    }
    $WprCommand = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if ($WprCommand) { & $WprCommand.Source -status }
    $record=Join-Path $Case 'Trend\FinalDiagnostics\Last-diagnostic-status.json'
    if (Test-Path -LiteralPath $record) {
        $d=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        if ($d.RequestFolder -match '^CLI-[0-9-]+$') {
            $log=Join-Path (Split-Path -Parent $record) "$($d.RequestFolder)\Publication-progress.jsonl"
            if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log -Tail 1 | Out-Host}
            if ($d.Status -eq 'AwaitingArchive' -and $d.ExpectedPath) {
                $named=Assert-LocalEvidencePath $d.ExpectedPath
                Get-Item -LiteralPath $named,([IO.Path]::ChangeExtension($named,'.tmp')) -ErrorAction SilentlyContinue |
                    Select-Object Name,Length,LastWriteTimeUtc | Format-Table
            }
        }
    }
    foreach ($Path in @((Join-Path $Case 'WPR\Trace-quality.json'),(Join-Path $Case 'Evidence-assessment.json'))) { if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path | Out-Host } }
    Write-Host 'Task exit 0 and file presence do not establish valid metrics or complete boot coverage.'
}

function Test-DiagnosticPending {
    param([string]$CasePath)
    $path=Join-Path $CasePath 'Trend\FinalDiagnostics\Last-diagnostic-status.json'
    if (!(Test-Path -LiteralPath $path)) { return $false }
    $rec=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $rec.Status -in 'Submitting','Running','TimedOut','AwaitingArchive','UnconfirmedRequest'
}

function Test-DiagnosticMonitorActive {
    param([string]$CasePath)
    $path=Join-Path $CasePath 'Trend\FinalDiagnostics\Request.lock'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
    try {$check=[IO.File]::Open($path,'Open','Read','None');$check.Dispose();return $false}
    catch [IO.IOException]{return $true}
}

function Save-DiagnosticRecord {
    param($Result,[string]$Destination,[string]$RecordPath)
    $json=$Result | ConvertTo-Json -Depth 6
    foreach ($path in @("$Destination\Diagnostic-status.json",$RecordPath)) {
        $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.partial'
        [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,($temp+'.previous')); [IO.File]::Delete($temp+'.previous') }
        else { [IO.File]::Move($temp,$path) }
    }
}

function Receive-DiagnosticArchive {
    param($Result,[string]$Destination,[string]$RecordPath)
    $response=(Get-Content -LiteralPath "$Destination\dsa_control-output.txt" -Raw) + "`n" + (Get-Content -LiteralPath "$Destination\dsa_control-error.txt" -Raw)
    if($response -match '(?i)HTTP Status:\s*([45]\d\d)'){ $Result.Status='Failed'; throw "Agent diagnostic HTTP failure: $($Matches[1])." }
    $reported=Get-DiagnosticResponsePath $response
    if(!$reported){$Result.Status='UnconfirmedRequest';throw 'No exact archive name in the service response. Preserve the output and verify completion before restarting the service.'}
    $Result.ExpectedPath=$reported
    $reported | Set-Content -LiteralPath "$Destination\Reported-diagnostic-path.txt" -Encoding UTF8
    $Result.Status='AwaitingArchive'
    Save-DiagnosticRecord $Result $Destination $RecordPath
    $before=@{}
    $beforeList=Get-Content -LiteralPath "$Destination\Before.json" -Raw | ConvertFrom-Json
    foreach($item in $beforeList){
        if ($item.Path) {$before[$item.Path]=$item.Stamp}
    }
    $since=(Parse-StateDateTime $Result.RequestedAt).ToUniversalTime()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $idleUntil=[datetime]::UtcNow.AddSeconds($ArtifactWaitSeconds)
    $hardLimit=[datetime]::UtcNow.AddMinutes($DiagnosticTimeoutMinutes)
    $nextUpdate=[datetime]::MinValue
    $previous=$null
    $tmpPath=[IO.Path]::ChangeExtension($reported,'.tmp')
    $lastError='The named ZIP has not appeared.'
    do {
        $now=[datetime]::UtcNow
        $f=Get-Item -LiteralPath $reported -ErrorAction SilentlyContinue
        $tmpFile=Get-Item -LiteralPath $tmpPath -ErrorAction SilentlyContinue
        $phase=if ($f) {'Checking final ZIP'} elseif ($tmpFile) {'Writing temporary file'} else {'Waiting for agent'}
        $current=if ($f) {$f} else {$tmpFile}
        $signature=if ($current) {"$($current.Name)/$($current.Length)/$($current.LastWriteTimeUtc.Ticks)"} else {''}
        if ($signature -and $signature -ne $previous) { $idleUntil=$now.AddSeconds($ArtifactWaitSeconds) }
        $previous=$signature
        if ($now -ge $nextUpdate) {
            $progress=[pscustomobject]@{AtUtc=$now.ToString('o');Expected=$reported;Phase=$phase;Bytes=$(if ($current) {$current.Length} else {0});ElapsedSeconds=[int]$watch.Elapsed.TotalSeconds}
            $progress | ConvertTo-Json -Compress | Add-Content -LiteralPath "$Destination\Publication-progress.jsonl" -Encoding UTF8
            Write-Host ("Diagnostic {0}: {1}, {2:N1} MiB, {3}s elapsed" -f ([IO.Path]::GetFileName($reported)),$phase,($progress.Bytes/1MB),$progress.ElapsedSeconds)
            $nextUpdate=$now.AddSeconds(15)
        }
        if($f -and $f.Length -gt 0) {
            $stamp="$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
            if($f.LastWriteTimeUtc -lt $since -or $before[$reported] -eq $stamp){$lastError='Named ZIP is stale for this request.'}
            else {
                try {
                    Start-Sleep -Milliseconds 500
                    $again=Get-Item -LiteralPath $reported -ErrorAction Stop
                    if ("$($again.Length):$($again.LastWriteTimeUtc.Ticks)" -ne $stamp) {throw 'Archive is growing.'}
                    $target=Join-Path $Destination $f.Name
                    $temp="$target.partial"
                    $source=[IO.File]::Open($reported,'Open','Read','Read')
                    try {
                        $out=[IO.File]::Open($temp,'Create','Write','None')
                        try {$source.CopyTo($out)}finally{$out.Dispose()}
                        $source.Position=0;$hash=[Security.Cryptography.SHA256]::Create()
                        try{$sha=[BitConverter]::ToString($hash.ComputeHash($source)).Replace('-','')}finally{$hash.Dispose()}
                    } finally {$source.Dispose()}
                    if((Get-FileHash -LiteralPath $temp).Hash -ne $sha){throw 'Diagnostic ZIP copy hash mismatch.'}
                    $z=[IO.Compression.ZipFile]::OpenRead($temp)
                    try {
                        $members=@($z.Entries|Where-Object Name)
                        if(!$members.Count){throw 'Empty diagnostic ZIP.'}
                        foreach($m in $members){$stream=$m.Open();try{$stream.CopyTo([IO.Stream]::Null)}finally{$stream.Dispose()}}
                        $Result.ExtractedDebugFiles=@()
                        $index=0
                        foreach($m in $members){
                            $name=$m.FullName.Replace('\','/')
                            if($name -match '(^|/)debug\.xml$'){$Result.DebugXmlPresent=$true;$leaf='debug.xml'}
                            elseif($name -match '(^|/)AMSP/AmTopNScan\.txt$'){$Result.TopNPresent=$true;$leaf='AmTopNScan.txt'}
                            else{continue}
                            $index++;$extract=Join-Path $Destination ("{0}-{1}-{2}" -f $f.BaseName,$index,$leaf)
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($m,$extract,$true)
                            $Result.ExtractedDebugFiles+= $extract
                        }
                        $members | Select-Object FullName,Length | Export-Csv -LiteralPath "$target.inventory.csv" -NoTypeInformation
                    }finally{$z.Dispose()}
                    if(Test-Path -LiteralPath $target){
                        if((Get-FileHash -LiteralPath $target).Hash -ne $sha){throw 'Existing case copy differs; preserving both versions.'}
                        Remove-Item -LiteralPath $temp
                    }else{[IO.File]::Move($temp,$target)}
                    "$sha  $($f.Name)" | Set-Content -LiteralPath "$target.sha256.txt" -Encoding ASCII
                    $Result.Source=$reported;$Result.CopiedZip=$target;$Result.RelativeCopiedZip=$target.Substring($Case.Length+1)
                    [pscustomobject]@{AtUtc=[datetime]::UtcNow.ToString('o');Expected=$reported;Phase='Verified';Bytes=$again.Length;ElapsedSeconds=[int]$watch.Elapsed.TotalSeconds;SHA256=$sha} | ConvertTo-Json -Compress | Add-Content -LiteralPath "$Destination\Publication-progress.jsonl" -Encoding UTF8
                    Write-Host ("Diagnostic {0} verified and copied ({1:N1} MiB, {2}s observed)." -f $f.Name,($again.Length/1MB),[int]$watch.Elapsed.TotalSeconds)
                    $Result.SHA256=$sha;$Result.Status='Succeeded';$Result.Message='Exact requested archive verified, fully read and copied.'
                    return
                } catch {$lastError=$_.Exception.Message}
                finally {if ($temp -and [IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
            }
        }
        if([datetime]::UtcNow -ge $idleUntil -or [datetime]::UtcNow -ge $hardLimit){break}
        Start-Sleep -Seconds 3
    }while($true)
    $lastError | Add-Content -LiteralPath "$Destination\ZIP-lookup-errors.txt"
    throw "The requested diagnostic is pending. $lastError Resume with -Stage Diagnostics."
}

function Request-AgentDiagnostics {
    if (!(Test-Path -LiteralPath $Case -PathType Container)) {throw "Case missing: $Case"}
    $dir=Assert-LocalEvidencePath (Join-Path $Case 'Trend\FinalDiagnostics')
    $null=New-Item -Path $dir -ItemType Directory -Force
    $file=Join-Path $dir 'Request.lock'
    try {$lock=[IO.File]::Open($file,'OpenOrCreate','ReadWrite','None')}
    catch [IO.IOException] {throw 'Another diagnostic monitor is active for this case. Use Status to see its progress.'}
    try { Invoke-DiagnosticRequest } finally { $lock.Dispose() }
}

function Invoke-DiagnosticRequest {
    Assert-CollectorsStopped
    if (-not (Test-Path -LiteralPath $Case -PathType Container)) { throw 'Case does not exist. Do not generate diagnostics into a guessed case.' }
    $Root = Join-Path $Case 'Trend\FinalDiagnostics'
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $RecordPath = Join-Path $Root 'Last-diagnostic-status.json'
    if (Test-DiagnosticPending $Case) {
        $Result = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
        if ($Result.RequestFolder -notmatch '^CLI-[0-9-]+$') { throw 'Legacy or invalid pending diagnostic. Preserve its files and verify the existing request.' }
        $Destination = Assert-LocalEvidencePath (Join-Path $Root $Result.RequestFolder)
        try { Receive-DiagnosticArchive $Result $Destination $RecordPath }
        catch { $Result.Message=$_.Exception.Message; Write-Warning $Result.Message }
        finally { Save-DiagnosticRecord $Result $Destination $RecordPath }
        return $Result
    }
    $Destination = Join-Path $Root ('CLI-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    $Result = [pscustomobject]@{
        Status='Starting'; RequestedAt=[datetime]::UtcNow.ToString('o'); ProcessId=$null; RequestFolder=(Split-Path $Destination -Leaf)
        ProcessStartedAt=$null; ExitCode=$null; Source=$null; ExpectedPath=$null; CopiedZip=$null
        SHA256=$null; RelativeCopiedZip=$null; DebugXmlPresent=$false; TopNPresent=$false; ExtractedDebugFiles=@(); Message=$null
    }
    $Process = $null
    try {
        $Control = $null
        foreach ($Name in @('dsa_control.cmd','dsa_control.exe')) {
            $Candidate = Join-Path $AgentFolder $Name
            if (Test-Path -LiteralPath $Candidate -PathType Leaf) { $Control = $Candidate; break }
        }
        if (-not $Control) { throw "dsa_control.cmd/exe not found in $AgentFolder. Use -AgentFolder with the verified installed location." }
        $Before = @{}
        $RequestedUtc = (Get-Date).ToUniversalTime()
        try {
            if (Test-Path -LiteralPath $DiagnosticFolder -PathType Container) {
                foreach ($File in (Get-ChildItem -LiteralPath $DiagnosticFolder -Filter '*.zip' -Recurse -File -Force)) {
                    $Before[$File.FullName] = "$($File.Length):$($File.LastWriteTimeUtc.Ticks)"
                }
            }
        } catch { $_ | Out-String | Add-Content -LiteralPath "$Destination\ZIP-lookup-errors.txt" }
        ConvertTo-Json -InputObject @($Before.GetEnumerator()|ForEach-Object {[pscustomobject]@{Path=$_.Key;Stamp=$_.Value}}) | Set-Content -LiteralPath "$Destination\Before.json" -Encoding UTF8
        "Command: $Control -d`r`nVerified diagnostic search folder: $DiagnosticFolder" | Out-File "$Destination\Command.txt"
        $Result.Status='Submitting'
        Save-DiagnosticRecord $Result $Destination $RecordPath
        if ([IO.Path]::GetExtension($Control) -eq '.cmd') {
            $Arguments = '/d /s /c ""{0}" -d"' -f $Control
            $Process = Start-Process -FilePath $env:ComSpec -ArgumentList $Arguments -WorkingDirectory $AgentFolder -NoNewWindow -PassThru -RedirectStandardOutput "$Destination\dsa_control-output.txt" -RedirectStandardError "$Destination\dsa_control-error.txt"
        } else {
            $Process = Start-Process -FilePath $Control -ArgumentList '-d' -WorkingDirectory $AgentFolder -NoNewWindow -PassThru -RedirectStandardOutput "$Destination\dsa_control-output.txt" -RedirectStandardError "$Destination\dsa_control-error.txt"
        }
        $null = $Process.Handle
        $Result.Status='Running'; $Result.ProcessId=$Process.Id
        $Result.ProcessStartedAt=$Process.StartTime.ToUniversalTime().ToString('o')
        Save-DiagnosticRecord $Result $Destination $RecordPath
        $Deadline = (Get-Date).AddMinutes($DiagnosticTimeoutMinutes)
        $NextMessage = Get-Date
        while (-not $Process.WaitForExit(1000)) {
            if ((Get-Date) -ge $Deadline) {
                $Result.Status='TimedOut'
                throw "dsa_control did not exit within $DiagnosticTimeoutMinutes minutes (PID $($Process.Id)). Its process was not forcibly killed. Check status before retrying or packaging."
            }
            if ((Get-Date) -ge $NextMessage) {
                Write-Host 'Agent diagnostic is being generated; waiting...'
                $NextMessage = (Get-Date).AddSeconds(30)
            }
        }
        $Process.WaitForExit()
        $Result.ExitCode=$Process.ExitCode
        Get-Content "$Destination\dsa_control-output.txt", "$Destination\dsa_control-error.txt" | Out-Host
        if ($Process.ExitCode -ne 0) { throw "dsa_control returned $($Process.ExitCode). Review captured output and self-protection." }
        Receive-DiagnosticArchive $Result $Destination $RecordPath
    } catch {
        if ($Result.Status -notin 'TimedOut','AwaitingArchive','UnconfirmedRequest') { $Result.Status='Failed' }
        $Result.Message=$_.Exception.Message
        $Result.Message | Out-File "$Destination\Diagnostic-error.txt"
        Write-Warning "Agent diagnostic not verified: $($Result.Message). Available raw debug evidence is retained."
    } finally {
        Save-DiagnosticRecord $Result $Destination $RecordPath
        if ($Process) { $Process.Dispose() }
    }
    return $Result
}

function New-CaseArchive {
    param([switch]$ResumePendingDiagnostic)
    if (Test-DiagnosticMonitorActive $Case) {throw 'The native diagnostic monitor is still writing case evidence. Wait before packaging.'}
    Assert-CollectorsStopped
    if (-not (Test-Path -LiteralPath $Case -PathType Container)) { throw "Case missing: $Case" }
    if (Test-Path -LiteralPath (Join-Path $Case 'Cleanup\PhaseA-state.json')) {
        try { Read-CollectionState -Pass 'PassA' } catch { Write-Warning 'Collection state cannot be loaded; packaging will preserve evidence and flag unknown coverage.' }
    }
    $SavedDebug = @(Get-ChildItem -LiteralPath "$Case\Trend\AMDebug" -Recurse -File -ErrorAction SilentlyContinue)
    if (-not $SavedDebug.Count -and $AmspDebug -and (Test-Path -LiteralPath $AmspDebug -PathType Container)) {
        try { Save-AMDebug -Label 'Package-RawDebug' }
        catch {
            Write-Warning "Additional raw debug snapshot failed: $_. Existing case files will still be packaged."
            $_ | Out-String | Out-File "$Case\Package-debug-copy-error.txt"
        }
    }
    if (!$SkipDiagnostics -and (!(Test-Path -LiteralPath "$Case\Trend\FinalDiagnostics\Last-diagnostic-status.json") -or ($ResumePendingDiagnostic -and (Test-DiagnosticPending $Case)))) {
        Request-AgentDiagnostics | Out-Null
        Assert-CollectorsStopped
    }
    $CasePath = (Resolve-Path -LiteralPath $Case).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $OutputFolder = [IO.Path]::GetFullPath($ArchiveDirectory)
    if ($OutputFolder -match '^[A-Za-z]:\\') { $null = Assert-LocalEvidencePath -Path $OutputFolder }
    $CasePrefix = $CasePath + [IO.Path]::DirectorySeparatorChar
    if ($OutputFolder.Equals($CasePath,[StringComparison]::OrdinalIgnoreCase) -or $OutputFolder.StartsWith($CasePrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'ArchiveDirectory must be outside the case folder to prevent recursive packaging.'
    }
    $null = @(Get-RegularEvidenceFiles -Root $CasePath)
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $Archive = Join-Path $OutputFolder ("AllEvidence-{0}-{1}.zip" -f (Split-Path $Case -Leaf),$Timestamp)
    $Partial = $Archive + '.partial'
    $Summary = @(
        "Packaging time: $(Get-Date -Format o)"
        "Source: $CasePath"
        'Entire case included; archive verification does not prove complete collection.'
        'Confirm actual metric/debug timestamps, scan evidence, copy errors and WPR event loss.'
        'Complete operator timing notes and record restoration of self-protection in the console.'
    )
    $Assessment = Get-CaseEvidenceAssessment
    $Missing = @($Assessment.EvidenceGaps)
    $Assessment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$Case\Evidence-assessment.json" -Encoding UTF8
    foreach ($Gap in $Missing) { Write-Warning "Evidence gap: $Gap" }
    $Summary += @('Evidence gaps:') + $Missing
    $Summary | Set-Content -LiteralPath "$Case\Packaging-summary-$Timestamp.txt" -Encoding UTF8
    $Files = @(Get-RegularEvidenceFiles -Root $CasePath)
    $Bytes = ($Files | Measure-Object -Property Length -Sum).Sum
    try {
        $Drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($OutputFolder))
        if ($Drive.IsReady -and $Drive.AvailableFreeSpace -lt ($Bytes + 1GB)) { throw 'Insufficient destination space for a worst-case ZIP plus working margin.' }
    } catch [ArgumentException] { Write-Warning 'Destination free-space check unavailable; verify sufficient space manually.' }
    Write-Host "Packaging $($Files.Count) files. Compression and full SHA-256 verification can take several minutes."
    [IO.Compression.ZipFile]::CreateFromDirectory($CasePath,$Partial,[IO.Compression.CompressionLevel]::Optimal,$false)
    $Zip = [IO.Compression.ZipFile]::OpenRead($Partial)
    try {
        $Entries = @($Zip.Entries | Where-Object { $_.Name -ne '' })
        if ($Entries.Count -ne $Files.Count) { throw 'ZIP/source file counts differ. Do not upload the partial file.' }
        foreach ($File in $Files) {
            $Relative = $File.FullName.Substring($CasePath.Length + 1)
            $Entry = $Zip.GetEntry($Relative.Replace('\','/'))
            if (-not $Entry) { $Entry = $Zip.GetEntry($Relative) }
            if (-not $Entry -or $Entry.Length -ne $File.Length) { throw "Missing/size-mismatched ZIP entry: $Relative" }
            $Stream = $Entry.Open(); $Hasher = [Security.Cryptography.SHA256]::Create()
            try { $Hash = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-','') }
            finally { $Stream.Dispose(); $Hasher.Dispose() }
            if ($Hash -ne (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash) { throw "ZIP hash mismatch: $Relative" }
        }
        $After = @(Get-RegularEvidenceFiles -Root $CasePath)
        if ($After.Count -ne $Files.Count) { throw 'Case file count changed during packaging. Keep the partial file for troubleshooting; retry after collectors stop.' }
        $BeforeMap = @{}
        foreach ($File in $Files) { $BeforeMap[$File.FullName] = "$($File.Length):$($File.LastWriteTimeUtc.Ticks)" }
        foreach ($File in $After) {
            if (-not $BeforeMap.ContainsKey($File.FullName) -or $BeforeMap[$File.FullName] -ne "$($File.Length):$($File.LastWriteTimeUtc.Ticks)") { throw 'A case file changed during packaging. Retry after all writes stop.' }
        }
    } finally { $Zip.Dispose() }
    Move-Item -LiteralPath $Partial -Destination $Archive -ErrorAction Stop
    $Hash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    "$Hash  $([IO.Path]::GetFileName($Archive))" | Set-Content -LiteralPath "$Archive.sha256.txt" -Encoding ASCII
    $null=New-Item -Path "$Case\Cleanup" -ItemType Directory -Force
    [pscustomobject]@{Archive=$Archive;SHA256=$Hash;Computer=$env:COMPUTERNAME;CaseName=(Split-Path $Case -Leaf)} | ConvertTo-Json | Set-Content -LiteralPath "$Case\Cleanup\Handoff-receipt.json" -Encoding UTF8
    if ($Missing.Count) {
        Write-Warning "ARCHIVE INTEGRITY VERIFIED — EVIDENCE GAPS REMAIN ($($Missing.Count)). Inspect Evidence-assessment.json."
    } else {
        Write-Host "ARCHIVE INTEGRITY VERIFIED — REQUIRED ARTIFACTS VERIFIED ($($Files.Count) files). Root-cause/trace interpretation still requires review."
    }
    Write-Host "ZIP: $Archive"
    Write-Host "SHA256: $Archive.sha256.txt"
    Write-Host 'Transfer both before Cleanup. Cleanup deletes C:\SWP-Perf, including archives there.'
}

function Invoke-PrepareB {
    Read-CollectionState -Pass 'PassA'
    if (-not $State.Finished) { throw 'Finish Phase A before the optional Procmon repeat.' }
    if ($State.ConfigRestored -or (Test-Path -LiteralPath "$Case\Cleanup\Collector-closed.json")) { throw 'This case has already been cleaned up. Prepare a new case.' }
    if (!$State.ConfigAppliedHash -or (Get-FileHash -LiteralPath $ConfigPath).Hash -ne $State.ConfigAppliedHash) { throw 'The installed DSA metrics configuration differs from the prepared case.' }
    if (Test-DiagnosticPending $Case) { throw 'Resume the pending agent diagnostic before preparing Pass B.' }
    Assert-CollectorsStopped
    $script:Wpr = Get-WprPath
    $SessionOutput = & logman.exe query -ets 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $SessionOutput -match 'WPR_initiated') { throw 'Resolve active WPR/session-check errors before the Procmon pass.' }
    $BState = Join-Path $Case 'Cleanup\PhaseB-state.json'
    if (Test-Path -LiteralPath $BState) { throw 'Pass B already prepared. Preserve it; do not overwrite its state.' }
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($Config.Metrics.collectMetrics -ne 1 -or $Config.Metrics.MetricsIntervalInSecond -ne 5 -or $Config.Metrics.MetricsDurationInSecond -ne 900 -or $Config.Tool.PressKeyToEnd -ne 0) { throw 'Metrics JSON no longer matches the five-second/900-second plan.' }
    $phaseA = $State
    $task = Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction Stop
    if (!(Test-MetricsTaskAction $task $phaseA $Case PassA) -or $task.State -ne 'Disabled') { throw 'Expected the disabled, case-owned Pass A metrics task.' }
    $TraceFolder = Join-Path $Case 'Cleanup\PersistentAMTrace'
    $notesPath = Get-TimingNotesPath $Case 'PassB'
    if (Test-Path -LiteralPath $notesPath) { throw 'Pass B already has timing notes. Review the case before preparing.' }
    if (Test-Path -LiteralPath $TraceFolder) {
        $Old = Get-Content "$TraceFolder\State.json" -Raw | ConvertFrom-Json
        if ($Old.Restored -ne $true) { throw 'Restore Phase A INI before preparing Pass B.' }
        Move-Item -LiteralPath $TraceFolder -Destination ($TraceFolder + '-PhaseA-restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $script:StatePath = $BState
    $script:State = [pscustomobject]@{
        PreparedAt=(Get-Date -Format o)
        PreparedBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        AmspDebug=$AmspDebug; Finished=$false; PreparationComplete=$false; AffectedUser=$phaseA.AffectedUser; RunId=[guid]::NewGuid().ToString('N')
        ComputerName=$env:COMPUTERNAME; ConfigAppliedHash=(Get-FileHash -LiteralPath $ConfigPath).Hash; Scenario='Reboot' 
    }
    Save-State
    [pscustomobject]@{CredentialSubmittedAt='';DesktopReadyAt='';Applications=@([pscustomobject]@{Name='';LaunchAt='';ReadyAt='';Symptom=''})} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $notesPath -Encoding UTF8
    $EnableTime = (Get-Date).ToUniversalTime()
    Enable-PersistentAMTrace -Case $Case
    $DebugDeadline = (Get-Date).AddSeconds(60)
    do {
        $DebugLog = Get-Item -LiteralPath (Join-Path $AmspDebug 'Amsp_LocalDebugLog.log') -ErrorAction SilentlyContinue
        if ($DebugLog -and $DebugLog.LastWriteTimeUtc -ge $EnableTime -and $DebugLog.Length -gt 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $DebugDeadline)
    if (-not $DebugLog -or $DebugLog.LastWriteTimeUtc -lt $EnableTime -or $DebugLog.Length -eq 0) { throw 'Pass B fresh AM debug output not verified. Resolve before reboot, or use RestoreTrace.' }
    @(Get-OriginalDebugValues) | ConvertTo-Json | Set-Content -LiteralPath "$Case\Cleanup\PersistentAMTrace\Registry-applied.json" -Encoding UTF8
    $task=Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction Stop
    if (!(Test-MetricsTaskAction $task $phaseA $Case PassA) -or $task.State -ne 'Disabled') { throw 'The Pass A task changed during preparation. Review recovery status.' }
    Unregister-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -Confirm:$false
    Register-MetricsTask PassB
    $State.PreparationComplete = $true
    Save-State
    Write-Host 'Pass B prepared for metrics and persistent AM logging. WPR is not armed.'
    Write-Host 'MANUAL: Open Procmon as administrator, stop live capture, enable Options > Enable Boot Logging (no thread profiling), and close it.'
    Write-Host 'Reboot, repeat login/apps, then open Procmon, save ALL PML segments under Case\Procmon, disable boot logging and exit.'
    Write-Host 'Run -Stage SaveDebug -Pass PassB promptly, then -Stage FinishB; run -Stage Package when ready.'
}

function Install-BundledTools {
    param([string]$KitRoot)
    $Bundles = @(
        @{ Zip='DSASupportTool-CMD.zip'; Folder='DSASupportTool'; Exe='DSASupportTool_CMD.exe'; Hash='17297B8ABB8193D7552C4A0023723ED0FEE29B93849B97C91DC69300E6520C42' }
        @{ Zip='DSASupportTool-GUI.zip'; Folder='DSASupportTool_GUI'; Exe='DSASupportTool_GUI.exe'; Hash='090E62DB8CD47663A314A0778083A18941DFE885715FA18A28D795508B9ED68F' }
    )
    if (Test-Path -LiteralPath $ToolRoot) {
        if ((Get-Item -LiteralPath $ToolRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Tool root is a link or junction: $ToolRoot"
        }
    }
    foreach ($Bundle in $Bundles) {
        $Archive = Join-Path $KitRoot ('Tools\' + $Bundle.Zip)
        if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "Bundled archive missing: $Archive. Extract the entire customer kit first." }
        if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $Bundle.Hash) {
            throw "Bundled archive hash mismatch: $Archive"
        }
        $Destination = Join-Path $ToolRoot $Bundle.Folder
        if (Test-Path -LiteralPath $Destination) {
            if ((Get-Item -LiteralPath $Destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Tool destination is a link or junction: $Destination"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $Destination $Bundle.Exe) -PathType Leaf)) {
                throw "Existing tool folder is incomplete: $Destination. Check the installation before retrying."
            }
            if ($Bundle.Folder -eq 'DSASupportTool' -and -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
                throw "Existing CMD configuration missing: $ConfigPath"
            }
            $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
            $Hasher = [Security.Cryptography.SHA256]::Create()
            try {
                $Stream = $Zip.GetEntry($Bundle.Exe).Open()
                try { $ExpectedHash = [BitConverter]::ToString($Hasher.ComputeHash($Stream)).Replace('-', '') }
                finally { $Stream.Dispose() }
            } finally { $Hasher.Dispose(); $Zip.Dispose() }
            $ActualHash = (Get-FileHash -LiteralPath (Join-Path $Destination $Bundle.Exe) -Algorithm SHA256).Hash
            if ($ActualHash -ne $ExpectedHash) {
                throw "A different tool version is installed in $Destination. Preserve existing collections and use the bundled version for this run."
            }
            Write-Host "Bundled build already present: $Destination"
            continue
        }
        New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
        $Staging = Join-Path $ToolRoot ('tool-install-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Staging)
            if (-not (Test-Path -LiteralPath (Join-Path $Staging $Bundle.Exe) -PathType Leaf)) {
                throw "Expected executable missing in $Archive"
            }
            if ($Bundle.Folder -eq 'DSASupportTool' -and -not (Test-Path -LiteralPath (Join-Path $Staging 'DSTool.json') -PathType Leaf)) {
                throw "CMD configuration missing in $Archive"
            }
            Rename-Item -LiteralPath $Staging -NewName $Bundle.Folder
        } finally {
            if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
        }
        Write-Host "Installed: $Destination"
    }
    foreach ($entry in 'SWP-Perf.ps1','SWP-SignIn.wprp','SWP-SignIn-128MiB.wprp') {
        $src=Join-Path $KitRoot $entry
        $target=Assert-LocalEvidencePath (Join-Path $ToolRoot $entry)
        if (!(Test-Path -LiteralPath $src)) { throw "Missing bundled file: $entry" }
        if ([IO.Path]::GetFullPath($src) -ne $target) { Copy-Item -LiteralPath $src -Destination $target -Force }
        if ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Installation checksum mismatch: $entry" }
    }

}

function Get-CollectionConfig {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $Changes = @{
        'Log Collection' = @{ enableAMSP=0; enableUMH=0; enableEYES=0; enableAEGIS=0; timerInSecondDebug=0; disableDebugAfterTimer=1; enableLogCollection=0 }
        'Process Monitor' = @{ enableProcMon=0; enableChangeAltitude=0; timerInSecondProcMon=10 }
        'WPR' = @{ enableWPR=0; timerInSecondWPR=10 }
        'Network Packet Capture' = @{ enableNetPCap=0; timerInSecondNetPCap=10 }
        'Network Check' = @{ enableNetCheck=0; URL2NetCheck='' }
        'Metrics' = @{ collectMetrics=1; MetricsIntervalInSecond=5; MetricsDurationInSecond=900 }
        'Tool' = @{ PressKeyToEnd=0; enableFeedback=0 }
    }
    foreach ($Section in $Changes.Keys) {
        if (-not $Config.PSObject.Properties[$Section]) { throw "Unexpected JSON: missing section $Section. Configuration has not been changed; review the vendor configuration." }
        foreach ($Key in $Changes[$Section].Keys) {
            $Config.$Section | Add-Member -NotePropertyName $Key -NotePropertyValue $Changes[$Section][$Key] -Force
        }
    }
    $CheckAndFix = $Config.PSObject.Properties['Check and Fix']
    if ($CheckAndFix) {
        foreach ($Action in $CheckAndFix.Value.PSObject.Properties) {
            foreach ($Flag in @('enableCheck','enableFix')) {
                if (-not $Action.Value.PSObject.Properties[$Flag]) {
                    throw "Unsupported Check and Fix action: $($Action.Name). Expected $Flag."
                }
                $Action.Value.$Flag = 0
            }
        }
    }
    # Require review of unrecognized top-level features before collection changes.
    foreach ($Property in $Config.PSObject.Properties) {
        if ($Property.Name -notin $Changes.Keys -and $Property.Name -ne 'Check and Fix') {
            throw "Additional JSON section '$($Property.Name)' requires review for check/fix actions. No JSON edits have been written."
        }
    }
    $Config
}

function Assert-WprAvailableForPrepare {
    $Sessions = & logman.exe query -ets 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect active tracing sessions.' }
    $WprSessions = @($Sessions | Where-Object { $_ -match 'WPR_initiated' })
    if (-not $WprSessions.Count) {
        $initial = & $Wpr -status 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $initial -notmatch '(?im)^\s*WPR is not recording\.?\s*$') { throw 'Could not verify that WPR is idle.' }
        return
    }

    $DiagTrackPattern = '^\s*WPR_initiated_DiagTrackMiniLogger_(?:OneTrace_User_Logger_\d{8}_\d+_EC_\d+|WPR System Collector)\s+Trace\s+Running\s*$'
    if (-not $AllowDiagTrackMiniLogger -or ($WprSessions | Where-Object { $_ -notmatch $DiagTrackPattern })) {
        throw ("A WPR session is already active. Coordinate with its owner before proceeding.`n" + ($WprSessions -join "`n"))
    }

    $Status = & $Wpr -status 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($Status -match '^\s*WPR is not recording\.?\s*$')) {
        throw ("Could not confirm WPR is idle. No recording was stopped.`n" + ($Status -join "`n"))
    }
    Write-Host 'WPR reports no active recording. Leaving the DiagTrackMiniLogger sessions running.'
}

function Initialize-CaseDirectory {
    param([string]$Path)
    $trusted=@('S-1-5-18','S-1-5-32-544')
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($id in $trusted){
        $sid=New-Object Security.Principal.SecurityIdentifier($id)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $null=Assert-LocalEvidencePath $Path
    if (!(Test-Path -LiteralPath $Path)) {$null=[IO.Directory]::CreateDirectory($Path,$acl)}
    $actual=Get-Acl -LiteralPath $Path
    $owner=$actual.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($owner -notin ($trusted+@($current))){throw "Case directory has an unexpected owner: $Path"}
    $write=[Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach($r in $actual.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if ($r.AccessControlType -eq 'Allow' -and ($r.FileSystemRights -band $write) -and $r.IdentityReference.Value -notin ($trusted+@($current))) {
            throw "Case directory permits other accounts to write. Use a protected case root: $Path"
        }
    }
}

function Get-CaseCatalog {
    param([string]$Root = 'C:\SWP-Perf')
    $null = Assert-LocalEvidencePath $Root
    if (!(Test-Path -LiteralPath $Root)) { return }
    if ($Root -eq 'C:\SWP-Perf') { Initialize-CaseDirectory $Root }
    foreach ($item in (Get-ChildItem -LiteralPath $Root -Directory -Force -Filter 'CASE-*')) {
        if ($item.Name -notmatch '^CASE-[a-z0-9_-]+$') { continue }
        $file = Assert-LocalEvidencePath (Join-Path $item.FullName 'Cleanup\PhaseA-state.json')
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
            foreach ($marker in 'Trend\DSTool-original.json','Events\Original-channel-state.csv','Cleanup\PersistentAMTrace') {
                if (Test-Path -LiteralPath (Join-Path $item.FullName $marker)) {
                    throw "Incomplete preparation in $($item.FullName). Review that case before continuing."
                }
            }
            continue
        }
        if ($Root -eq 'C:\SWP-Perf') { Initialize-CaseDirectory $item.FullName }
        $record = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ($record.ComputerName -ne $env:COMPUTERNAME -or $record.RunId -notmatch '^[a-f0-9]{32}$' -or
            ($record.CasePath -and $record.CasePath -ne $item.FullName)) {
            throw "Cannot confirm the saved case identity in $file. Use Status with the explicit case path."
        }
        $closed = $record.ConfigRestored -eq $true
        if ($closed -and $record.CasePath) {
            $stamp = Assert-LocalEvidencePath (Join-Path $item.FullName 'Cleanup\Collector-closed.json')
            $closed = (Test-Path -LiteralPath $stamp -PathType Leaf) -and
                (Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json).RunId -eq $record.RunId
        }
        [pscustomobject]@{ Path=$item.FullName; Phase=$record; Open=(!$closed -or (Test-DiagnosticPending $item.FullName)) }
    }
}

function Get-NextCasePath {
    param([string]$Root = 'C:\SWP-Perf', [string]$Handoff = 'C:\SWP-Handoff')
    [long]$highest = 0
    foreach ($dir in @($Root, $Handoff) | Select-Object -Unique) {
        $null = Assert-LocalEvidencePath $dir
        if (!(Test-Path -LiteralPath $dir)) { continue }
        foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force)) {
            $pattern = if ($dir -eq $Root) { '^CASE-([0-9]+)$' } else { '^AllEvidence-CASE-([0-9]+)-[0-9]{8}-[0-9]{6}-[0-9]{3}\.zip$' }
            if ($entry.Name -match $pattern) { $highest = [Math]::Max($highest, [long]::Parse($Matches[1])) }
        }
    }
    Join-Path $Root ('CASE-{0:D2}' -f [long]($highest + 1))
}

function Select-CollectionCase {
    param([string]$Action, [object[]]$Catalog, [string]$ExplicitCase)
    $open = @($Catalog | Where-Object Open)
    if ($Action -eq 'Prepare' -and $open.Count) {
        throw ('Previous preparation still requires attention: ' + ($open.Path -join ', ') + '. Use Status or finish restoration before preparing another case.')
    }
    if ($ExplicitCase) { return $ExplicitCase }
    if ($Action -eq 'Prepare') { return Get-NextCasePath }
    if ($open.Count -eq 1) { return $open[0].Path }
    if ($open.Count -gt 1) { throw ('Multiple active cases. Specify -Case and review: ' + ($open.Path -join ', ')) }
    if ($Catalog.Count -eq 1) { return $Catalog[0].Path }
    if ($Catalog.Count -gt 1) { throw 'Multiple retained cases. Specify -Case to select one.' }
    # Preserve the legacy default for standalone packaging and initial status.
    'C:\SWP-Perf\CASE-01'
}

function Test-CollectorDesktop {
    if ($env:SSH_CONNECTION -or $Host.Name -eq 'ServerRemoteHost' -or ![Environment]::UserInteractive -or
        [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { return $false }
    return !([Environment]::GetCommandLineArgs() -match '^[-/]noni(nteractive)?$')
}

function Install-CollectorShortcut {
    $programs = [Environment]::GetFolderPath('CommonPrograms')
    if (!$programs) { return }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'SWP Performance Collector.lnk'))
    $link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # On unconfigured Windows clients, use the same process-only policy as
    # the scheduled worker. Preserve any explicit policy, including AllSigned.
    $bootstrap = @'
$policy = ''; if (!(Get-ExecutionPolicy -List | Where-Object { $_.ExecutionPolicy -ne 'Undefined' })) { $policy = ' -ExecutionPolicy RemoteSigned' }; $argsForGui = '-NoProfile -STA' + $policy + ' -File ' + [char]34 + (Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1') + [char]34 + ' -Stage Gui'; Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $argsForGui
'@
    $link.Arguments = '-NoProfile -Command "' + $bootstrap.Trim() + '"'
    $link.WorkingDirectory = $ToolRoot
    $link.Description = 'Open the SWP performance collector as administrator'
    $link.Save()
}

function Get-CollectorView {
    param($Entry, [bool]$Installed, [datetime]$BootUtc)
    $prepareB = $false
    $activeB = $false
    $notesPass = 'PassA'
    $action = 'Prepare'
    $title = 'Ready for a new capture'
    $message = 'Choose the sign-in scenario and confirm the affected account. Record the baseline and verify agent self-protection with the policy owner before preparing.'
    if (!$Installed) {
        $action = 'InstallTools'; $title = 'Install the collection tools'
        $message = 'Install from the complete extracted customer kit. The same PowerShell commands remain available after installation.'
    } elseif ($Entry) {
        $phase = $Entry.Phase
        $dir = $Entry.Path
        $diagnostic = Test-DiagnosticPending $dir
        $receipt = Get-Item -LiteralPath (Join-Path $dir 'Cleanup\Handoff-receipt.json') -ErrorAction SilentlyContinue
        $traceFile = Join-Path $dir 'Cleanup\PersistentAMTrace\State.json'
        $restoreDue = $phase.Finished -and (Test-Path -LiteralPath $traceFile) -and
            (Get-Content -LiteralPath $traceFile -Raw | ConvertFrom-Json).Restored -ne $true
        if ($receipt) {
            foreach ($updated in 'Operator-notes.json','Procmon\Operator-notes.json','Test-notes.txt','Cleanup\PhaseB-state.json','Trend\FinalDiagnostics\Last-diagnostic-status.json',$traceFile) {
                $file = if ([IO.Path]::IsPathRooted($updated)) { $updated } else { Join-Path $dir $updated }
                $item = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
                if ($item -and $item.LastWriteTimeUtc -gt $receipt.LastWriteTimeUtc) { $receipt = $null; break }
            }
        }
        $b = Join-Path $dir 'Cleanup\PhaseB-state.json'
        $phaseB = if (Test-Path -LiteralPath $b) { Get-Content -LiteralPath $b -Raw | ConvertFrom-Json }
        if ($phaseB) { $notesPass = 'PassB' }
        $activeB = $Entry.Open -and $phaseB -and !$phaseB.Finished
        $prepareB = $Entry.Open -and $phase.Finished -and !$phaseB -and !$restoreDue -and !$diagnostic
        $quality = Join-Path $dir 'WPR\Trace-quality.json'
        if ($diagnostic) {
            $action = 'Diagnostics'; $title = 'Native diagnostic pending'; $message = 'Wait for the previous monitor to exit, then resume the named archive. Review the result before packaging.'
        } elseif ($activeB) {
            $title = 'Pass B - Procmon boot capture'
            if ($phaseB.PreparationComplete -eq $false) {
                $action = 'Review'; $message = 'Pass B preparation was interrupted. Review status and use Recover Pass B to preserve the available evidence.'
            } elseif ($BootUtc -le (Parse-StateDateTime $phaseB.PreparedBoot).ToUniversalTime()) {
                $action = 'Instructions'
                $message = 'Open Microsoft Process Monitor as administrator. Stop live capture, enable Options > Enable Boot Logging without thread profiling, then exit Procmon. Restart, sign in and repeat the agreed launches. Reopen this collector when the symptom ends.'
            } elseif (!$phaseB.EarlyDebugSavedUtc) {
                $action = 'SaveDebugB'
                $message = 'As soon as the agreed sign-in or app delay ends, save the early Trend logs. Then open Procmon to save the boot capture.'
            } else {
                $action = 'FinishB'
                $message = "Open Procmon as administrator. Save all PML segments to $dir\Procmon, turn off boot logging and exit Procmon. Enter the Pass B timing notes, then choose Finish B."
            }
        } elseif ($restoreDue) {
            $action = 'RestoreTrace'; $title = 'Restore trace settings'
            $message = 'The diagnostic has ended. Restore the saved agent trace settings and then package the case.'
        } elseif ($phase.Finished -and $receipt) {
            $action = 'OpenHandoff'; $title = 'Handoff available'
            $message = 'Open the ZIP location, transfer the ZIP and checksum, then restore settings and keep evidence.'
            $assessment = Join-Path $dir 'Evidence-assessment.json'
            if (Test-Path -LiteralPath $assessment) {
                $gaps = @((Get-Content -LiteralPath $assessment -Raw | ConvertFrom-Json).EvidenceGaps | Where-Object { $_ })
                if ($gaps.Count) { $message += " Evidence gaps reported: $($gaps.Count). Review Evidence-assessment.json." }
            }
        } elseif ($phase.Finished) {
            $action = 'Package'; $title = 'Ready to package'; $message = 'Review notes, confirm any deferred trace restoration, then package the case.'
        } elseif (!$Entry.Open) {
            $action = 'Status'; $title = 'Settings restored'; $message = 'Inspect this retained case or open the collector without a case to start a new capture.'
        } elseif ($phase.TraceSaved) {
            $action = 'FinishAndPackage'; $title = 'Trace saved'
            $message = 'Open timing notes and save the actual timestamps before finishing. Finish waits for DSA metrics and the native diagnostic.'
        } elseif (!$phase.Armed -or ((Test-Path -LiteralPath $quality) -and !(Get-Content -LiteralPath $quality -Raw | ConvertFrom-Json).Saved)) {
            $action = 'Review'; $title = 'Interrupted capture'; $message = 'Review Status before choosing recovery. Recover and package keeps available evidence and reports coverage gaps.'
        } elseif ($phase.Scenario -eq 'Reboot' -and $BootUtc -le (Parse-StateDateTime $phase.PreparedBoot).ToUniversalTime()) {
            $action = 'Instructions'; $title = 'Prepared for restart'
            $message = 'Close this window. Restart manually, sign in to the affected account, and launch the agreed apps normally. Reopen the collector at the agreed milestone.'
        } else {
            $action = 'StopTrace'; $title = 'Capture armed'
            $message = 'After the agreed sign-in and application milestone, stop the trace immediately. For a sign-out test, fully sign out and sign back in first.'
        }
    }
    if ($prepareB) { $message += ' If support requested a Procmon repeat, choose Prepare Pass B in the action list before cleanup.' }
    [pscustomobject]@{ Action=$action; Title=$title; Message=$message; CanPrepareB=$prepareB; ActiveB=$activeB; NotesPass=$notesPass }
}

function New-CollectorWindow {
    Add-Type -AssemblyName PresentationFramework
    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 Title="SWP Performance Collector" Width="780" Height="660" MinWidth="610" MinHeight="580"
 WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14" Background="#F5F7FA">
 <Window.Resources>
  <Style TargetType="Button"><Setter Property="Padding" Value="12,6"/><Setter Property="Margin" Value="0,0,8,6"/></Style>
  <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
 </Window.Resources>
 <Grid Margin="22"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel Grid.Row="0">
   <TextBlock Name="Title" FontSize="25" FontWeight="SemiBold" Foreground="#21354C"/>
   <TextBlock Name="Identity" Margin="0,7,0,3"/>
   <TextBlock Name="CasePath" FontWeight="SemiBold"/>
   <TextBlock Name="Instruction" Margin="0,8,0,12"/>
  </StackPanel>
  <Grid Grid.Row="1" Name="Setup"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
   <StackPanel Margin="0,0,10,8"><Label Target="{Binding ElementName=Scenario}" Padding="0" Content="Sign-in scenario"/>
    <ComboBox Name="Scenario" SelectedIndex="0"><ComboBoxItem>Reboot</ComboBoxItem><ComboBoxItem>SignOutSignIn</ComboBoxItem></ComboBox></StackPanel>
   <StackPanel Grid.Column="1"><Label Target="{Binding ElementName=Affected}" Padding="0" Content="Affected Windows account"/><TextBox Name="Affected" Padding="4"/></StackPanel>
  </Grid>
  <WrapPanel Grid.Row="2"><Button Name="Primary" Background="#204D70" Foreground="White" FontWeight="SemiBold"/><Button Name="Notes" Content="Open timing notes"/><Button Name="Refresh" Content="Refresh"/></WrapPanel>
  <WrapPanel Grid.Row="3"><ComboBox Name="Other" Width="225" VerticalAlignment="Top" Margin="0,0,8,6" Padding="4"/><Button Name="RunOther" Content="Run selected action"/></WrapPanel>
  <TextBlock Grid.Row="4" Name="ProgressLabel" Text="Action output" FontWeight="SemiBold" Margin="0,4,0,5"/>
  <TextBox Grid.Row="5" Name="Output" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
    VerticalScrollBarVisibility="Auto" Padding="7" Background="White"/>
  <TextBlock Grid.Row="6" Margin="0,9,0,0" Text="For automation and advanced options, run SWP-Perf.ps1 -Stage Help in elevated PowerShell." Foreground="#404F60"/>
 </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($layout)
    try { [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Confirm-CollectorAction {
    param($Window, [string]$Message, [string]$Title)
    [Windows.MessageBox]::Show($Window,$Message,$Title,'YesNo','Question','No') -eq 'Yes'
}

function Show-CollectorWindow {
    param([string]$RequestedCase, [string]$SourcePath = $PSCommandPath)
    $window = New-CollectorWindow
    $controls = @{}
    foreach ($name in 'Title','Identity','CasePath','Instruction','Setup','Scenario','Affected','Primary','Notes','Refresh','Other','RunOther','ProgressLabel','Output') {
        $controls[$name] = $window.FindName($name)
    }
    $ui = @{ Job=$null; Script=$SourcePath; Case=$null; Action=$null; Requested=$RequestedCase }
    $labels = [ordered]@{
        InstallTools='Install tools'; Prepare='Prepare new capture'; Instructions='View reproduction instructions'
        StopTrace='Stop trace now'; FinishAndPackage='Finish and package'; Package='Package case'; OpenHandoff='Open handoff folder'
        Review='Review recovery status'; Status='Show status'; Diagnostics='Resume or request diagnostic'; FinishB='Finish B'
        PrepareB='Prepare Pass B'; SaveDebugB='Save Pass B early logs'; RecoverB='Recover Pass B and package'
        RecoverAndPackage='Recover and package'; RestoreTrace='Restore trace settings'; Restore='Restore settings and keep evidence'
        Delete='Delete all local cases'
    }
    $controls.Affected.Text = [string](Get-CimInstance Win32_ComputerSystem).UserName
    $admin = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $installedScript = Join-Path $ToolRoot 'SWP-Perf.ps1'
    $append = {
        param($line)
        $controls.Output.AppendText(([string]$line) + [Environment]::NewLine)
        if ($controls.Output.Text.Length -gt 65000) { $controls.Output.Text = $controls.Output.Text.Substring(20000) }
        $controls.Output.ScrollToEnd()
    }
    $refresh = {
        $controls.Other.Items.Clear()
        $controls.Primary.IsEnabled = $false
        $controls.RunOther.IsEnabled = $false
        $controls.Notes.IsEnabled = $false
        $controls.Setup.Visibility = 'Collapsed'
        $ui.Case = $null
        try {
            $known = @(Get-CaseCatalog)
            $open = @($known | Where-Object Open)
            if ($ui.Requested) {
                $entry = $known | Where-Object Path -eq $ui.Requested
                $ui.Case = $ui.Requested
                if (!$entry -and $open.Count) { throw ('Another case is active: ' + ($open.Path -join ', ')) }
            } elseif ($open.Count -gt 1) {
                throw ('Multiple active cases. Open Status in PowerShell with -Case. ' + ($open.Path -join ', '))
            } else {
                $entry = $open | Select-Object -First 1
                if ($entry) { $ui.Case = $entry.Path }
            }
            $installed = (Test-Path -LiteralPath $installedScript) -and (Test-Path -LiteralPath $Executable) -and
                (Get-FileHash -LiteralPath $installedScript).Hash -eq (Get-FileHash -LiteralPath $ui.Script).Hash
            if (!$installed -and $entry) { throw 'This case is active under another installation. Open the installed collector that prepared the case.' }
            $view = Get-CollectorView $entry $installed $boot
            $ui.Action = $view.Action
            $ui.NotesPass = $view.NotesPass
            $controls.Title.Text = $view.Title
            $controls.Instruction.Text = $view.Message
            $controls.Identity.Text = "Administrator: $admin"
            if ($entry) { $controls.Identity.Text += "     Affected user: $($entry.Phase.AffectedUser)" }
            $displayPath = if ($ui.Case) { $ui.Case } else { Get-NextCasePath }
            $controls.CasePath.Text = "Case folder: $displayPath"
            if ($view.Action -eq 'Prepare') { $controls.Setup.Visibility = 'Visible' }
            $controls.Primary.Content = $labels[$view.Action]
            $controls.Primary.IsEnabled = $true
            $controls.Notes.Content = if ($view.NotesPass -eq 'PassB') { 'Open Pass B timing notes' } else { 'Open timing notes' }
            $controls.Notes.IsEnabled = $ui.Case -and (Test-Path -LiteralPath (Get-TimingNotesPath $ui.Case $view.NotesPass))
            $choices = @('Status')
            if ($entry) {
                if ($view.CanPrepareB) { $choices += 'PrepareB' }
                if ($view.ActiveB) { $choices += 'RecoverB' }
                else {
                    if ($entry.Phase.TraceSaved -or $entry.Phase.Finished) { $choices += 'Package','Diagnostics' }
                    if ($entry.Open -and !$entry.Phase.Finished) { $choices += 'RecoverAndPackage','RestoreTrace' }
                }
            }
            if ($known.Count) { $choices += 'Restore','Delete' }
            foreach ($choice in $choices) { [void]$controls.Other.Items.Add($labels[$choice]) }
            $controls.Other.SelectedIndex = 0
            $controls.RunOther.IsEnabled = $true
        } catch {
            $controls.Title.Text = 'Case requires review'
            $controls.Instruction.Text = $_.Exception.Message
            $controls.Primary.Content = 'Review in PowerShell'
            & $append $_.Exception.Message
        }
    }
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [timespan]::FromMilliseconds(450)
    $run = {
        param([string]$action)
        if ($ui.Job) { return }
        try {
            $argsForStage = @{}
            if ($ui.Case) { $argsForStage.Case = $ui.Case }
            switch ($action) {
                'Instructions' { [void][Windows.MessageBox]::Show($window,$controls.Instruction.Text,'Reproduce the delay'); return }
                'OpenHandoff' {
                    $receipt = Get-Content -LiteralPath (Join-Path $ui.Case 'Cleanup\Handoff-receipt.json') -Raw | ConvertFrom-Json
                    $archive = [IO.FileInfo]::new([string]$receipt.Archive)
                    if ($archive.Extension -ne '.zip' -or !$archive.Exists) { throw 'The recorded ZIP is unavailable. Check the handoff location or package again.' }
                    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ('/select,"{0}"' -f $archive.FullName)
                    return
                }
                'Prepare' {
                    if (!$controls.Affected.Text.Trim()) { throw 'Enter the affected Windows account.' }
                    $argsForStage.AffectedUser = $controls.Affected.Text.Trim()
                    $argsForStage.Scenario = $controls.Scenario.SelectedItem.Content
                }
                'Review' { $action = 'Status' }
                'PrepareB' {
                    if (!(Confirm-CollectorAction $window 'Prepare the optional repeat on this case? Have Microsoft Process Monitor available and confirm the recorded self-protection settings with the policy owner.' 'Prepare Pass B')) { return }
                }
                'SaveDebugB' { $argsForStage.Pass = 'PassB'; $action = 'SaveDebug' }
                { $_ -in 'RecoverAndPackage','RecoverB' } {
                    $argsForStage.Pass = if ($action -eq 'RecoverB') { 'PassB' } else { 'PassA' }
                    if (!(Confirm-CollectorAction $window "Preserve a partial $($argsForStage.Pass) capture and begin recovery now?" 'Recover evidence')) { return }
                    $action = 'RecoverAndPackage'
                }
                'Restore' {
                    if ([Windows.MessageBox]::Show($window,'Restore settings for all cases and keep their files? This can end an unfinished recording.','Restore collection settings','YesNo','Question','No') -ne 'Yes') { return }
                    $action = 'Cleanup'; $argsForStage.KeepEvidence = $true
                }
                'Delete' {
                    $items = Get-ChildItem -LiteralPath 'C:\SWP-Perf' -Force | Select-Object -ExpandProperty Name
                    $prompt = "Delete ALL contents of C:\SWP-Perf after handoff checks?`n`n" + ($items -join "`n")
                    if ([Windows.MessageBox]::Show($window,$prompt,'Delete all local cases','YesNo','Warning','No') -ne 'Yes') { return }
                    $action = 'Cleanup'
                }
            }
            $argsForStage.Stage = $action
            $ui.Job = Start-Job -ArgumentList $ui.Script,$argsForStage -ScriptBlock {
                param($source,$options)
                $ErrorActionPreference = 'Stop'
                & $source @options *>&1 | Out-String -Stream
            }
            $controls.ProgressLabel.Text = "$action in progress"
            foreach ($id in 'Primary','RunOther','Notes','Refresh','Setup') { $controls[$id].IsEnabled = $false }
            & $append "Starting $action..."
            $timer.Start()
        } catch { & $append $_.Exception.Message }
    }
    $timer.Add_Tick({
        if (!$ui.Job) { return }
        $job = $ui.Job
        # Read terminal state before draining so the final messages are included.
        $done = $job.State -in 'Completed','Failed','Stopped'
        foreach ($line in @(Receive-Job -Job $job -ErrorAction Continue 2>&1)) { & $append $line }
        if ($done) {
            $timer.Stop()
            $controls.ProgressLabel.Text = "Action output ($($job.State))"
            if ($job.State -eq 'Failed') { & $append $job.ChildJobs[0].JobStateInfo.Reason }
            Remove-Job -Job $job
            $ui.Job = $null
            $controls.Refresh.IsEnabled = $true
            $controls.Setup.IsEnabled = $true
            & $refresh
        }
    })
    $controls.Primary.Add_Click({ & $run $ui.Action })
    $controls.RunOther.Add_Click({
        foreach ($key in $labels.Keys) { if ($labels[$key] -eq $controls.Other.SelectedItem) { & $run $key; break } }
    })
    $controls.Refresh.Add_Click({ & $refresh })
    $controls.Notes.Add_Click({
        try {
            $path = Assert-LocalEvidencePath (Get-TimingNotesPath $ui.Case $ui.NotesPass)
            Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList ('"{0}"' -f $path)
        } catch { & $append $_.Exception.Message }
    })
    $window.Add_Closing({ param($sender,$eventArgs)
        if ($ui.Job) { $eventArgs.Cancel = $true; & $append 'An action is running. Wait for completion before closing.' }
    })
    & $refresh
    [void]$window.ShowDialog()
}

function Invoke-Prepare {
    Write-Host "Preparing case: $Case"
    $script:Wpr = Get-WprPath
    foreach ($Required in @($Executable, $ConfigPath)) {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Missing tool file: $Required" }
    }
    if (!(Test-Path -LiteralPath "$ToolRoot\SWP-Perf.ps1") -or (Get-FileHash "$ToolRoot\SWP-Perf.ps1").Hash -ne (Get-FileHash $PSCommandPath).Hash) { throw 'Install the matching customer script and profiles using InstallTools.' }
    if (!$AffectedUser) { $AffectedUser = (Get-CimInstance Win32_ComputerSystem).UserName }
    if (!$AffectedUser) { throw 'Supply -AffectedUser DOMAIN\user for the interactive test account.' }
    $profileName=if ($WprBuffers -eq 'LargerBuffers') {'SWP-SignIn-128MiB.wprp'} else {'SWP-SignIn.wprp'}
    $profileFile=Join-Path $ToolRoot $profileName
    if (!(Test-Path -LiteralPath $profileFile -PathType Leaf)) { throw "Missing focused profile: $profileFile" }
    $Config = Get-CollectionConfig
    foreach ($Existing in @($StatePath, "$Case\Cleanup\PersistentAMTrace", "$Case\Events\Original-channel-state.csv", "$Case\Trend\DSTool-original.json")) {
        if (Test-Path -LiteralPath $Existing) { throw "Previous preparation exists: $Existing. Use a fresh case or perform Pass C cleanup." }
    }
    if (Test-Path -LiteralPath 'C:\SWP-Perf') {
        $PriorStates = @(Get-ChildItem -LiteralPath 'C:\SWP-Perf' -Filter 'PhaseA-state.json' -Recurse -File)
        foreach ($PriorState in $PriorStates) {
            $Prior = Get-Content -LiteralPath $PriorState.FullName -Raw | ConvertFrom-Json
            if ($Prior.ConfigRestored -ne $true) { throw "Previous Phase A configuration has not been restored: $($PriorState.FullName). Complete Pass C first." }
        }
    }
    if (Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue) {
        throw 'The temporary DSA task already exists. Complete cleanup rather than replacing its state.'
    }
    $Collectors = @(Get-Process | Where-Object { $_.ProcessName -match '^(DSASupportTool.*|procmon.*|wprui|xperf)$' })
    if ($Collectors.Count) { throw 'Close diagnostic tools and verify that no other collection owns WPR before preparation.' }
    Assert-WprAvailableForPrepare
    $Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($Disk.FreeSpace -lt 20GB) { throw 'Less than 20 GB is free on C:. Free space before a file-mode boot trace. This threshold is not a size guarantee.' }
    Initialize-CaseDirectory (Split-Path -Parent $Case)
    Initialize-CaseDirectory $Case
    foreach ($Folder in @("$Case\Events", "$Case\WPR", "$Case\Procmon", "$Case\Trend", "$Case\Cleanup")) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
    $script:State = [pscustomobject]@{
        PreparedAt = (Get-Date -Format o)
        ComputerName = $env:COMPUTERNAME
        RunId = [guid]::NewGuid().ToString('N')
        Scenario = $Scenario
        CasePath = $Case
        AffectedUser = $AffectedUser
        WprBuffers = $WprBuffers
        PreparedBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        AmspDebug = $AmspDebug
        ConfigOriginalHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
        ConfigAppliedHash = $null
        ConfigRestored = $false
        Armed = $false
        TraceSaved = $false
        Finished = $false
    }
    Copy-Item -LiteralPath $ConfigPath -Destination "$Case\Trend\DSTool-original.json"
    if ((Get-FileHash -LiteralPath "$Case\Trend\DSTool-original.json").Hash -ne $State.ConfigOriginalHash) { throw 'DSA JSON backup verification failed.' }
    Save-State
    if ($PSCommandPath) { Copy-Item -LiteralPath $PSCommandPath -Destination "$Case\Cleanup\SWP-Perf-used.ps1" }
    if (-not (Test-Path "$Case\Test-notes.txt")) {
        @('Operator timing notes (complete manually):', 'Original self-protection state/inheritance:', 'Baseline login/application timings:', 'Measured reboot/login/application timestamps with time-zone offset:', 'Observed symptom:', 'Missing intervals/dropped events:', 'Self-protection restoration time:') | Set-Content -LiteralPath "$Case\Test-notes.txt" -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath "$Case\Operator-notes.json")) {
        [pscustomobject]@{ CredentialSubmittedAt=''; DesktopReadyAt=''; Applications=@([pscustomobject]@{Name='';LaunchAt='';ReadyAt='';Symptom=''}); Baseline=''; OriginalSelfProtection=''; RestoredSelfProtection='' } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$Case\Operator-notes.json" -Encoding UTF8
    }
    Save-LoginContext
    Get-Date -Format o | Out-File "$Case\Preparation-time.txt"
    whoami | Out-File "$Case\Test-account.txt"
    Get-TimeZone | Format-List * | Out-File "$Case\Timezone.txt"
    Save-NativeEvidence 'w32tm.exe' @('/query','/status') "$Case\Clock-status.txt"
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime | Format-List | Out-File "$Case\Windows-version.txt"
    Get-Service SysMain -ErrorAction SilentlyContinue | Format-List Name, Status, StartType | Out-File "$Case\SysMain-before.txt"
    Get-Service | Where-Object DisplayName -like '*Trend*' | Format-Table -AutoSize | Out-File "$Case\Trend-services-before.txt"
    try {
        Get-MpComputerStatus -ErrorAction Stop | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, AMProductVersion | Format-List | Out-File "$Case\Defender-before.txt"
    } catch { $_ | Out-String | Out-File "$Case\Defender-before-error.txt" }
    & fltmc.exe filters | Out-File "$Case\File-system-filters-before.txt"
    & fltmc.exe instances | Out-File "$Case\File-system-filter-instances-before.txt"
    & icacls.exe $ToolRoot | Out-File "$Case\Trend\Tool-root-permissions.txt"
    & icacls.exe $ToolFolder /T | Out-File "$Case\Trend\DSA-tool-permissions.txt"
    Save-NativeEvidence $Wpr @('-profiles') "$Case\WPR-profiles.txt"
    Save-NativeEvidence $Wpr @('-status') "$Case\WPR-initial-status.txt"
    $OriginalChannels = @(foreach ($Channel in $Channels) {
        try {
            $Log = Get-WinEvent -ListLog $Channel -ErrorAction Stop
            [pscustomobject]@{ Name = $Channel; WasEnabled = [bool]$Log.IsEnabled }
        } catch { "$Channel : $_" | Add-Content "$Case\Events\Unavailable-channels.txt" }
    })
    $OriginalChannels | Export-Csv -LiteralPath "$Case\Events\Original-channel-state.csv" -NoTypeInformation
    foreach ($Entry in $OriginalChannels) {
        if (-not $Entry.WasEnabled) {
            & wevtutil.exe sl $Entry.Name /e:true
            if ($LASTEXITCODE -ne 0) { throw "Could not enable $($Entry.Name). Original channel states are saved." }
        }
    }
    Write-CollectorConfig $Config "$Case\Trend\DSTool-collection.json"
    $State.ConfigAppliedHash = (Get-FileHash -LiteralPath "$Case\Trend\DSTool-collection.json").Hash
    Save-State
    Copy-Item "$Case\Trend\DSTool-collection.json" -Destination $ConfigPath -Force
    if ((Get-FileHash -LiteralPath $ConfigPath).Hash -ne $State.ConfigAppliedHash) { throw 'Installed vendor JSON did not verify.' }
    $EnableTime = (Get-Date).ToUniversalTime()
    Enable-PersistentAMTrace -Case $Case
    $Deadline = (Get-Date).AddSeconds(60)
    do {
        $DebugLog = Get-Item -LiteralPath (Join-Path $AmspDebug 'Amsp_LocalDebugLog.log') -ErrorAction SilentlyContinue
        if ($DebugLog -and $DebugLog.LastWriteTimeUtc -ge $EnableTime -and $DebugLog.Length -gt 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $Deadline)
    if (-not $DebugLog -or $DebugLog.LastWriteTimeUtc -lt $EnableTime -or $DebugLog.Length -eq 0) {
        throw 'Fresh AMSP debug output was not verified. Review logs and self-protection; no boot recording has been armed. Pass C restores the saved settings.'
    }
    Get-Item -LiteralPath $DebugLog.FullName | Select-Object FullName, Length, LastWriteTimeUtc | Format-List | Out-File "$Case\Trend\AMDebug-enabled.txt"
    @(Get-OriginalDebugValues) | ConvertTo-Json | Set-Content -LiteralPath "$Case\Cleanup\PersistentAMTrace\Registry-applied.json" -Encoding UTF8
    Register-MetricsTask 'PassA'
    # No automatic cancellation: an already scheduled trace must be reviewed first.
    if ($Scenario -eq 'SignOutSignIn') { Confirm-WarmScanControl }
    $verb=if ($Scenario -eq 'Reboot') {'-boottrace -addboot'} else {'-start'}
    $BootArguments = '{0} "{1}!SWPSignIn.Light"' -f $verb,$profileFile
    if ($IncludeNetwork) { $BootArguments += $(if ($Scenario -eq 'Reboot') {' -addboot Network'} else {' -start Network'}) }
    $BootArguments += " -filemode -instancename SWP$($State.RunId)"
    $BootArguments | Out-File "$Case\WPR\Selected-profiles.txt"
    $Process = Start-Process -FilePath $Wpr -ArgumentList $BootArguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$Case\WPR\Arm-output.txt" -RedirectStandardError "$Case\WPR\Arm-error.txt"
    Get-Content "$Case\WPR\Arm-output.txt", "$Case\WPR\Arm-error.txt" | Out-Host
    if ($Process.ExitCode -ne 0) { throw "WPR arm failed: $($Process.ExitCode). Do not reboot into an unverified setup; use troubleshooting or Pass C." }
    $State | Add-Member -NotePropertyName ArmedAtUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
    $State.Armed = $true
    Save-State
    if ($Scenario -eq 'SignOutSignIn') {
        Start-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\'
        Write-Host 'Prepared. Fully sign out and sign back in now. Run StopTrace at the agreed desktop or application milestone.'
        return
    }
    Write-Host 'Prepared. Focused boot WPR, persistent AM debug and DSA metrics are armed.'
    Write-Host 'Reboot manually now, log in and reproduce the agreed application launches.'
    Write-Host 'Immediately afterward run SWP-Perf.ps1 -Stage StopTrace, then -Stage FinishAndPackage. Do not wait for metrics before StopTrace.'
    return
}

function Invoke-StopTrace {
    Read-CollectionState -Pass 'PassA'
    Assert-CaseTrace $State
    $script:Wpr = Get-WprPath
    if ($State.TraceSaved) { throw 'The boot trace has already been saved. Continue with -Stage Finish.' }
    $Etl = "$Case\WPR\PassA-BootLoginApps.etl"
    if (Test-Path -LiteralPath $Etl) { throw 'ETL already exists. Preserve it; do not overwrite it.' }
    $State | Add-Member -NotePropertyName RecordedBootUtc -NotePropertyValue ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')) -Force
    $State | Add-Member -NotePropertyName TraceStopRequestedAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Save-State
    $EarlySaved = $false
    $snapshot=$null
    try { $snapshot=Start-EarlySnapshot; $null=$snapshot.Handle }
    catch {
        $_ | Out-String | Set-Content -LiteralPath "$Case\WPR\Early-debug-copy-error.txt" -Encoding UTF8
        Write-Warning 'Early debug copy failed. WPR will still be stopped; the error is recorded.'
    }
    $stop=if ($State.Scenario -eq 'SignOutSignIn') {'-stop'} else {'-boottrace -stopboot'}
    $Arguments = '{0} "{1}" "Windows sign-in and application startup" -instancename SWP{2}' -f $stop,$Etl,$State.RunId
    $State | Add-Member -NotePropertyName WprSaveInvokedAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Save-State
    Write-Host 'Saving WPR trace; this can take several minutes. Do not interrupt, reboot or run another stop.'
    $Process = Start-Process -FilePath $Wpr -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$Case\WPR\Save-output.txt" -RedirectStandardError "$Case\WPR\Save-error.txt"
    Get-Content "$Case\WPR\Save-output.txt", "$Case\WPR\Save-error.txt" | Out-Host
    $Process.ExitCode | Out-File "$Case\WPR\Save-exit-code.txt"
    $Text = (Get-Content -LiteralPath "$Case\WPR\Save-output.txt" -Raw) + "`n" + (Get-Content -LiteralPath "$Case\WPR\Save-error.txt" -Raw)
    if ($snapshot) {
        try { $snapshot.WaitForExit(); $EarlySaved=$snapshot.ExitCode -eq 0 } finally { $snapshot.Dispose() }
        if (!$EarlySaved) { 'Snapshot subprocess failed; see Early-copy-error.txt.' | Out-File "$Case\WPR\Early-debug-copy-error.txt" }
    }
    try { Save-SignInMilestones } catch { $_.Exception.Message | Out-File "$Case\WPR\SignIn-milestone-error.txt" }
    $Quality = Get-WprSaveAssessment -Etl $Etl -ExitCode $Process.ExitCode -OutputText $Text
    $Quality | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$Case\WPR\Trace-quality.json" -Encoding UTF8
    if (-not $Quality.Saved) { Write-Warning 'Run -Stage RecoverAndPackage to preserve independent evidence.'; throw "WPR save failed or produced no nonempty ETL. Inspect Trace-quality.json and save output; do not cancel or reboot immediately." }
    $State.TraceSaved = $true
    Save-State
    if (-not $EarlySaved) {
        try { Save-AMDebug -Label 'PassA-AfterWprSave-Fallback' }
        catch { $_ | Out-String | Set-Content -LiteralPath "$Case\WPR\Fallback-debug-copy-error.txt"; Write-Warning 'Fallback debug copy also failed. Preserve partial evidence.' }
    }
    if ($Quality.Status -in @('SavedWithEventLoss','SavedLossCountUnparsed')) { Write-Warning "WPR QUALITY: $($Quality.Status); reported dropped events: $($Quality.ReportedDroppedEvents). Preserve this trace and report the gap." }
    else { Write-Host 'WPR saved; coverage and boot markers still require analysis.' }
    Write-Host 'Next run -Stage FinishAndPackage (or -Stage Finish). It waits for CMD metrics before copying and diagnostic collection.'
    return
}

function Assert-PassBBoot {
    param([datetime]$BootUtc)
    $marker = Join-Path $Case "Trend\LiveMetrics\PassB\$($State.RunId)\BootUtc.txt"
    if (Test-Path -LiteralPath $marker) {
        $saved = Parse-StateDateTime (Get-Content -LiteralPath $marker -Raw).Trim()
        if ($saved.ToUniversalTime() -ne $BootUtc) { throw 'A different restart owns the Pass B metrics task. Recover available evidence.' }
    } else {
        $prepared = (Parse-StateDateTime $State.PreparedAt).ToLocalTime()
        $boots = @(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12;StartTime=$prepared} -ErrorAction SilentlyContinue)
        if ($boots.Count -ne 1 -or [math]::Abs(($boots[0].TimeCreated.ToUniversalTime() - $BootUtc).TotalSeconds) -gt 30) {
            throw 'The Pass B restart is unverified. Retry after the startup task or System boot event appears, or recover partial evidence.'
        }
    }
    if ($State.RecordedBootUtc -and (Parse-StateDateTime $State.RecordedBootUtc).ToUniversalTime() -ne $BootUtc) { throw 'The recorded Pass B boot differs from this restart.' }
}

function Set-PassBReproductionEnd {
    param([string]$Source)
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    if ($boot -le (Parse-StateDateTime $State.PreparedBoot).ToUniversalTime()) { return }
    if (!$State.ReproductionEndUtc) {
        $State | Add-Member -NotePropertyName RecordedBootUtc -NotePropertyValue ($boot.ToString('o')) -Force
        $State | Add-Member -NotePropertyName ReproductionEndUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
        $State | Add-Member -NotePropertyName ReproductionEndSource -NotePropertyValue $Source -Force
        Save-State
    }
}

function Save-PassBMilestones {
    $file = Join-Path $Case 'Procmon\SignIn-milestones.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $previous = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ($previous.SessionCorroborated) { return }
    }
    Save-SignInMilestones -PassName PassB
}

function Invoke-Finish {
    param([string]$Pass = 'PassA',[switch]$Recovery)
    Read-CollectionState -Pass $Pass -RequireReboot:(-not $Recovery)
    if ($State.Finished -and !$Recovery) { Write-Host "$Pass already finished. Use Package for the handoff."; return }
    if ($Pass -eq 'PassB') {
        if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^procmon(64|64a)?$' }) { throw 'Save the PML, disable Procmon boot logging and exit Procmon before FinishB.' }
        if (!$Recovery -and $State.PreparationComplete -eq $false) { throw 'Pass B preparation was interrupted. Use RecoverAndPackage -Pass PassB.' }
        $Pml = @(Get-ChildItem -LiteralPath "$Case\Procmon" -Filter '*.pml' -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 -and $_.LastWriteTimeUtc -ge (Parse-StateDateTime $State.PreparedAt).ToUniversalTime() })
        if (!$Pml.Count -and !$Recovery) { throw 'No saved PML found. Save the Procmon boot capture before FinishB, or recover available evidence.' }
        if ($Recovery) {
            try {
                $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
                Assert-PassBBoot $boot
                Set-PassBReproductionEnd 'Recovery'
                if ($State.RecordedBootUtc) { Save-PassBMilestones }
            } catch { Write-Warning "Pass B sign-in window unverified: $($_.Exception.Message)" }
        } else {
            Set-PassBReproductionEnd 'FinishB'
            try { Save-PassBMilestones } catch { $_.Exception.Message | Out-File "$Case\Procmon\SignIn-milestone-error.txt" }
        }
    }
if (!$Recovery -and $Pass -eq 'PassA' -and -not $State.TraceSaved) { throw 'Run -Stage StopTrace immediately after the measured reproduction first.' }
$Deadline = (Get-Date).AddMinutes(46)
do {
    $Task = Get-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction SilentlyContinue
    $Detached = @(Get-CimInstance Win32_Process -Filter "Name='DSASupportTool_CMD.exe'" | Where-Object { -not $_.ExecutablePath -or $_.ExecutablePath.Equals($Executable,[StringComparison]::OrdinalIgnoreCase) })
    if ($Task.State -notin @('Running','Queued') -and -not $Detached.Count) { break }
    Write-Host ("{0}: DSA collection is still running; waiting 30 seconds." -f (Get-Date -Format 'HH:mm:ss'))
    if ((Get-Date) -ge $Deadline) { throw 'Task remains running beyond the wait limit. Preserve its state; investigate before copying/restoring.' }
    Start-Sleep -Seconds 30
} while ($true)
if ($Task -and !(Test-MetricsTaskAction $Task $State $Case $Pass)) {
    $phaseA = Get-Content -LiteralPath "$Case\Cleanup\PhaseA-state.json" -Raw | ConvertFrom-Json
    if ($Pass -eq 'PassB' -and $Recovery -and $Task.State -eq 'Disabled' -and (Test-MetricsTaskAction $Task $phaseA $Case PassA)) {
        $Task = $null
    } else { throw 'Unrecognized scheduled task. Preserve its state.' }
}
$PassFolder = "$Case\Trend\$Pass"
if (Test-Path $PassFolder) {
    $PassFolder = "$Case\Trend\$Pass-Retry-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Write-Warning "Earlier snapshot preserved. This finish attempt uses: $PassFolder"
}
try {
    $disableError = $null
    if ($Task) {
        try { Disable-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction Stop | Out-Null }
        catch { $disableError = $_.Exception.Message; Write-Warning "Could not disable the owned metrics task: $disableError" }
    }
    New-Item -ItemType Directory -Path $PassFolder -ErrorAction Stop | Out-Null
    if ($disableError) { $disableError | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt" }
    if ($Task) {
        try {
            $Info = Get-ScheduledTaskInfo -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\' -ErrorAction Stop
            $Info | Format-List * | Out-File "$PassFolder\Task-result.txt"
            [pscustomobject]@{LastRunTimeUtc=$Info.LastRunTime.ToUniversalTime().ToString('o');LastTaskResult=$Info.LastTaskResult;PreparedAt=$State.PreparedAt} |
                ConvertTo-Json | Set-Content -LiteralPath "$PassFolder\Task-run-assessment.json" -Encoding UTF8
            Write-TaskXml -Xml (Export-ScheduledTask -TaskName 'SWP-Perf-DSAMetrics' -TaskPath '\') -Path "$PassFolder\Task-definition.xml"
            if ($Info.LastTaskResult -ne 0) { "DSA task result: $($Info.LastTaskResult)" | Add-Content "$PassFolder\Collection-errors.txt" }
        }catch { $_ | Out-String | Add-Content "$PassFolder\Collection-errors.txt" }
    } else { 'DSA task was absent.' | Add-Content "$PassFolder\Collection-errors.txt" }
    if ($Recovery) { "Recovery handoff for $Pass. Review incomplete or missing evidence." | Add-Content "$PassFolder\Collection-errors.txt" }
    if ($Pass -eq 'PassB' -and $Pml.Count) {
        $manifest = "$Case\Procmon\PassB-segments.csv"
        if (!(Test-Path -LiteralPath $manifest)) {
            try {
                $segments = foreach ($file in $Pml) {
                    $path = Assert-LocalEvidencePath $file.FullName
                    [pscustomobject]@{RunId=$State.RunId;Name=$file.Name;Bytes=$file.Length;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
                }
                $segments | Export-Csv -LiteralPath "$manifest.tmp" -NoTypeInformation -Encoding UTF8
                [IO.File]::Move("$manifest.tmp",$manifest)
            } catch { "PML inventory failed: $_" | Add-Content "$PassFolder\Collection-errors.txt" }
        }
    }
    try {
        $snapshot = New-Item -Path "$PassFolder\SupportToolSnapshot" -ItemType Directory -Force
        foreach ($name in 'DSTool.json','logs\GetConfiguration.xml') {
            $file = Join-Path $ToolFolder $name
            if(Test-Path -LiteralPath $file) {Copy-Item -LiteralPath $file -Destination $snapshot.FullName}
        }
        $supportLog = Join-Path $ToolFolder 'logs\DSA_SupportTool.log'
        if (Test-Path -LiteralPath $supportLog) {
            $from = (Parse-StateDateTime $State.PreparedAt).ToLocalTime()
            $include = $false
            Get-Content -LiteralPath $supportLog | ForEach-Object {
                if ($_ -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3})') {
                    $stamp = [datetime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss,fff',[cultureinfo]::InvariantCulture)
                    $include = $stamp -ge $from
                }
                if ($include) { $_ }
            } | Out-File -LiteralPath (Join-Path $snapshot.FullName 'DSA_SupportTool.log') -Encoding utf8
        }
    }
    catch { $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt"; Write-Warning "Tool snapshot failed: $_" }
    $Since = if ($State.Scenario -eq 'SignOutSignIn' -and $State.ArmedAtUtc) {(Parse-StateDateTime $State.ArmedAtUtc).ToUniversalTime()} elseif ($State.RecordedBootUtc) { (Parse-StateDateTime $State.RecordedBootUtc).ToUniversalTime() } else { (Parse-StateDateTime $State.PreparedAt).ToUniversalTime() }
    $End = if ($State.TraceStopRequestedAtUtc) { (Parse-StateDateTime $State.TraceStopRequestedAtUtc).ToUniversalTime() } elseif ($State.ReproductionEndUtc) { (Parse-StateDateTime $State.ReproductionEndUtc).ToUniversalTime() } else { [datetime]::MinValue }
    if ($Info -and $End -ne [datetime]::MinValue -and $Info.LastRunTime.ToUniversalTime() -gt $End) { 'Metrics task ran again after the reproduction ended. Review run association.' | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt" }
    try { Copy-ToolMetrics -PassFolder $PassFolder -SinceUtc $Since -RequiredEndUtc $End | Out-Null }
    catch { $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt"; Write-Warning "Explicit tool metrics retrieval failed: $_" }
    $Metrics = Join-Path $env:ProgramData 'Trend Micro\Deep Security Agent\metrics'
    if (Test-Path -LiteralPath $Metrics -PathType Container) {
        try { Copy-EvidenceFolder $Metrics "$PassFolder\AgentMetrics" "$PassFolder\AgentMetrics-copy.log" }
        catch { $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt"; Write-Warning "Normal metrics snapshot failed: $_" }
    } else { 'Normal agent metrics folder missing.' | Out-File "$PassFolder\Missing-sources.txt" }
    try { Save-AMDebug -Label "$Pass-Final" }
    catch { $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt"; Write-Warning "Final debug copy failed: $_" }
    if (!$SkipDiagnostics) {
        try {Request-AgentDiagnostics | Out-Null}
        catch {
            $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt"
            Write-Warning "Native diagnostic requires attention: $($_.Exception.Message)"
        }
    }
    else { Write-Warning 'Agent CLI diagnostic request skipped explicitly. The handoff assessment will report this gap.' }
} finally {
    try { Restore-PersistentAMTrace -Case $Case }
    catch {
        Write-Warning "Restoration requires attention: $_"
        if (Test-Path -LiteralPath $PassFolder -PathType Container) { $_ | Out-String | Add-Content -LiteralPath "$PassFolder\Collection-errors.txt" }
    }
}
$eventFolder = if ($Pass -eq 'PassB') { "$Case\Events\PassB" } else { "$Case\Events" }
$null = New-Item -ItemType Directory -Path $eventFolder -Force
Export-PassEvents $eventFolder
Save-NativeEvidence 'gpresult.exe' @('/h',"$eventFolder\gpresult-administrator.html",'/f') "$eventFolder\gpresult-output.txt"
Get-ChildItem -LiteralPath $Case -Recurse -File | Select-Object FullName, Length, LastWriteTimeUtc | Export-Csv -LiteralPath "$Case\File-inventory.csv" -NoTypeInformation
$State.Finished = $true
$State | Add-Member -NotePropertyName FinishedAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
Save-State
Write-Host "$Pass evidence retrieval finished. Inspect recovery state and collection errors before cleanup."
if (Test-Path -LiteralPath "$PassFolder\Collection-errors.txt") { Write-Warning 'One or more evidence-copy steps failed. Inspect Collection-errors.txt; do not treat Finished as complete evidence.' }
Write-Host 'Still required: verify actual timestamps/dropped events and complete Test-notes.txt/policy context. Native agent diagnostics do not replace any extra GUI support-tool data specifically requested by support.'
Write-Host 'Restore recorded self-protection in the console. Use optional Pass B only for an unanswered question.'
}

function Assert-HandoffsOutsideRoot {
    param([string]$Root)
    $prefix=$Root.TrimEnd('\')+'\'
    foreach($item in @(Get-ChildItem -LiteralPath $Root -Force)){
        if(!$item.PSIsContainer){
            if ($item.Name -notmatch '^AllEvidence-CASE-[\w-]+\.zip(?:\.sha256\.txt)?$'){throw "Unrecognized file under case root: $($item.FullName). Preserve it before cleanup."}
            $outside=Join-Path $ArchiveDirectory $item.Name
            if([IO.Path]::GetFullPath($outside).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $outside -PathType Leaf) -or (Get-FileHash -LiteralPath $outside).Hash -ne (Get-FileHash -LiteralPath $item.FullName).Hash){throw "Copy this archive or checksum outside the case root first: $($item.Name)"}
            continue
        }
        if ($item.Name -notmatch '^CASE-[\w-]+$'){throw "Unrecognized directory under case root: $($item.Name)"}
        $receipt=Get-Content -LiteralPath (Join-Path $item.FullName 'Cleanup\Handoff-receipt.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if($receipt.Computer -ne $env:COMPUTERNAME -or $receipt.CaseName -ne $item.Name -or $receipt.SHA256 -notmatch '^[0-9A-F]{64}$'){throw "Handoff receipt identity mismatch for $($item.Name)."}
        $name=[IO.Path]::GetFileName($receipt.Archive)
        $paths=@((Join-Path $ArchiveDirectory $name),$receipt.Archive) | Select-Object -Unique
        $found=$null
        foreach($path in $paths){
            if([IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
            if((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-FileHash -LiteralPath $path).Hash -eq $receipt.SHA256){$found=$path;break}
        }
        if(!$found){throw "No verified handoff outside $Root for $($item.Name). Retaining case files."}
        # Data added or edited after packaging must also survive whole-root cleanup.
        $z=[IO.Compression.ZipFile]::OpenRead($found)
        try{
            foreach($file in (Get-RegularEvidenceFiles $item.FullName)){
                $rel=$file.FullName.Substring($item.FullName.Length+1)
                if($rel -in 'Cleanup\Handoff-receipt.json','Cleanup\PhaseA-state.json','Cleanup\PhaseB-state.json','Cleanup\PersistentAMTrace\State.json','Cleanup\PersistentAMTrace\Restored-trace-assessment.json'){continue}
                $m=$z.GetEntry($rel);if(!$m){$m=$z.GetEntry($rel.Replace('\','/'))}
                if(!$m -or $file.Length -ne $m.Length){throw "New or changed evidence requires repackaging: $rel"}
                $str=$m.Open();$hash=[Security.Cryptography.SHA256]::Create()
                try{$h=[BitConverter]::ToString($hash.ComputeHash($str)).Replace('-','')}finally{$str.Dispose();$hash.Dispose()}
                if((Get-FileHash -LiteralPath $file.FullName).Hash -ne $h){throw "Changed evidence requires repackaging: $rel"}
            }
        }finally{$z.Dispose()}
    }
}

function Get-OriginalDebugValues {
    $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\TrendMicro\AMSP\AmspConfig\Debug' -ErrorAction Stop
    foreach($n in 'DebugLevel','DebugFlag','DebugLogAMSPServiceStart','DebugLogFileMaxSize','DebugLogFileMaxCount','DebugLogFilePath','DebugLogFilePrefix','DebugLogMode') {
        $exists=$n -in $key.GetValueNames()
        [pscustomobject]@{Name=$n;Exists=$exists;Value=$(if ($exists){$key.GetValue($n)});Kind=$(if ($exists){$key.GetValueKind($n).ToString()})}
    }
}

function Confirm-DebugRestoration {
    param([string]$CasePath)
    $dir=Join-Path $CasePath 'Cleanup\PersistentAMTrace'
    if (!(Test-Path -LiteralPath "$dir\Registry-before.json")) {return}
    $before=(Get-Content -LiteralPath "$dir\Registry-before.json" -Raw|ConvertFrom-Json)
    $applied=@()
    if(Test-Path -LiteralPath "$dir\Registry-applied.json"){$applied=(Get-Content -LiteralPath "$dir\Registry-applied.json" -Raw|ConvertFrom-Json)}
    $live=@(Get-OriginalDebugValues)
    $key='HKLM:\SOFTWARE\TrendMicro\AMSP\AmspConfig\Debug'
    foreach($v in $live){
        $old=@($before|Where-Object Name -eq $v.Name);$ours=@($applied|Where-Object Name -eq $v.Name)
        if($old.Count -ne 1){throw "Missing original registry record for $($v.Name)"}
        $o=$old[0]
        if($o.Exists -eq $v.Exists -and $o.Value -eq $v.Value -and $o.Kind -eq $v.Kind){continue}
        if($ours.Count -ne 1 -or $v.Exists -ne $ours[0].Exists -or $v.Value -ne $ours[0].Value -or $v.Kind -ne $ours[0].Kind){throw "Trend registry value changed independently: $($v.Name)"}
        if($o.Exists){New-ItemProperty -LiteralPath $key -Name $o.Name -PropertyType $o.Kind -Value $o.Value -Force|Out-Null}
        else{Remove-ItemProperty -LiteralPath $key -Name $o.Name}
    }
    if((@(Get-OriginalDebugValues)|ConvertTo-Json -Compress) -cne ($before|ConvertTo-Json -Compress)){throw 'Original Trend registry readback differs.'}
}


function Invoke-Cleanup {
    $CaseRoot = 'C:\SWP-Perf'
    $TaskName = 'SWP-Perf-DSAMetrics'
    $TaskPath = '\'
    $Wpr = Get-WprPath
    $null = Assert-LocalEvidencePath -Path $CaseRoot
    if (Test-Path -LiteralPath $CaseRoot) { $null = @(Get-RegularEvidenceFiles -Root $CaseRoot) }
    if ((Get-AMTraceSetting -Path (Join-Path $env:SystemRoot 'ds_agent.ini')).AMDebugRequested) { Write-Warning 'The current INI requests AM debug. Deleting case files does not disable pre-existing debug logging; the INI is retained for owner review.' }
# First disable Procmon boot logging in its GUI, then close Procmon.
if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^procmon(64|64a)?$' }) {
    throw 'Disable Procmon boot logging and exit Procmon before cleanup.'
}
$cases=@(if(Test-Path -LiteralPath $CaseRoot){Get-ChildItem -LiteralPath $CaseRoot -Directory -Force})
foreach($entry in $cases){ if((Test-DiagnosticPending $entry.FullName) -or (Test-DiagnosticMonitorActive $entry.FullName)){throw "Native diagnostic is pending in $($entry.Name). Resume Diagnostics before cleanup."} }
$Task=Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if($Task){
    $owners=@(foreach($entry in $cases){foreach($phase in 'PassA','PassB'){
        $file=Join-Path $entry.FullName ("Cleanup\Phase{0}-state.json" -f $phase.Substring(4))
        if(Test-Path -LiteralPath $file){$owner=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
            if(Test-MetricsTaskAction $Task $owner $entry.FullName $phase){$owner}}
    }})
    if($owners.Count -ne 1 -or $Task.State -in 'Running','Queued'){throw 'Task ownership or completion is unverified. Preserve all cases.'}
}
if(@(Get-CimInstance Win32_Process | Where-Object {$_.Name -like 'DSASupportTool*'}).Count){throw 'Support tool still running. Retaining all case data.'}
if($Task){
    Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
}
# Only cancel a recording that this case root successfully armed and did not save.
# Without that ownership record, leave WPR alone rather than cancel another activity.
$OwnedRecordings = @()
if (Test-Path -LiteralPath $CaseRoot) {
    foreach ($File in (Get-ChildItem -LiteralPath $CaseRoot -Filter 'PhaseA-state.json' -Recurse -File)) {
        $Owner = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
        if ($Owner.Armed -eq $true -and $Owner.TraceSaved -ne $true) {
            $OwnedRecordings += [pscustomobject]@{ Path=$File.FullName; State=$Owner }
        }
    }
}
if ($OwnedRecordings.Count -gt 1) { throw 'Multiple cases claim an unsaved WPR recording. Resolve ownership before cancellation or deleting backups.' }
if ($OwnedRecordings.Count -eq 1) {
    $Owner = $OwnedRecordings[0]
    Assert-CaseTrace $Owner.State -BeforeBoot
    $operation=if ($Owner.State.Scenario -eq 'Reboot') {'-boottrace -cancelboot'} else {'-cancel'}
    $arguments="$operation -instancename SWP$($Owner.State.RunId)"
    $process=Start-Process -FilePath $Wpr -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -notin @(0,-984076288)){throw "Owned WPR cleanup failed: $($process.ExitCode). Evidence retained."}
    $Owner.State.Armed = $false
    $Owner.State | Add-Member -NotePropertyName WprCancelledAt -NotePropertyValue (Get-Date -Format o) -Force
    $Owner.State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Owner.Path -Encoding UTF8
} else { Write-Host 'No unsaved WPR recording is owned by the saved case state; no global cancellation was performed.' }

if (Test-Path -LiteralPath $CaseRoot) {
    # Reject directory links before recursive discovery/deletion outside the fixed case tree.
    $Links = @(Get-ChildItem -LiteralPath $CaseRoot -Recurse -Force -Attributes ReparsePoint)
    if ((Get-Item -LiteralPath $CaseRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or $Links.Count) {
        throw 'Case tree contains links/junctions. Review before deletion.'
    }
    foreach($caseDir in $cases) {
        $folder=Join-Path $caseDir.FullName 'Cleanup\PersistentAMTrace'
        if((Test-Path -LiteralPath $folder -PathType Container) -and !(Test-Path -LiteralPath (Join-Path $folder 'State.json') -PathType Leaf)) {
            throw "The trace backup folder for $($caseDir.Name) has no restoration record. Retaining evidence for recovery."
        }
    }
    $TraceStates = @(Get-ChildItem -LiteralPath $CaseRoot -Filter 'State.json' -Recurse -File |
        Where-Object { $_.Directory.Name -eq 'PersistentAMTrace' })
    $ActiveStates = @($TraceStates | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Restored -ne $true
    })
    if ($ActiveStates.Count -gt 1) { throw 'Multiple unrestored INI states found. Resolve their order before deleting any backups.' }
    foreach ($TraceState in $ActiveStates) {
        $ActualCase = $TraceState.Directory.Parent.Parent.FullName
        Restore-PersistentAMTrace -Case $ActualCase
    }
    if (!$ActiveStates.Count -and $TraceStates.Count) {
        $latest=$TraceStates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        Restore-PersistentAMTrace -Case $latest.Directory.Parent.Parent.FullName
    }
    if (-not $TraceStates.Count -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'ds_agent.ini'))) {
        Write-Warning 'No saved INI state found. Existing ds_agent.ini was left unchanged; review whether earlier test logging is still enabled.'
    }
    # Restore the original DSA tool JSON when the consolidated Phase A script changed it.
    $PhaseStates = @(Get-ChildItem -LiteralPath $CaseRoot -Filter 'PhaseA-state.json' -Recurse -File | Sort-Object LastWriteTimeUtc -Descending)
    $PendingConfig = @($PhaseStates | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).ConfigRestored -ne $true
    })
    if ($PendingConfig.Count -gt 1) { throw 'Multiple unrestored JSON states found. Review them before deleting backups.' }
    foreach ($PhaseFile in $PendingConfig) {
        $Phase = Get-Content -LiteralPath $PhaseFile.FullName -Raw | ConvertFrom-Json
        $ActualCase = $PhaseFile.Directory.Parent.FullName
        $Original = Join-Path $ActualCase 'Trend\DSTool-original.json'
        $Config = Join-Path $ToolRoot 'DSASupportTool\DSTool.json'
        if (-not (Test-Path -LiteralPath $Original -PathType Leaf) -or
            (Get-FileHash -LiteralPath $Original -Algorithm SHA256).Hash -ne $Phase.ConfigOriginalHash) {
            throw 'Original DSA JSON backup missing or changed. Cases have not been deleted.'
        }
        $CurrentHash = if (Test-Path -LiteralPath $Config -PathType Leaf) { (Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash } else { $null }
        if ($CurrentHash -notin @($Phase.ConfigOriginalHash, $Phase.ConfigAppliedHash) -or -not $CurrentHash) {
            throw 'DSA JSON changed after preparation. Review before overwriting or deleting the backup.'
        }
        Copy-Item -LiteralPath $Original -Destination $Config -Force
        if ((Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash -ne $Phase.ConfigOriginalHash) { throw 'DSA JSON restore verification failed.' }
        $Phase.ConfigRestored = $true
        $Phase | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PhaseFile.FullName -Encoding UTF8
    }
    if (!$PendingConfig.Count -and $PhaseStates.Count) {
        $last=Get-Content -LiteralPath $PhaseStates[0].FullName -Raw|ConvertFrom-Json
        if ($last.ConfigOriginalHash) {
            $config=Join-Path $ToolRoot 'DSASupportTool\DSTool.json'
            if (!(Test-Path -LiteralPath $config -PathType Leaf) -or (Get-FileHash -LiteralPath $config).Hash -ne $last.ConfigOriginalHash) {
                throw 'The current metrics configuration differs from the restored baseline. Retaining the case backups.'
            }
        }
    }
    $Allowed = @(
        'Microsoft-Windows-GroupPolicy/Operational'
        'Microsoft-Windows-User Profile Service/Operational'
        'Microsoft-Windows-Diagnostics-Performance/Operational'
        'Microsoft-Windows-Shell-Core/Operational'
        'Microsoft-Windows-Winlogon/Operational'
        'Microsoft-Windows-TaskScheduler/Operational'
    )
    $ChannelFiles = @(Get-ChildItem -LiteralPath $CaseRoot -Filter 'Original-channel-state.csv' -Recurse -File | Sort-Object LastWriteTimeUtc)
    $Restored = @{}
    foreach ($File in $ChannelFiles) {
        foreach ($Entry in (Import-Csv -LiteralPath $File.FullName)) {
            if ($Entry.Name -notin $Allowed -or $Entry.WasEnabled -notin @('True','False')) { throw 'Unexpected event-channel restore data. Stop for review.' }
            if (-not $Restored.ContainsKey($Entry.Name)) {
                & wevtutil.exe sl $Entry.Name (('/e:{0}' -f $Entry.WasEnabled.ToLowerInvariant()))
                if ($LASTEXITCODE -ne 0) { throw "Could not restore $($Entry.Name). Cases have not been deleted." }
                $channel=Get-WinEvent -ListLog $Entry.Name -ErrorAction Stop
                if([bool]$channel.IsEnabled -ne [bool]::Parse($Entry.WasEnabled)){throw "Event-channel readback failed: $($Entry.Name)"}
                $Restored[$Entry.Name] = $true
            }
        }
    }
    if (-not $ChannelFiles.Count) { Write-Warning 'Original channel states missing. Unknown channel settings were left unchanged.' }
    if ($KeepEvidence) {
        foreach ($dir in $cases) {
            $phaseFile = Join-Path $dir.FullName 'Cleanup\PhaseA-state.json'
            if (!(Test-Path -LiteralPath $phaseFile -PathType Leaf)) { continue }
            $phase = Get-Content -LiteralPath $phaseFile -Raw | ConvertFrom-Json
            if ($phase.CasePath -and $phase.ConfigRestored) {
                $closed = Join-Path $dir.FullName 'Cleanup\Collector-closed.json'
                if (!(Test-Path -LiteralPath $closed)) {
                    $sysMain = try { Get-Service SysMain -ErrorAction Stop | Select-Object Name,Status,StartType } catch { $_.Exception.Message }
                    $defender = try { Get-MpComputerStatus -ErrorAction Stop | Select-Object AMRunningMode,AntivirusEnabled,RealTimeProtectionEnabled,AMProductVersion } catch { $_.Exception.Message }
                    [pscustomobject]@{ RunId=$phase.RunId; RestoredAtUtc=[datetime]::UtcNow.ToString('o'); SysMain=$sysMain; Defender=$defender } |
                        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $closed -Encoding UTF8
                }
            }
        }
        Write-Host "Settings restored. Case evidence retained: $CaseRoot"
    } else {
        Assert-HandoffsOutsideRoot $CaseRoot
        Set-Location -LiteralPath $env:SystemRoot
        Remove-Item -LiteralPath $CaseRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $CaseRoot) { throw 'Case root still exists; cleanup deletion was not completed.' }
        Write-Host "Deleted all test cases and archives under: $CaseRoot"
    }
} else { Write-Host 'Case root already absent.' }
& $Wpr -status
Write-Host "Retained tools, scripts and tool-generated files: $ToolRoot"
Write-Host 'Installed Trend logs/metrics and Windows event logs were not deleted.'
Write-Host 'Restore the recorded computer-specific self-protection state/inheritance in the management console now.'
Write-Host 'If Procmon was used, verify Enable Boot Logging is unchecked. This script does not change its registry/driver settings.'
}


if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell, not the x86 host.' }
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$null = Assert-LocalEvidencePath -Path $Case
$requested = if ($PSBoundParameters.ContainsKey('Case')) { $Case }
if ($Stage -eq 'Gui' -and !(Test-CollectorDesktop)) {
    if ($PSBoundParameters.ContainsKey('Stage')) { throw 'The GUI needs an interactive Windows desktop. Use -Stage Help or another CLI stage.' }
    $Stage = 'Help'
}
# Serialize operator changes across logon sessions. The scheduled worker and
# early snapshot intentionally run in parallel with the operator's stage.
$gate = $null
$held = $false
try {
    if ($Stage -notin 'Help','Gui','Status','CaptureMetrics','SaveDebug' -or ($Stage -eq 'SaveDebug' -and $Pass -eq 'PassB')) {
        $gate = [Threading.Mutex]::new($false,'Global\SWP-Perf-Operator')
        try { $held = $gate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Another collector action is in progress. Run Status or wait for it to finish.' }
    }
    if ($Stage -eq 'Prepare' -or (!$requested -and $Stage -notin 'Help','Gui','InstallTools','Cleanup','CaptureMetrics')) {
        $Case = Select-CollectionCase $Stage @(Get-CaseCatalog) $requested
        $StatePath = Join-Path $Case 'Cleanup\PhaseA-state.json'
    }
    switch ($Stage) {
    'Help' {
        Write-Host 'Open the script on the desktop for the GUI. All explicit collection stages run directly from PowerShell.'
        Write-Host 'Prepare allocates the next CASE number. Later stages resolve the active case; use -Case for an explicit path.'
        Write-Host 'SWP-Perf.ps1: Prepare -> manual reboot/login/apps -> StopTrace -> FinishAndPackage'
        Write-Host 'Other actions: InstallTools, Finish, Diagnostics, Package, Status, PrepareB, SaveDebug -Pass PassB, FinishB, RestoreTrace, CollectContext, Cleanup.'
        Write-Host 'Keep this script in C:\Program Files\SWP-PerfTools. Extract the DSA CMD package first; handle self-protection in the console.'
        Write-Host 'Cleanup deletes ALL C:\SWP-Perf, including archives there. Transfer ZIP and SHA256 first.'
        Write-Host 'Run Get-Help .\SWP-Perf.ps1 -Full for requirements and examples.'
    }
    'Gui' { Show-CollectorWindow -RequestedCase $requested }
    'InstallTools' {
        $installed = Join-Path $ToolRoot 'SWP-Perf.ps1'
        if ((Test-Path -LiteralPath $installed) -and (Get-FileHash $installed).Hash -ne (Get-FileHash $PSCommandPath).Hash -and
            @(Get-CaseCatalog | Where-Object Open).Count) { throw 'Finish and restore the active case using its installed version before upgrading.' }
        Install-BundledTools -KitRoot $PSScriptRoot
        try { Install-CollectorShortcut } catch { Write-Warning "CLI tools installed. Start menu shortcut unavailable: $_" }
    }
    'CaptureMetrics' { Invoke-MetricsWorker }
    'Prepare' { Invoke-Prepare }
    'StopTrace' { Invoke-StopTrace }
    'Finish' { Invoke-Finish -Pass 'PassA' }
    'RecoverAndPackage' { Invoke-Finish -Pass $Pass -Recovery; New-CaseArchive }
    'FinishAndPackage' { Invoke-Finish -Pass 'PassA'; New-CaseArchive }
    'PrepareB' { Invoke-PrepareB }
    'FinishB' { Invoke-Finish -Pass 'PassB' }
    'SaveDebug' {
        Read-CollectionState -Pass $Pass -RequireReboot:($Pass -eq 'PassB')
        if ($Pass -eq 'PassB') {
            if ($State.Finished -or $State.PreparationComplete -eq $false) { throw 'Pass B is not ready for an early snapshot.' }
            Set-PassBReproductionEnd 'EarlySnapshot'
        }
        Save-AMDebug -Label "$Pass-Early"
        if ($Pass -eq 'PassB') {
            $State | Add-Member -NotePropertyName EarlyDebugSavedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            Save-State
            try { Save-PassBMilestones } catch { $_.Exception.Message | Out-File "$Case\Procmon\SignIn-milestone-error.txt" }
        }
    }
    'Diagnostics' {
        Assert-CollectorsStopped
        if (Test-Path -LiteralPath $StatePath) { Read-CollectionState -Pass 'PassA' }
        if (!(Test-DiagnosticPending $Case) -and (Test-Path -LiteralPath $AmspDebug -PathType Container)) {
            try { Save-AMDebug -Label 'Diagnostics-RawDebug' }
            catch { Write-Warning "Raw debug snapshot failed: $($_.Exception.Message). Continuing with the agent diagnostic." }
        }
        $diagnostic=Request-AgentDiagnostics
        $diagnostic | Format-List
        if ($diagnostic.Status -ne 'Succeeded') { throw "Diagnostic status: $($diagnostic.Status). $($diagnostic.Message)" }
    }
    'CollectContext' {
        if (-not (Test-Path -LiteralPath $Case -PathType Container)) { throw 'Prepare the case before collecting context.' }
        Save-LoginContext
    }
    'Package' { New-CaseArchive -ResumePendingDiagnostic }
    'RestoreTrace' { Restore-PersistentAMTrace -Case $Case }
    'Status' { Show-Status }
    'Cleanup' { Invoke-Cleanup }
}
} finally {
    if ($held) { $gate.ReleaseMutex() }
    if ($gate) { $gate.Dispose() }
}
