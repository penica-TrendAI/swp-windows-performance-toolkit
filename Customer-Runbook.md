# Windows sign-in and application startup collection

**For the Windows administrator and Trend Micro policy administrator**

**Collector revision** 26 November 2026 · **Documentation edition** 26 November 2026

For role-specific instructions, see the [full handbook](Documentation/SWP-Perf-Handbook.pdf). Give the person signing in the [one-page participant instructions](Documentation/Participant-sheet.pdf). When the affected user is also a local administrator, use the [solo administrator checklist](Documentation/Administrator-participant.pdf) or its [copyable commands](Documentation/Administrator-participant.md). Developers can start with the [maintenance guide](Developer/README.md).

Use this kit on one affected Windows 10 or Windows 11 computer with the TrendAI Vision One Server & Workload Protection / Deep Security Agent already installed. It collects the slow reboot, sign-in and first application launches in one pass. The scheduled Trend CMD tool samples agent metrics every five seconds for 15 minutes after initialization. The task has a 45-minute cap. WPR captures Windows file I/O and process starts. The script separately checks whether AMSP logged paired per-file scan timings during sign-in. An immediate sign-in in the lab had no paired scan records between authentication and Explorer. In a separate lab run, waiting two minutes at the sign-in screen produced 218 paired scan timings across 211 paths between authentication and Explorer. The handoff assesses coverage for each run. If the delay also occurs after signing out, the same-boot scenario provides a second way to measure it.

## 1. Set up on the affected computer

1. If using the GitHub source, add the two pinned archives following [vendor prerequisites](Tools/README.md). If using a preassembled kit, extract the complete customer ZIP into a local folder such as `C:\SWP-Customer-Kit`. Keep the two `.wprp` profiles and the `Tools` folder beside `SWP-Perf.ps1`.
2. Open **64-bit Windows PowerShell as administrator**. Run the following, adjusting the extracted folder path if necessary.

   ```powershell
   Set-Location -LiteralPath 'C:\SWP-Customer-Kit'
   .\SWP-Perf.ps1 -Stage InstallTools
   $toolRoot = Join-Path $env:ProgramFiles 'SWP-PerfTools'
   $swp = Join-Path $toolRoot 'SWP-Perf.ps1'
   ```

   Setup checks the bundled archives by SHA-256 and extracts Trend's CMD and GUI support tools, build **1.0.0.1203**. It reuses a matching executable and preserves the existing tool configuration. If Windows blocks script execution, use your organization's approved signing or execution process.

3. Check Windows Performance Recorder and the installed sign-in profile.

   ```powershell
   Get-Command wpr.exe
   wpr.exe -profiles "$toolRoot\SWP-SignIn.wprp"
   wpr.exe -status
   ```

   Confirm the file lists **SWPSignIn**. If WPR is missing or the profiles are unavailable, obtain Windows Performance Toolkit from Microsoft. If a WPR recording is active or already armed, resolve its ownership before preparing this collection. [Microsoft WPR reference](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options)

4. Allow time for one reboot and up to 45 minutes for the metrics task, plus diagnostic generation and packaging. Phase A preparation checks for at least **20 GB free on C:**. Long file-mode recordings can grow well beyond this minimum. Plan substantially more free space for long captures, and keep this reproduction short. Packaging also requires room for a complete second copy of the case on the archive destination. Confirm the installed agent service **ds_agent** is running. Confirm standard users cannot modify the tools folder or CMD tool files, because Task Scheduler runs the collector as SYSTEM.

### Choose the collector window or PowerShell

After installation, open **SWP Performance Collector** from the Windows Start menu and approve elevation. You can also run `& $swp` or `& $swp -Stage Gui` in an elevated desktop PowerShell session. If your organization restricts scripts, launch from its approved PowerShell environment. On a Windows client with every execution-policy scope unconfigured, the shortcut starts its child with process-only RemoteSigned. Explicit policies still apply. The separate **Trend DSA Support Tool GUI** is for vendor diagnostics.

