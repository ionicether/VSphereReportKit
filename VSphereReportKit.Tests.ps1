#Requires -Version 5.1
<#
    Tests for VSphereReportKit. No vCenter, no PowerCLI.

    Fakes are defined inside the module's own session state, so the module's functions
    resolve Get-View and friends to these instead of the real ones. No Pester here -
    5.1 ships Pester 3.4, whose syntax is incompatible with modern Pester, and pulling
    Pester 5 in needs the gallery. The shape maps onto Describe/It/Should directly if
    you ever get CI.

    Fixtures for the menu test are written to a temp folder and removed afterwards.

    Get-VMRemovalEvent is not covered - it constructs VMware.Vim.EventFilterSpec, which
    only exists once PowerCLI is loaded. That path needs a real vCenter.

    Order matters. The query tests run first; the front-end tests then overwrite the
    Get-* functions in module scope with stubs, which would break the query tests if
    they ran afterwards.
#>

[CmdletBinding()]
param(
    [string] $ModulePath = (Join-Path $PSScriptRoot 'VSphereReportKit')
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $Label)
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n        expected [{1}] got [{2}]" -f $Label, $Expected, $Actual)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    Assert-Equal $true $Condition $Label
}

Import-Module $ModulePath -Force
$module = Get-Module VSphereReportKit

# Both the connection guard and the front end look here, so a fake connection is all
# that is needed to exercise either.
$global:DefaultVIServers = @([PSCustomObject]@{ Name = 'fake-vc'; IsConnected = $true })
$global:DefaultVIServer  = $global:DefaultVIServers[0]

function global:New-VmView {
    param(
        [string]$Name, [string]$Os, [string]$Hw, [string]$Domain, [string]$HostName,
        [string]$Tools2, [string]$ToolsLegacy, [string]$Power, [bool]$Template, [string]$Notes
    )
    [PSCustomObject]@{
        Name    = $Name
        Config  = [PSCustomObject]@{ GuestFullName = $Os; Version = $Hw; Annotation = $Notes; Template = $Template }
        Guest   = [PSCustomObject]@{
            Domain = $Domain; HostName = $HostName; GuestFullName = $Os
            ToolsStatus = $ToolsLegacy; ToolsVersionStatus2 = $Tools2
            ToolsRunningStatus = 'guestToolsRunning'; ToolsVersion = '12325'
        }
        Runtime = [PSCustomObject]@{ PowerState = $Power }
    }
}

Write-Host "`n=== Get-VMInventoryReport ==="

& $module {
    function script:Get-View {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $ViewType, $Property, $Server)
        @(
            (New-VmView -Name 'web-01' -Os 'Ubuntu Linux (64-bit)' -Hw 'vmx-19' -Domain '' `
                        -HostName 'web-01.corp.example.com' -Tools2 'guestToolsUnmanaged' `
                        -ToolsLegacy 'toolsOk' -Power 'poweredOn' -Template $false -Notes "line one`r`n  line two"),
            (New-VmView -Name 'sql-01' -Os 'Microsoft Windows Server 2019 (64-bit)' -Hw 'vmx-17' -Domain 'corp.example.com' `
                        -HostName 'sql-01' -Tools2 'guestToolsNeedUpgrade' -ToolsLegacy 'toolsOld' `
                        -Power 'poweredOn' -Template $false -Notes ''),
            (New-VmView -Name 'gold-tmpl' -Os 'Microsoft Windows Server 2022 (64-bit)' -Hw 'vmx-21' -Domain 'corp.example.com' `
                        -HostName 'gold' -Tools2 'guestToolsNotInstalled' -ToolsLegacy 'toolsNotInstalled' `
                        -Power 'poweredOff' -Template $true -Notes '')
        )
    }
}

$inventory = @(Get-VMInventoryReport)
Assert-Equal 2 $inventory.Count 'templates excluded by default'
Assert-Equal 3 (@(Get-VMInventoryReport -IncludeTemplate)).Count 'templates included with -IncludeTemplate'

$web = $inventory | Where-Object Name -eq 'web-01'
Assert-Equal 'corp.example.com' $web.Domain 'domain derived from FQDN when Guest.Domain is empty'
Assert-Equal 'guestToolsUnmanaged' $web.ToolsStatus 'ToolsVersionStatus2 preferred over deprecated ToolsStatus'
Assert-Equal 'line one line two' $web.Notes 'annotation newlines collapsed'
Assert-Equal 'VSphereReportKit.VMInventory' ($web.PSObject.TypeNames[0]) 'custom type name applied'
Assert-Equal 'corp.example.com' ($inventory | Where-Object Name -eq 'sql-01').Domain 'Guest.Domain used when present'

Write-Host "`n=== Get-VMToolsReport ==="

$outdated = @($inventory | Get-VMToolsReport -State Outdated)
Assert-Equal 1 $outdated.Count 'guestToolsUnmanaged excluded from Outdated'
Assert-Equal 'sql-01' $outdated[0].Name 'the genuinely outdated VM is reported'
Assert-Equal 'Upgrade' $outdated[0].Action 'action is Upgrade'
Assert-Equal 2 (@($inventory | Get-VMToolsReport -State Outdated -IncludeUnmanaged)).Count 'unmanaged included with -IncludeUnmanaged'

