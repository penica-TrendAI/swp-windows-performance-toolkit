# Export Windows trace reports

On a Windows analysis host with the Windows Performance Toolkit installed, run the helper on a working copy of the ETL. Choose a fresh output directory in private case storage. This reads an existing trace and runs xperf once for the selected reports. [Microsoft xperf reference](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/xperf-command-line-reference)

```powershell
.\Analysis\Export-WprReports.ps1 -TracePath 'D:\Case\WPR\PassA-BootLoginApps.etl' -OutputDirectory 'D:\Case\Exports'
```

Start with `TraceStats.txt` for trace bounds and lost events, then review process and disk activity. `-InitialWindowSeconds 180` adds a summary of the first three minutes relative to trace start. Supply `-IncludeCpu` if the trace includes sampling or context-switch events. Supply `-XperfPath` for a non-default Windows Performance Toolkit location.

Review the report contents and both xperf logs. Available providers determine what each report can show. Open the ETL in Windows Performance Analyzer to isolate the actual sign-in interval. For file-specific scan timing, correlate that interval with paired Trend scan records. Process reports can contain full command lines and user paths.
