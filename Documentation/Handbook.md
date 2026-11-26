# Windows sign-in performance collection

## Start here

Use this handbook to investigate slow Windows sign-in and first application launches on a computer protected by TrendAI Vision One Server & Workload Protection or Deep Security Agent. It takes one person to reproduce the delay and an administrator to operate the collector. An affected user with local administrator rights can do both without a second Windows administrator.

DSA means Deep Security Agent. AMSP is the Trend anti-malware component. Windows Performance Recorder (WPR) captures the Windows timeline.

**Choose the symptom first.** If a full sign-out and sign-in reproduces the delay, use the same-boot test. It can capture Trend’s per-file scan times while the agent is already running. If the delay occurs only on first sign-in after a restart, choose the reboot test. Both modes can include the first launch of an affected application.

| Your role | Where to start |
|---|---|
| Person experiencing the delay | Page 2, also supplied as `Participant-sheet.pdf`. Your administrator runs the tools. |
| Endpoint administrator or service desk | Pages 3–10 cover preparation through restoration. The separate `Customer-Runbook.md` includes copyable commands. |
| Administrator reproducing the problem personally | Use page 6 or the standalone `Administrator-participant.pdf` checklist. |
| Trend policy administrator | Use page 8 for policy and protection, and page 10 for restoration. |
| Support analyst | Use pages 11–12 to interpret the returned case and pages 13–15 for recovery or an optional repeat. |
| Developer or release maintainer | Pages 16–22 cover the command interface, implementation, regression tests and release procedure. |

**What to distribute.** Send `SWP-Customer-Kit.zip` with its matching `.sha256.txt`. After testing, the customer returns a different file named `AllEvidence-CASE-…zip` and its checksum. Use the Markdown runbook or handbook source when copying commands. The administrator owns the transfer. The installed collector writes to local storage.

**Edition.** Collector and handbook dated 26 November 2026. The preceding collection engine was tested on Windows 11 build 22631, Windows PowerShell 5.1, agent core 20.0.3-31610 and DSA Support Tool 1.0.0.1203. The lab and customer builds discussed here are both in the 20.0.3.* family. Verify scan coverage in each case. See `Validation-summary.json` for the test results.

## Participant instructions

**What you will do.** Use the sign-in timing agreed with IT. Record when you enter your credentials and when your desktop responds. You can do this with your usual account and permissions.

1. Save your work and close anything you would lose on sign-out or restart. Agree with IT which application to open, if any, and what “ready” means. For example, the desktop accepts a click or the application opens the document you normally use.
2. For a full sign-out test, select **Start → account → Sign out**, then sign back in. For a reboot test, select **Start → Power → Restart**. **When the Windows sign-in screen first appears, wait two full minutes, then sign in locally.** Use your normal timing if the case specifically calls for an immediate sign-in.
3. Note the local time when you submit your credentials and when the desktop responds. If an application is part of the test, launch it once and note when you click it and when it becomes usable. For a sign-in-only test, leave applications closed.
4. Tell IT **desktop ready** or **application ready** as soon as you reach the agreed point. Report an error, timeout or a run that felt normal. Include seconds when you could observe them. If you only know the minute, say so.

**A note you can send to IT**

```text
Computer or support case: ____________________________________
Time zone: ______________   Sign-out or restart: ______________
Submitted sign-in at: __________    Desktop usable at: ________
Application tested, if any: __________________________________
Launched at: ______________    Became usable at: ______________
What I saw while waiting: ____________________________________
______________________________________________________________
```

Keep passwords, PINs and authentication codes private. IT may collect process names and file paths from this workstation. Give timing notes through the support channel arranged for this case. Once IT confirms that the trace has stopped, you can continue using the computer.

## Plan the capture

**Endpoint administrator.** Use one affected workstation and one account per case. Agree on the account, connection type, test scenario and stop point. Record an uninstrumented baseline if available, including Windows and agent builds and when the delay normally occurs. Use the same apps and connection for comparisons.

| Question | Choice |
|---|---|
| Is full sign-out sufficient to reproduce it? | Choose `SignOutSignIn`. Keep the computer on. WPR runs machine-wide and the SYSTEM metrics task starts before sign-out. |
| Does the delay require a fresh boot? | Choose `Reboot`. For per-file evidence, wait two minutes from the visible sign-in screen. For an immediate reproduction, use normal timing and label the run. |
| Is sign-in the only symptom? | End at usable desktop. Set `Applications` to `[]` in the case notes. |
| Is an app slow on first launch? | Include the agreed launch in the same recording and stop when it becomes usable. |
| Does support need Procmon stacks or additional I/O detail? | Finish Pass A first. Use the optional Procmon repeat only for that outstanding question. |

**Prerequisites.** Use elevated 64-bit Windows PowerShell 5.1, an installed and running `ds_agent` service, and a WPR executable that accepts the bundled focused profile. Arrange computer-specific self-protection handling with the Trend policy owner. Close Procmon, WPR UI, xperf and DSA support tools. Check that Procmon boot logging is off and that another session does not own WPR.

**Time and space.** Plan for a short measured reproduction, 15 minutes of DSA metrics after initialization, native diagnostic generation and full ZIP verification. The task has a 45-minute limit. Prepare requires at least 20 GiB free on C:. WPR file-mode size depends on activity and duration. At packaging the destination needs room for the uncompressed case size plus a 1 GiB margin. Budget extra space if the destination also holds the case.

## Install and check the kit

For a source checkout, first add the two pinned support-tool archives as described in `Tools/README.md`. For an assembled kit, keep its ZIP and checksum together. Run the following in elevated Windows PowerShell with the actual download folder. Use a fresh extraction directory so old profiles or support binaries cannot be mistaken for this release.

