# Test your own administrator account

Use this checklist when **you experience the delay and are a local administrator on this computer**. You can operate the collector and perform the sign-in yourself. Use your usual Windows account and normal desktop for the test. Membership in local Administrators gives you the ability to elevate PowerShell. Trend console access is a separate permission.

**1. Get ready.** Save your work. Verify the kit checksum and extract to `C:\SWP-Customer-Kit` as described on handbook page 4. Confirm the prerequisites on handbook page 3 and arrange the temporary computer-specific self-protection setting with the policy owner. If you also own that permission, record the original value and inheritance yourself. In a **normal** console, run `whoami.exe`. Note the exact account and the app or desktop milestone.

**2. Prepare before signing out.** Open 64-bit **Windows PowerShell → Run as administrator**. These commands test a slow full sign-out/sign-in. You can also choose this scenario in the collector window. For a reboot-only symptom change `SignOutSignIn` to `Reboot` before running Prepare. Use one scenario per case. If elevation prompts for another account, enter your normal desktop identity at the script prompt.

```powershell
& 'C:\SWP-Customer-Kit\SWP-Perf.ps1' -Stage InstallTools
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
$user = Read-Host 'Enter the account printed by whoami on your normal desktop'
& $swp -Stage Prepare -Scenario SignOutSignIn -AffectedUser $user
```

**3. Reproduce.** Wait for **Prepared**. Fully sign out or restart as chosen, then sign in once as the account you noted. Record when you submit credentials and when the desktop responds. Launch an agreed app normally and record its launch/ready times, if part of the test. For sign-in only, stop at usable desktop.

**4. Stop immediately.** Reopen the collector and click **Stop trace now**, or open a **new elevated Windows PowerShell**. The previous window and its variables are gone. Run these lines before waiting for metrics. Note any delay opening the elevated window.

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage StopTrace
```

**5. Finish and return the case.** Update `Operator-notes.json` in the case printed by Prepare with your actual timings. Use `"Applications": []` for sign-in only. Run `& $swp -Stage FinishAndPackage` and wait for **ARCHIVE INTEGRITY VERIFIED**. Restore the original console setting or have its owner verify it. Add the confirmation to your notes and run `& $swp -Stage Package` again if you changed them. Transfer the newest `AllEvidence` ZIP and checksum from `C:\SWP-Handoff`.

Run `& $swp -Stage Cleanup -KeepEvidence` to restore local settings and retain the case. Use default Cleanup only after verifying the transferred handoffs for **all** cases under `C:\SWP-Perf`. If any step fails, keep the case and follow pages 13–14 of the handbook.
