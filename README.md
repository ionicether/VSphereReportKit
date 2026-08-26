# VSphereReportKit

(Almost) read-only reporting over a VMware vCenter connection: five commands, plus a terminal menu
if you would rather not remember the parameters.

Most reporting tools tell you what they found. Very few tell you what they could not see.
That distinction turns out to matter more than any feature, because a report that is
quietly incomplete is worse than no report at all. It does not merely fail to inform you;
it persuades you that you are informed. A good deal of the care in this module has gone
into the places where vCenter will hand you a confident-looking answer that is wrong, and
into saying so plainly rather than hoping you never notice.

Every reporting command is read-only. Two commands change things, `Remove-OldVMSnapshot`
and `Repair-VMConsolidation`, and both are deliberately separate steps rather than prompts
at the end of a report. A confirmation that appears immediately after a list gets answered by
muscle memory, and forty rows someone has skimmed become forty deletions. Reading and
deleting are different decisions, so they live in different commands.

## What it reports

| Command | Answers |
|---|---|
| `Get-VMInventoryReport` | What is out there: OS, hardware version, domain, power state, Tools |
| `Get-VMToolsReport` | Which VMs have no VMware Tools, or Tools that need upgrading |
| `Get-VMRemovalEvent` | What was removed from inventory or destroyed from disk, and by whom |
| `Get-VMSnapshotReport` | Snapshots by age and size, plus VMs carrying orphaned delta disks |
| `Get-VMHostComplianceReport` | ESXi patch compliance, from vLCM images or VUM baselines |
| `Invoke-VSphereReport` | A menu over the five, or direct dispatch with `-Report` |
| `Remove-OldVMSnapshot` | Deletes snapshots the report found |
| `Repair-VMConsolidation` | Consolidates VMs carrying delta disks with no snapshot |

## Requirements

**Windows PowerShell 5.1**, or PowerShell 7.x.

**PowerCLI**, which is neither bundled nor installed for you. Broadcom renamed the module
from `VMware.PowerCLI` to `VCF.PowerCLI` in June 2025; both names remain in the wild and
this kit accepts either.

```powershell
Install-Module VCF.PowerCLI -Scope CurrentUser
```

PowerCLI is deliberately absent from the manifest's `RequiredModules`. Declaring it there
would force a full PowerCLI import every time this module loads, and would make the module
unimportable, and therefore untestable, on any machine that lacks it. The commands check
at runtime and say so plainly when it is missing. This is a considered trade, not an
oversight.

**vSphere 7.0 or 8.0.** Compliance reporting via vLCM images requires 7.0 or later.

**A read-only vCenter role** suffices for everything but one detail. The removal report
attempts to read the `event.maxAge` advanced setting so that it can warn you when your
window exceeds vCenter's retention, and that read requires the `Global.Settings`
privilege. Without it the warning is skipped and the rest of the report proceeds. You
simply lose one safeguard, which is worth knowing in advance rather than discovering
later.

## Installation

There is no installer. Copy the `VSphereReportKit` folder wherever you keep tools and
import it by path:

```powershell
Import-Module C:\Tools\VSphereReportKit
```

Or place it in a `$env:PSModulePath` directory and let auto-loading find it, in which case
you can type a command and skip the import entirely.

`Start-Report.ps1` sits alongside the folder and performs the import for you. It exists
for the jump box where you cannot write to `PSModulePath`.

## Quick start

Connecting is your responsibility, so that a single session can serve as many reports as
you care to run:

```powershell
Connect-VIServer vcenter.corp.local

Get-VMSnapshotReport -OlderThanDays 30 | Sort-Object SizeGB -Descending
Get-VMInventoryReport | Get-VMToolsReport -State Outdated
Get-VMHostComplianceReport | Where-Object Status -ne 'Compliant'
```

Or let the menu handle it:

```
PS> Invoke-VSphereReport

  vSphere reports   (vcenter.corp.local)

   1  VM inventory            OS, hardware version, domain, Tools state
   2  VMware Tools            missing or out of date
   3  Recent removals         VMs removed from inventory or destroyed
   4  Old snapshots           age, size, and VMs needing consolidation
   5  Host patch compliance   vLCM images and VUM baselines

   q  quit

  Choose [1-5, q]:
```