| When | Collector window | Command line |
|---|---|---|
| Before measuring | Confirm the affected account and scenario. Click **Prepare new capture** and wait for **Prepared**. | `& $swp -Stage Prepare -Scenario Reboot`, or choose `SignOutSignIn`. Add `-AffectedUser` for the agreed account. |
| At the sign-in screen after restart | Wait **two full minutes** from when the Windows sign-in screen first appears, then sign in locally. The collector reopens for the same administrator. | The same two-minute wait applies. Use `-NoAutoResume` with Prepare for a CLI-only capture. |
| At the agreed sign-in or app milestone | Click **Stop trace now** in the collector. If the window is closed, open **SWP Performance Collector** from Start. | `& $swp -Stage StopTrace` |
| After the trace is saved | Use **Open timing notes**, save the times, then **Finish and package**. Keep the window open and watch the action output. | Complete the notes and run `& $swp -Stage FinishAndPackage`. |
| After handoff | **Open handoff folder**. Transfer the ZIP and checksum. Select **Restore settings and keep evidence**. | `& $swp -Stage Cleanup -KeepEvidence` |
| If interrupted | Choose **Show status**, read the saved state and follow the recovery section. | `& $swp -Stage Status`. All recovery, optional Pass B and advanced switches remain available. |

GUI and CLI can be mixed within a run. For a reboot case, the window reopens once when the preparing administrator signs in to the affected account. A different account or a CLI-only capture can resume manually. Explicit collection, packaging, scheduled-task and cleanup stages run directly. Automated sessions should supply their stage. With no stage, a headless Windows session displays Help.

### Actions in the collector window

During a normal reboot capture, use the main **Stop trace now** button at the agreed milestone. The drop-down offers additional actions according to the case state. Selecting an entry only highlights it. Read the description beside the menu, or below it on a narrow window. Click **Run selected action** to execute it.

| Exact menu label | When to use it and what it affects | PowerShell equivalent |
|---|---|---|
| **Show status** | Inspect the current case, WPR and task state. Safe while collection is running. | `-Stage Status` |
| **Recover and package** | An interrupted Pass A cannot finish normally. Collect surviving logs and events, attempt restoration and package the selected case with any gaps identified. | `-Stage RecoverAndPackage -Pass PassA` |
| **Restore trace settings** | End temporary agent tracing for the selected case and restore its saved INI state. The agent can restart. Use after the measured window. Other collection settings and case files are retained. | `-Stage RestoreTrace` |
| **Restore settings and keep evidence** | After handoff or during approved cleanup, restore saved settings and retire owned tasks across **all local cases**. Leaves case folders and their contents on disk. | `-Stage Cleanup -KeepEvidence` |
| **Delete all local cases** | After verifying the external handoffs, restore settings and delete **everything under `C:\SWP-Perf`**. The GUI asks for confirmation. Installed tools and external handoffs are retained. | `-Stage Cleanup` |
| **Package case** | Create a verified handoff ZIP for the selected case. If needed, packaging can request or resume the native diagnostic. | `-Stage Package` |
| **Resume or request diagnostic** | Resume the selected case’s pending native agent diagnostic or request a fresh one. | `-Stage Diagnostics` |
| **Prepare Pass B** | After Pass A finishes and before cleanup, arm an optional Procmon repeat for the same case. Enable Procmon boot logging as instructed. | `-Stage PrepareB` |
| **Recover Pass B and package** | Salvage an interrupted Pass B and package both passes for the selected case. | `-Stage RecoverAndPackage -Pass PassB` |

## 2. Record the baseline and prepare Phase A

Record a normal sign-in and launch of each affected application with collectors off, if you can reproduce the problem that way. Write down the computer, Windows and agent versions, connection type, affected user/session, time zone, application names and observed delay. Use the same account, connection and applications for the capture.