$missing = @(Get-VMInventoryReport -IncludeTemplate | Get-VMToolsReport -State NotInstalled)
Assert-Equal 1 $missing.Count 'NotInstalled finds the template with no tools'
Assert-Equal 'Install' $missing[0].Action 'action is Install'

$fetched = @(Get-VMToolsReport -State Any)
Assert-Equal 1 $fetched.Count 'fetches inventory itself when nothing is piped in'
Assert-Equal 'sql-01' $fetched[0].Name 'Any means either problem state, not every VM'

# Built directly rather than through the Get-View fake. Adding VMs to that fixture would
# change the inventory counts asserted above, and a test that quietly depends on another
# test's fixture is a test that will one day fail for reasons nobody can find.
$syntheticTools = @(
    [PSCustomObject]@{ Name='bl-01';  OS='Windows'; PowerState='poweredOn';  ToolsStatus='guestToolsBlacklisted'; ToolsRunning='guestToolsRunning';    ToolsVersion='9' }
    [PSCustomObject]@{ Name='off-01'; OS='Windows'; PowerState='poweredOff'; ToolsStatus='guestToolsNeedUpgrade';  ToolsRunning='guestToolsNotRunning'; ToolsVersion='9' }
)
Assert-Equal 2 (@($syntheticTools | Get-VMToolsReport -State Outdated)).Count 'blacklisted Tools count as outdated'
$poweredOn = @($syntheticTools | Get-VMToolsReport -State Outdated -PoweredOnOnly)
Assert-Equal 1 $poweredOn.Count '-PoweredOnOnly drops VMs whose guest data is stale'
Assert-Equal 'bl-01' $poweredOn[0].Name '-PoweredOnOnly keeps the powered-on one'

Write-Host "`n=== Get-VMSnapshotReport ==="

& $module {
    function script:Get-View {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $ViewType, $Property, $Server)

        # 1 is the .vmsn state file, 2 the delta belonging to snap-1, 3 the base disk
        # that must never be counted, 4 the delta belonging to snap-2.
        $files = @(
            [PSCustomObject]@{ Key = 1; Size = 1GB }
            [PSCustomObject]@{ Key = 2; Size = 2GB }
            [PSCustomObject]@{ Key = 3; Size = 4GB }
            [PSCustomObject]@{ Key = 4; Size = 8GB }
            [PSCustomObject]@{ Key = 5; Size = 16GB }  # memory image for snapshot-2
        )
        $layouts = @(
            [PSCustomObject]@{
                Key     = [PSCustomObject]@{ Value = 'snapshot-1' }
                DataKey = 1
                Disk    = @([PSCustomObject]@{ Chain = @(
                    [PSCustomObject]@{ FileKey = @(3) },   # base, must NOT be counted
                    [PSCustomObject]@{ FileKey = @(2) })   # this snapshot's delta
                })
            }
            [PSCustomObject]@{
                Key       = [PSCustomObject]@{ Value = 'snapshot-2' }
                DataKey   = -1
                MemoryKey = 5
                Disk    = @([PSCustomObject]@{ Chain = @(
                    [PSCustomObject]@{ FileKey = @(3) },
                    [PSCustomObject]@{ FileKey = @(2) },
                    [PSCustomObject]@{ FileKey = @(4) })
                })
            }
        )
        $child = [PSCustomObject]@{
            Name = 'recent'; Description = 'too new to report'
            CreateTime = (Get-Date).ToUniversalTime().AddDays(-3)
            Snapshot = [PSCustomObject]@{ Value = 'snapshot-2' }
            State = 'poweredOn'; Quiesced = $false; ChildSnapshotList = $null
        }
        $root = [PSCustomObject]@{
            Name = 'pre-patch'; Description = "before   the   upgrade"
            CreateTime = (Get-Date).ToUniversalTime().AddDays(-40)
            Snapshot = [PSCustomObject]@{ Value = 'snapshot-1' }
            State = 'poweredOn'; Quiesced = $true; ChildSnapshotList = @($child)
        }

        @(
            [PSCustomObject]@{
                Name     = 'app-01'
                Snapshot = [PSCustomObject]@{ RootSnapshotList = @($root) }
                LayoutEx = [PSCustomObject]@{ File = $files; Snapshot = $layouts }
                Runtime  = [PSCustomObject]@{ ConsolidationNeeded = $false }
                Config   = [PSCustomObject]@{ Template = $false }
            },
            [PSCustomObject]@{
                Name     = 'orphan-01'
                Snapshot = $null
                LayoutEx = $null
                Runtime  = [PSCustomObject]@{ ConsolidationNeeded = $true }
                Config   = [PSCustomObject]@{ Template = $false }
            }
        )
    }
}

$snaps    = @(Get-VMSnapshotReport -OlderThanDays 7)
$snapRows = @($snaps | Where-Object Kind -eq 'Snapshot')
Assert-Equal 1 $snapRows.Count 'child snapshot newer than the threshold is excluded (UTC compare)'
Assert-Equal 'pre-patch' $snapRows[0].Snapshot 'the old snapshot is reported'
Assert-Equal 3 $snapRows[0].SizeGB 'size = state file + last chain unit, base disk not counted'
Assert-Equal 40 ([math]::Round($snapRows[0].AgeDays)) 'age in days'
Assert-Equal 'before the upgrade' $snapRows[0].Description 'description whitespace collapsed'
Assert-Equal $true $snapRows[0].Quiesced 'quiesced flag carried through'