Choose a report and it prompts for that report's arguments with defaults you can press
past, prints a table, offers a CSV path, and returns to the menu. If you are not already
connected it will ask for a server and credentials, and will disconnect that session on
the way out. A session you opened yourself is left alone.

## Usage

Full help on any command:

```powershell
Get-Help Get-VMSnapshotReport -Full
```

A few things worth knowing.

**One scan, two Tools reports.** Pipe inventory in and both slices come out of a single
round trip:

```powershell
$inventory = Get-VMInventoryReport
$inventory | Get-VMToolsReport -State NotInstalled
$inventory | Get-VMToolsReport -State Outdated
```

**`-State Any` means either problem state**, not every VM. Healthy machines never appear
in a Tools report. Use `Get-VMInventoryReport` when you want the whole estate.

**You do not need to know the values before you filter on them.**

```powershell
Get-VMInventoryReport | Group-Object HardwareVersion | Sort-Object Count -Descending
```

**`-Filter` on `Invoke-VSphereReport`** is a literal, case-insensitive contains across
every column, in both menu and direct mode. `*` and `[` are treated as text rather than as
wildcards, on the theory that someone searching for a bracket means a bracket.

## Deleting snapshots

`Remove-OldVMSnapshot` takes report rows from the pipeline, so what you delete is exactly
what you looked at. Its `ConfirmImpact` is High, meaning it asks about each snapshot unless
you pass `-Confirm:$false`. Begin with `-WhatIf` regardless:

```powershell
Get-VMSnapshotReport -OlderThanDays 90 | Remove-OldVMSnapshot -WhatIf
Get-VMSnapshotReport -OlderThanDays 90 | Where-Object SizeGB -gt 50 | Remove-OldVMSnapshot
```

It is worth being clear that removal, not creation, is the dangerous moment. Deleting a
snapshot commits the delta back into the base disk, which requires free space on the
datastore and can run for a long time on a large or neglected snapshot. Before any work
begins the command warns you of the total space about to be committed.

**Snapshots are identified by managed object reference, never by name.** This matters more
than it sounds. `Get-Snapshot` treats `-Name` as a wildcard pattern, so a snapshot called
`Pre-Patch` also matches `Pre-Patch-2`, and a name containing a bracket or an asterisk
matches something else entirely or nothing at all. The report carries a `SnapshotId` and
removal looks up that, exactly. Rows without one fall back to a case-sensitive name
comparison and say so. PowerCLI resolves VM names by wildcard too, so those are filtered
to an exact match as well.

**Removal is ordered newest first, deepest leaf upward.** Each deletion then commits the
smallest delta that exists, which keeps the consolidation, the stun and the free space it
demands as small as they can be. Deleting a parent first would merge everything beneath it.

Things it will refuse to do:

- **Delete an orphaned delta.** Rows with `Kind` of `OrphanedDelta` describe a VM carrying
  delta disks with no snapshot attached. There is nothing to remove and deletion is not the
  remedy; use `Repair-VMConsolidation`.
- **Guess between ambiguous matches.** Two VMs sharing a name, or a snapshot name matching
  more than one snapshot, are refused rather than resolved by guesswork. There is no undo.
- **Silently take a subtree.** `-RemoveChildren` deletes a whole subtree, so any row that
  descends from another row in the same batch is dropped with a warning rather than
  attempted and then reported as missing.
- **Abandon the batch on one failure.** A snapshot that has vanished since the report was
  taken, or that cannot be removed, is reported through `Write-Error` and the run
  continues. Check `-ErrorVariable` on an unattended run.

Before any work starts it totals the space about to be committed and, where it can read
them, warns per datastore when the commit will not fit. `-SkipSpaceCheck` turns that off.

Every attempt produces a result row (`Removed`, `Submitted`, `Skipped`, `Failed`), carrying
a `TaskId` under `-RunAsync` so the work can be tracked with `Get-Task`. `-WhatIf` emits no
rows at all: the What-if messages are the output.

## Consolidating orphaned deltas