In the Trend management console, record the original **Agent Self-Protection** value and whether the computer inherits it. Temporarily disable self-protection for this test computer and verify the updated setting reached it. The test uses an agent service restart to apply the debug configuration, and later to restore it. [Trend anti-malware debug logging procedure](https://success.trendmicro.com/en-US/solution/KA-0004561)

Close collection GUIs and ensure any Procmon boot logging is off. Then run:

```powershell
& $swp -Stage Prepare
```

Wait until the script says **Prepared**. The script also exports the selected login-task XML; its default is `\IntuneDriveMapping`. A missing task is recorded as a context gap and does not change or create that task. Use `-LoginTask '\YourTaskName'` with Prepare if another task is relevant. The script saves configuration backups, enables temporary collection settings and arms WPR and the startup metrics task. If preparation stops with an error, retain the case and record the error. Use `Status` to inspect it and follow the recovery section before trying another preparation. If your AMSP debug folder is custom, supply its full path with `-AmspDebug` during preparation.

Prepare prints the allocated case path. The first is `C:\SWP-Perf\CASE-01`. Subsequent numbers are one higher than the largest numeric case under that root or in the ZIP names under `C:\SWP-Handoff`. Custom names and other archive locations do not reserve numbers. The saved phase record identifies the computer, case path and run ID. Later stages automatically resume the unique active case. If several retained cases exist and none is active, select one with `-Case 'C:\SWP-Perf\CASE-02'`. An unfinished case must be resolved before preparing another. After verified handoff, `Cleanup -KeepEvidence` restores the settings and closes the active case. The next Prepare allocates a new number. If both numbering locations are empty, numbering starts at 01 again.

### Choose the sign-in scenario

Use the default `-Scenario Reboot` when a restart is needed to reproduce the delay. If the user experiences the same delay after a full sign-out, prepare that scenario on the already running workstation instead. Choose one Prepare command per case.

```powershell
& $swp -Stage Prepare -Scenario SignOutSignIn -AffectedUser 'DOMAIN\affected.user'
```

Substitute the actual interactive account. The script verifies a signed Windows executable produces a timed AMSP scan before arming a machine-wide WPR recording. When it prints **Prepared**, save work, choose **Sign out**, and sign back in to that account. A lock/unlock or RDP disconnect/reconnect does not reproduce a full sign-in. If the control fails, keep the session open and use recovery. The default WPR buffer allocation is 32 MiB. Use `-WprBuffers LargerBuffers` (128 MiB) on a fresh run if the earlier ETL reported event loss and the machine has sufficient memory.

### First sign-in after a restart

1. Prepare the case while signed in as the local administrator who will reproduce the issue. Save work and choose **Restart**. Ensure this is a manual sign-in so the credential screen can be held.
2. **When the Windows sign-in screen first appears, wait two full minutes, then sign in locally.** For a case specifically investigating the usual immediate sign-in, sign in at the usual pace and label the run **immediate**.
3. The collector reopens once in the preparing administrator's desktop session. At the agreed desktop or application milestone click **Stop trace now** for Pass A, or **Save Pass B early logs** for Pass B. Use the Start shortcut if the window is closed. An explicit `-NoAutoResume` on Prepare keeps the workflow CLI-only.
4. Record the timing choice and screen-visible time in `Test-notes.txt`, then enter the credential and usable-desktop times in `Operator-notes.json`. Keep the pre-credential wait separate. The launch timestamp, session and process ID of the reopened GUI are in `Cleanup\<pass>-GUI-launch.json`.

**What the two minutes establish.** On a Windows 11 lab machine running DSA 20.0.3-31610, the delayed sign-in produced 218 scans across 211 paths entirely between authentication and Explorer startup. The customer build 20.0.3.29020 belongs to the same 20.0.3.* family. Evidence assessment verifies the actual sign-in coverage for each capture.

**How the script preserves AMSP logs.** Windows schedules a separate background task at startup, or starts it at Prepare for a same-boot capture. Actual startup can lag boot. The watcher’s `StartUtc.txt` records when it began, and its first sweep includes retained rotations modified since this boot. Every two seconds it checks for newly rotated `Amsp_LocalDebugLog.<n>.log` files. It saves each observed version in `Trend\AMDebug\<pass>-Live-<run ID>`. At the stop signal it also captures the active file. The existing early and final snapshots still collect the general agent logs. The watcher stops after 45 minutes if no stop signal arrives and reserves 1 GiB of free space when copying. Check `Result.json` and any `Copy-errors.txt` in the live folder. A generation reused between checks can still be missed.

At handoff, review `SignInScans` or `PassBSignInScans` in `Evidence-assessment.json`. `SignInScanStarts` counts observed starts, `SignInStartPaths` counts their distinct paths, and `SignInPairs` counts scans that both started and finished before Explorer appeared. The per-pass `Trend\<pass>-SignIn-scan-starts.csv` includes starts with missing or later completions. An unverified sign-in window has no verified count.

## 3. Reproduce and save the trace

1. For a reboot, follow the first-sign-in procedure above. For a same-boot capture, sign out and sign back in after **Prepared**. Aim for the first two to three minutes or one representative slow launch; do not leave WPR running while waiting for the 15-minute metrics collection.
2. Sign in as the affected user and reproduce the slow first launches. Record the times of restart, credential submission, usable desktop, each app launch and when it became usable. Include the time zone.
3. At the agreed milestone, the affected person reports that the desktop or application is ready. If that person is a local administrator, they can open a new elevated PowerShell themselves. Otherwise the endpoint administrator stops WPR on that same computer, using the existing authorized administrative session or elevating locally after the milestone. Keep the affected person’s interactive session available for correlation. Do this before waiting for the DSA CMD task.

   ```powershell
   $swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
   & $swp -Stage StopTrace
   ```

4. Complete `Operator-notes.json` in the case printed by Prepare with the actual times. Keep baseline observations, self-protection settings and other context in `Test-notes.txt`. Enter credential submission and usable-desktop times. For a sign-in-only test, use `"Applications": []`. Otherwise enter each tested application and its launch/ready times. Use ISO dates with the timezone offset, for example `2001-06-15T09:15:02+01:00`; substitute the actual capture date/time. A blank template is reported as incomplete. If an application never became ready, leave ReadyAt blank and describe the timeout/symptom; do not invent a ready time. Applications recorded outside the Pass A reproduction window are flagged for coverage review.

   ```json
   {
     "CredentialSubmittedAt": "",
     "DesktopReadyAt": "",
     "Applications": [
       { "Name": "", "LaunchAt": "", "ReadyAt": "", "Symptom": "" }
     ],
     "Baseline": "",
     "OriginalSelfProtection": "",
     "RestoredSelfProtection": ""
   }
   ```

   StopTrace starts the early AMSP log copy in a separate process, then asks WPR to save immediately. It keeps the active log, generations modified since preparation, and one preceding generation. A copy failure is recorded and does not prevent stopping WPR. The saved state records both the operator's stop request and when WPR saving was invoked. Check `WPR\Trace-quality.json` for detected event loss. A successful save does not verify boot markers or complete login coverage.

## 4. Finish and package

```powershell
& $swp -Stage FinishAndPackage
```

Keep PowerShell open. Finish waits for the SYSTEM task and Trend CMD collector. During collection the task copies completed metrics batches into `Trend\LiveMetrics\PassA` while they are still available. Finish also checks the tool’s completion log and any remaining metrics files. Review the hostname, embedded sample timestamps, first and last sample, cadence, and gaps in the metrics assessment.

**Wait for the native Trend diagnostic.** The script calls `dsa_control -d` once and watches the exact filename the agent returns. It checks about every three seconds and displays progress about every 15 seconds. “Writing temporary file” is expected, and the byte count can pause. When the final ZIP is stable, the collector reads its members and verifies the SHA-256 of the case copy. The original ZIP stays in the agent’s diagnostic folder. Look under `Trend\FinalDiagnostics\CLI-...\` for the copied ZIP, its inventory, its checksum, and `Publication-progress.jsonl`. If the archive contains `debug.xml` or `Agent/AMSP/AmTopNScan.txt`, the collector also extracts a copy. The Trend Top 10 report ranks scan frequency and gives the last duration recorded for each listed file. It does not total all scans during sign-in. [Trend agent commands](https://help.deepsecurity.trendmicro.com/20_0/on-premise/command-line-interface.html)

The default publication wait allows ten minutes without a file change and up to 30 minutes overall per monitoring attempt. The CLI itself has a separate 30-minute timeout. Use a second elevated PowerShell window to see progress at any time. If the collector reports **AwaitingArchive**, let the agent continue. Keep the original case and use these commands when ready.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage Status
& $swp -Stage Diagnostics    # Resume once the previous monitor has exited.
```

When the status is **Succeeded**, run `-Stage RestoreTrace` if restoration was deferred and `-Stage Package` to include the result. An earlier ZIP marked with evidence gaps remains a partial handoff. Never restart the agent while the diagnostic is being written. A completed native diagnostic and an outer case ZIP are separate artifacts.

Wait for **ARCHIVE INTEGRITY VERIFIED** and note the printed paths. If the message also says **EVIDENCE GAPS REMAIN**, preserve the ZIP but report it as partial evidence. Review `Evidence-assessment.json`, the packaging summary and `Trend\PassA\VerifiedToolMetrics\Metrics-assessment.json`. A ZIP containing metric records is recognized even when there is no loose JSON. Sampling gaps and initial agent-readiness gaps are reported separately; Pass A/B are assessed in their own time windows. Archive verification checks file integrity. For collection coverage, verify the WPR save output for event loss and compare the metric and debug log timestamps with the recorded delay. A scheduled task exit code of 0 alone cannot establish that metric samples were captured.

Restore the original self-protection setting or inheritance through the management console, verify that it has applied and record the restoration time. **Original INI restored does not necessarily mean debug is disabled.** If debug was already requested before the test, restoration deliberately retains it and issues a warning. Review the intended normal logging state with its owner/Trend support; do not delete a pre-existing INI by guessing. If you update the notes or add evidence after packaging, run `& $swp -Stage Package` to create a new verified ZIP. If Trend support also requests a GUI support-tool package, run the bundled GUI from `C:\Program Files\SWP-PerfTools\DSASupportTool_GUI`, use **Collect Data**, copy its result into the current case’s `Trend\FinalDiagnostics`, close the GUI and rerun `Package`.

### Add the relevant login and policy context

After collection, ask the policy administrator to export the **effective malware scan configuration and every assigned file, directory, extension and process-image exclusion list**, including inherited entries and any certificate/hash exceptions used. `GetConfiguration.xml` supplies names/mappings and cannot replace list-member exports. Save the console exports in a dedicated local folder such as `C:\SWP-ConsoleExports`. The script does not connect to the management console or infer that those exports are complete.

To include a relevant sign-in task and its scripts, replace the sample names below with the paths verified on the affected computer.

```powershell
& $swp -Stage CollectContext `
    -LoginTask '\ExampleSignInTask' `
    -LoginScriptPath @(
        'C:\Example\SignIn.ps1',
        'C:\Example\SignInHelper.vbs'
    ) `
    -PolicyExportFolder 'C:\SWP-ConsoleExports'

& $swp -Stage Package
```

Use the verified task/script paths for that computer and the same `-Case` as the collection. Repeat your selected `-LoginTask` here if it differs from the default. Only explicitly selected PS1/VBS files are copied; they are never executed by CollectContext. Task XML, script and policy-export copies have hashes and a `Context-manifest.json` under the current case’s `Context` folder. Missing or changed files appear in the handoff assessment. The administrator must still confirm that the exports include all effective list members.

Send the latest verified ZIP and its matching `.sha256.txt` through the agreed support channel. The case can contain identifiable file paths, process activity, system configuration and security logs.

The default handoff folder is `C:\SWP-Handoff`. To use a different local drive, supply the destination when packaging.

```powershell
& $swp -Stage Package -ArchiveDirectory 'D:\SWP-Handoff'
```

## 5. Restore settings and close the case

Confirm that WPR and Procmon are idle and any Procmon boot logging from this case is off. Once the needed diagnostics are saved, restore temporary local settings while retaining the case:

```powershell
& $swp -Stage Cleanup -KeepEvidence
```

Check the output for restoration errors. The action removes the scheduled collector and restores the saved tool configuration and Windows event channel settings. It also restores the original agent INI if collection stopped before that step. It cancels WPR only when a saved case state says this kit successfully armed an unsaved recording. Without that ownership record, WPR is left alone for manual coordination. It refuses recursive deletion through links/junctions or while an unidentified support-tool process remains. Use the Trend management console for self-protection restoration.

Retaining a case adds `Cleanup\Collector-closed.json` with the restoration time and the final Defender and SysMain observations. Package the retained case once more to include that record. Use the case path printed during your capture. For example, for CASE-01 run the following command.

```powershell
& $swp -Stage Package -Case 'C:\SWP-Perf\CASE-01'
```

Transfer the newest verified ZIP and its matching checksum. **After support has the evidence**, run `& $swp -Stage Cleanup` if the case should be deleted. This removes **all cases under `C:\SWP-Perf`**. Each case needs a hash-verified external handoff. Package each retained case that changed. If you moved the handoffs, pass their current directory with `-ArchiveDirectory`. Keep the Program Files tool installation for the next test.

## Optional Procmon pass

Use this only if support asks for a second, file-level capture. Obtain a build compatible with your Windows release directly from Microsoft. [Process Monitor download](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)

Finish Pass A and keep the case open. Do this **before Cleanup**, including Cleanup with retained evidence. Coordinate the recorded self-protection settings with the policy owner. Open the installed collector and use the following sequence.

| When | Administrator action |
|---|---|
| After Pass A | Select **Prepare Pass B** in the action list, click **Run selected action** and confirm. Wait for preparation to finish. |
| Before restart | Open Procmon as administrator, stop live capture, enable **Options → Enable Boot Logging** without thread profiling, then exit Procmon and restart Windows. |
| At the sign-in screen | Wait two full minutes from the visible sign-in screen for per-file timings. For an immediate comparison, repeat the timing used for Pass A. |
| At the agreed milestone | Repeat the agreed launches. As soon as the delay ends, click **Save Pass B early logs** in the reopened collector. This records the end time and preserves the available AMSP rotations. |
| Before finishing | Open Procmon as administrator. Save **every PML segment** into the displayed case’s `Procmon` folder, turn off boot logging and exit Procmon. Use **Open Pass B timing notes** for this repeat’s credential, desktop and application times. |
| Handoff | Click **Finish B**, then **Package case**. Check `Evidence-assessment.json` in the new combined ZIP. Pass A event logs are in `Events`, Pass B in `Events\PassB`. Packaging checks the names, sizes and hashes of the PML files present at finish. |
| If interrupted | Turn off boot logging and close Procmon. Choose **Recover Pass B and package** to retrieve available evidence even if you could not save a PML. Inspect the reported gaps. |

Allow time for conversion and verification. In the Windows 11 lab, a 7.0 GB raw boot log produced two PML segments totaling 5.48 GB. **Package case** took approximately 61 minutes to compress and verify the full 8.08 GB case on that VM. The 45-minute scheduled-task limit applies to DSA metrics collection. Leave the dashboard open until it shows **Open handoff folder** and the ZIP has a matching checksum.

The same workflow is available in elevated PowerShell. Run each stage at the corresponding point above.

```powershell
& $swp -Stage PrepareB
# After the restart and reproduction
& $swp -Stage SaveDebug -Pass PassB
# After saving every PML, closing Procmon and entering timing notes
& $swp -Stage FinishB
& $swp -Stage Package
```

For an interrupted B run use `& $swp -Stage RecoverAndPackage -Pass PassB`. Look for B’s paired scan records in `Trend\PassB-Timed-scans.csv` and its sign-in milestones in `Procmon\SignIn-milestones.json`. Counts measure the records that survived during each interval. A missing segment that was never saved by Procmon cannot be identified from the finish inventory alone.

Restore console self-protection and follow the handoff and cleanup steps above.

## Recovery and separate actions

| Action | When to use it |
|---|---|
| `-Stage CollectContext` | Export the selected login-task XML and copy explicit PS1/VBS definitions and a dedicated console-export folder. No scripts or tasks are executed. |
| `-Stage Status` | Inspect recorded state, startup-task status, and WPR state. |
| `-Stage Finish` | Copy evidence, request diagnostics and restore AM trace settings. Then add notes or additional diagnostics before packaging. |
| `-Stage Diagnostics` | Retry the agent diagnostic after troubleshooting. Read the output under `Trend\FinalDiagnostics`. Use `-AgentFolder` and `-DiagnosticFolder` for verified non-default agent locations. |
| `-Stage Package` | Archive existing data. Start a first diagnostic when needed or resume a pending publication. Use `-SkipDiagnostics` to archive without this attempt. |
| `-Stage RestoreTrace` | Restore backed-up agent trace settings after an aborted collection. Keep the case and backup on a restoration error. |
| `-Stage Cleanup -KeepEvidence` | End the test and restore saved local settings while retaining case files. Confirm the capture belongs to this kit before canceling any pending WPR recording. |
| `-Stage Help` | Show the main actions and their sequence. `Get-Help $swp -Full` displays the script help. |

If `StopTrace` fails, keep the case and run `& $swp -Stage RecoverAndPackage` before trying another reboot. This collects independent Windows events, Trend metrics and raw logs, records the WPR failure, and writes a partial handoff. If service restoration or the handoff check fails, keep the backup and status files. Resolve that issue before deleting a case.

**Interpreting sign-in evidence.** Review `WPR\SignIn-milestones.json`, `Trend\Timed-scans.csv` and `SignInScans` in `Evidence-assessment.json`. The authentication-to-Explorer interval and the operator’s credential-to-usable-desktop interval measure different milestones. A Trend timing of 4,445 microseconds equals 4.445 milliseconds. Windows file I/O identifies paths touched. Attribute an engine duration to a file only when the AMSP start and completion can be paired. If the assessment reports unverified sign-in timings, keep that gap in the customer report.

[Trend DSA Support Tool documentation](https://success.trendmicro.com/en-US/solution/KA-0012444) · [Microsoft Sysinternals licensing FAQ](https://learn.microsoft.com/en-us/sysinternals/license-faq)

## Validation

See `Validation-summary.json` in this kit for the tested versions and scenarios. For each customer capture, check the evidence assessment against the operator’s observed delay.
