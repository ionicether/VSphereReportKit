# Changelog

All notable changes to VSphereReportKit.

## [1.0.0] - 2026-08-25

The first release. This began as a WinForms dashboard; the interface is gone and what
remains is the part that was actually doing the work.

### Reports

- `Get-VMInventoryReport` - inventory with guest, hardware and Tools detail
- `Get-VMToolsReport` - Tools missing or in need of upgrade
- `Get-VMRemovalEvent` - VMs removed from inventory or destroyed from disk
- `Get-VMSnapshotReport` - snapshot age and attributable size, plus orphaned deltas
- `Get-VMHostComplianceReport` - vLCM image and VUM baseline compliance
- `Invoke-VSphereReport` - terminal menu, or direct dispatch via `-Report`
- `Remove-OldVMSnapshot` - deletes snapshots the report identified. Supports `-WhatIf` and
  `-Confirm`, and is kept out of the menu so that deleting is always a second, deliberate
  act rather than an answer to a prompt
- `Repair-VMConsolidation` - consolidates VMs carrying delta disks with no snapshot
  attached, which is the remedy removal refuses to apply

### Corrected from the original dashboard

It is worth being clear about what these were. None of them announced themselves. The
dashboard ran, drew its tables, and returned numbers that looked entirely plausible. That
is the characteristic failure of reporting tools, and it is why each of these is listed
with the consequence rather than merely the cause.

- **Removal events no longer stop at 100.** `Get-VIEvent` caps its results there unless
  both `-Start` and `-Finish` are supplied, and says nothing when it does. On any busy
  estate the deletion report was silently truncated. An EventManager collector is used
  instead, and is destroyed afterwards, because a session is permitted only 32 of them.
- **`VmDestroyedEvent` is captured alongside `VmRemovedEvent`.** Removed from inventory
  and deleted from disk are different events. Only the first was being caught, so a VM
  genuinely destroyed could go unreported.
- **Snapshot age compares UTC against UTC.** `CreateTime` arrives as UTC and was being
  compared against a local threshold, which skewed every row by the local offset. Near a
  boundary this is the difference between a snapshot appearing in a cleanup list and not.
- **Tools status reads `ToolsVersionStatus2`**, rather than the properties deprecated in
  vSphere API 4.0 and 5.1. `guestToolsUnmanaged` no longer appears as outdated, which
  removes a standing list of Linux machines that never needed attention.
- **`Get-Compliance` and `Test-Compliance` are called with `-Entity`**, as documented. The
  `Start-Sleep` that followed `Test-Compliance` has been removed: the cmdlet is
  synchronous without `-RunAsync`, so the sleep was guarding against nothing and would
  have been insufficient had it needed to.
- **CSV export is UTF-8.** Windows PowerShell 5.1 defaults `Export-Csv` to ASCII and
  corrupts anything outside it without complaint.

### Added

- Snapshot `SizeGB` and `Consolidate`, together with rows for VMs carrying orphaned delta
  disks. Those machines are invisible to any report built from the snapshot tree alone,
  and they are frequently the ones consuming the datastore.
- vLCM image compliance, with per-cluster fallback to VUM baselines, so the report
  continues to work as an estate migrates off a deprecated feature.
- `-Filter` across every column, in both menu and direct mode.
- A format file, so reports render as tables rather than as property-per-line lists.
- 115 tests requiring neither vCenter nor PowerCLI.

### Corrected in the removal path after review

These were found by validating the new command against the PowerCLI reference rather than
by running it, which is the only reason they were caught before rather than after.

- **Snapshots are identified by managed object reference, not by name.** `Get-Snapshot`
  treats `-Name` as a wildcard pattern. Matching by name meant `Pre-Patch` also matched
  `Pre-Patch-2`, and any name containing a bracket or an asterisk matched something else or
  nothing. On a command with no undo, that is the difference between a tool and an
  accident. `Get-VMSnapshotReport` now emits `SnapshotId`, `VMId` and `ParentId`, and
  removal looks up the id exactly.
- **VM names are resolved exactly.** PowerCLI resolves `-VM` by wildcard too, so `app-01`
  could return `app-011`. Names are now filtered to an exact match, and two VMs genuinely
  sharing a name are refused.
- **Deletion order reversed to newest first.** Committing a leaf merges the smallest delta
  that exists; committing a parent first merges everything beneath it. The original order
  maximised the stun and the free space required.
- **`-RemoveChildren` no longer fights itself.** It removes a whole subtree, so rows
  descending from another row in the same batch are dropped with a warning instead of being
  attempted and then reported as missing snapshots this command had just deleted.
- **The `-RunAsync` task handle is returned.** It was being discarded, so callers were told
  the work had been accepted and given no way to discover whether it finished.
- **A per-datastore headroom check** warns when a commit will not fit, rather than only
  reporting a global total.
- **`-WhatIf` emits no pipeline output**, as convention expects; result rows are reserved
  for things that actually happened.

### Also fixed, found while writing the removal tests

- **Generic collections are constructed with `::new()` rather than `New-Object`.** A list
  built with `New-Object System.Collections.Generic.List[object]` throws "Argument types
  do not match" the moment it is wrapped in `@()`, even when empty; the `::new()` form
  does not. This had been latent, because until now nothing in the module had wrapped one
  of those lists. It is the kind of defect that waits for the next person to write an
  ordinary line of PowerShell.

### Known limitations

See the "What these reports cannot see" section of README.md. In brief: snapshot sizes
have been verified against linear chains only, folder deletions raise no per-VM event, and
guest data is stale on powered-off machines. These are stated because a limitation you
know about is a caveat, and one you do not is a defect.
