#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [string]$VendorKitRoot='',
    [string]$ResultsFolder='C:\SWP-Analysis\CollectionScript-TestResults',
    [switch]$LongPublicationTest,
    [switch]$Baseline
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$SourcePath=(Resolve-Path -LiteralPath $SourcePath).ProviderPath
$SourceHashBefore=(Get-FileHash -LiteralPath $SourcePath).Hash
$Tokens=$null; $ParseErrors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
function Import-CollectorFunctions {
    foreach ($Statement in $Ast.EndBlock.Statements) {
        if ($Statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
            # Define functions in the caller's script scope, without running script actions.
            . ([scriptblock]::Create($Statement.Extent.Text.Replace('function '+$Statement.Name+' {','function script:'+$Statement.Name+' {')))
        }
    }
}
Import-CollectorFunctions
function Assert-True { param($Value,[string]$Message) if (-not $Value) { throw $Message } }
function Assert-Throws { param([scriptblock]$Action,[string]$Message) $Threw=$false;try { & $Action | Out-Null } catch { $Threw=$true };Assert-True $Threw $Message }
$Results=[Collections.Generic.List[object]]::new()
function Test-Case {
    param([string]$Name,[scriptblock]$Action)
    try { & $Action; $Results.Add([pscustomobject]@{Name=$Name;Status='PASS';Error=$null}); Write-Host "PASS $Name" }
    catch { $Results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.ToString()}); Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
