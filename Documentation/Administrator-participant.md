# Test your own administrator account

Use this checklist when **you experience the delay and are a local administrator on this computer**. You can operate the collector and perform the sign-in yourself. Use your usual Windows account and normal desktop for the test. Membership in local Administrators gives you the ability to elevate PowerShell. Trend console access is a separate permission.

**1. Get ready.** Save your work. Verify the kit checksum and extract to `C:\SWP-Customer-Kit` as described in “Install and check the kit”. Confirm the prerequisites in “Plan the capture” and arrange the temporary computer-specific self-protection setting with the policy owner. If you also own that permission, record the original value and inheritance yourself. In a **normal** console, run `whoami.exe`. Note the exact account and the app or desktop milestone.

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

Run `& $swp -Stage Cleanup -KeepEvidence` to restore local settings and retain the case. Use default Cleanup only after verifying the transferred handoffs for **all** cases under `C:\SWP-Perf`. If any step fails, keep the case and follow “Recover an interrupted capture” and “Follow a native diagnostic request” in the collection guide.