`Repair-VMConsolidation` handles what removal refuses. A VM flagged for consolidation with
nothing in its snapshot tree is carrying delta disks that no snapshot points at, so there
is nothing to delete and the disks have to be committed back into the base.

```powershell
Get-VMSnapshotReport | Where-Object Kind -eq 'OrphanedDelta' | Repair-VMConsolidation -WhatIf
```

There is no PowerCLI cmdlet for this, so it calls `ConsolidateVMDisks_Task` on the
underlying managed object and returns immediately; track completion with `Get-Task`. It
carries the same costs as any consolidation: it commits data, needs free space, stuns the
VM, and can run for a long time.

## Output and export

Every command emits plain `PSCustomObject`s tagged with a type name, so a bundled format
file renders them as tables rather than the property-per-line lists PowerShell falls back
to above four properties. The tables show a useful subset. The objects always carry
everything, because what is displayed and what is retained are separate decisions and
conflating them is how tools begin to mislead.

```powershell
Get-VMSnapshotReport | Select-Object *
Get-VMSnapshotReport | Export-Csv snaps.csv -NoTypeInformation -Encoding UTF8
```

`-Encoding UTF8` matters on Windows PowerShell 5.1, where `Export-Csv` defaults to ASCII
and will silently corrupt any non-ASCII VM name, note or username. The menu's own export
already does this.

## What these reports cannot see

Read this section before acting on the numbers. Each report has an edge beyond which it is
blind, and knowing where that edge lies is the difference between using a tool and being
used by one.

**Snapshot sizes are an attribution, not a measurement.** `SizeGB` is the space
attributable to a single snapshot: its state file, its memory image where one exists, and
the delta disks it created. The base disk is never counted, because deleting a snapshot
does not reclaim it. Two qualifications follow:

- Sizes come from `LayoutEx`, which reports size at snapshot creation. A snapshot that has
  been growing quietly for six months will still report its birth size. Pass `-Refresh` to
  call `RefreshStorageInfo()` for live figures, at the cost of a round trip per VM.
- The attribution has been verified against linear snapshot chains only. **Benchmark one
  VM against `Get-Snapshot | Select-Object Name, SizeGB` before trusting these numbers on
  a branched tree.** Linked clones, where delta files are shared between VMs, should be
  treated as approximate in any case.

**An empty removal report is not evidence that nothing was deleted.** vCenter retains
events for thirty days by default; request a longer window and you will be warned. More
subtly, deleting a *folder* that contains VMs can remove them without raising a per-VM
event at all, and those deletions will never appear here no matter how you query. This
report is a strong signal. It is not an audit, and it should not be offered as one.

**Guest data is stale while a VM is powered off.** The Tools status of a powered-off
machine is whatever it was when the machine last ran. `PowerState` appears on every row
for precisely this reason, and `-PoweredOnOnly` will drop the rows you cannot trust.

**`guestToolsUnmanaged` is excluded from "outdated" by default.** That state means
open-vm-tools, shipped and patched by the Linux distribution, and it is not something
vCenter can or should update. Reporting it as an action item produces a list of work that
does not need doing, which is a reliable way to get the entire report ignored. Use
`-IncludeUnmanaged` if you disagree.

**Compliance covers only what has been configured.** vLCM image compliance applies to
clusters managed by a single image; everything else falls through to VUM baselines, and
hosts with no baseline attached report `NotApplicable`. A host that errors is reported via
`Write-Error` and the scan continues, so check `-ErrorVariable` on an unattended run.

## Compatibility

PowerCLI 13.x and `VCF.PowerCLI` 9.x. On Windows PowerShell 5.1, Broadcom documents that a
server-side failure can surface as `There is an error in the XML document` rather than the
actual message. PowerShell 7 shows the real error, which is reason enough to prefer it
when something has already gone wrong.

VUM baselines are deprecated as of vSphere 8.0 and are slated for removal in the next
major release. `-Mode Auto` already prefers vLCM images and falls back to baselines per
cluster, so compliance reporting continues to work while an estate migrates.

## Licence and trademarks

See `LICENSE`.

Not affiliated with or endorsed by Broadcom. VMware, vSphere, vCenter, ESXi and PowerCLI
are trademarks of Broadcom Inc.