$orphans = @($snaps | Where-Object Kind -eq 'OrphanedDelta')
Assert-Equal 1 $orphans.Count 'consolidation-needed VM with no snapshot is surfaced'
Assert-Equal 'orphan-01' $orphans[0].VM 'orphan row names the VM'

$all = @(Get-VMSnapshotReport | Where-Object Kind -eq 'Snapshot')
Assert-Equal 2 $all.Count 'OlderThanDays 0 returns every snapshot'
Assert-Equal 24 ($all | Where-Object Snapshot -eq 'recent').SizeGB 'memory file (MemoryKey) added to the delta: 8GB + 16GB'
Assert-Equal 3 $snapRows[0].SizeGB 'layout with no MemoryKey property at all still sizes correctly'

Write-Host "`n=== Get-VMHostComplianceReport ==="

& $module {
    function script:Get-Cluster {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Server)
        @([PSCustomObject]@{ Name = 'cluster-image' }, [PSCustomObject]@{ Name = 'cluster-baseline' })
    }
    function script:Test-LcmClusterCompliance {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Cluster)
        if ($Cluster.Name -eq 'cluster-baseline') { throw 'Cluster is not managed by an image.' }
        [PSCustomObject]@{
            Status            = 'NonCompliant'
            CompliantHosts    = @([PSCustomObject]@{ Name = 'esx-01' })
            NonCompliantHosts = @([PSCustomObject]@{ Name = 'esx-02' })
        }
    }
    function script:Get-VMHost {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Location, $Server)
        @([PSCustomObject]@{ Name = 'esx-01' }, [PSCustomObject]@{ Name = 'esx-02' },
          [PSCustomObject]@{ Name = 'esx-03' }, [PSCustomObject]@{ Name = 'esx-04' })
    }
    function script:Get-Module {
        param([Parameter(ValueFromRemainingArguments)]$Rest, [switch]$ListAvailable, $Name)
        if ($Name -eq 'VMware.VumAutomation') { return [PSCustomObject]@{ Name = 'VMware.VumAutomation' } }
        return $null
    }
    function script:Import-Module { param([Parameter(ValueFromRemainingArguments)]$Rest) }
    function script:Test-Compliance { param([Parameter(ValueFromRemainingArguments)]$Rest, $Entity) }
    function script:Get-Compliance {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Entity)
        if ($Entity.Name -eq 'esx-04') { throw 'Permission to perform this operation was denied.' }
        if ($Entity.Name -eq 'esx-03') { return @() }
        @([PSCustomObject]@{
            Status   = 'Compliant'
            Baseline = [PSCustomObject]@{ Name = 'Critical Host Patches' }
            Entity   = [PSCustomObject]@{ Name = $Entity.Name }
        })
    }
}

$compliance = @(Get-VMHostComplianceReport -Mode Auto -ErrorAction SilentlyContinue -ErrorVariable compErrors)
$imageRows  = @($compliance | Where-Object Source -eq 'vLCM image')
Assert-Equal 2 $imageRows.Count 'image-managed cluster yields one row per host'
Assert-Equal 'Compliant' ($imageRows | Where-Object Entity -eq 'esx-01').Status 'compliant host bucket mapped'
Assert-Equal 'NonCompliant' ($imageRows | Where-Object Entity -eq 'esx-02').Status 'non-compliant host bucket mapped'

$baselineRows = @($compliance | Where-Object Source -eq 'Baseline (VUM)')
Assert-Equal 1 $baselineRows.Count 'only the two hosts the image pass missed are rescanned, and one of those fails'
Assert-Equal 'NotApplicable' ($baselineRows | Where-Object Entity -eq 'esx-03').Status 'host with no baseline reported as NotApplicable'

# PowerShell records an exception in $Error even when it is caught, so the variable holds
# more than this command deliberately reported. Counting only the records that name the
# failing host is the difference between asserting on behaviour and asserting on noise.
Assert-Equal 1 (@($compErrors | Where-Object { "$_" -like '*esx-04*' })).Count 'failing host raises one non-terminating error naming it'
Assert-Equal 3 $compliance.Count 'the run continues past the failing host'
Assert-Equal 2 (@(Get-VMHostComplianceReport -Mode Image -WarningAction SilentlyContinue)).Count '-Mode Image skips the baseline pass entirely'

Write-Host "`n=== Remove-OldVMSnapshot ==="