```powershell
$zip = Join-Path "$env:USERPROFILE\Downloads" 'SWP-Customer-Kit.zip'
$expected = ((Get-Content -LiteralPath "$zip.sha256.txt" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
    throw 'Kit checksum mismatch. Obtain the matching package and checksum.'
}
$kit = 'C:\SWP-Customer-Kit'
if (Test-Path -LiteralPath $kit) { throw 'Choose a fresh extraction folder.' }
Expand-Archive -LiteralPath $zip -DestinationPath $kit
& (Join-Path $kit 'SWP-Perf.ps1') -Stage InstallTools
```

InstallTools creates the tools folder when needed. The CMD executable, its complete supplied `DSTool.json` and its adjacent files belong in `C:\Program Files\SWP-PerfTools\DSASupportTool` on a standard installation. The vendor diagnostic GUI has a separate `DSASupportTool_GUI` directory. The installed script and both WPR profiles sit directly under `SWP-PerfTools`. Setup verifies the bundled archives and installed executables. Investigate any version mismatch before proceeding.

```powershell
$root = Join-Path $env:ProgramFiles 'SWP-PerfTools'
$swp = Join-Path $root 'SWP-Perf.ps1'
Get-Command wpr.exe -All | Select-Object Source
wpr.exe -profiles "$root\SWP-SignIn.wprp"
wpr.exe -status
Get-Service ds_agent, Amsp | Select-Object Name, Status
Get-Process | Where-Object ProcessName -Match '^(DSASupportTool.*|procmon.*|wprui|xperf)$'
```

Look for `SWPSignIn`, an idle WPR and running Trend services. The idle-state check expects an English WPR status message. On a localized host, preserve the output if Prepare cannot confirm the idle state. The last command normally returns no matching process. Prepare also checks active tracing sessions. Follow your organization’s approved script execution process. Keep the installed tool tree writable only by trusted administrators and SYSTEM because Task Scheduler runs the collector as SYSTEM.

## Prepare the endpoint

The policy administrator records the original self-protection value and inheritance and applies the temporary test-computer setting before preparation. Keep the case root dedicated to this collector. The script saves backups and event-channel state there.

Open **SWP Performance Collector** from Start, confirm account and scenario, and choose **Prepare new capture**. For the CLI, use elevated Windows PowerShell. Prepare chooses the next case number. Later stages resume the saved case. An explicit `-Case` selects a named case.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
$account = Read-Host 'Affected interactive account, DOMAIN\user or COMPUTER\user'
```

**Choose one Prepare command.** For a symptom reproducible at full sign-out, use the first command.

```powershell
& $swp -Stage Prepare -Scenario SignOutSignIn -AffectedUser $account
```

For a first sign-in after restart, use this command instead.

```powershell
& $swp -Stage Prepare -Scenario Reboot -AffectedUser $account
```

Prepare records the baseline and task configuration, backs up the vendor JSON, applies metrics settings, and saves the original agent INI state before enabling detailed AM tracing. Expect `ds_agent` to restart. In same-boot mode it verifies a signed control executable produced a paired scan, arms WPR, and starts the metrics task. In reboot mode it schedules WPR and registers the task to survive restart. Wait for the final **Prepared** message.

For a same-boot test where metrics overlap matters, look at the latest entries in the CMD log before releasing the participant. Confirm the metrics timer entry is from this run. File batches can appear several minutes later.

```powershell
$cmdLog = Join-Path $env:ProgramFiles 'SWP-PerfTools\DSASupportTool\logs\DSA_SupportTool.log'
Get-Content -LiteralPath $cmdLog -Tail 30
```

**First sign-in after restart.** Wait two full minutes from the visible Windows sign-in screen, then sign in locally. Record the wait separately from credential submission and desktop readiness. The collector reopens once for the administrator who prepared the case. Use `-NoAutoResume` at Prepare for a CLI-only run. At handoff, check the actual sign-in pair count and paths. A usual immediate sign-in remains available for a separate comparison.

If preparation fails, retain the case and follow “Recover an interrupted capture”.

## Test your own administrator account

Use this checklist when **you experience the delay and are a local administrator on this computer**. You can operate the collector and perform the sign-in yourself. Use your usual Windows account and normal desktop for the test. Membership in local Administrators gives you the ability to elevate PowerShell. Trend console access is a separate permission.

**1. Get ready.** Save your work. Verify the kit checksum and extract to `C:\SWP-Customer-Kit` as described on handbook page 4. Confirm the prerequisites on handbook page 3 and arrange the temporary computer-specific self-protection setting with the policy owner. If you also own that permission, record the original value and inheritance yourself. In a **normal** console, run `whoami.exe`. Note the exact account and the app or desktop milestone.

**2. Prepare before signing out.** Open 64-bit **Windows PowerShell → Run as administrator**. These commands test a slow full sign-out/sign-in. You can also choose this scenario in the collector window. For a reboot-only symptom change `SignOutSignIn` to `Reboot` before running Prepare. Use one scenario per case. If elevation prompts for another account, enter your normal desktop identity at the script prompt.

```powershell
& 'C:\SWP-Customer-Kit\SWP-Perf.ps1' -Stage InstallTools
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
$user = Read-Host 'Enter the account printed by whoami on your normal desktop'
& $swp -Stage Prepare -Scenario SignOutSignIn -AffectedUser $user
```

**3. Reproduce.** After **Prepared**, follow the selected scenario. For **SignOutSignIn**, fully sign out and sign back in. For **Reboot**, restart Windows, wait **two full minutes** from the moment the sign-in screen appears, then sign in locally. For an immediate comparison, use your usual timing and note that choice. Record credential submission, usable desktop and any agreed application launch/ready times.

**4. Stop at the milestone.** After reboot, the collector reopens for the local administrator who prepared the case. Click **Stop trace now** when the desktop or agreed application responds. If the window is closed, use the Start shortcut or run these commands in a new elevated PowerShell.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage StopTrace
```

**5. Finish and return the case.** Update `Operator-notes.json` in the case printed by Prepare with your actual timings. Use `"Applications": []` for sign-in only. Run `& $swp -Stage FinishAndPackage` and wait for **ARCHIVE INTEGRITY VERIFIED**. Restore the original console setting or have its owner verify it. Add the confirmation to your notes and run `& $swp -Stage Package` again if you changed them. Transfer the newest `AllEvidence` ZIP and checksum from `C:\SWP-Handoff`.