$fixtureBase=if ($env:RUNNER_TEMP) {$env:RUNNER_TEMP} else {[IO.Path]::GetFullPath($env:TEMP)}
$Root=Join-Path $fixtureBase ('SWP Collector Tests '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
New-Item -ItemType Directory -Path $ResultsFolder -Force | Out-Null
$Case=Join-Path $Root 'CASE-Test'
$ToolFolder=Join-Path $Root 'Tool'
$Executable=Join-Path $ToolFolder 'DSASupportTool_CMD.exe'
$ArtifactWaitSeconds=0
$SkipDiagnostics=$true
$AgentFolder=Join-Path $Root 'Fake Agent'
$DiagnosticFolder=Join-Path $Root 'Assumed Diag'
$AmspDebug=Join-Path $Root 'Debug'
$LoginTask=@('\IntuneDriveMapping')
$LoginScriptPath=@(); $PolicyExportFolder=''
$Start=(Get-Date).ToUniversalTime().AddMinutes(-10)
$End=$Start.AddSeconds(20)
foreach ($Folder in @($Case,"$Case\Cleanup","$Case\WPR","$Case\Trend","$Case\Events",$ToolFolder,"$ToolFolder\logs",$AmspDebug)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
function New-RecordsText {
    param([datetime]$At=$Start,[int]$Count=5,[int]$Step=5,[string]$Computer=$env:COMPUTERNAME)
    @(for($I=0;$I -lt $Count;$I++) {
        [pscustomobject]@{eventType='Metrics';time=([datetimeoffset]$At.AddSeconds($I*$Step)).ToUnixTimeMilliseconds();hostname=$Computer;sample=@{} } | ConvertTo-Json -Compress
    }) -join "`r`n"
}
function New-ZipFixture {
    param([string]$Path,[string]$Text,[string]$Name='nested\records_jsonRecords.json')
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $Zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try { $Entry=$Zip.CreateEntry($Name);$Writer=[IO.StreamWriter]::new($Entry.Open());try {$Writer.Write($Text)}finally{$Writer.Dispose()} }finally{$Zip.Dispose()}
}
function Set-ValidNotes {
    [pscustomobject]@{CredentialSubmittedAt=$Start.AddSeconds(1).ToString('o');DesktopReadyAt=$Start.AddSeconds(2).ToString('o');Applications=@([pscustomobject]@{Name='Test app';LaunchAt=$Start.AddSeconds(3).ToString('o');ReadyAt=$Start.AddSeconds(6).ToString('o')})} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$Case\Operator-notes.json" -Encoding UTF8
}
try {
    if (!$Baseline) {
        Test-Case 'Next number accounts for gaps and retained handoffs' {
            $bucket=Join-Path $Root 'numbering'
            $handoff=Join-Path $Root 'handoff'
            Assert-True ((Split-Path (Get-NextCasePath $bucket $handoff) -Leaf) -eq 'CASE-01') 'First case'
            $null=New-Item -ItemType Directory "$bucket\CASE-01","$bucket\CASE-03","$bucket\CASE-custom",$handoff -Force
            Assert-True ((Split-Path (Get-NextCasePath $bucket $handoff) -Leaf) -eq 'CASE-04') 'Gap filled or custom name counted'
            $null=New-Item -ItemType File "$handoff\AllEvidence-CASE-12-20010615-120000-010.zip","$handoff\AllEvidence-CASE-99-20010615-120000-010.zip.partial"
            Assert-True ((Split-Path (Get-NextCasePath $bucket $handoff) -Leaf) -eq 'CASE-13') 'Handoff or partial incorrectly counted'
        }
        Test-Case 'GUI and CLI resolve the current run from persisted identity' {
            $bucket=Join-Path $Root 'routing'
            $folder=Join-Path $bucket 'CASE-02'
            $null=New-Item -ItemType Directory "$folder\Cleanup" -Force
            $phase=[pscustomobject]@{CasePath=$folder;RunId=[guid]::NewGuid().ToString('N');ComputerName=$env:COMPUTERNAME;ConfigRestored=$false}
            $file=Join-Path $folder 'Cleanup\PhaseA-state.json'
            $phase|ConvertTo-Json|Set-Content $file
            $open=@(Get-CaseCatalog $bucket)
            Assert-True ((Select-CollectionCase StopTrace $open) -eq $folder) 'Cannot resume active case'
            Assert-Throws {Select-CollectionCase Prepare $open 'C:\SWP-Perf\CASE-04'} 'Started a second case'
            $phase.ConfigRestored=$true;$phase|ConvertTo-Json|Set-Content $file
            Assert-True (@(Get-CaseCatalog $bucket | Where-Object Open).Count -eq 1) 'Partial restoration closed case'
            @{RunId=$phase.RunId}|ConvertTo-Json|Set-Content "$folder\Cleanup\Collector-closed.json"
            Assert-True (@(Get-CaseCatalog $bucket | Where-Object Open).Count -eq 0) 'Restored case still active'
            $phase.CasePath+='-moved';$phase|ConvertTo-Json|Set-Content $file
            Assert-Throws {Get-CaseCatalog $bucket} 'Moved active identity accepted'
        }
        Test-Case 'Ambiguous cases require explicit selection' {
            $a=[pscustomobject]@{Path='C:\SWP-Perf\CASE-01';Open=$true}
            $b=[pscustomobject]@{Path='C:\SWP-Perf\CASE-02';Open=$true}
            Assert-Throws { Select-CollectionCase Status @($a,$b) } 'Guessed among two active runs'
            $a.Open=$false;$b.Open=$false
            Assert-Throws { Select-CollectionCase Package @($a,$b) } 'Guessed among two retained cases'
            Assert-True ((Select-CollectionCase Package @($a,$b) $b.Path) -eq $b.Path) 'Explicit selection failed'
        }
        Test-Case 'Dashboard maps restart, stop, finish, recovery and handoff' {
            $dir=Join-Path $Root 'View'
            $null=New-Item -ItemType Directory "$dir\Cleanup","$dir\WPR" -Force
            $boot=[datetime]::UtcNow
            $phase=[pscustomobject]@{Scenario='Reboot';PreparedBoot=$boot.ToString('o');Armed=$true;TraceSaved=$false;Finished=$false}
            $entry=[pscustomobject]@{Path=$dir;Phase=$phase;Open=$true}
            Assert-True ((Get-CollectorView $null $false $boot).Action -eq 'InstallTools') 'Install missing'
            Assert-True ((Get-CollectorView $null $true $boot).Action -eq 'Prepare') 'Prepare missing'
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'Instructions') 'Stop offered before restart'
            $message = (Get-CollectorView $entry $true $boot).Message
            Assert-True ($message.Contains('stay at the sign-in screen') -and $message.Contains("-Stage CheckSignInReady -Pass PassA -Case '$dir'")) 'Missing Pass A participant or administrator instruction'
            Assert-True ((Get-CollectorView $entry $true $boot.AddMinutes(1)).Action -eq 'StopTrace') 'Stop missing'
            '{"Saved":false}'|Set-Content "$dir\WPR\Trace-quality.json"
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'Review') 'Failure hidden'
            $phase.TraceSaved=$true
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'FinishAndPackage') 'Finish missing'
            $phase.Finished=$true
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'Package') 'Package missing'
            '{}'|Set-Content "$dir\Cleanup\Handoff-receipt.json"
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'OpenHandoff') 'Receipt hidden'
            Assert-True (Get-CollectorView $entry $true $boot).CanPrepareB 'Optional repeat missing after handoff'
            $b=[pscustomobject]@{PreparedBoot=$boot.ToString('o');PreparationComplete=$false;Finished=$false;EarlyDebugSavedUtc=$null}
            $bp=Join-Path $dir 'Cleanup\PhaseB-state.json'
            $b|ConvertTo-Json|Set-Content $bp
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'Review') 'Partial preparation offered a restart'
            $b.PreparationComplete=$true; $b|ConvertTo-Json|Set-Content $bp
            Assert-True ((Get-CollectorView $entry $true $boot).Action -eq 'Instructions') 'B offered premature finish'
            $message = (Get-CollectorView $entry $true $boot).Message
            Assert-True ($message.Contains('Enable Boot Logging') -and $message.Contains("-Pass PassB -Case '$dir'")) 'Missing Pass B Procmon or readiness instruction'
            $view=Get-CollectorView $entry $true $boot.AddMinutes(1)
            Assert-True ($view.Action -eq 'SaveDebugB' -and $view.ActiveB -and $view.NotesPass -eq 'PassB') 'Missing B capture routing'
            $b.EarlyDebugSavedUtc=$boot.AddMinutes(1).ToString('o'); $b|ConvertTo-Json|Set-Content $bp
            Assert-True ((Get-CollectorView $entry $true $boot.AddMinutes(2)).Action -eq 'FinishB') 'B finish missing'
        }
    }
    if (!$Baseline) {
        Test-Case 'Cold sign-in readiness requires a new paired scan while the console is held' {
            $State = [pscustomobject]@{Scenario='Reboot';ComputerName=$env:COMPUTERNAME;RunId=('a'*32);Finished=$false;PreparationComplete=$true}
            function Read-CollectionState { param($Pass,[switch]$RequireReboot) Assert-True $RequireReboot 'Boot validation skipped' }
            function Assert-CaseTrace { param($Owner) Assert-True ($Owner -eq $State) 'Missing Pass A ownership check' }
            $fixture = @{ Attempts=0; ConsoleReads=0; LoginAt=0; PairAt=2 }
            function Get-CimInstance {
                param($ClassName,$ErrorAction)
                if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=$Start} }
                $fixture.ConsoleReads++
                $user = if ($fixture.LoginAt -and $fixture.ConsoleReads -ge $fixture.LoginAt) { 'fixture\user' }
                [pscustomobject]@{UserName=$user}
            }
            function Get-FreshScanControl {
                param($WaitSeconds)
                $fixture.Attempts++
                if ($fixture.Attempts -eq $fixture.PairAt) { [pscustomobject]@{Path='C:\fixture\unique.exe';EngineMicroseconds=462} }
            }
            Confirm-ColdSignInReady PassA
            $result = Get-Content "$Case\Trend\PassA-Cold-signin-control.json" -Raw | ConvertFrom-Json
            Assert-True ($result.Status -eq 'Observed' -and $result.RunId -eq $State.RunId -and $result.Pairs.Count -eq 1 -and $fixture.Attempts -eq 2) 'Missing fresh evidence or retry'
            $fixture.Attempts=0; $fixture.PairAt=0
            Assert-Throws { Confirm-ColdSignInReady PassA } 'Timeout released user'
            $result = Get-Content "$Case\Trend\PassA-Cold-signin-control.json" -Raw | ConvertFrom-Json
            Assert-True ($result.Status -eq 'Unverified' -and !$result.Pairs.Count -and $fixture.Attempts -eq 3) 'Stale proof or unbounded retries'
            $fixture.Attempts=0; $fixture.PairAt=1; $fixture.ConsoleReads=0; $fixture.LoginAt=2
            Assert-Throws { Confirm-ColdSignInReady PassB } 'User signed in during check'
            $fixture.Attempts=0
            Assert-Throws { Confirm-ColdSignInReady PassB } 'Active console accepted'
            Assert-True ($fixture.Attempts -eq 0) 'Ran a probe after console sign-in'
            $State.Scenario='SignOutSignIn'
            Assert-Throws { Confirm-ColdSignInReady PassA } 'Wrong scenario accepted'
        }
        Test-Case 'Pass B desktop buttons run the correct CLI stages in both finish and recovery workflows' {
            $ToolRoot=Join-Path $Root 'WpfTools'
            $null=New-Item -ItemType Directory $ToolRoot
            $uiScript=Join-Path $ToolRoot 'SWP-Perf.ps1'
            $Executable=$uiScript
            @'
param($Stage,$Pass,$Case)
@{Stage=$Stage;Pass=$Pass;Case=$Case}|ConvertTo-Json -Compress|Add-Content "$Case\actions.jsonl"
$file=Join-Path $Case 'Cleanup\PhaseB-state.json'
switch ($Stage) {
    'PrepareB' { @{PreparedBoot='2001-01-01T00:00:00Z';PreparationComplete=$true;Finished=$false}|ConvertTo-Json|Set-Content $file }
    'SaveDebug' { $b=Get-Content $file -Raw|ConvertFrom-Json; $b|Add-Member -NotePropertyName EarlyDebugSavedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o'));$b|ConvertTo-Json|Set-Content $file }
    'FinishB' { $b=Get-Content $file -Raw|ConvertFrom-Json;$b.Finished=$true;$b|ConvertTo-Json|Set-Content $file }
}
'@ | Set-Content -LiteralPath $uiScript
            $realFactory=(Get-Command New-CollectorWindow).ScriptBlock
            function Confirm-CollectorAction { $true }
            function Get-CaseCatalog { [pscustomobject]@{Path=$guiCase;Open=$true;Phase=[pscustomobject]@{Finished=$true;TraceSaved=$true}} }
            function New-CollectorWindow {
                $w=& $realFactory
                $script:guiProbe.Window=$w
                $w
            }
            foreach ($recover in $false,$true) {
                $guiCase=Join-Path $Root ("GuiCase-"+$recover)
                $null=New-Item -ItemType Directory "$guiCase\Cleanup","$guiCase\Procmon" -Force
                '{}'|Set-Content "$guiCase\Procmon\Operator-notes.json"
                Add-Type -AssemblyName PresentationFramework
                $script:guiProbe=@{Step=0;Error='';Window=$null;Deadline=[datetime]::UtcNow.AddSeconds(90)}
                $driver=[Windows.Threading.DispatcherTimer]::new()
                $driver.Interval=[TimeSpan]::FromMilliseconds(150)
                $driver.Add_Tick({
                    $w=$script:guiProbe.Window
                    if (!$w) {return}
                    try {
                        if ($w.FindName('Title').Text -eq 'Case requires review' -or [datetime]::UtcNow -gt $script:guiProbe.Deadline) {
                            throw "Window at step $($script:guiProbe.Step): $($w.FindName('Title').Text), $($w.FindName('ProgressLabel').Text), $($w.FindName('Instruction').Text), $($w.FindName('Output').Text)"
                        }
                        $primary=$w.FindName('Primary')
                        if (!$primary.IsEnabled) {return}
                        $other=$w.FindName('Other')
                        $button=$primary
                        switch ($script:guiProbe.Step) {
                            0 {$other.SelectedItem='Prepare Pass B';$button=$w.FindName('RunOther')}
                            1 {
                                if ($primary.Content -ne 'Save Pass B early logs') {throw "Unexpected post-restart button: $($primary.Content)"}
                                if($recover){$other.SelectedItem='Recover Pass B and package';$button=$w.FindName('RunOther')}
                            }
                            2 {
                                if ($recover) {$driver.Stop();$w.Close();return}
                                if ($primary.Content -ne 'Finish B') {throw 'Early snapshot did not advance the dashboard'}
                            }
                            3 {if ($primary.Content -ne 'Package case') {throw 'B did not advance to packaging'}}
                            4 {$driver.Stop();$w.Close();return}
                        }
                        $script:guiProbe.Step++
                        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    } catch {$script:guiProbe.Error=$_.Exception.Message;$driver.Stop();$w.Close()}
                })
                $driver.Start()
                try { Show-CollectorWindow -RequestedCase $guiCase -SourcePath $uiScript } finally {$driver.Stop()}
                Assert-True (!$script:guiProbe.Error) $script:guiProbe.Error
                $actions=@(Get-Content "$guiCase\actions.jsonl"|ForEach-Object {$_|ConvertFrom-Json})
                $expected=if($recover){'PrepareB,RecoverAndPackage'}else{'PrepareB,SaveDebug,FinishB,Package'}
                Assert-True (($actions.Stage -join ',') -eq $expected -and $actions[1].Pass -eq 'PassB' -and !@($actions|Where-Object Case -ne $guiCase).Count) "Incorrect GUI dispatch: $($actions | ConvertTo-Json -Compress)"
            }
        }
    }
    Test-Case 'StopTrace snapshots before merge' {
        $script:Calls=[Collections.Generic.List[string]]::new()
        function script:Read-CollectionState { param($Pass,[switch]$RequireReboot) $script:State=[pscustomobject]@{TraceSaved=$false};$script:StatePath="$Case\Cleanup\PhaseA-state.json" }
        if (!$Baseline) {
            function script:Assert-CaseTrace {param($Owner,[switch]$BeforeBoot)}
            function script:Start-EarlySnapshot {
                Save-AMDebug 'PassA-Early'
                $child=[pscustomobject]@{Handle=0;ExitCode=0}
                $child|Add-Member ScriptMethod WaitForExit {};$child|Add-Member ScriptMethod Dispose {}
                return $child
            }
            function script:Save-SignInMilestones {}
        }
        function script:Get-WprPath { 'fixture-wpr.exe' }
        function script:Get-CimInstance { param($ClassName) [pscustomobject]@{LastBootUpTime=$Start} }
        function script:Save-AMDebug { param($Label) $Calls.Add('Snapshot') }
        function script:Start-Process {
            param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$Wait,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
            $Calls.Add('Save');'fixture ETL'|Set-Content -LiteralPath "$Case\WPR\PassA-BootLoginApps.etl"
            'The trace was successfully saved. This trace has dropped 4154278 events.'|Set-Content -LiteralPath $RedirectStandardOutput
            ''|Set-Content -LiteralPath $RedirectStandardError
            [pscustomobject]@{ExitCode=0}
        }
        Remove-Item -LiteralPath "$Case\WPR\PassA-BootLoginApps.etl" -ErrorAction SilentlyContinue
        Invoke-StopTrace
        Assert-True ($Calls[0] -eq 'Snapshot' -and $Calls[1] -eq 'Save') 'Snapshot happened after merge.'
        if (-not $Baseline) {
            $Quality=Get-Content -LiteralPath "$Case\WPR\Trace-quality.json" -Raw|ConvertFrom-Json
            Assert-True ($Quality.ReportedDroppedEvents -eq 4154278 -and $Quality.Status -eq 'SavedWithEventLoss') 'Lost events were not recorded.'
        }
    }
    Test-Case 'Debug copy failure does not prevent StopTrace' {
        $Calls.Clear()
        function script:Save-AMDebug { param($Label) $Calls.Add('Snapshot');throw 'fixture copy denied' }
        Remove-Item -LiteralPath "$Case\WPR\PassA-BootLoginApps.etl" -ErrorAction SilentlyContinue
        Invoke-StopTrace
        Assert-True ($Calls -contains 'Save') 'WPR was left recording after snapshot failure.'
        Assert-True (Test-Path -LiteralPath "$Case\WPR\Early-debug-copy-error.txt") 'Early copy error missing.'
    }
    Remove-Item Function:\Start-Process,Function:\Get-CimInstance -ErrorAction SilentlyContinue
    Import-CollectorFunctions
    if (-not $Baseline) {
        Test-Case 'State dates preserve typed values and existing supported formats' {
            Assert-True ((Parse-StateDateTime $Start).ToUniversalTime() -eq $Start) 'Typed DateTime changed.'
            $Offset=[datetimeoffset]::new($Start)
            Assert-True ((Parse-StateDateTime $Offset).ToUniversalTime() -eq $Start) 'Typed DateTimeOffset changed.'
            Assert-True ((Parse-StateDateTime $Start.ToString('o')).ToUniversalTime() -eq $Start) 'ISO roundtrip failed.'
            Assert-True ((Parse-StateDateTime '2001-01-01T01:00:00+01:00') -eq (Parse-StateDateTime '2001-01-01T00:00:00Z')) 'Operator times without fractional seconds lost their offset.'
            Assert-True ((Parse-StateDateTime '15/06/2001 08.09.10').Year -eq 2001) 'Existing European state format lost.'
        }
        if ($VendorKitRoot) {
            Test-Case 'Bundled tools install, verify and preserve existing configuration' {
                $ToolRoot=Join-Path $Root 'Installed Tools';$ConfigPath=Join-Path $ToolRoot 'DSASupportTool\DSTool.json'
                Install-BundledTools -KitRoot $VendorKitRoot
                Assert-True ((Test-Path -LiteralPath "$ToolRoot\DSASupportTool\DSASupportTool_CMD.exe") -and (Test-Path -LiteralPath "$ToolRoot\DSASupportTool_GUI\DSASupportTool_GUI.exe")) 'Bundled CMD or GUI missing.'
                $Original=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
                $Original.Metrics|Add-Member -NotePropertyName preservedTestField -NotePropertyValue 'keep'
                $Original|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
                $Hash=(Get-FileHash -LiteralPath $ConfigPath).Hash
                Install-BundledTools -KitRoot $VendorKitRoot
                Assert-True ((Get-FileHash -LiteralPath $ConfigPath).Hash -eq $Hash) 'Reinstall overwrote existing configuration.'
                $Config=Get-CollectionConfig
                Assert-True ($Config.Metrics.MetricsIntervalInSecond -eq 5 -and $Config.Metrics.MetricsDurationInSecond -eq 900 -and $Config.Metrics.preservedTestField -eq 'keep' -and $null -ne $Config.'Process Monitor'.timerInSecondProcMon) 'Collection JSON lost supplied fields.'
                $Original|Add-Member -NotePropertyName 'Unknown executable feature' -NotePropertyValue @{enable=1}
                $Original|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
                $Before=(Get-FileHash -LiteralPath $ConfigPath).Hash
                Assert-Throws {Get-CollectionConfig} 'Unrecognized feature was enabled silently.'
                Assert-True ((Get-FileHash -LiteralPath $ConfigPath).Hash -eq $Before) 'Rejected JSON was modified.'
            }
        }
        Test-Case 'Exact diagnostic response path with brackets and spaces' {
            $Path=Get-DiagnosticResponsePath -Text "HTTP Status: 200 - OK`r`npath = $Root\Native Output`r`nfile name = diag-[fresh].zip"
            Assert-True ($Path -eq "$Root\Native Output\diag-[fresh].zip") 'Response path incorrectly parsed.'
            Assert-Throws {Get-DiagnosticResponsePath -Text "path = $Root`nfile name = ..\old.zip"} 'Traversal filename accepted.'
        }
        $MetricsZip=Join-Path $ToolFolder ('DSTool-METRICS-test-['+$env:COMPUTERNAME+'].zip')
        New-ZipFixture -Path $MetricsZip -Text (New-RecordsText)
        Test-Case 'Metrics ZIP content and five-second cadence without loose JSON' {
            $A=Get-ToolMetricsAssessment -Paths @($MetricsZip) -SinceUtc $Start -RequiredEndUtc $End
            Assert-True ($A.ArtifactRecordsVerified -and $A.UniqueSampleTimes -eq 5 -and $A.MedianIntervalSeconds -eq 5 -and $A.EvidenceGaps.Count -eq 0) ($A|ConvertTo-Json -Depth 5)
        }
        Test-Case 'Metrics ZIP is copied from completion log outside tool folder' {
            $Outside=Join-Path $Root 'Other Output\DSTool-METRICS-[outside].zip';New-ZipFixture -Path $Outside -Text (New-RecordsText)
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss,fff') [INFO] Metrics Collection DONE! The logfile is $Outside."|Set-Content -LiteralPath "$ToolFolder\logs\DSA_SupportTool.log"
            $PassFolder=Join-Path $Case 'Trend\PassA';New-Item -ItemType Directory $PassFolder|Out-Null
            $A=Copy-ToolMetrics -PassFolder $PassFolder -SinceUtc $Start -RequiredEndUtc $End
            $Copied=@(Get-ChildItem -LiteralPath "$PassFolder\VerifiedToolMetrics" -Recurse -Filter '*.zip')
            Assert-True ($Copied.Count -eq 2 -and $A.ArtifactRecordsVerified) 'Explicit outside/bracketed metrics archive was not copied.'
            Assert-True (@(Get-ChildItem -LiteralPath "$PassFolder\VerifiedToolMetrics" -Recurse -Filter 'Source.json').Count -eq 2) 'Copy hashes/provenance missing.'
        }
        Test-Case 'Missing metrics is not verified on task success alone' {
            $A=Get-ToolMetricsAssessment -Paths @() -SinceUtc $Start -RequiredEndUtc $End
            Assert-True (-not $A.ArtifactRecordsVerified -and $A.EvidenceGaps.Count -gt 0) 'Missing metrics falsely passed.'
        }
        Test-Case 'Slow, old and wrong-computer metrics rejected or flagged' {
            $Slow=Join-Path $Root 'slow_jsonRecords.json';New-RecordsText -Step 20 | Set-Content -LiteralPath $Slow
            $A=Get-ToolMetricsAssessment -Paths $Slow -SinceUtc $Start -RequiredEndUtc $End
            Assert-True ($A.CadenceStatus -eq 'NotNearFiveSeconds') 'Slow normal metrics treated as five-second data.'
            $Old=Join-Path $Root 'old_jsonRecords.json';New-RecordsText -At $Start.AddDays(-1)|Set-Content -LiteralPath $Old
            Assert-True (-not (Get-ToolMetricsAssessment -Paths $Old -SinceUtc $Start).ArtifactRecordsVerified) 'Old metrics accepted.'
            $Other=Join-Path $Root 'other_jsonRecords.json';New-RecordsText -Computer 'another-host'|Set-Content -LiteralPath $Other
            Assert-True (-not (Get-ToolMetricsAssessment -Paths $Other -SinceUtc $Start).ArtifactRecordsVerified) 'Wrong host metrics accepted.'
        }
        Test-Case 'Malformed and empty metrics ZIPs do not verify' {
            $Bad=Join-Path $Root 'bad.zip';'not a ZIP'|Set-Content -LiteralPath $Bad
            $Empty=Join-Path $Root 'empty.zip';New-ZipFixture -Path $Empty -Text '{}' -Name 'unrelated.json'
            foreach($Path in @($Bad,$Empty)) { Assert-True (-not (Get-ToolMetricsAssessment -Paths $Path -SinceUtc $Start).ArtifactRecordsVerified) "Bad metrics accepted: $Path" }
        }
        Test-Case 'Metrics initial gaps and internal gaps remain visible' {
            $Late=Join-Path $Root 'late_jsonRecords.json';New-RecordsText -At $Start.AddSeconds(25)|Set-Content -LiteralPath $Late
            $A=Get-ToolMetricsAssessment -Paths $Late -SinceUtc $Start -RequiredEndUtc $End
            Assert-True ($A.InitialGapSeconds -eq 25 -and $A.EvidenceGaps.Count -gt 0) 'Initial gap hidden.'
            $Internal=Join-Path $Root 'gap_jsonRecords.json'
            ((New-RecordsText -Count 3)+"`r`n"+(New-RecordsText -At $Start.AddSeconds(30) -Count 3))|Set-Content -LiteralPath $Internal
            $A=Get-ToolMetricsAssessment -Paths $Internal -SinceUtc $Start -RequiredEndUtc $End
            Assert-True ($A.MedianIntervalSeconds -eq 5 -and $A.MaximumGapSeconds -eq 20 -and $A.EvidenceGaps.Count -gt 0) 'Median cadence hid a real internal gap.'
        }
        Test-Case 'Repeated NDJSON samples preserve host identity and cadence' {
            $sampleZip = Join-Path $Root 'metrics-series.zip'
            $samples = New-RecordsText -At $Start -Count 121 -Computer 'fixture-endpoint'
            New-ZipFixture -Path $sampleZip -Text $samples
            $assessment = Get-ToolMetricsAssessment -Paths $sampleZip -SinceUtc $Start -RequiredEndUtc $Start.AddMinutes(10) -ExpectedComputer 'fixture-endpoint'
            Assert-True ($assessment.ArtifactRecordsVerified -and $assessment.UniqueSampleTimes -eq 121 -and $assessment.MedianIntervalSeconds -eq 5) 'The generated five-second series did not verify.'
        }
        Test-Case 'Fresh ZIP accepts literal brackets; stale ZIP is rejected' {
            $Ready=@(Get-ReadableFreshZip -Paths $MetricsZip -Before @{} -SinceUtc $Start -ErrorLog "$Root\zip-errors.txt")
            Assert-True ($Ready.Count -eq 1) 'Fresh bracketed ZIP not readable.'
            Assert-True (@(Get-ReadableFreshZip -Paths @($MetricsZip,$MetricsZip.ToUpperInvariant()) -Before @{} -SinceUtc $Start -ErrorLog "$Root\zip-errors.txt").Count -eq 1) 'Case variants of one ZIP returned twice.'
            $Before=@{};$F=Get-Item -LiteralPath $MetricsZip;$Before[$F.FullName]="$($F.Length):$($F.LastWriteTimeUtc.Ticks)"
            Assert-True (@(Get-ReadableFreshZip -Paths $MetricsZip -Before $Before -SinceUtc $Start -ErrorLog "$Root\zip-errors.txt").Count -eq 0) 'Unchanged pre-request ZIP accepted.'
        }
        Test-Case 'Unreadable ZIP errors are retained instead of treated as absence' {
            $Lock=[IO.File]::Open($MetricsZip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try { $Ready=@(Get-ReadableFreshZip -Paths $MetricsZip -Before @{} -SinceUtc $Start -ErrorLog "$Root\locked-errors.txt");Assert-True ($Ready.Count -eq 0) 'Locked ZIP accepted.' }
            finally{$Lock.Dispose()}
            Assert-True ((Get-Content -LiteralPath "$Root\locked-errors.txt" -Raw) -match 'process|access|sharing') 'Read/open failure reason missing.'
        }
        Test-Case 'Access-denied ZIP read is recorded' {
            $Denied=Join-Path $Root 'denied.zip';Copy-Item -LiteralPath $MetricsZip -Destination $Denied
            $Acl=Get-Acl -LiteralPath $Denied
            $Changed=Get-Acl -LiteralPath $Denied
            $Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $Rule=[Security.AccessControl.FileSystemAccessRule]::new($Sid,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.AccessControlType]::Deny)
            $Changed.AddAccessRule($Rule);Set-Acl -LiteralPath $Denied -AclObject $Changed
            try { Assert-True (@(Get-ReadableFreshZip -Paths $Denied -Before @{} -SinceUtc $Start -ErrorLog "$Root\denied-errors.txt").Count -eq 0) 'Access-denied ZIP accepted.' }
            finally { Set-Acl -LiteralPath $Denied -AclObject $Acl }
            Assert-True ((Get-Content -LiteralPath "$Root\denied-errors.txt" -Raw) -match 'denied|Unauthorized') 'Access-denied reason missing.'
        }
        Test-Case 'Original AM debug warning and disabled settings detection' {
            $Ini=Join-Path $Root 'ds_agent.ini';'Trace=AM,AMSP,dsp.am.*'|Set-Content -LiteralPath $Ini
            Assert-True (Get-AMTraceSetting $Ini).AMDebugRequested 'Pre-existing AM debug missed.'
            'Trace=OTHER'|Set-Content -LiteralPath $Ini
            Assert-True (-not (Get-AMTraceSetting $Ini).AMDebugRequested) 'Unrelated trace treated as AM debug.'
            'Trace=dsp.*'|Set-Content -LiteralPath $Ini
            Assert-True (Get-AMTraceSetting $Ini).AMDebugRequested 'Broader pre-existing trace wildcard missed.'
        }
        Test-Case 'Exact INI restoration and repeat-call drift protection' {
            $TestWindows=Join-Path $Root 'WindowsFixture';New-Item -ItemType Directory $TestWindows|Out-Null
            $Ini=Join-Path $TestWindows 'ds_agent.ini';$Recovery="$Case\Cleanup\PersistentAMTrace";New-Item -ItemType Directory $Recovery -Force|Out-Null
            [IO.File]::WriteAllText("$Recovery\ds_agent.ini.original","Trace=AM,AMSP,dsp.am.*`r`nOther=unchanged",[Text.Encoding]::Unicode)
            'Trace=*'|Set-Content -LiteralPath $Ini
            $S=[pscustomobject]@{IniPath=$Ini;OriginallyExisted=$true;OriginalHash=(Get-FileHash -LiteralPath "$Recovery\ds_agent.ini.original").Hash;AppliedHash=(Get-FileHash -LiteralPath $Ini).Hash;Restored=$false}
            $S|ConvertTo-Json|Set-Content -LiteralPath "$Recovery\State.json"
            $F=$Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Restore-PersistentAMTrace'}
            $Code=$F.Extent.Text.Replace("Join-Path `$env:SystemRoot 'ds_agent.ini'","Join-Path `$TestWindows 'ds_agent.ini'")
            . ([scriptblock]::Create($Code))
            function Restart-Service {param($Name,$ErrorAction) Assert-True ($Name -eq 'ds_agent') 'Wrong service requested.'}
            function Get-Service {param($Name) [pscustomobject]@{Name=$Name;Status='Running'}}
            Restore-PersistentAMTrace -Case $Case
            Assert-True ((Get-FileHash -LiteralPath $Ini).Hash -eq $S.OriginalHash) 'Original bytes not restored.'
            Assert-True (Get-Content -LiteralPath "$Recovery\Restored-trace-assessment.json" -Raw|ConvertFrom-Json).AMDebugRequested 'Restored original debug not reported.'
            'changed later'|Set-Content -LiteralPath $Ini
            Assert-Throws {Restore-PersistentAMTrace -Case $Case} 'Restored=true bypassed current-file verification.'
        }
        Test-Case 'Originally absent INI is removed without touching other files' {
            $TestWindows=Join-Path $Root 'NoOriginalWindows';New-Item -ItemType Directory $TestWindows|Out-Null
            $Ini=Join-Path $TestWindows 'ds_agent.ini';'Trace=AM'|Set-Content -LiteralPath $Ini
            $Other=Join-Path $TestWindows 'untouched.txt';'keep'|Set-Content -LiteralPath $Other
            $RestoreCase=Join-Path $Root 'RestoreAbsent';$Recovery="$RestoreCase\Cleanup\PersistentAMTrace";New-Item -ItemType Directory $Recovery -Force|Out-Null
            [pscustomobject]@{IniPath=$Ini;OriginallyExisted=$false;OriginalHash=$null;AppliedHash=(Get-FileHash -LiteralPath $Ini).Hash;Restored=$false}|ConvertTo-Json|Set-Content -LiteralPath "$Recovery\State.json"
            $F=$Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Restore-PersistentAMTrace'}
            . ([scriptblock]::Create($F.Extent.Text.Replace("Join-Path `$env:SystemRoot 'ds_agent.ini'","Join-Path `$TestWindows 'ds_agent.ini'")))
            function Restart-Service {param($Name,$ErrorAction)}
            function Get-Service {param($Name) [pscustomobject]@{Name=$Name;Status='Running'}}
            Restore-PersistentAMTrace -Case $RestoreCase
            Assert-True (-not (Test-Path -LiteralPath $Ini) -and (Get-Content -LiteralPath $Other) -eq 'keep') 'Absent-original restoration changed unrelated files.'
        }
        Test-Case 'WPR success does not claim zero loss or marker completeness' {
            $A=Get-WprSaveAssessment -Etl "$Case\WPR\PassA-BootLoginApps.etl" -ExitCode 0 -OutputText 'The trace was successfully saved.'
            Assert-True ($A.Status -eq 'SavedCoverageUnverified' -and -not $A.CompleteCoverageVerified -and -not $A.BootMarkersVerified) 'Save success overstates coverage.'
            Assert-True ((Get-WprSaveAssessment -Etl "$Root\absent.etl" -ExitCode 0 -OutputText 'success').Status -eq 'SaveFailed') 'Missing ETL accepted.'
        }
        Test-Case 'Template, filled, partial and reversed application notes' {
            '{"CredentialSubmittedAt":"","DesktopReadyAt":"","Applications":[]}'|Set-Content -LiteralPath "$Case\Operator-notes.json"
            Assert-True ((Get-OperatorNotesAssessment).Status -eq 'Incomplete') 'Blank template passed.'
            Set-ValidNotes;Assert-True ((Get-OperatorNotesAssessment).Status -eq 'Filled') 'Valid timing notes failed.'
            $N=Get-Content -LiteralPath "$Case\Operator-notes.json" -Raw|ConvertFrom-Json;$N.Applications+=@([pscustomobject]@{Name='Second app';LaunchAt='';ReadyAt=''})
            $N|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$Case\Operator-notes.json"
            Assert-True ((Get-OperatorNotesAssessment).Status -eq 'Incomplete') 'Incomplete second app passed.'
            Set-ValidNotes
            $N=Get-Content -LiteralPath "$Case\Operator-notes.json" -Raw|ConvertFrom-Json;$N.Applications[0].ReadyAt=$Start.ToString('o')
            $N|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$Case\Operator-notes.json"
            Assert-True ((Get-OperatorNotesAssessment).Status -eq 'Incomplete') 'Reversed application times passed.'
            Set-ValidNotes
            Assert-True ((Get-OperatorNotesAssessment -WindowStartUtc $Start -WindowEndUtc $Start.AddSeconds(4)).Status -eq 'Incomplete') 'Application readiness outside the reproduction window passed.'
        }
        Test-Case 'Evidence walker rejects junctions instead of following them' {
            $Safe=Join-Path $Root 'Walk';$Foreign=Join-Path $Root 'Foreign';New-Item -ItemType Directory $Safe,$Foreign|Out-Null
            'outside selected tree'|Set-Content -LiteralPath "$Foreign\foreign.txt"
            New-Item -ItemType Junction -Path "$Safe\Link" -Target $Foreign|Out-Null
            try { Assert-Throws {Get-RegularEvidenceFiles -Root $Safe} 'Junction was followed.' }
            finally { [IO.Directory]::Delete("$Safe\Link") }
        }
        Test-Case 'Scoped task XML and selected scripts/policy exports copied without execution' {
            function script:Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{TaskName=$TaskName;TaskPath=$TaskPath} }
            function script:Export-ScheduledTask { param($TaskName,$TaskPath) '<?xml version="1.0" encoding="UTF-16"?><Task><Name>IntuneDriveMapping</Name></Task>' }
            $Ps1=Join-Path $Root 'DriveMapping.ps1';'throw "THIS MUST NOT EXECUTE"'|Set-Content -LiteralPath $Ps1
            $Vbs=Join-Path $Root 'Helper.vbs';'WScript.Quit 10'|Set-Content -LiteralPath $Vbs
            $LoginScriptPath=@($Ps1,$Vbs);$PolicyExportFolder=Join-Path $Root 'Console Exports';New-Item -ItemType Directory $PolicyExportFolder|Out-Null
            '<FileList><File>C:\example.dll</File></FileList>'|Set-Content -LiteralPath "$PolicyExportFolder\exclusions.xml"
            Save-LoginContext
            $M=Get-ChildItem -LiteralPath "$Case\Context" -Recurse -Filter Context-manifest.json|Select-Object -Last 1
            $Data=Get-Content -LiteralPath $M.FullName -Raw|ConvertFrom-Json
            Assert-True (@($Data.Items|Where-Object Status -eq 'Copied').Count -eq 4) 'Task, scripts or policy export missing.'
            $TaskXml=($Data.Items|Where-Object Kind -eq 'Task').File
            $Doc=[Xml.XmlDocument]::new();$Doc.Load($TaskXml)
            Assert-True ($Doc.Task.Name -eq 'IntuneDriveMapping') 'Task XML byte encoding/declaration mismatch.'
            $LoginScriptPath=@();$PolicyExportFolder=''
        }
        Test-Case 'Real robocopy preserves bracketed evidence filenames' {
            'literal filename'|Set-Content -LiteralPath "$ToolFolder\sample[1].txt"
            $Target=Join-Path $Root 'RoboSnapshot'
            Copy-EvidenceFolder -Source $ToolFolder -Target $Target -Log "$Root\robocopy.log"
            Assert-True ((Get-Content -LiteralPath "$Target\sample[1].txt") -eq 'literal filename') 'Robocopy snapshot lost bracketed file.'
        }
        Test-Case 'Finish attempts restoration even when evidence and diagnostic steps fail' {
            function script:Read-CollectionState {param($Pass,[switch]$RequireReboot) $script:State=[pscustomobject]@{TraceSaved=$true;Finished=$false;PreparedAt=$Start.ToString('o');RecordedBootUtc=$Start.ToString('o');TraceStopRequestedAtUtc=$End.ToString('o')};$script:StatePath="$Case\Cleanup\PhaseA-state.json"}
            function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute=$Executable})}}
            function script:Test-MetricsTaskAction {param($Task,$PhaseState,$CasePath,$Phase) $true}
            function script:Get-ScheduledTaskInfo {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{LastRunTime=$Start;LastTaskResult=0}}
            function Export-ScheduledTask {param($TaskName,$TaskPath) throw 'fixture export failure'}
            function script:Disable-ScheduledTask {param($TaskName,$TaskPath)}
            function script:Get-CimInstance {param($ClassName,$Filter) if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{LastBootUpTime=$Start}}}
            function script:Copy-EvidenceFolder {param($Source,$Target,$Log) throw 'fixture snapshot failure'}
            function script:Copy-ToolMetrics {param($PassFolder,$SinceUtc,$RequiredEndUtc) throw 'fixture metrics failure'}
            function script:Save-AMDebug {param($Label) throw 'fixture debug failure'}
            function script:Request-AgentDiagnostics {throw 'fixture diagnostic failure'}
            function script:Restore-PersistentAMTrace {param($Case) $script:RestorationAttempted=$true}
            $script:RestorationAttempted=$false;$SkipDiagnostics=$false
            function wevtutil.exe {param($verb,$name,$path,$overwrite) 'event'|Set-Content -LiteralPath $path;$global:LASTEXITCODE=0}
            function Save-NativeEvidence {param($Command,$Arguments,$Output) }
            Invoke-Finish -Pass PassA
            $err=@(Get-ChildItem -LiteralPath "$Case\Trend" -Recurse -Filter 'Collection-errors.txt'|ForEach-Object {Get-Content -LiteralPath $_.FullName}) -join ' '
            Assert-True ($err -match 'fixture diagnostic failure' -and $err -match 'fixture export failure' -and (Test-Path -LiteralPath "$Case\Events\System.evtx")) 'Diagnosis or task-export failure prevented independent events or went unreported.'
            Assert-True $RestorationAttempted 'Copy/diagnostic failure bypassed INI restoration.'
        }
        Remove-Item Function:\Get-CimInstance,Function:\Disable-ScheduledTask -ErrorAction SilentlyContinue
        Import-CollectorFunctions
        Test-Case 'Native diagnostic command exact returned path copied and debug extracted' {
            function script:Assert-CollectorsStopped {}
            $AgentFolder=Join-Path $Root 'Fake Agent';$DiagnosticFolder=Join-Path $Root 'Assumed Diag';$NativeOut=Join-Path $Root 'Returned Diag'
            foreach($Folder in @($AgentFolder,$DiagnosticFolder,$NativeOut)){New-Item -ItemType Directory $Folder -Force|Out-Null}
            $NativeZip=Join-Path $NativeOut 'diag-[fresh].zip'
            $Generator=@"
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
`$z=[IO.Compression.ZipFile]::Open('$NativeZip',[IO.Compression.ZipArchiveMode]::Create)
`$e=`$z.CreateEntry('logs/debug.xml');`$w=[IO.StreamWriter]::new(`$e.Open());`$w.Write('<debug/>');`$w.Dispose();`$z.Dispose()
Write-Output 'HTTP Status: 200 - OK'
Write-Output 'Create diagnostic package done.'
Write-Output 'path = $NativeOut'
Write-Output 'file name = diag-[fresh].zip'
"@
            $Generator|Set-Content -LiteralPath "$AgentFolder\Generate.ps1" -Encoding UTF8
            '@echo off',('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f "$AgentFolder\Generate.ps1"),'exit /b %ERRORLEVEL%'|Set-Content -LiteralPath "$AgentFolder\dsa_control.cmd" -Encoding ASCII
            $DiagnosticTimeoutMinutes=1
            $R=Request-AgentDiagnostics
            Assert-True ($R.Status -eq 'Succeeded' -and $R.Source -eq $NativeZip -and $R.DebugXmlPresent) ($R|ConvertTo-Json -Depth 5)
            Assert-True ((Get-FileHash -LiteralPath $R.CopiedZip).Hash -eq $R.SHA256) 'Diagnostic copy hash mismatch.'
            $script:LastGoodDiagnostic=$R
        }
        Test-Case 'HTTP error with exit zero cannot use an old diagnostic' {
            '@echo off','echo HTTP Status: 403 - Forbidden','exit /b 0'|Set-Content -LiteralPath "$AgentFolder\dsa_control.cmd" -Encoding ASCII
            $R=Request-AgentDiagnostics
            Assert-True ($R.Status -eq 'Failed' -and $R.Message -match '403') 'HTTP failure passed because exit was zero.'
        }
        Test-Case 'Native command returning an unchanged old ZIP does not verify' {
            $OldZip=$LastGoodDiagnostic.Source
            (Get-Item -LiteralPath $OldZip).LastWriteTimeUtc=(Get-Date).ToUniversalTime().AddSeconds(-1)
            '@echo off','echo HTTP Status: 200 - OK',('echo path = '+(Split-Path $OldZip)),('echo file name = '+(Split-Path $OldZip -Leaf)),'exit /b 0'|Set-Content -LiteralPath "$AgentFolder\dsa_control.cmd" -Encoding ASCII
            $R=Request-AgentDiagnostics
            Assert-True ($R.Status -eq 'AwaitingArchive' -and (Get-Content -LiteralPath (Join-Path (Split-Path (Get-ChildItem -LiteralPath "$Case\Trend\FinalDiagnostics" -Recurse -Filter Reported-diagnostic-path.txt|Sort-Object LastWriteTimeUtc|Select-Object -Last 1).FullName) 'ZIP-lookup-errors.txt') -Raw) -match 'stale') 'Old response ZIP was accepted or its reason lost.'
        }
        Test-Case 'Live timed-out diagnostic blocks packaging and stale PID metadata does not' {
            $Record="$Case\Trend\FinalDiagnostics\Last-diagnostic-status.json";$Saved=Get-Content -LiteralPath $Record -Raw
            $Started=(Get-Process -Id $PID).StartTime
            $F=$Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Assert-CollectorsStopped'}
            . ([scriptblock]::Create($F.Extent.Text))
            function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $null}
            function Get-Process {param($Id,$ErrorAction) if($Id -eq $PID){[pscustomobject]@{StartTime=$Started}}}
            try {
                [pscustomobject]@{Status='TimedOut';ProcessId=$PID;ProcessStartedAt=$Started.ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $Record
                Assert-Throws {Assert-CollectorsStopped} 'Live timed-out diagnostic did not block packaging.'
                [pscustomobject]@{Status='TimedOut';ProcessId=$PID;ProcessStartedAt=$Started.AddHours(-1).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $Record
                Assert-CollectorsStopped
            } finally {$Saved|Set-Content -LiteralPath $Record -Encoding UTF8}
        }
        Test-Case 'Packaging verifies archives with zipped-only metrics and reports partial quality' {
            function script:Assert-CollectorsStopped {}
            function script:Read-CollectionState {param($Pass) $script:State=[pscustomobject]@{} }
            'event fixture'|Set-Content -LiteralPath "$Case\Events\System.evtx"; 'event fixture'|Set-Content -LiteralPath "$Case\Events\Application.evtx"
            [pscustomobject]@{RecordedBootUtc=$Start.ToString('o');TraceStopRequestedAtUtc=$End.ToString('o');FinishedAtUtc=$End.AddSeconds(1).ToString('o');ComputerName=$env:COMPUTERNAME}|ConvertTo-Json|Set-Content -LiteralPath "$Case\Cleanup\PhaseA-state.json"
            $DebugFolder="$Case\Trend\AMDebug";New-Item -ItemType Directory $DebugFolder -Force|Out-Null;'debug fixture'|Set-Content -LiteralPath "$DebugFolder\Amsp_LocalDebugLog.log"
            $ArchiveDirectory=Join-Path $Root 'Handoff';$SkipDiagnostics=$true
            $Output=(& {New-CaseArchive} 3>&1 6>&1|Out-String)
            Assert-True ($Output -match 'ARCHIVE INTEGRITY VERIFIED.*EVIDENCE GAPS REMAIN') 'Partial evidence printed an unconditional success.'
            $A=Get-Content -LiteralPath "$Case\Evidence-assessment.json" -Raw|ConvertFrom-Json
            Assert-True ($A.Metrics.ArtifactRecordsVerified -and ($A.EvidenceGaps -join ' ') -match 'SavedWithEventLoss') 'Zipped-only metrics or WPR gap assessment failed.'
            $Archive=Get-ChildItem -LiteralPath $ArchiveDirectory -Filter '*.zip'|Select-Object -Last 1
            $Z=[IO.Compression.ZipFile]::OpenRead($Archive.FullName);try{Assert-True ($null -ne $Z.GetEntry('Evidence-assessment.json')) 'Quality assessment missing from handoff ZIP.'}finally{$Z.Dispose()}
            Assert-True ((Get-Content -LiteralPath ($Archive.FullName+'.sha256.txt') -Raw) -match (Get-FileHash -LiteralPath $Archive.FullName).Hash) 'Outer ZIP checksum missing or incorrect.'
        }
        Test-Case 'Complete required-artifact fixture gets a distinct packaging result' {
            $exportRows = foreach ($channel in 'System','Application') {
                [pscustomobject]@{Channel=$channel;Status='Exported';Bytes=(Get-Item "$Case\Events\$channel.evtx").Length}
            }
            $exportRows | Export-Csv "$Case\Events\Channel-exports.csv" -NoTypeInformation
            Get-ChildItem -LiteralPath $Case -Recurse -File|Where-Object Name -in @('Collection-errors.txt','Early-debug-copy-error.txt','Fallback-debug-copy-error.txt')|Remove-Item -Force
            $LastGoodDiagnostic|ConvertTo-Json -Depth 6|Set-Content -LiteralPath "$Case\Trend\FinalDiagnostics\Last-diagnostic-status.json"
            '{"AMDebugRequested":false}'|Set-Content -LiteralPath "$Case\Cleanup\PersistentAMTrace\Restored-trace-assessment.json"
            $Q=Get-WprSaveAssessment -Etl "$Case\WPR\PassA-BootLoginApps.etl" -ExitCode 0 -OutputText 'The trace was successfully saved.'
            $Q|ConvertTo-Json|Set-Content -LiteralPath "$Case\WPR\Trace-quality.json"
            $ArchiveDirectory=Join-Path $Root 'CompleteHandoff'
            $mark=[pscustomobject]@{AuthenticatedUtc=$Start.ToString('o');ExplorerUtc=$End.ToString('o');SessionCorroborated=$true;TimeZone=(Get-TimeZone).Id}
            $mark|ConvertTo-Json|Set-Content -LiteralPath "$Case\WPR\SignIn-milestones.json"
            $lo=$Start.AddSeconds(1).ToLocalTime().ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
            $hi=$Start.AddSeconds(2).ToLocalTime().ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
            @("$lo,[00001:00002] >>> SCANFILE: C:\sample.dll,[fixture]","$hi,[00001:00002] <<< SCANFILE: scan time (microsecond) = 4445")|Set-Content -LiteralPath "$Case\Trend\AMDebug\Amsp_LocalDebugLog.log"
            $Output=(& {New-CaseArchive} 3>&1 6>&1|Out-String)
            Assert-True ($Output -match 'REQUIRED ARTIFACTS VERIFIED') $Output
            $A=Get-Content -LiteralPath "$Case\Evidence-assessment.json" -Raw|ConvertFrom-Json
            Assert-True ($A.EvidenceGaps.Count -eq 0 -and -not $A.Wpr.BootMarkersVerified) 'Artifact checks confused with marker/causality verification.'
        }
        Test-Case 'Pass A and B windows are assessed independently' {
            $BStart=$Start.AddSeconds(120);$BEnd=$BStart.AddSeconds(20)
            $BFolder=Join-Path $Case 'Trend\PassB\VerifiedToolMetrics\Archive-1';New-Item -ItemType Directory $BFolder -Force|Out-Null
            New-ZipFixture -Path "$BFolder\DSTool-METRICS-B.zip" -Text (New-RecordsText -At $BStart)
            [pscustomobject]@{RecordedBootUtc=$BStart.ToString('o');ReproductionEndUtc=$BEnd.ToString('o');FinishedAtUtc=$BEnd.AddSeconds(1).ToString('o');ComputerName=$env:COMPUTERNAME;Finished=$true}|ConvertTo-Json|Set-Content -LiteralPath "$Case\Cleanup\PhaseB-state.json"
            New-Item -ItemType Directory "$Case\Procmon","$Case\Events\PassB","$Case\Trend\AMDebug\PassB-Early-test" -Force | Out-Null
            $segments = foreach ($name in 'boot.pml','boot-1.pml') {
                $file="$Case\Procmon\$name"; [IO.File]::WriteAllBytes($file,[byte[]](1,2,3))
                [pscustomobject]@{Name=$name;Bytes=3;SHA256=(Get-FileHash $file).Hash}
            }
            $segments | Export-Csv "$Case\Procmon\PassB-segments.csv" -NoTypeInformation
            Copy-Item "$Case\Events\*.evtx","$Case\Events\Channel-exports.csv" "$Case\Events\PassB"
            $mark=[pscustomobject]@{AuthenticatedUtc=$BStart.ToString('o');ExplorerUtc=$BEnd.ToString('o');SessionCorroborated=$true;TimeZone=(Get-TimeZone).Id}
            $mark|ConvertTo-Json|Set-Content "$Case\Procmon\SignIn-milestones.json"
            $lo=$BStart.AddSeconds(1).ToLocalTime().ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
            $hi=$BStart.AddSeconds(2).ToLocalTime().ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
            @("$lo,[00001:00002] >>> SCANFILE: C:\sampleB.dll,[fixture]","$hi,[00001:00002] <<< SCANFILE: scan time (microsecond) = 3000")|Set-Content "$Case\Trend\AMDebug\PassB-Early-test\Amsp_LocalDebugLog.log"
            [pscustomobject]@{CredentialSubmittedAt=$BStart.ToString('o');DesktopReadyAt=$BEnd.ToString('o')}|ConvertTo-Json|Set-Content "$Case\Procmon\Operator-notes.json"
            $A=Get-CaseEvidenceAssessment
            Assert-True ($A.MetricsByPass.Count -eq 2 -and $A.EvidenceGaps.Count -eq 0 -and $A.MetricsByPass[1].MaximumGapSeconds -eq 5) ($A|ConvertTo-Json -Depth 8)
            Assert-True ($A.PassBSignInScans.SignInPairs -eq 1 -and $A.SignInScans.SignInPairs -eq 1) 'Pass-specific AMSP evidence mixed'
        }
        Test-Case 'Combined ZIP reports a lost segment and failed B channel, and retains A events' {
            $ArchiveDirectory=Join-Path $Root 'Combined'
            $pml="$Case\Procmon\boot-1.pml"
            $manifest="$Case\Events\PassB\Channel-exports.csv"
            $original=[IO.File]::ReadAllBytes($manifest)
            try {
                Remove-Item -LiteralPath $pml
                $rows=@(Import-Csv $manifest);($rows|Where-Object Channel -eq 'Application').Status='Failed'
                $rows|Export-Csv $manifest -NoTypeInformation
                New-CaseArchive
                $zip=[IO.Compression.ZipFile]::OpenRead((Get-ChildItem $ArchiveDirectory -Filter '*.zip').FullName)
                try {
                    $entry=$zip.Entries | Where-Object Name -eq 'Evidence-assessment.json'
                    $reader=[IO.StreamReader]::new($entry.Open())
                    try {$report=$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
                    $missing=$report.EvidenceGaps -join ' '
                    Assert-True ($missing -match 'boot-1.pml' -and $missing -match 'PassB event export.*Application' -and $report.Status -eq 'EvidenceGapsRemain') $missing
                    Assert-True (@($zip.Entries|Where-Object Name -eq 'System.evtx').Count -eq 2) 'One pass overwrote the other'
                } finally {$zip.Dispose()}
                [IO.File]::WriteAllBytes($pml,[byte[]](1,2,4))
                Assert-True ((Get-PmlEvidenceGaps "$Case\Procmon") -match 'changed') 'Same-size replacement passed'
            } finally {[IO.File]::WriteAllBytes($pml,[byte[]](1,2,3));[IO.File]::WriteAllBytes($manifest,$original)}
        }
        Test-Case 'Case renaming preserves diagnostic and context verification' {
            $Renamed=$Case+'-Renamed';Move-Item -LiteralPath $Case -Destination $Renamed;$script:Case=$Renamed
            $A=Get-CaseEvidenceAssessment
            Assert-True ($A.EvidenceGaps.Count -eq 0) ($A|ConvertTo-Json -Depth 8)
        }
        Test-Case 'Pass B recovery retrieves events and restores tracing without a saved PML' {
            Import-CollectorFunctions
            $Case=Join-Path $Root 'Case-Recovery-B'
            $boot=[datetime]::UtcNow.AddHours(-1)
            $null=New-Item -ItemType Directory "$Case\Procmon","$Case\Trend","$Case\Cleanup","$Case\Events" -Force
            $phase=[pscustomobject]@{ComputerName=$env:COMPUTERNAME;Scenario='Reboot';PreparedAt=[datetime]::UtcNow.ToString('o');PreparedBoot=$boot.ToString('o');RunId=[guid]::NewGuid().ToString('N');Finished=$false;PreparationComplete=$false}
            $phase|ConvertTo-Json|Set-Content "$Case\Cleanup\PhaseB-state.json"
            function Get-CimInstance {param($ClassName,$Filter) if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{LastBootUpTime=$boot}}}
            function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)}
            function Get-Process {param($ErrorAction)}
            function Get-WinEvent {param($FilterHashtable,$ErrorAction)}
            function Copy-ToolMetrics {param($PassFolder,$SinceUtc,$RequiredEndUtc) 'attempted'|Set-Content "$PassFolder\metrics-attempt.txt"}
            function Copy-EvidenceFolder {param($Source,$Target,$Log)}
            function Save-AMDebug {param($Label)}
            function Restore-PersistentAMTrace {param($Case) 'restored'|Set-Content "$Case\Cleanup\restored.txt"}
            function Save-NativeEvidence {param($Exe,$Arguments,$Output)}
            function wevtutil.exe {param($verb,$channel,$file,$overwrite) 'fixture'|Set-Content -LiteralPath $file;$global:LASTEXITCODE=0}
            $SkipDiagnostics=$true
            Invoke-Finish -Pass PassB -Recovery
            Assert-True ((Test-Path "$Case\Trend\PassB\metrics-attempt.txt") -and (Test-Path "$Case\Cleanup\restored.txt") -and (Test-Path "$Case\Events\PassB\System.evtx")) 'Interrupted B blocked independent retrieval'
            Assert-True (!(Test-Path "$Case\Procmon\PassB-segments.csv") -and (Get-PmlEvidenceGaps "$Case\Procmon") -match 'missing') 'Recovery verified an absent PML'
            $phase.PreparedBoot=$boot.AddHours(-2).ToString('o')
            $phase.PreparedAt=$boot.AddMinutes(-1).ToString('o')
            $phase.PreparationComplete=$true
            $phase|ConvertTo-Json|Set-Content "$Case\Cleanup\PhaseB-state.json"
            $live="$Case\Trend\LiveMetrics\PassB\$($phase.RunId)"
            $null=New-Item -ItemType Directory -Path $live -Force
            $boot.ToString('o')|Set-Content "$live\BootUtc.txt"
            Assert-Throws {Invoke-Finish -Pass PassB} 'Normal Finish B accepted an empty capture'
            foreach ($name in 'login.pml','login-1.pml') { [IO.File]::WriteAllBytes("$Case\Procmon\$name",[byte[]](1,2,3)) }
            Invoke-Finish -Pass PassB
            $rows=@(Import-Csv "$Case\Procmon\PassB-segments.csv")
            Assert-True ($rows.Count -eq 2 -and !@(Get-PmlEvidenceGaps "$Case\Procmon" $phase.RunId).Count) 'Normal finish did not inventory both segments'
            Assert-True ((Get-Content "$Case\Cleanup\PhaseB-state.json" -Raw|ConvertFrom-Json).Finished) 'Successful B finish was not persisted'
        }
        Test-Case 'Cleanup retains tools, supports KeepEvidence, and only deletes its fixture case root' {
            $CleanupRoot=Join-Path $Root 'CleanupOnly';New-Item -ItemType Directory "$CleanupRoot\CASE-X" -Force|Out-Null
            New-Item -ItemType Directory "$CleanupRoot\CASE-X\Cleanup"|Out-Null
            [pscustomobject]@{Armed=$true;TraceSaved=$false;ConfigRestored=$true;ComputerName=$env:COMPUTERNAME;RunId=[guid]::NewGuid().ToString('N');Scenario='Reboot';PreparedBoot=$Start.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath "$CleanupRoot\CASE-X\Cleanup\PhaseA-state.json"
            'case data'|Set-Content -LiteralPath "$CleanupRoot\CASE-X\data.txt"
            $ToolRoot=Join-Path $Root 'RetainedTools';New-Item -ItemType Directory $ToolRoot|Out-Null;'keep tool'|Set-Content -LiteralPath "$ToolRoot\retained.txt"
            $F=$Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-Cleanup'}
            . ([scriptblock]::Create($F.Extent.Text.Replace("'C:\SWP-Perf'","'$CleanupRoot'")))
            function Get-WprPath {'fixture-wpr.exe'}
            function Get-Process {param($ErrorAction) @()}
            function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $null}
            function Get-CimInstance {param($ClassName) @()}
            function Get-AMTraceSetting {param($Path) [pscustomobject]@{AMDebugRequested=$false}}
            $script:CancellationCalls=0
            function Start-Process {param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$Wait,[switch]$PassThru) $script:CancellationCalls++;[pscustomobject]@{ExitCode=0}}
            $WprFixture=Join-Path $Root 'fixture-wpr.exe';'fixture'|Set-Content -LiteralPath $WprFixture
            # The final status command is also simulated; no live WPR command runs.
            function fixture-wpr.exe {param([switch]$status) 'WPR is not recording'}
            function Assert-CaseTrace {param($Owner,[switch]$BeforeBoot) if($Owner.ComputerName -ne $env:COMPUTERNAME){throw 'Unexpected owner'}}
            $ArchiveDirectory=Join-Path $Root 'DeletionHandoff'
            New-Item -ItemType Directory $ArchiveDirectory | Out-Null
            $KeepEvidence=$true;Invoke-Cleanup
            Assert-True (Test-Path -LiteralPath "$CleanupRoot\CASE-X\data.txt") 'KeepEvidence deleted case data.'
            $KeepEvidence=$false
            Assert-Throws {Invoke-Cleanup} 'Missing outside handoff permitted deletion.'
            $outside=Join-Path $ArchiveDirectory 'AllEvidence-CASE-X.zip'
            [IO.Compression.ZipFile]::CreateFromDirectory("$CleanupRoot\CASE-X",$outside)
            [pscustomobject]@{Archive=$outside;SHA256=(Get-FileHash -LiteralPath $outside).Hash;Computer=$env:COMPUTERNAME;CaseName='CASE-X'}|ConvertTo-Json|Set-Content -LiteralPath "$CleanupRoot\CASE-X\Cleanup\Handoff-receipt.json"
            $caseTwo=Join-Path $CleanupRoot 'CASE-Y'
            New-Item -ItemType Directory "$caseTwo\Cleanup" -Force|Out-Null
            'second case'|Set-Content -LiteralPath "$caseTwo\data.txt"
            Assert-Throws {Invoke-Cleanup} 'A second case without a handoff was deleted.'
            Assert-True (Test-Path -LiteralPath "$CleanupRoot\CASE-X\data.txt") 'The first case was deleted before verification of the second.'
            $twoZip=Join-Path $ArchiveDirectory 'AllEvidence-CASE-Y.zip'
            [IO.Compression.ZipFile]::CreateFromDirectory($caseTwo,$twoZip)
            [pscustomobject]@{Archive=$twoZip;SHA256=(Get-FileHash -LiteralPath $twoZip).Hash;Computer=$env:COMPUTERNAME;CaseName='CASE-Y'}|ConvertTo-Json|Set-Content -LiteralPath "$caseTwo\Cleanup\Handoff-receipt.json"
            Invoke-Cleanup
            Invoke-Cleanup
            Assert-True (-not(Test-Path -LiteralPath $CleanupRoot) -and (Test-Path -LiteralPath "$ToolRoot\retained.txt")) 'Cleanup crossed its case root or removed retained tools.'
            Assert-True ($CancellationCalls -eq 1) 'Cleanup cancelled WPR again after the owned recording was already cleared.'
        }
        Test-Case 'Cleanup blocks an unidentified support-tool process before deleting evidence' {
            $CleanupRoot=Join-Path $Root 'CleanupBlocked';New-Item -ItemType Directory $CleanupRoot|Out-Null
            'preserve'|Set-Content -LiteralPath "$CleanupRoot\evidence.txt"
            $ToolRoot=Join-Path $Root 'RetainedTools'
            $F=$Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-Cleanup'}
            . ([scriptblock]::Create($F.Extent.Text.Replace("'C:\SWP-Perf'","'$CleanupRoot'")))
            function Get-WprPath {'fixture-wpr.exe'}
            function Get-Process {param($ErrorAction) @()}
            function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $null}
            function Get-CimInstance {param($ClassName) [pscustomobject]@{Name='DSASupportTool_CMD.exe';ExecutablePath=$null;ProcessId=2147483000}}
            function Get-AMTraceSetting {param($Path) [pscustomobject]@{AMDebugRequested=$false}}
            Assert-Throws {Invoke-Cleanup} 'Cleanup ignored a support-tool process with unknown ownership.'
            Assert-True (Test-Path -LiteralPath "$CleanupRoot\evidence.txt") 'Unknown collector did not protect evidence.'
        }
        Import-CollectorFunctions
        Test-Case 'Pending native diagnostic resumes exact late ZIP without a second command' {
            $Case=Join-Path $Root 'CASE-Resume'
            $DiagnosticFolder=Join-Path $Root 'DelayedNative'
            $null=New-Item -ItemType Directory $Case,$DiagnosticFolder
            $count=Join-Path $Root 'requests.txt'
            $artifact=Join-Path $DiagnosticFolder '1234567890.zip'
            $temp=[IO.Path]::ChangeExtension($artifact,'.tmp')
            '@echo off',('echo request>>"'+$count+'"'),'echo HTTP Status: 200 - OK',('echo path = '+$DiagnosticFolder),'echo file name = 1234567890.zip','exit /b 0' | Set-Content -LiteralPath "$AgentFolder\dsa_control.cmd" -Encoding ASCII
            function Assert-CollectorsStopped {}
            $ArtifactWaitSeconds=0
            $DiagnosticTimeoutMinutes=1
            'partial'|Set-Content -LiteralPath $temp
            New-ZipFixture (Join-Path $DiagnosticFolder 'unrelated.zip') '[]'
            $first=Request-AgentDiagnostics
            Assert-True ($first.Status -eq 'AwaitingArchive' -and !$first.CopiedZip) 'Unrelated ZIP or temporary file satisfied request.'
            Assert-True (Test-DiagnosticPending $Case) 'Pending service was marked settled.'
            $job=Start-Job -ArgumentList $artifact,$temp -ScriptBlock {
                param($z,$t)
                Start-Sleep -Seconds 2
                Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
                $f=[IO.Compression.ZipFile]::Open($t+'.complete','Create')
                foreach($n in 'Agent/AMSP/AmTopNScan.txt','config/debug.xml'){
                    $w=[IO.StreamWriter]::new($f.CreateEntry($n).Open());try{$w.Write('evidence')}finally{$w.Dispose()}
                }
                $f.Dispose()
                [IO.File]::Move($t+'.complete',$z);[IO.File]::Delete($t)
            }
            try {
                $ArtifactWaitSeconds=25
                $again=Request-AgentDiagnostics
                Assert-True ($again.Status -eq 'Succeeded' -and $again.RequestFolder -eq $first.RequestFolder -and $again.TopNPresent -and $again.DebugXmlPresent) ($again|ConvertTo-Json)
                Assert-True (@(Get-Content -LiteralPath $count).Count -eq 1 -and (Get-FileHash -LiteralPath $artifact).Hash -eq $again.SHA256) 'Second request or bad hash.'
                $progress=Get-Content -LiteralPath (Join-Path (Split-Path $again.CopiedZip) 'Publication-progress.jsonl')|ConvertFrom-Json
                Assert-True ('Writing temporary file' -in $progress.Phase -and 'Verified' -in $progress.Phase) 'Progress did not show publication.'
            } finally {Remove-Job -Job $job -Force}
        }
        if ($LongPublicationTest) {
            Test-Case 'Exact TopN-only native ZIP survives a five-minute asynchronous publication' {
                $Case=Join-Path $Root 'CASE-Late'
                $DiagnosticFolder=Join-Path $Root 'LateAgent'
                $null=New-Item -ItemType Directory $Case,$DiagnosticFolder
                function Assert-CollectorsStopped {}
                $ArtifactWaitSeconds=600;$DiagnosticTimeoutMinutes=10
                $agentName='100001.zip'
                '@echo off','echo HTTP Status: 200 - OK',('echo path = '+$DiagnosticFolder),('echo file name = '+$agentName),'exit /b 0' | Set-Content -LiteralPath "$AgentFolder\dsa_control.cmd" -Encoding ASCII
                $job=Start-Job -ArgumentList $DiagnosticFolder,$agentName -ScriptBlock {
                    param($dir,$name)
                    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
                    function Publish($path) {
                        $z=[IO.Compression.ZipFile]::Open($path,'Create')
                        $w=[IO.StreamWriter]::new($z.CreateEntry('Agent/AMSP/AmTopNScan.txt').Open())
                        try{$w.Write('frequency fixture')}finally{$w.Dispose();$z.Dispose()}
                    }
                    Start-Sleep -Seconds 2
                    Publish (Join-Path $dir 'unrelated.zip')
                    $file=Join-Path $dir $name
                    'incomplete archive'|Set-Content -LiteralPath $file
                    Start-Sleep -Seconds 306
                    Publish ($file+'.writing')
                    [IO.File]::Replace($file+'.writing',$file,$file+'.old')
                }
                try {
                    $timer=[Diagnostics.Stopwatch]::StartNew()
                    $out=Request-AgentDiagnostics
                    Assert-True ($timer.Elapsed.TotalSeconds -ge 300 -and $out.Status -eq 'Succeeded' -and $out.TopNPresent -and !$out.DebugXmlPresent -and $out.Source -eq (Join-Path $DiagnosticFolder $agentName)) ($out|ConvertTo-Json)
                    $data=[pscustomobject]@{WaitSeconds=$timer.Elapsed.TotalSeconds;Result=$out}
                    $data|ConvertTo-Json -Depth 7|Set-Content -LiteralPath "$ResultsFolder\Delayed-publication.json"
                }finally{Remove-Job -Job $job -Force}
            }
        }
        Test-Case 'Overlapping diagnostic monitor cannot submit a second request' {
            $Case=Join-Path $Root 'CASE-Resume'
            $lock=[IO.File]::Open((Join-Path $Case 'Trend\FinalDiagnostics\Request.lock'),'Open','ReadWrite','None')
            try{Assert-Throws {Request-AgentDiagnostics} 'Concurrent monitor was allowed.'}finally{$lock.Dispose()}
        }
        Test-Case 'Live metrics copies complete batches once and retries invalid writes' {
            $src=Join-Path $Root 'RollingMetrics';$dest=Join-Path $Root 'SavedBatches'
            $run=Join-Path $src '20010615-141900'
            $null=New-Item -ItemType Directory $run,$dest -Force
            $f=Join-Path $run '142100_jsonRecords.json';$seen=@{}
            '{'|Set-Content -LiteralPath $f
            Copy-NewMetricBatches $src $dest $Start $seen
            Assert-True (!$seen.Count) 'Partial series accepted.'
            New-RecordsText -At $Start | Set-Content -LiteralPath $f
            $writer=[IO.File]::Open($f,'Open','ReadWrite','ReadWrite')
            try {
                Copy-NewMetricBatches $src $dest $Start $seen
                Assert-True (!$seen.Count) 'Accepted a valid prefix while the vendor writer still held the batch.'
            } finally {$writer.Dispose()}
            Copy-NewMetricBatches $src $dest $Start $seen
            Copy-NewMetricBatches $src $dest $Start $seen
            Remove-Item -LiteralPath $f
            $saved=@(Get-ChildItem -LiteralPath $dest -Recurse -Filter '*_jsonRecords.json')
            Assert-True ($saved.Count -eq 1 -and @(Get-Content -LiteralPath "$dest\Batches.jsonl").Count -eq 1 -and (Get-ToolMetricsAssessment -Paths $saved[0].FullName -SinceUtc $Start -RequiredEndUtc $End).ArtifactRecordsVerified) 'Saved series did not survive source removal.'
        }
        Test-Case 'Final loose metrics exclude old samples and a batch already preserved live' {
            $src=Join-Path $Root 'TwoMetricsRuns';$dest=Join-Path $Root 'FinalBatches';$live=Join-Path $Root 'LiveBatches'
            $old='20010615-141900';$new='20010615-153000'
            $null=New-Item -ItemType Directory "$src\$old","$src\$new","$live\$new",$dest -Force
            New-RecordsText -At $Start.AddHours(-1)|Set-Content "$src\$old\141905_jsonRecords.json"
            New-RecordsText -At $Start|Set-Content "$src\$new\153005_jsonRecords.json"
            Copy-Item "$src\$new\153005_jsonRecords.json" "$live\$new"
            New-RecordsText -At $Start.AddSeconds(15)|Set-Content "$src\$new\153020_jsonRecords.json"
            Copy-NewMetricBatches $src $dest $Start @{} $live
            $saved=@(Get-ChildItem $dest -Recurse -Filter '*_jsonRecords.json')
            Assert-True ($saved.Count -eq 1 -and $saved[0].Name -eq '153020_jsonRecords.json' -and (Test-Path "$dest\Skipped-batches.jsonl")) 'Old or duplicate batch included, or new batch lost.'
        }
        Test-Case 'Wrong case or run cannot control metrics task or cancel WPR' {
            $ToolRoot='C:\Program Files\SWP-PerfTools';$ToolFolder=Join-Path $ToolRoot DSASupportTool
            $valid='C:\SWP-Perf\CASE-A';$id=[guid]::NewGuid().ToString('N')
            $owner=[pscustomobject]@{ComputerName=$env:COMPUTERNAME;RunId=$id}
            $task=[pscustomobject]@{Actions=@([pscustomobject]@{Execute="$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe";WorkingDirectory=$ToolFolder;Arguments=(Get-MetricsTaskArguments $valid PassA $id)})}
            Assert-True (Test-MetricsTaskAction $task $owner $valid PassA) 'Correct task ownership failed.'
            Assert-True (!(Test-MetricsTaskAction $task $owner 'C:\SWP-Perf\CASE-B' PassA)) 'Wrong case accepted.'
            $owner.RunId=[guid]::NewGuid().ToString('N')
            Assert-True (!(Test-MetricsTaskAction $task $owner $valid PassA)) 'Wrong run accepted.'
            Assert-Throws {Assert-CaseTrace $owner} 'Unarmed case owns a recording.'
        }
        Test-Case 'Boot ownership checks accept one recorded startup and reject a later reboot' {
            $Case=Join-Path $Root 'CASE-BootOwner'
            $id=[guid]::NewGuid().ToString('N')
            $dest=Join-Path $Case "Trend\LiveMetrics\PassA\$id";$null=New-Item -ItemType Directory $dest -Force
            $newBoot=[datetime]::UtcNow.AddMinutes(-3)
            function Get-CimInstance {param($ClassName) [pscustomobject]@{LastBootUpTime=$newBoot}}
            $s=[pscustomobject]@{Armed=$true;TraceSaved=$false;Scenario='Reboot';RunId=$id;ComputerName=$env:COMPUTERNAME;PreparedAt=$newBoot.AddMinutes(-5).ToString('o');PreparedBoot=$newBoot.AddHours(-2).ToString('o')}
            $newBoot.ToString('o')|Set-Content -LiteralPath "$dest\BootUtc.txt"
            Assert-CaseTrace $s
            $newBoot=$newBoot.AddMinutes(1);Assert-Throws {Assert-CaseTrace $s} 'Second reboot accepted.'
            $newBoot=$newBoot.AddMinutes(-1)
            Remove-Item -LiteralPath "$dest\BootUtc.txt"
            function Get-WinEvent {param($FilterHashtable,$ErrorAction) [pscustomobject]@{TimeCreated=$newBoot.ToLocalTime()}}
            Assert-CaseTrace $s
        }
        Test-Case 'Overlapping AMSP generations preserve repeated scans of one file' {
            $Case = Join-Path $Root 'CASE-Overlap'
            $dir = Join-Path $Case 'Trend\AMDebug'
            $null = New-Item -ItemType Directory $dir,"$Case\WPR" -Force
            @{ AuthenticatedUtc=$Start.ToString('o'); ExplorerUtc=$End.ToString('o'); SessionCorroborated=$true; TimeZone='UTC' } |
                ConvertTo-Json | Set-Content -LiteralPath "$Case\WPR\SignIn-milestones.json"
            '{}' | Set-Content -LiteralPath "$Case\Operator-notes.json"
            $paths = 'alpha.dll','beta.dll','alpha.dll'
            $lines = for ($i=0; $i -lt $paths.Count; $i++) {
                $at = $Start.AddSeconds($i + 1)
                $from = $at.ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
                $to = $at.AddMilliseconds(12).ToString('yyyy/MM/dd HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
                "$from,[00001:00002] >>> SCANFILE: C:\Fixture\$($paths[$i]),[fixture]"
                "$to,[00001:00002] <<< SCANFILE: scan time (microsecond) = 12000"
            }
            $lines[0..3] | Set-Content -LiteralPath "$dir\Amsp_LocalDebugLog.1.log"
            $lines[2..5] | Set-Content -LiteralPath "$dir\Amsp_LocalDebugLog.log"
            $coverage = Get-ScanCoverage (Get-RegularEvidenceFiles $Case) $Start $End
            Assert-True ($coverage.Status -eq 'Observed' -and $coverage.SignInPairs -eq 3) 'Expected three distinct scan events.'
            $rows = @(Import-Csv -LiteralPath "$Case\Trend\Timed-scans.csv")
            Assert-True (@($rows | Where-Object { $_.Path -eq 'C:\Fixture\alpha.dll' -and [int]$_.EngineMicroseconds -eq 12000 }).Count -eq 2) 'Expected two scans of alpha.dll.'
        }
    }
} finally {
    New-Item -ItemType Directory -Path $ResultsFolder -Force|Out-Null
    $SourceHashAfter=(Get-FileHash -LiteralPath $SourcePath).Hash
    if ($SourceHashBefore -ne $SourceHashAfter) { $Results.Add([pscustomobject]@{Name='Tested source unchanged during execution';Status='FAIL';Error='Source changed during the run; rerun against a frozen revision.'}) }
    [pscustomobject]@{RunAt=(Get-Date -Format o);PowerShell=$PSVersionTable.PSVersion.ToString();Source=$SourcePath;SourceSHA256=$SourceHashBefore;SourceSHA256After=$SourceHashAfter;SourceChangedDuringRun=($SourceHashBefore -ne $SourceHashAfter);Baseline=[bool]$Baseline;Results=@($Results.ToArray());Note='Real Windows file/ZIP/ACL/native-CMD tests; Trend service, reboot, WPR and scheduled-task interactions are simulated or inspected, not a real customer capture.'} |
        ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $ResultsFolder $(if($Baseline){'Baseline-results.json'}else{'Regression-results.json'})) -Encoding UTF8
    # Only this test run's random fixture root is deleted; no collector Cleanup action runs.
    if ((Split-Path $Root -Parent) -eq $fixtureBase -and (Split-Path $Root -Leaf) -like 'SWP Collector Tests *') { Remove-Item -LiteralPath $Root -Recurse -Force }
}
if (@($Results|Where-Object Status -eq 'FAIL').Count) { exit 1 }
exit 0