# This is the only command here that destroys anything, so most of what follows tests
# what it refuses to do rather than what it does. The question a destructive command has
# to answer is not whether it works, but whether it can be made to act on the wrong
# object, and that is what these are for.
& $module {
    $script:RemoveCalls = [System.Collections.Generic.List[string]]::new()
    $script:LookupCalls = [System.Collections.Generic.List[string]]::new()

    # This fake deliberately reproduces the behaviour that made the original dangerous:
    # -Name matches as a wildcard, -Id matches exactly. A fake that were kinder than the
    # real thing would let the bug back in.
    function script:Get-Snapshot {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $VM, $Name, $Id, $Server)
        if ($Id) {
            $script:LookupCalls.Add("id:$Id")
            if ($Id -eq 'VirtualMachineSnapshot-snapshot-gone') { return @() }
            if ($Id -eq 'VirtualMachineSnapshot-snapshot-boom') { throw 'A general system error occurred' }
            return @([PSCustomObject]@{ Name = 'whatever'; Id = $Id })
        }
        $script:LookupCalls.Add("vm:$($VM.Name)")
        # Two snapshots whose names differ only by a suffix. A wildcard -Name returns
        # both; an exact comparison must return one.
        return @([PSCustomObject]@{ Name = 'Pre-Patch';   Id = 'VirtualMachineSnapshot-snapshot-a' },
                 [PSCustomObject]@{ Name = 'Pre-Patch-2'; Id = 'VirtualMachineSnapshot-snapshot-b' })
    }
    function script:Get-VM {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Name, $Server)
        if ($Name -eq 'ghost-01') { return @() }
        # PowerCLI resolves names by pattern, so asking for app-01 legitimately returns
        # app-011 as well. The exact filter has to discard it.
        $out = @([PSCustomObject]@{ Name = $Name; Id = "VirtualMachine-vm-$Name" })
        if ($Name -eq 'app-01')  { $out += [PSCustomObject]@{ Name = 'app-011'; Id = 'VirtualMachine-vm-app-011' } }
        # Genuine ambiguity: the same name twice, as happens across datacenters.
        if ($Name -eq 'twin-01') { $out += [PSCustomObject]@{ Name = 'twin-01'; Id = 'VirtualMachine-vm-twin-b' } }
        return $out
    }
    function script:Get-Datastore {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $VM, $Server)
        @([PSCustomObject]@{ Name = 'ds-small'; FreeSpaceGB = 10.0 })
    }
    function script:Remove-Snapshot {
        param([Parameter(ValueFromRemainingArguments)]$Rest, $Snapshot, [switch]$RemoveChildren, [switch]$RunAsync)
        if ($Snapshot.Id -eq 'VirtualMachineSnapshot-snapshot-locked') { throw 'The operation is not allowed in the current state.' }
        $script:RemoveCalls.Add([string]$Snapshot.Id)
        if ($RunAsync) { return [PSCustomObject]@{ Id = 'Task-task-99' } }
    }
}
function Get-RemoveCalls { & $module { ,@($script:RemoveCalls.ToArray()) } }
function Get-LookupCalls { & $module { ,@($script:LookupCalls.ToArray()) } }
function Reset-Calls { & $module { $script:RemoveCalls.Clear(); $script:LookupCalls.Clear() } }

function New-SnapRow {
    param(
        [string]$VM = 'app-01', [string]$Snapshot = 'Pre-Patch', $SizeGB = 4.0,
        [string]$Kind = 'Snapshot', $SnapshotId = 'VirtualMachineSnapshot-snapshot-1',
        $ParentId = $null, $AgeDays = 90.0
    )
    [PSCustomObject]@{
        PSTypeName = 'VSphereReportKit.VMSnapshot'
        Kind = $Kind; VM = $VM; VMId = "VirtualMachine-vm-$VM"
        Snapshot = $Snapshot; SnapshotId = $SnapshotId; ParentId = $ParentId
        Description = 'd'; CreatedOn = (Get-Date).AddDays(-$AgeDays); AgeDays = $AgeDays
        SizeGB = $SizeGB; State = 'poweredOff'; Quiesced = $false; Consolidate = $false
    }
}

# -WhatIf must touch nothing whatsoever.
Reset-Calls
$whatIfOut = @(New-SnapRow | Remove-OldVMSnapshot -WhatIf -SkipSpaceCheck -WarningAction SilentlyContinue)
Assert-Equal 0 (Get-RemoveCalls).Count '-WhatIf removes nothing'
Assert-Equal 0 $whatIfOut.Count '-WhatIf emits no pipeline output'

# The point of the rewrite. Identify by id, never by a name that Get-Snapshot would
# treat as a pattern.
Reset-Calls
$done = @(New-SnapRow | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -WarningAction SilentlyContinue)
Assert-Equal 1 (Get-RemoveCalls).Count 'confirmed removal calls Remove-Snapshot once'
Assert-Equal 'VirtualMachineSnapshot-snapshot-1' (Get-RemoveCalls)[0] 'the snapshot removed is the one identified by Id'
Assert-Equal 'id:VirtualMachineSnapshot-snapshot-1' (Get-LookupCalls)[0] 'lookup goes through -Id, not -Name'
Assert-Equal $true $done[0].Removed 'result says removed'
Assert-Equal 'VirtualMachineSnapshot-snapshot-1' $done[0].SnapshotId 'result carries the id acted on'

# A row with no id falls back to an exact name comparison, which must not pick up the
# similarly named snapshot that a wildcard would have returned.
Reset-Calls
$legacy = New-SnapRow -SnapshotId $null -VM 'solo-01' -Snapshot 'Pre-Patch'
$legacyOut = @($legacy | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -WarningAction SilentlyContinue)
Assert-Equal 1 (Get-RemoveCalls).Count 'name fallback removes exactly one snapshot'
Assert-Equal 'VirtualMachineSnapshot-snapshot-a' (Get-RemoveCalls)[0] 'exact name match ignores Pre-Patch-2'