Run `& $swp -Stage Cleanup -KeepEvidence` to restore local settings and retain the case. Use default Cleanup only after verifying the transferred handoffs for **all** cases under `C:\SWP-Perf`. If any step fails, keep the case and follow pages 13–14 of the handbook.

## Record timings and finish

**When two people run the test**, the participant reports “desktop ready” or “application ready”. The endpoint administrator stops WPR on that same computer from an authorized elevated session. Preserve the affected person’s interactive desktop for correlation. If you are both the participant and the administrator, page 6 covers this step. Run StopTrace once per capture.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage StopTrace
```

Edit `Operator-notes.json` in the current case. Keep the field names. Use the workstation’s date and local offset. The following is an **illustration**, for a sign-in-only test. Replace example times with observations. Keep exact-time fields blank when only the minute is known and put the approximate observation in `Test-notes.txt`. The assessment will flag the missing precision.

```json
{
  "CredentialSubmittedAt": "2001-06-15T09:12:04+01:00",
  "DesktopReadyAt": "2001-06-15T09:12:31+01:00",
  "Applications": [],
  "Baseline": "Same account and connection, uninstrumented sign-in 24 seconds",
  "OriginalSelfProtection": "Record the effective setting and inheritance",
  "RestoredSelfProtection": ""
}
```

For each application, use an object with `Name`, `LaunchAt`, `ReadyAt` and `Symptom` inside `Applications`. If it timed out, leave `ReadyAt` blank and describe what happened. Windows authentication, Explorer startup and a human reporting that the desktop responds are three separate observations.

After a successful StopTrace, use the same elevated console and case path.

```powershell
& $swp -Stage FinishAndPackage
```

Keep the window open. Finish waits for the SYSTEM metrics task and any associated CMD processes, copies current-run metrics, takes a final debug snapshot, requests the native Trend diagnostic, attempts trace restoration, exports Windows events and builds the handoff. A message every 30 seconds while waiting for DSA is normal. A second elevated window can show status.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage Status
```

Look for **ARCHIVE INTEGRITY VERIFIED** and read the rest of the message. **EVIDENCE GAPS REMAIN** means the files in the ZIP passed integrity checks and the report lists missing or insufficient evidence. Use `Evidence-assessment.json` to decide whether the original question can be answered.

## Policy context and protection