# VM names are resolved by pattern too. A wildcard hit on a longer name is not ambiguity
# and must simply be discarded.
Reset-Calls
$wildcardVm = New-SnapRow -SnapshotId $null -VM 'app-01'
$null = @($wildcardVm | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
Assert-Equal 1 (Get-RemoveCalls).Count 'a wildcard hit on app-011 is filtered out, app-01 still proceeds'

# Two VMs genuinely sharing a name is ambiguity, and there is no safe way to choose.
Reset-Calls
$twinVm = New-SnapRow -SnapshotId $null -VM 'twin-01'
$null = @($twinVm | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -ErrorVariable vmErr -WarningAction SilentlyContinue)
Assert-Equal 0 (Get-RemoveCalls).Count 'two VMs with the same exact name removes nothing'
Assert-True ([bool](@($vmErr) -match 'matches 2 VMs')) 'the refusal explains the ambiguity'

Reset-Calls
$noVm = New-SnapRow -SnapshotId $null -VM 'ghost-01'
$null = @($noVm | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -ErrorVariable ghostErr -WarningAction SilentlyContinue)
Assert-Equal 0 (Get-RemoveCalls).Count 'a VM that does not exist removes nothing'
Assert-True ([bool](@($ghostErr) -match 'No VM named exactly')) 'says the VM could not be resolved'

# An orphaned delta has no snapshot to delete, so the command must send the caller
# somewhere useful rather than simply failing.
Reset-Calls
$orphan = New-SnapRow -Kind 'OrphanedDelta' -Snapshot $null -SnapshotId $null
$orphanOut = @($orphan | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -WarningVariable orphanWarn -WarningAction SilentlyContinue)
Assert-Equal 0 (Get-RemoveCalls).Count 'orphaned delta rows are never removed'
Assert-Equal 0 $orphanOut.Count 'orphaned delta rows produce no result row'
Assert-True ([bool](@($orphanWarn) -match 'Repair-VMConsolidation')) 'the orphan warning names the right remedy'

# The report is a photograph, not a lock. A snapshot can be gone by the time removal
# reaches it, and the lookup itself can fail.
Reset-Calls
$null = @(New-SnapRow -SnapshotId 'VirtualMachineSnapshot-snapshot-gone' | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -ErrorVariable missErr -WarningAction SilentlyContinue)
Assert-Equal 0 (Get-RemoveCalls).Count 'a snapshot that has gone is not removed'
Assert-True ([bool](@($missErr) -match 'no longer exists')) 'says the snapshot has gone'

Reset-Calls
$null = @(New-SnapRow -SnapshotId 'VirtualMachineSnapshot-snapshot-boom' | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -ErrorVariable lookErr -WarningAction SilentlyContinue)
Assert-True ([bool](@($lookErr) -match 'Could not look up')) 'a failed lookup is reported'

# Order matters for cost, not correctness: committing a leaf merges the smallest delta
# that exists, while committing a parent first merges everything beneath it.
Reset-Calls
$chain = @(
    (New-SnapRow -Snapshot 'root'  -SnapshotId 'VirtualMachineSnapshot-snapshot-r' -AgeDays 300.0),
    (New-SnapRow -Snapshot 'leaf'  -SnapshotId 'VirtualMachineSnapshot-snapshot-l' -AgeDays 10.0  -ParentId 'VirtualMachineSnapshot-snapshot-m'),
    (New-SnapRow -Snapshot 'mid'   -SnapshotId 'VirtualMachineSnapshot-snapshot-m' -AgeDays 100.0 -ParentId 'VirtualMachineSnapshot-snapshot-r')
)
$null = @($chain | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -WarningAction SilentlyContinue)
$order = Get-RemoveCalls
Assert-Equal 3 $order.Count 'the whole chain is processed'
Assert-Equal 'VirtualMachineSnapshot-snapshot-l' $order[0] 'newest (leaf) is removed first'
Assert-Equal 'VirtualMachineSnapshot-snapshot-r' $order[2] 'oldest (root) is removed last'

# -RemoveChildren takes a whole subtree, so descendants in the same batch have to be
# dropped rather than attempted and then reported missing by the command that removed
# them a moment earlier.
Reset-Calls
$subtree = @($chain | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -RemoveChildren -WarningVariable subWarn -WarningAction SilentlyContinue)
Assert-Equal 1 (Get-RemoveCalls).Count '-RemoveChildren removes only the top of the subtree'
Assert-Equal 'VirtualMachineSnapshot-snapshot-r' (Get-RemoveCalls)[0] 'the root is the one acted on'
Assert-True ([bool](@($subWarn) -match 'descend from another snapshot')) 'explains which rows it dropped'

# One failure must not abandon the batch. A run that stops halfway leaves an operator
# with no idea what was done and what was not.
Reset-Calls
$batch = @(
    (New-SnapRow -Snapshot 'a' -SnapshotId 'VirtualMachineSnapshot-snapshot-1' -AgeDays 10.0),
    (New-SnapRow -Snapshot 'b' -SnapshotId 'VirtualMachineSnapshot-snapshot-locked' -AgeDays 20.0),
    (New-SnapRow -Snapshot 'c' -SnapshotId 'VirtualMachineSnapshot-snapshot-2' -AgeDays 30.0)
)
$batchOut = @($batch | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -ErrorAction SilentlyContinue -ErrorVariable batchErr -WarningAction SilentlyContinue)
Assert-Equal 2 (Get-RemoveCalls).Count 'the two healthy snapshots are still removed'
Assert-Equal 3 $batchOut.Count 'every row gets a result, including the failure'
Assert-Equal 1 (@($batchOut | Where-Object Result -eq 'Failed')).Count 'the failure is labelled Failed'

# Told that work was accepted, a caller needs some way of discovering whether it
# finished. -RunAsync must hand back the task.
Reset-Calls
$async = @(New-SnapRow | Remove-OldVMSnapshot -Confirm:$false -SkipSpaceCheck -RunAsync -WarningAction SilentlyContinue)
Assert-Equal 'Submitted' $async[0].Result '-RunAsync reports Submitted, not Removed'
Assert-Equal 'Task-task-99' $async[0].TaskId '-RunAsync returns a task id to track'

# The warnings have to arrive before the work, not after it. A warning that a datastore
# will fill is of no use once consolidation has filled it.
Reset-Calls
$big = @((New-SnapRow -Snapshot 'x' -SnapshotId 'VirtualMachineSnapshot-snapshot-1' -SizeGB 40.0 -VM 'solo-01'))
$null = @($big | Remove-OldVMSnapshot -Confirm:$false -WarningVariable spaceWarn -WarningAction SilentlyContinue)
Assert-True ([bool](@($spaceWarn) -match '40\.0 GB')) 'warns with the total space about to be committed'
Assert-True ([bool](@($spaceWarn) -match 'stuns the VM')) 'warns that the VM is stunned'
Assert-True ([bool](@($spaceWarn) -match 'ds-small.*may fill it')) 'warns that the datastore has too little free space'

Write-Host "`n=== Repair-VMConsolidation ==="

Reset-Calls
& $module {
    $script:ConsolidateCalls = [System.Collections.Generic.List[string]]::new()
}
$consolidRow = [PSCustomObject]@{ Kind = 'OrphanedDelta'; VM = 'solo-01'; Snapshot = $null }
$repairWhatIf = @($consolidRow | Repair-VMConsolidation -WhatIf)
Assert-Equal 0 $repairWhatIf.Count '-WhatIf on consolidation emits no pipeline output'

$dupRows = @(
    [PSCustomObject]@{ Kind = 'OrphanedDelta'; VM = 'solo-01'; Snapshot = $null },
    [PSCustomObject]@{ Kind = 'OrphanedDelta'; VM = 'solo-01'; Snapshot = $null }
)
$repaired = @($dupRows | Repair-VMConsolidation -Confirm:$false -ErrorAction SilentlyContinue)
Assert-Equal 1 $repaired.Count 'a VM named twice is consolidated once'

$badRepair = @([PSCustomObject]@{ VM = 'ghost-01' } | Repair-VMConsolidation -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable repErr)
Assert-True ([bool](@($repErr) -match 'Could not resolve')) 'an unresolvable VM is reported'

Reset-Calls

Write-Host "`n=== PowerCLI detection ==="

# Broadcom renamed VMware.PowerCLI to VCF.PowerCLI. Both names will be in the wild for
# years, so detection has to accept either.
& $module {
    function script:Get-Module {
        param([Parameter(ValueFromRemainingArguments)]$Rest, [switch]$ListAvailable, $Name)
        if ($Name -eq $script:FakeInstalledModule) { return [PSCustomObject]@{ Name = $Name } }
        return $null
    }
}
foreach ($available in @('VMware.VimAutomation.Core', 'VCF.PowerCLI', 'VMware.PowerCLI')) {
    & $module { param($p) $script:FakeInstalledModule = $p } $available
    Assert-True (& $module { Test-PowerCLIPresent }) "detects PowerCLI via $available"
}
& $module { $script:FakeInstalledModule = 'nothing-installed' }
Assert-Equal $false (& $module { Test-PowerCLIPresent }) 'reports absent when no PowerCLI module is installed'

Write-Host "`n=== output formatting ==="

# PowerShell falls back to a list above four properties, and most of these reports have
# more. Without the format file they would each render as a block per row.
$formatChecks = @(
    @{ Type = 'VSphereReportKit.VMInventory';    Props = @{ Name='web-01'; OS='Ubuntu'; HardwareVersion='vmx-19'; Domain='corp'; PowerState='poweredOn'; ToolsStatus='guestToolsCurrent'; ToolsRunning='r'; ToolsVersion='1'; IsTemplate=$false; Notes='' }; Header = 'Name\s+PowerState\s+HW' }
    @{ Type = 'VSphereReportKit.VMToolsStatus';  Props = @{ Name='sql-01'; OS='Windows'; PowerState='poweredOn'; ToolsStatus='guestToolsNeedUpgrade'; ToolsRunning='r'; ToolsVersion='2'; Action='Upgrade' }; Header = 'Name\s+Action\s+PowerState' }
    @{ Type = 'VSphereReportKit.VMRemovalEvent'; Props = @{ Time=(Get-Date); EventType='VmRemovedEvent'; User='u'; VM='v'; VMHost='h'; Datacenter='d'; Message='m' }; Header = 'Time\s+EventType\s+User' }
    @{ Type = 'VSphereReportKit.VMSnapshot';     Props = @{ Kind='Snapshot'; VM='app-01'; Snapshot='s'; Description='d'; CreatedOn=(Get-Date); AgeDays=40.0; SizeGB=3.0; State='poweredOn'; Quiesced=$true; Consolidate=$false }; Header = 'VM\s+Snapshot\s+AgeDays' }
    @{ Type = 'VSphereReportKit.HostCompliance'; Props = @{ Source='vLCM image'; Entity='esx-01'; Target='c'; Status='Compliant' }; Header = 'Entity\s+Status\s+Source' }
)
foreach ($check in $formatChecks) {
    $object = [PSCustomObject]$check.Props
    $object.PSObject.TypeNames.Insert(0, $check.Type)
    $rendered = $object | Out-String -Width 200
    Assert-True ($rendered -match $check.Header) "$($check.Type.Split('.')[-1]) renders as a table"
}

Write-Host "`n=== Invoke-VSphereReport - direct dispatch ==="

# From this point the Get-* functions are themselves stubbed, so no query test may be
# added below without silently testing the stub instead of the code.
& $module {
    function script:Get-VMInventoryReport {
        param($IncludeTemplate, $Server)
        $rows = @(
            [PSCustomObject]@{ Name='web-01'; OS='Ubuntu'; HardwareVersion='vmx-19'; Domain='corp'; PowerState='poweredOn'; ToolsStatus='guestToolsCurrent'; ToolsVersion='1' }
            [PSCustomObject]@{ Name='sql-01'; OS='Windows'; HardwareVersion='vmx-17'; Domain='corp'; PowerState='poweredOn'; ToolsStatus='guestToolsNeedUpgrade'; ToolsVersion='2' }
        )
        if ($IncludeTemplate) { $rows += [PSCustomObject]@{ Name='tmpl'; OS='Windows'; HardwareVersion='vmx-21'; Domain='corp'; PowerState='poweredOff'; ToolsStatus='guestToolsNotInstalled'; ToolsVersion='0' } }
        $rows
    }
    function script:Get-VMToolsReport {
        param($State, $IncludeUnmanaged, $IncludeTemplate, $Server, [Parameter(ValueFromPipeline)]$InputObject)
        end { [PSCustomObject]@{ Name='sql-01'; OS='Windows'; PowerState='poweredOn'; ToolsStatus='guestToolsNeedUpgrade'; ToolsVersion='2'; Action="Upgrade:$State" } }
    }
    function script:Get-VMRemovalEvent {
        param($Days, $EventType, $Server)
        [PSCustomObject]@{ Time=(Get-Date); EventType='VmRemovedEvent'; User='CORP\jr'; VM="gone-$Days"; VMHost='esx-01' }
    }
    function script:Get-VMSnapshotReport {
        param($OlderThanDays, $IncludeTemplate, $Server)
        [PSCustomObject]@{ Kind='Snapshot'; VM='app-01'; Snapshot="snap-$OlderThanDays"; AgeDays=40.0; SizeGB=3.0; State='poweredOn'; Quiesced=$true; Consolidate=$false }
    }
    function script:Get-VMHostComplianceReport {
        param($Mode, $Server)
        [PSCustomObject]@{ Source="src-$Mode"; Entity='esx-01'; Target='cluster'; Status='Compliant' }
    }
}

$direct = @(Invoke-VSphereReport -Report Snapshots -OlderThanDays 30)
Assert-Equal 1 $direct.Count 'Snapshots returns a row'
Assert-True ($direct[0] -is [PSCustomObject]) 'result is an object, not formatted text'
Assert-Equal 'snap-30' $direct[0].Snapshot '-OlderThanDays is passed through'
Assert-True ($null -ne $direct[0].Quiesced) 'columns beyond the menu list survive'

Assert-Equal 'gone-45' (@(Invoke-VSphereReport -Report Removals -Days 45))[0].VM '-Days is passed through'
Assert-Equal 'Upgrade:Outdated' (@(Invoke-VSphereReport -Report Tools -ToolsState Outdated))[0].Action '-ToolsState is passed through'
Assert-Equal 'src-Image' (@(Invoke-VSphereReport -Report Compliance -ComplianceMode Image))[0].Source '-ComplianceMode is passed through'
Assert-Equal 2 (@(Invoke-VSphereReport -Report Inventory)).Count 'templates excluded by default'
Assert-Equal 3 (@(Invoke-VSphereReport -Report Inventory -IncludeTemplate)).Count '-IncludeTemplate is passed through'
Assert-Equal 1 (@($direct | Where-Object SizeGB -gt 1)).Count 'output pipes into Where-Object'

Write-Host "`n=== Invoke-VSphereReport - filter ==="

Assert-Equal 1 (@(Invoke-VSphereReport -Report Inventory -Filter 'vmx-17')).Count 'filter matches on hardware version'
Assert-Equal 'sql-01' (@(Invoke-VSphereReport -Report Inventory -Filter 'vmx-17'))[0].Name 'filter keeps the right row'
Assert-Equal 1 (@(Invoke-VSphereReport -Report Inventory -Filter 'WEB')).Count 'filter is case-insensitive'
Assert-Equal 2 (@(Invoke-VSphereReport -Report Inventory -Filter 'corp')).Count 'filter matches across any property'
Assert-Equal 2 (@(Invoke-VSphereReport -Report Inventory -Filter '')).Count 'empty filter keeps everything'
Assert-Equal 0 (@(Invoke-VSphereReport -Report Inventory -Filter 'zzz')).Count 'no match returns nothing'
Assert-Equal 0 (@(Invoke-VSphereReport -Report Inventory -Filter '[web')).Count 'brackets are literal, not wildcards'
Assert-Equal 0 (@(Invoke-VSphereReport -Report Inventory -Filter '*')).Count 'asterisk is literal, not a wildcard'

Write-Host "`n=== Invoke-VSphereReport - menu ==="

# Read-Host reads the host rather than the pipeline, so the menu can only be driven by a
# child process with stdin redirected into it. Fixtures are written to a temporary folder
# and removed at the end; test scaffolding does not belong in a source tree.
$fixtures = Join-Path ([System.IO.Path]::GetTempPath()) ("vsr-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $fixtures -Force

# The child gets its own stub, written out literally rather than reflected out of this
# process. Simpler, and it leaves a launcher a person can read when a run goes wrong.
$launcher = Join-Path $fixtures 'launcher.ps1'
@"
Import-Module '$($ModulePath -replace "'", "''")' -Force
`$m = Get-Module VSphereReportKit
& `$m {
    function script:Get-VMSnapshotReport {
        param(`$OlderThanDays, `$IncludeTemplate, `$Server)
        [PSCustomObject]@{
            Kind = 'Snapshot'; VM = 'app-01'; Snapshot = "snap-`$OlderThanDays"
            AgeDays = 40.0; SizeGB = 3.0; State = 'poweredOn'; Quiesced = `$true; Consolidate = `$false
        }
    }
}
`$global:DefaultVIServers = @([PSCustomObject]@{ Name = 'fake-vc'; IsConnected = `$true })
`$global:DefaultVIServer  = `$global:DefaultVIServers[0]
Invoke-VSphereReport
"@ | Set-Content -Path $launcher -Encoding UTF8

# Choose 4 (Snapshots), accept the default age, no filter, skip the export, then quit.
"4`n`n`n`nq`n" | Set-Content -Path (Join-Path $fixtures 'menu.txt') -Encoding UTF8 -NoNewline
"99`nbanana`nq`n"  | Set-Content -Path (Join-Path $fixtures 'bad.txt')  -Encoding UTF8 -NoNewline

$pwsh = (Get-Process -Id $PID).Path
function Invoke-Menu {
    param([string] $InputFile)
    Get-Content (Join-Path $fixtures $InputFile) | & $pwsh -NoProfile -File $launcher 2>&1 | Out-String
}

try {
    $transcript = Invoke-Menu 'menu.txt'
    Assert-True ($transcript -match 'vSphere reports')        'menu header is shown'
    Assert-True ($transcript -match 'Old snapshots')          'menu lists the snapshot report'
    Assert-True ($transcript -match 'Host patch compliance')  'menu lists every report'
    Assert-True ($transcript -match 'q\s+quit')               'quit option is offered'
    Assert-True ($transcript -match 'Filter \(blank for all\)') 'filter prompt is offered'
    Assert-True ($transcript -match 'app-01')                 'the chosen report actually ran'
    Assert-True ($transcript -match 'snap-7')                 'the default age was applied'
    Assert-True ($transcript -match '1 row\(s\)')             'row count is reported'
    Assert-True ($transcript -match 'Export to CSV')          'export is offered'
    Assert-Equal 2 ([regex]::Matches($transcript, 'Choose \[1-5').Count) 'menu redraws after a report'

    # Piped input that runs out mid-menu has to exit. Otherwise the loop spins on empty
    # Read-Host results, consuming a core and producing nothing.
    "3`n" | Set-Content -Path (Join-Path $fixtures 'short.txt') -Encoding UTF8 -NoNewline
    $shortRun = Invoke-Menu 'short.txt'
    Assert-True ($shortRun -match 'No more input|No interactive input available') 'truncated stdin exits instead of looping'

    $badRun = Invoke-Menu 'bad.txt'
    Assert-Equal 2 ([regex]::Matches($badRun, 'Not one of the options').Count) 'out-of-range and non-numeric input both rejected'
    Assert-True ($badRun -notmatch 'Exception') 'bad input does not throw'
    Assert-True ($badRun -notmatch 'app-01')    'no report runs on bad input'
} finally {
    Remove-Item $fixtures -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
Remove-Variable -Name DefaultVIServers, DefaultVIServer -Scope Global -ErrorAction SilentlyContinue
Remove-Item function:global:New-VmView -ErrorAction SilentlyContinue
if ($script:Fail -gt 0) { exit 1 }