**Trend policy administrator.** Identify the computer and its assigned policy in Vision One Server & Workload Protection or Deep Security Manager. In the computer editor, open **Settings → General → Agent Self-Protection**. Record the effective value, inheritance, approval and change time. [Trend console procedure](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-use-agent-self-protection) For the authorized capture, disable self-protection on this computer and save. Confirm that the setting reached the agent before Prepare. The collector restarts the agent to apply and restore the local trace settings. [Trend AM debug procedure](https://success.trendmicro.com/en-US/solution/KA-0004561)

Export the effective real-time anti-malware configuration. Include directories and files in scope, file selection such as All files or IntelliScan, applicable scan triggers and the members of each assigned exclusion list. Include process-image, file, directory, extension and applicable certificate or hash exceptions and inheritance. Record the policy name, computer override and export time. A list name in `GetConfiguration.xml` alone cannot establish whether a particular DLL was excluded.

Place approved XML, CSV or JSON exports in a dedicated local folder. The collector recursively copies eligible files from that folder. If a console only offers a screenshot, retain it as supplementary evidence in a clearly named case folder and describe the missing structured export. The administrator still checks membership.

```powershell
& $swp -Stage CollectContext `
    -PolicyExportFolder 'C:\SWP-ConsoleExports'
```

The default selected login task is `\IntuneDriveMapping`. For a different task, supply its full scheduler path with `-LoginTask`. Supply local paths to relevant PS1 or VBS definitions with `-LoginScriptPath`. The action copies those definitions and the task XML. It does not execute the selected scripts. See `Customer-Runbook.md` for a multi-file example.

After the native diagnostic completes and local trace restoration succeeds, restore the recorded self-protection value **and its inheritance** on this computer. Confirm the policy is effective on the agent. Record who verified it and when in the case notes. If you added exports or edited notes after the first ZIP, run Package again. Policy changes or exclusions proposed as a result of analysis belong to a separate reviewed change.

## Verify and return the evidence

By default the collector writes `AllEvidence-CASE-…zip` and a matching `.zip.sha256.txt` in `C:\SWP-Handoff`. Inside the ZIP the case files start at the archive root. A metrics-only ZIP, the native diagnostic ZIP and the software distribution all have different purposes. Give support the **full AllEvidence ZIP and its checksum**.

1. Read the latest `Packaging-summary-*.txt` and `Evidence-assessment.json`. Check the session, recorded gap list and operator notes. Confirm the files needed for this symptom were collected.
2. If you added policy exports, notes or a GUI diagnostic after Finish, run `& $swp -Stage Package`. Select the newly printed archive and its matching checksum.
3. Transfer the pair using the approved support channel. On the receiving system verify the specific transferred file. The code below prompts for that file, including its full path. Keep its matching checksum beside it.
4. Tell support the affected account and time zone, capture scenario, symptom interval, Windows and agent builds, and unresolved gaps. Confirm the recipient has a verified copy before deleting any cases.

```powershell
$received = Read-Host 'Full path of the received AllEvidence ZIP'
$listed = ((Get-Content -LiteralPath "$received.sha256.txt" -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash -LiteralPath $received -Algorithm SHA256).Hash
if ($listed -notmatch '^[0-9A-Fa-f]{64}$' -or $actual -ne $listed) {
    throw 'Handoff checksum mismatch. Check the pair and repeat the transfer.'
}
Write-Host 'Received ZIP matches the supplied SHA-256.'
```

**Data handling.** ETLs, Windows event exports, policy exports, task XML, local scripts, Trend logs and backups can disclose account names, network or file paths and configuration. Use the case’s authorized recipients and retention rules. Keep originals and hashes intact. If redaction is necessary, agree on a separately labelled derivative and preserve its provenance. The software ZIP is the appropriate file for another customer to deploy.

## Restore and close

**Restore with evidence retained.** Finish normally restores the original `ds_agent.ini`. Cleanup completes local restoration, including tool JSON, recorded event-channel states and task removal. The cleanup scope is the entire `C:\SWP-Perf` root, including other stored cases, even when `-Case` is supplied. Coordinate with their owners first.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage Cleanup -KeepEvidence
Get-Service ds_agent, Amsp | Select-Object Name, Status
Get-ScheduledTask -TaskName 'SWP-Perf-*' -TaskPath '\' -ErrorAction SilentlyContinue
wpr.exe -status
```

Expect both Trend services to run and the case-owned tasks to be absent. Verify the case’s WPR session ended. An unrelated WPR recording belongs to its owner. If Procmon was used, turn off its boot logging in the GUI and exit. The policy administrator separately restores and verifies the computer’s original protection and inheritance. Record the result. An original INI that requested debugging will still request it after restoration.

**Package the closure record.** Retained cleanup writes the final Defender and SysMain observations to `Cleanup\Collector-closed.json`. For CASE-01, run `& $swp -Stage Package -Case 'C:\SWP-Perf\CASE-01'` and transfer the newest ZIP and checksum. Substitute the actual case path. Before deleting the case root, Cleanup verifies each case against its external handoff. Use `-ArchiveDirectory` for moved handoffs.

```powershell
& $swp -Stage Cleanup
Test-Path -LiteralPath 'C:\SWP-Perf'
Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'SWP-PerfTools')
```

After successful deletion these checks return `False` and `True`, respectively. Tools and tool-generated files under Program Files, native agent diagnostics, installed Trend logs, Windows event logs and external handoffs have their own retention lifecycle. For “INI state missing”, keep the current INI and the case, review the saved state and backups with the policy owner, and use the recovery guidance.

## Read the evidence

Open `Evidence-assessment.json` first. Establish which account, boot, time zone and reproduction the package describes. Then use the following paths relative to the extracted evidence ZIP.

| Artifact | What it answers |
|---|---|
| `Operator-notes.json` and `Test-notes.txt` | What the person saw, approximate or exact times, apps and baseline. Check their precision. |
| `WPR\PassA-BootLoginApps.etl` | Process lifetimes, logical file I/O and physical disk I/O. The same file name serves both sign-in scenarios. Open it in Windows Performance Analyzer. |
| `WPR\SignIn-milestones.json` and `WPR\Trace-quality.json` | Authentication, Explorer, session corroboration, save status and recognized loss warnings. A saved trace can still have unknown loss. |
| `Trend\Timed-scans.csv` and `Trend\AMDebug` | Deduplicated paired engine scans and the raw log generations that support them. Look for `InAuthenticatedSignIn` and check the associated milestones and gaps. |
| `Trend\LiveMetrics\PassA` and `Trend\PassA\VerifiedToolMetrics\Metrics-assessment.json` | Preserved tool batches, embedded host and timestamps, cadence and overlap. Retry snapshots can have a `PassA-Retry-…` name. |
| `Trend\PassA\AgentMetrics` and `SupportToolSnapshot` under that pass | Ordinary agent metrics, tool configuration and available CMD log/config output. A successful task alone gives no sampling result. |
| `Trend\FinalDiagnostics` | Latest native request status and per-request ZIP, checked copy, inventory, extracted debug or Top 10 report when present. |
| `Events` and `Context` | System/Application and available operational EVTX exports, elevated administrator’s gpresult, selected login-task XML, script copies and policy exports. |
| `Cleanup` and `File-inventory.csv` | Original states, run identity, backups and inventories used in recovery and verification. The external handoff receipt is written locally after the ZIP is finished. |

In WPA, locate the authenticated session and Explorer launch, select that time range and inspect file or disk I/O by process and path. Correlate it with Trend’s paired scan records and the user’s observed wait. The focused profiles record process/thread and file/disk activity. Use additional tracing if the question requires other providers.

## Interpret scan times

**What counts as a timed scan.** AMSP supplies a scan start with a path and a completion on the same process/thread with an engine duration in microseconds. The collector pairs them and writes start, end, thread, path and both duration units. `4,445 µs = 4.445 ms`. Concurrent scans can overlap. Their summed engine time can exceed the elapsed sign-in time.

**Worked example (synthetic).** Suppose Windows records a sign-in at 10:00:00 and Explorer starts at 10:00:08. If the first paired AMSP scan starts at 10:00:15, Windows traced the sign-in but individual scan timings for those eight seconds remain unverified. A later 12 ms scan contributes only to the interval in which it occurred.

To review the longest recorded scans, open elevated PowerShell if the evidence location requires it. The following example uses an extracted copy, filters to the corroborated interval, and sorts the numeric microseconds before converting to milliseconds.

```powershell
$evidence = Read-Host 'Folder containing the extracted Evidence-assessment.json'
$rows = Import-Csv -LiteralPath (Join-Path $evidence 'Trend\Timed-scans.csv')
$rows | Where-Object InAuthenticatedSignIn -eq 'True' |
    Sort-Object { [long]$_.EngineMicroseconds } -Descending |
    Select-Object -First 10 Path, StartLocal,
        @{Name='EngineMs';Expression={[long]$_.EngineMicroseconds / 1000.0}}
```

**What justifies an exclusion trial.** First establish overlap with the reported delay, repeated material scans of the same path, effective scan policy and whether a narrow exception already exists. Compare against a controlled repeat with the same user, route, app and timing. Record each candidate’s exact path, software owner, expected improvement, risk and rollback. The policy owner decides whether to trial it. The kit applies no exclusions.

WPR file activity alone, a busy Trend process, a DLL name in a general log or a Top 10 frequency entry can suggest where to investigate. They supply different evidence from per-scan timings. The Top 10 report lists frequency and the last recorded duration for each item. An empty filtered CSV with unverified milestones leaves the question open.

## Recover an interrupted capture

| What you see | What to do next |
|---|---|
| Prepare stopped, WPR already armed or another recording exists | Stay in the current session. Read `Status` and the case’s WPR arm output. Identify the owner. Use the kit’s recovery or cleanup for its own run. Avoid issuing a second raw `-addboot` command. |
| No fresh AMSP log or signed control produced no pair | Keep the current case, verify the AM component, effective protection setting and actual debug folder. For same-boot mode, wait for a successful control before asking the user to sign out. Recover existing evidence before retrying in a fresh case. |
| StopTrace failed after reboot, or ETL is missing | Record the error and preserve the WPR output. Run `RecoverAndPackage`. Review the partial handoff for surviving Windows events, raw AMSP and metrics. |
| Saved ETL reports dropped events | Keep the ETL and report the loss. For a repeat, shorten the workload and use a fresh case with `-WprBuffers LargerBuffers` when memory permits. |
| DSA task shows Ready, nonzero result, or only a sample ZIP | Check `Task-result.txt`, `Collection-errors.txt`, tool log and metric timestamps. A bundled `SignedSampleCase.zip` is not output from this run. |
| No matching external handoff or case evidence changed | Preserve the case, produce a fresh verified Package for that case, transfer the pair and retry cleanup. Check each case in the root. |
| An INI, JSON or registry value differs from backup | Keep original/applied/current versions. Have the configuration owner reconcile drift. Retry restoration only after resolving ownership and evidence. |

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
$case = Read-Host 'Full path of the case needing recovery'
& $swp -Stage Status -Case $case
```

For a failed WPR save with readable phase state, run `& $swp -Stage RecoverAndPackage -Case $case`. If phase state is absent or unreadable, use `& $swp -Stage Package -Case $case -SkipDiagnostics` for available files once collectors have stopped. Report unknown coverage and unresolved restoration. Keep the original folder name during an active run. Renaming a case can break its task identity and handoff receipt.

## Follow a native diagnostic request

The scheduled DSA CMD tool collects metrics. The installed agent’s `dsa_control -d` separately requests a diagnostic archive after reproduction. The optional Trend diagnostic GUI is a separate vendor tool that an administrator can run if Trend support requests it. A normal finish automatically collects and verifies the native archive.

**Watch the write.** In a second elevated window, run `Status` for the same case. Check `Trend\FinalDiagnostics\Last-diagnostic-status.json` for `ExpectedPath`. In its `CLI-…` folder, read `Publication-progress.jsonl`, `dsa_control-output.txt` and `dsa_control-error.txt`. The watcher polls roughly every three seconds and reports roughly every 15 seconds. A matching temporary file can pause at one size while the agent finishes.

| State or symptom | Operator action |
|---|---|
| `Running` or `Submitting` | Leave the existing monitor in control. Keep the case and agent service running. |
| `AwaitingArchive` | The service named a ZIP. Wait for the current monitor to finish. If it exits pending, invoke Diagnostics on the same case to resume watching the same request. |
| `TimedOut` or `UnconfirmedRequest` | Inspect output, process identity and returned filename. Preserve the case and ask Trend support if the service never identifies its archive. Coordinate before any agent restart. |
| `Failed` or HTTP error | Review both command output files and agent status. Address the cause before a new request. |
| `Succeeded` | The exact fresh ZIP was readable and its copied SHA-256 matched. Check the inventory for `AmTopNScan.txt` and `debug.xml`. Either member can be absent. |

```powershell
& $swp -Stage Diagnostics
```

Run Diagnostics after any prior monitor has exited. A standalone Diagnostics command ends with an error if its result is incomplete. After success, if local restoration was deferred, run `& $swp -Stage RestoreTrace`, then `& $swp -Stage Package`. A partial handoff remains labelled as such until a subsequent archive includes the additional evidence.

The default publication wait permits 600 seconds without progress and has an overall cap of 30 minutes per attempt. Command execution has its own timeout. The original diagnostic stays in the agent diagnostic directory. Never substitute the newest unrelated ZIP for the named file.

## Optional Procmon repeat

Use the optional repeat when support needs Windows file operations from a separate restart. Allow space for the PML files and the combined ZIP. Obtain a compatible Process Monitor build. [Microsoft Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)

1. Finish A and confirm trace settings were restored. Before cleanup, coordinate self-protection with the policy owner. Select **Prepare Pass B** in the action list, click **Run selected action** and confirm.
2. Open Procmon as administrator, stop live capture and choose **Options → Enable Boot Logging** without thread profiling. Close Procmon and restart. For delayed sign-in, wait two minutes from the visible sign-in screen before entering credentials. Repeat the agreed timing and launches.
3. At the agreed milestone, use the reopened collector to click **Save Pass B early logs**. In Procmon save every PML segment in the displayed case’s `Procmon` folder. Turn off boot logging and exit Procmon.
4. Select **Open Pass B timing notes** and enter B’s actual times. Click **Finish B**, then **Package case**. Check `Evidence-assessment.json` for B’s scan coverage, PML integrity and event exports.

```powershell
& $swp -Stage PrepareB
# After reproduction
& $swp -Stage SaveDebug -Pass PassB
# After saving PML and closing Procmon
& $swp -Stage FinishB
& $swp -Stage Package
```

If a PML could not be saved, close Procmon after disabling boot logging and choose **Recover Pass B and package**, or run `& $swp -Stage RecoverAndPackage -Pass PassB`. Review the partial ZIP. Pass A events remain in `Events`; B events are in `Events\PassB`. Only paired AMSP records support per-file engine times.

## Stage reference

Use one `-Stage` per command (`-Action` is an alias). Both GUI and CLI use the saved case.

| Stage | Purpose and expected next step |
|---|---|
| `Gui`, `Help` | Open the administrator window or print a workflow summary. |
| `InstallTools` | Run from the extracted kit. Installs the two verified vendor bundles, the collector and both WPR profiles into Program Files. |
| `Prepare` | Creates a fresh case, backups, temporary config and an owned metrics task. Arms the requested WPR scenario. Wait for Prepared. |
| `WatchAMSP`, `ResumeGui` | Internal tasks preserve rotated logs and reopen the reboot case in the preparing administrator’s session. |
| `StopTrace` | After the milestone, starts a raw AMSP snapshot, saves the owned WPR ETL, records quality and attempts to correlate the sign-in. |
| `Finish` | Retrieves Pass A evidence, requests diagnostics unless skipped, exports events and attempts trace restoration. Use Package separately. |
| `FinishAndPackage` | Runs Finish for Pass A, then creates the verified full-case archive. |
| `Status` | Shows recorded collection and diagnostic state, WPR/task status and available progress information. Safe to consult in a second console. |
| `CollectContext` | Captures selected task definitions, designated script files and local exports into a timestamped context folder. |
| `Diagnostics` | Starts a native diagnostic or resumes an existing pending request. Check for Succeeded before restoring deferred agent settings. |
| `Package` | Assesses the case, may request a missing diagnostic or resume a pending one, creates a versioned ZIP and writes its checksum. |
| `RecoverAndPackage` | Runs the recovery form of Finish for the selected pass and packages available evidence. Review WPR and other gaps. |
| `RestoreTrace` | Restores the saved local AM trace configuration and checks its readback. Use Cleanup for the other saved settings. |
| `PrepareB` | After a finished A and before cleanup, prepares the optional reboot/Procmon repeat. Start Procmon boot logging manually. |
| `SaveDebug` | Copies current/rotated AMSP generations for the selected pass. Use `-Pass PassB` for the optional repeat. |
| `FinishB` | Checks the saved PML, retrieves Pass B evidence and attempts trace restoration. Use Package for the combined handoff. |
| `Cleanup` | Restores saved local configuration across the root. With `-KeepEvidence` retains case files. Default deletion covers every case. |
| `CaptureMetrics` | Internal SYSTEM task entry point. Validates the case, pass and run identity, runs the CMD tool and preserves completed batches. |

## Parameter reference

Values below are the defaults of the released collector. PowerShell variables defined in an old login session need to be set again after sign-in.

| Parameter | Meaning and limits |
|---|---|
| `-Stage`, alias `-Action` | Explicit stages run headlessly except `Gui`. Omit the stage for the desktop window. |
| `-Case` | Optional explicit path under `C:\SWP-Perf` with a `CASE-` prefix. Prepare selects the next number from local cases and default handoff ZIPs. Later stages resume the unique active case. Cleanup covers the root. |
| `-Scenario` | `Reboot` by default, or `SignOutSignIn`. Select at Prepare. |
| `-AffectedUser` | Interactive `DOMAIN\user` or `COMPUTER\user`. Prepare attempts the computer’s reported signed-in user when omitted. Specify explicitly for RDP or alternate administrator credentials. |
| `-WprBuffers` | `Standard`, 32 MiB, or `LargerBuffers`, 128 MiB. Select at Prepare. These are buffer allocations, independent of eventual ETL size. |
| `-Pass` | `PassA` by default, or `PassB` for SaveDebug, recovery and task operations that select a pass. Finish and FinishB select their own pass. |
| `-IncludeNetwork` | Optional extra WPR Network profile during Prepare. Adds trace volume. The CMD tool’s packet capture remains disabled. |
| `-AllowDiagTrackMiniLogger` | Prepare can accept specifically recognized background DiagTrack sessions if WPR otherwise reports idle. Other sessions still require owner review. |
| `-AmspDebug` | Default `C:\Program Files\Trend Micro\AMSP\debug`. Supply a verified alternate log location at Prepare. Phase state records the selected location. |
| `-AgentFolder` | Defaults to `%ProgramFiles%\Trend Micro\Deep Security Agent`. Directory containing the installed native diagnostic command. |
| `-DiagnosticFolder` | Defaults to `%ProgramData%\Trend Micro\Deep Security Agent\diag`. Used for diagnostic discovery/baseline. The service response supplies the exact requested name. |
| `-ArchiveDirectory` | Default `C:\SWP-Handoff`. Use a local directory external to the case root. Supply again for a moved handoff during cleanup. |

## Timing and context options

| Parameter | Meaning and limits |
|---|---|
| `-ArtifactWaitSeconds` | Integer 0–600. Default 600. Controls the wait for evidence artifacts. During native publication, file progress renews the idle window. Values near zero can leave a still-writing diagnostic pending. |
| `-DiagnosticTimeoutMinutes` | Integer 1–120. Default 30. Bounds CLI execution and separately caps a native publication monitoring attempt. |
| `-SkipDiagnostics` | Explicitly skips a new native diagnostic attempt on applicable finish/package actions. Expect an evidence gap when no verified native ZIP exists. An existing pending request can still prevent restoration. |
| `-LoginTask` | Array of exact scheduler paths. Default `\IntuneDriveMapping`. Specify other relevant tasks at Prepare or CollectContext. |
| `-LoginScriptPath` | Array of explicit local PS1/VBS files, empty by default. CollectContext copies definitions and hashes. |
| `-PolicyExportFolder` | Optional dedicated local directory of XML, CSV and JSON exports. Preserve the exported hierarchy and confirm completeness with the policy administrator. |
| `-KeepEvidence` | Cleanup restores settings while retaining the case tree. Use before archive verification or while awaiting recipient confirmation. |
| `-RunId` | Internal task identifier, 32 lowercase hexadecimal characters. The script generates it when preparing a phase. |

**Common path map.** Distribution files live in the extracted kit. Executables, vendor files and focused profiles live under `%ProgramFiles%\SWP-PerfTools`. Case files and restoration backups live under `C:\SWP-Perf\CASE-…`. Verified outer ZIPs and their checksums normally live under `C:\SWP-Handoff`. The software ZIP and case output have different names so the recipient can identify which to install and which to analyze.

**Custom settings.** Treat path and timeout overrides as invocation parameters. Repeat applicable overrides on later diagnostic, package and cleanup commands. Use the same case path throughout a live sequence. Choose the larger WPR profile for a fresh reproduction after reviewing trace loss. The profile changes memory usage and cannot repair an already saved ETL.

## Developer architecture

`SWP-Perf.ps1` is the Windows entry point. Its top-level parameter block and final switch define the command interface. Most collection and validation logic lives in named functions in the same file. The exported task invokes that installed copy under Windows PowerShell as SYSTEM. `InstallTools` checks the vendor ZIPs against embedded hashes and validates installed script/profile copies.

| Change area | Read these functions and files first |
|---|---|
| Ownership, lifecycle and identity | `Invoke-Prepare`, `Save-State`, `Read-CollectionState`, `Assert-CaseTrace`. Inspect `Cleanup\PhaseA-state.json` or `PhaseB-state.json` for host, run ID, phase, boot and timing fields. |
| Metrics task and ingestion | `Get-CollectionConfig`, `Write-CollectorConfig`, `Register-MetricsTask`, `Invoke-MetricsWorker`, `Copy-NewMetricBatches`, `Copy-ToolMetrics`, `Get-ToolMetricsAssessment`. |
| WPR and session attribution | Both `SWP-SignIn*.wprp` profiles, `Invoke-StopTrace`, `Save-SignInMilestones`, `Get-WprSaveAssessment`. |
| Per-file engine timings | `Save-AMDebug`, `Confirm-WarmScanControl`, embedded C# in `Initialize-ScanReader` and `Get-ScanCoverage`. |
| Native ZIP lifecycle | `Request-AgentDiagnostics`, `Invoke-DiagnosticRequest`, `Receive-DiagnosticArchive`, `Save-DiagnosticRecord` and `Test-DiagnosticPending`. |
| Closure and review | `Invoke-Finish`, `Get-CaseEvidenceAssessment`, `New-CaseArchive`, `Restore-PersistentAMTrace`, `Confirm-DebugRestoration`, `Invoke-Cleanup` and `Assert-HandoffsOutsideRoot`. |

**Lifecycle.** Prepare persists restoration data before configuration changes. An armed case can be measured and stopped. StopTrace stores both its request time and the WPR save invocation time. Finish disables the matched task, retrieves artifacts and attempts restoration. Packaging evaluates evidence separately. `Finished` describes workflow progress and can coexist with missing data.

**Ownership.** The task action is checked against the installed script, working directory, pass, case and run ID. WPR uses `SWP<RunId>` as its instance name. Same-boot mode checks the prepared boot. Reboot mode checks boot identity and startup evidence. Preserve these boundaries when changing recovery or cancellation.

## Developer configuration and evidence contracts

**Vendor configuration.** The script edits the complete supplied `DSTool.json` object, saves original and collection copies, writes the applied file as UTF-8 without a BOM, and checks the hash. `Get-CollectionConfig` requires the expected top-level sections. It turns off supported optional Check and Fix actions. Unexpected top-level features or unsupported actions cause preparation to stop for review.

| Section | Applied values |
|---|---|
| Metrics and Tool | `collectMetrics=1`, `MetricsIntervalInSecond=5`, `MetricsDurationInSecond=900`, `PressKeyToEnd=0` and `enableFeedback=0`. |
| Log Collection | `enableAMSP`, `enableUMH`, `enableEYES`, `enableAEGIS`, `enableLogCollection` and `timerInSecondDebug` are 0. `disableDebugAfterTimer=1`. |
| Process Monitor and WPR | `enableProcMon=0`, `enableChangeAltitude=0` and `enableWPR=0`. Both tool timers are 10 seconds. The script operates WPR independently. |
| Network Packet Capture and Network Check | `enableNetPCap=0`, `timerInSecondNetPCap=10`, `enableNetCheck=0` and an empty `URL2NetCheck`. |

**Live log preservation.** During the run, the watcher checks for newly rotated AMSP files every two seconds. At the stop signal it also copies the active file. Review the pass-specific live folder, final result and copy errors.

**Persistent agent tracing.** The script backs up `%SystemRoot%\ds_agent.ini` if present, records absence if applicable, and merges `AM,AMSP,dsp.am.*` into a supported single Trace directive. A wildcard already covers those tokens. It checks encoding and refuses ambiguous formats. The INI persists through reboot. The CMD tool’s `enableAMSP=0` does not disable this separately requested agent trace. [Trend AM debug procedure](https://success.trendmicro.com/en-US/solution/KA-0004561)

See `Documentation/DSTool-collection.example.json` for a full applied JSON example for the bundled build. Prepare reads and updates the installed vendor file.

The script records the original and applied values under `HKLM\SOFTWARE\TrendMicro\AMSP\AmspConfig\Debug` and validates restoration. This release exposes no parameter to set a particular log rotation count or file size. It mitigates rotation by preserving generations at StopTrace. During restoration it handles expected changes using saved values and checks for independent drift.

**Metrics and scan parsing.** The worker preserves completed `*_jsonRecords.json` batches while the tool is running. Retrieval also checks the archive named in the completion log. Metrics validation checks embedded host and UTC timestamps, deduplicates sample times and reports cadence and gaps. Near-five-second cadence requires at least three unique sample times and a median of 2.5–7.5 seconds. Internal gaps above ten seconds are reported.

## Developer integrity and recovery contracts

**Correlating a session.** The collector matches the affected account’s Windows Security event 4624 with a new Explorer process and LocalSessionManager event 21. It recognizes a linked pair of split administrator logon tokens. Ambiguous or missing evidence leaves the interval unverified. A human reporting “desktop ready” supplies an additional endpoint to the measurement.

**Pairing scans.** The reader attributes AMSP start/completion records by process/thread and deduplicates copies across overlapping log generations. It retains unmatched-record and parse-error counts. `InAuthenticatedSignIn` identifies pairs wholly inside the corroborated authentication-to-Explorer interval. The reader has a small pre-window allowance and reads retained generations through five minutes after the stop request. Check raw logs if studying later activity.

**Publishing a native archive.** A case lock serializes requests. The script saves the pre-request directory listing, command streams, request identity and exact returned path. A CLI exit code or HTTP success alone cannot complete a request. The collector follows the matching temporary/final names, checks stability and freshness, reads all ZIP entries with a writer-excluding handle and verifies the hash of the copied case file. If a previous monitor exited pending, retrieval resumes from its recorded request. [Trend agent CLI](https://help.deepsecurity.trendmicro.com/20_0/on-premise/command-line-interface.html)

**Packaging.** The case walker rejects links/junctions. The packager writes a temporary archive, compares member count, sizes and hashes with the source, and checks for source changes. After verification it publishes the archive and checksum and records a machine/case-bound receipt. A repeat after additional evidence produces a new timestamped handoff. Operators should review errors recorded in `Collection-errors.txt` even if Finish returned.

**Recovery boundaries.** Recovery can collect surviving data after a WPR save failure. Verify task/trace ownership before cancelling anything, preserve unknown sessions, and keep original backups when checks fail. RestoreTrace handles local agent trace settings. Cleanup also handles task, tool configuration and event channels. Deletion requires external handoffs for every case. Keep Program Files, ordinary agent diagnostics and Windows event history outside recursive case cleanup.

**Compatibility.** Preserve the input and output contracts on Windows PowerShell 5.1. Changing a stage, parameter default, task wrapper, state field, archive path, BOM or duration unit requires corresponding regression coverage and documentation. Treat an established customer case directory as recovery evidence when upgrading a release.

## Developer tests and release

The extracted package includes the exact `Developer\CollectionScript.Tests.ps1` harness. In an elevated Windows PowerShell 5.1 session on a test machine, set the location to the extracted kit and run the portable tests. Use a separate results directory for each release. The five-minute native-publication test makes this run take several minutes.

```powershell
$kit = (Resolve-Path 'C:\SWP-Customer-Kit').Path
$harness = Join-Path $kit 'Developer\CollectionScript.Tests.ps1'
$out = Join-Path $env:TEMP ('SWP-TestResults-' + (Get-Date -Format yyyyMMdd-HHmmss))
& $harness -SourcePath (Join-Path $kit 'SWP-Perf.ps1') `
    -VendorKitRoot $kit -ResultsFolder $out -LongPublicationTest
Get-Content -LiteralPath (Join-Path $out 'Regression-results.json') -Raw
```

The harness imports functions without running the production dispatcher. It exercises real Windows file I/O, ACLs, robocopy and ZIPs and simulates selected service, tracing and scheduler interactions. The tests generate their sign-in and metrics records locally. The overlap fixture checks that repeated copies of one scan are counted once while two separate scans of the same path are retained.

**For a code change**, run the fixture suite, then install from the rebuilt kit on a protected Windows test machine. Exercise reboot, same-boot sign-out/sign-in and failed WPR save/recovery. Open each transferred handoff. Verify ETL interval/loss, session corroboration, scan rows, transient metric batches, exact native ZIP and errors. Check original INI, registry values, vendor JSON, event channels, service state, task removal, unrelated WPR sessions, free space, Program Files retention and external handoffs. Repeat cleanup to check idempotence. Record actual OS, agent, harness result and collector SHA-256 in the validation summary.

**For a documentation release**, compare the shipped script, WPR profiles and pinned vendor binaries with the tested release. Verify all paths and command examples against the script. Build the distribution with `Developer/build_kit.py` as described in `Developer/README.md`. Verify the external checksum after transfer. Share only the distribution and its checksum with the endpoint operator.

**Further reference.** The kit’s primary evidence is its released script and `Validation-summary.json`. Official product references are available from [Trend DSA Support Tool](https://success.trendmicro.com/en-US/solution/KA-0012444), [Trend native agent commands](https://help.deepsecurity.trendmicro.com/20_0/on-premise/command-line-interface.html) and [Microsoft WPR command reference](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options).

## Actions in the collector window

The main button shows the next normal step. For a reboot capture, click **Stop trace now** when the desktop or agreed application responds. For an interrupted capture or another action, open the drop-down. Selecting an item displays its description beside the buttons or below them on a narrow window. Only **Run selected action** starts the selected operation.

| Menu label | Purpose and scope |
|---|---|
| **Show status** | Inspect the current case, its recording and tasks. Collection continues. |
| **Recover and package** | Salvage an interrupted Pass A and package the current case with identified evidence gaps. |
| **Restore trace settings** | Restore the agent trace settings saved for this case. The agent may restart. Use after measurement. |
| **Restore settings and keep evidence** | Restore settings and remove collector tasks across all local cases. This can end an active capture. All case files stay on disk. |
| **Delete all local cases** | After external handoff checks and confirmation, restore settings and delete everything under `C:\SWP-Perf`. Installed tools and external handoffs are retained. |
| **Package case** | Create a verified ZIP and checksum for this case. Packaging may request or resume its native diagnostic. |
| **Resume or request diagnostic** | Resume the pending native agent diagnostic or request a fresh one for this case. |
| **Prepare Pass B** | Arm the optional Procmon repeat for this case. Follow the boot logging instructions before restarting. |
| **Recover Pass B and package** | Salvage the interrupted second pass and package both passes for this case. |

**Windows Task Scheduler.** The background entries are separate from these menu actions. `SWP-Perf-DSAMetrics` runs the DSA CMD collector. `SWP-Perf-WatchAMSP-<run ID>` preserves rotated AMSP logs. `SWP-Perf-ResumeGui-<run ID>` reopens the prepared reboot case once for the local administrator. The launch time is in `Cleanup\<pass>-GUI-launch.json`. Finish or recovery retires the pass-specific tasks. Cleanup also removes the owned DSA metrics task.
