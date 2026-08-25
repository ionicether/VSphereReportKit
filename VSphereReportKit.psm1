#Requires -Version 5.1

<#
    VSphereReportKit

    Reporting over a vCenter connection. Every function writes objects to the pipeline -
    no formatting, no files, no grids. Sort, filter, export and schedule with the usual
    tools.

    Every Get- command is read-only. Remove-OldVMSnapshot is the single exception and is
    deliberately a separate step, taking report objects from the pipeline so that what is
    deleted is exactly what was looked at.

        Connect-VIServer vcenter.corp.local
        Get-VMSnapshotReport -OlderThanDays 30 | Where-Object SizeGB -gt 50 | Export-Csv snaps.csv -NoTypeInformation

    Invoke-VSphereReport wraps the five in a menu for interactive use, or dispatches
    straight to one of them with -Report.

    Needs VMware PowerCLI 13.x (VMware.VimAutomation.Core). Connecting is the caller's
    job - these functions use the current connection, or whatever you pass to -Server.

    Keep this file ASCII. 5.1 reads a BOM-less file as ANSI, so the first smart quote
    anyone pastes in comes back mangled.
#>

#region ----------------------------------------------------------------- private

# Walks a dotted path and returns a default rather than throwing when something in the
# middle is null. This is not defensive paranoia. Get-View genuinely omits Config, Guest
# and LayoutEx whenever the data is unavailable, and a VM that is powered off or still
# being created is the normal case, not the exception.
function Get-SafeProp {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] $InputObject,
        [Parameter(Position = 1)] [string] $Path,
        [Parameter(Position = 2)] $Default = $null
    )

    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

# -Server is optional throughout, so it is assembled once and splatted. The alternative
# is the same conditional repeated at every call site, which is where drift begins.
function Get-ServerParameter {
    [CmdletBinding()]
    param($Server)

    $parameters = @{}
    if ($Server) { $parameters['Server'] = $Server }
    return $parameters
}

# Broadcom renamed VMware.PowerCLI to VCF.PowerCLI in June 2025. Both names are still in
# the wild and will be for years, so asking which one is installed is the wrong question.
# What matters is whether the core module can be loaded, and either package provides it.
function Test-PowerCLIPresent {
    [CmdletBinding()]
    param()

    foreach ($name in @('VMware.VimAutomation.Core', 'VCF.PowerCLI', 'VMware.PowerCLI')) {
        if (Get-Module -ListAvailable -Name $name) { return $true }
    }
    return $false
}

function Import-PowerCLICore {
    [CmdletBinding()]
    param()

    if (Get-Module -Name VMware.VimAutomation.Core) { return }
    if (-not (Test-PowerCLIPresent)) {
        throw 'PowerCLI is not installed. Install VCF.PowerCLI (or the legacy VMware.PowerCLI) first.'
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
}

function Assert-VIConnection {
    [CmdletBinding()]
    param($Server)

    if ($Server) { return }
    if (-not (Test-VIConnected)) {
        throw 'Not connected to a vCenter Server. Run Connect-VIServer first, or pass -Server.'
    }
}

#endregion

#region --------------------------------------------------------------- inventory

function Get-VMInventoryReport {
    <#
    .SYNOPSIS
        Virtual machine inventory with guest, hardware and VMware Tools detail.

    .DESCRIPTION
        One Get-View call, dotted property paths only - ask for whole Config or Guest
        objects and you drag back far more than these few fields.

        Domain comes from Guest.Domain where the guest reports it, otherwise it's
        derived from the reported FQDN.

        ToolsStatus is Guest.ToolsVersionStatus2, which is the one to trust.
        ToolsStatus and ToolsVersionStatus were deprecated in vSphere API 4.0 and 5.1;
        the fallback is there for ancient endpoints.

    .PARAMETER Server
        vCenter connection to use. Defaults to the current one.

    .PARAMETER IncludeTemplate
        Include VM templates. Excluded by default.

    .EXAMPLE
        Get-VMInventoryReport | Group-Object HardwareVersion | Sort-Object Count -Descending

    .EXAMPLE
        Get-VMInventoryReport | Where-Object PowerState -eq 'poweredOff' | Select-Object Name, OS
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        $Server,
        [switch] $IncludeTemplate
    )

    Assert-VIConnection -Server $Server
    $viParameters = Get-ServerParameter -Server $Server

    $properties = @(
        'Name'
        'Config.GuestFullName'
        'Config.Version'
        'Config.Annotation'
        'Config.Template'
        'Guest.Domain'
        'Guest.HostName'
        'Guest.GuestFullName'
        'Guest.ToolsStatus'
        'Guest.ToolsVersionStatus2'
        'Guest.ToolsRunningStatus'
        'Guest.ToolsVersion'
        'Runtime.PowerState'
    )

    Write-Verbose 'Retrieving virtual machine views'
    $views = @(Get-View @viParameters -ViewType VirtualMachine -Property $properties)
    Write-Verbose "Got $($views.Count) view(s)"

    $index = 0
    foreach ($view in $views) {
        $index++
        if ($index % 50 -eq 0 -or $index -eq $views.Count) {
            Write-Progress -Activity 'Building VM inventory' -Status "$index of $($views.Count)" `
                -PercentComplete (($index / [math]::Max(1, $views.Count)) * 100)
        }

        $isTemplate = [bool](Get-SafeProp $view 'Config.Template' $false)
        if ($isTemplate -and -not $IncludeTemplate) { continue }

        $domain = Get-SafeProp $view 'Guest.Domain'
        if (-not $domain) {
            $fqdn = Get-SafeProp $view 'Guest.HostName'
            if ($fqdn -and $fqdn.Contains('.')) {
                $parts = $fqdn.Split('.')
                if ($parts.Length -gt 1) { $domain = ($parts[1..($parts.Length - 1)] -join '.') }
            }
        }

        $osName = Get-SafeProp $view 'Config.GuestFullName'
        if (-not $osName) { $osName = Get-SafeProp $view 'Guest.GuestFullName' }

        $notes = Get-SafeProp $view 'Config.Annotation' ''
        if ($notes) { $notes = ($notes -replace '\s+', ' ').Trim() }

        $toolsStatus = Get-SafeProp $view 'Guest.ToolsVersionStatus2'
        if (-not $toolsStatus) { $toolsStatus = Get-SafeProp $view 'Guest.ToolsStatus' }

        [PSCustomObject]@{
            PSTypeName      = 'VSphereReportKit.VMInventory'
            Name            = $view.Name
            OS              = $osName
            HardwareVersion = Get-SafeProp $view 'Config.Version'
            Domain          = $domain
            PowerState      = [string](Get-SafeProp $view 'Runtime.PowerState')
            ToolsStatus     = [string]$toolsStatus
            ToolsRunning    = [string](Get-SafeProp $view 'Guest.ToolsRunningStatus')
            ToolsVersion    = [string](Get-SafeProp $view 'Guest.ToolsVersion')
            IsTemplate      = $isTemplate
            Notes           = $notes
        }
    }

    Write-Progress -Activity 'Building VM inventory' -Completed
}

#endregion

#region ------------------------------------------------------------ VMware Tools

function Get-VMToolsReport {
    <#
    .SYNOPSIS
        VMs whose VMware Tools are missing or out of date.

    .DESCRIPTION
        Takes inventory from the pipeline, or fetches it if you don't supply any. Pipe
        it in when you want both slices out of a single scan:

            $inventory = Get-VMInventoryReport
            $inventory | Get-VMToolsReport -State NotInstalled
            $inventory | Get-VMToolsReport -State Outdated

        Outdated leaves out guestToolsUnmanaged unless you ask for it. That's
        open-vm-tools, patched by the distro, and not something vCenter should be
        nagging anyone about. guestToolsBlacklisted counts as outdated - blacklisted
        builds have known issues and need replacing.

        Guest data goes stale while a VM is powered off, so PowerState is on every row.
        Use -PoweredOnOnly to drop the ones you can't trust.

    .PARAMETER InputObject
        Inventory objects from Get-VMInventoryReport.

    .PARAMETER State
        NotInstalled, Outdated, or Any. Defaults to Any, which means either problem
        state - it does not return healthy VMs. Use Get-VMInventoryReport for those.

    .PARAMETER IncludeUnmanaged
        Count guestToolsUnmanaged as outdated. Off by default.

    .PARAMETER Server
        vCenter connection, used only when no inventory is piped in.

    .PARAMETER IncludeTemplate
        Include templates, used only when no inventory is piped in.

    .EXAMPLE
        Get-VMToolsReport -State Outdated | Where-Object PowerState -eq 'poweredOn'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromPipeline)]
        [PSObject[]] $InputObject,

        [ValidateSet('NotInstalled', 'Outdated', 'Any')]
        [string] $State = 'Any',

        [switch] $IncludeUnmanaged,
        [switch] $PoweredOnOnly,
        $Server,
        [switch] $IncludeTemplate
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
        $notInstalled = @('guestToolsNotInstalled', 'toolsNotInstalled')
        # Not the complete VirtualMachineToolsVersionStatus enum. It has grown since API
        # 4.0 and varies by version, so enumerating it exhaustively would only give the
        # illusion of completeness. These are the states that call for action.
        $outdated     = @('guestToolsNeedUpgrade', 'guestToolsSupportedOld', 'guestToolsTooOld',
                          'guestToolsBlacklisted', 'toolsOld')
    }

    process {
        if ($InputObject) {
            foreach ($item in $InputObject) { $collected.Add($item) }
        }
    }

    end {
        if ($collected.Count -eq 0) {
            Write-Verbose 'Nothing piped in, fetching inventory'
            $collected.AddRange(@(Get-VMInventoryReport -Server $Server -IncludeTemplate:$IncludeTemplate))
        }

        $wanted = @()
        if ($State -eq 'NotInstalled') { $wanted = $notInstalled }
        elseif ($State -eq 'Outdated') {
            $wanted = $outdated
            if ($IncludeUnmanaged) { $wanted += 'guestToolsUnmanaged' }
        }
        else { $wanted = $notInstalled + $outdated }

        foreach ($vm in $collected) {
            if ($wanted -notcontains $vm.ToolsStatus) { continue }
            if ($PoweredOnOnly -and $vm.PowerState -ne 'poweredOn') { continue }

            [PSCustomObject]@{
                PSTypeName   = 'VSphereReportKit.VMToolsStatus'
                Name         = $vm.Name
                OS           = $vm.OS
                PowerState   = $vm.PowerState
                ToolsStatus  = $vm.ToolsStatus
                ToolsRunning = $vm.ToolsRunning
                ToolsVersion = $vm.ToolsVersion
                Action       = $(if ($notInstalled -contains $vm.ToolsStatus) { 'Install' } else { 'Upgrade' })
            }
        }
    }
}

#endregion

#region ---------------------------------------------------------- removal events

function Get-VMRemovalEvent {
    <#
    .SYNOPSIS
        VMs removed from inventory or destroyed from disk, from the vCenter event log.

    .DESCRIPTION
        Get-VIEvent stops at 100 samples unless you pass BOTH -Start and -Finish, and
        it won't tell you it did. This uses an EventManager collector instead: no cap,
        filters by type server-side, pages through the lot, and destroys the collector
        afterwards - a session only gets 32 of them.

        Removed from inventory and destroyed from disk are two different events. Ask
        for only one and you'll think you have the full picture.

        Two reasons an empty result is not proof that nothing was deleted:

          Retention. vCenter keeps events for 30 days by default (event.maxAge). Ask for
          a longer window and you get a warning - otherwise silence reads as "nothing was
          deleted" when it means "vCenter forgot". Reading that setting needs the
          Global.Settings privilege, so on a read-only account the check is skipped.

          Folder deletes. Deleting a folder that contains VMs can remove them without
          raising a per-VM event at all, so those deletions never appear here. Treat this
          as a strong signal, not an audit.

    .PARAMETER Days
        How far back to look. Defaults to 14.

    .PARAMETER EventType
        Removed, Destroyed, or both. Defaults to both.

    .PARAMETER PageSize
        Events per ReadNextEvents call. Defaults to 500.

    .PARAMETER Server
        vCenter connection to use.

    .EXAMPLE
        Get-VMRemovalEvent -Days 30 | Group-Object User | Sort-Object Count -Descending
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 3650)]
        [int] $Days = 14,

        [ValidateSet('Removed', 'Destroyed')]
        [string[]] $EventType = @('Removed', 'Destroyed'),

        [ValidateRange(1, 5000)]
        [int] $PageSize = 500,

        $Server
    )

    Assert-VIConnection -Server $Server
    $viParameters = Get-ServerParameter -Server $Server

    $typeMap = @{ Removed = 'VmRemovedEvent'; Destroyed = 'VmDestroyedEvent' }
    $typeIds = @($EventType | ForEach-Object { $typeMap[$_] })
    $sinceUtc = (Get-Date).AddDays(-$Days).ToUniversalTime()

    # Warn before the query rather than after. A caller who has asked for ninety days of
    # history should learn that vCenter keeps thirty before they read the results, not
    # while they are drawing conclusions from them.
    try {
        $maxAge     = Get-AdvancedSetting @viParameters -Entity $global:DefaultVIServer -Name 'event.maxAge' -ErrorAction Stop
        $maxEnabled = Get-AdvancedSetting @viParameters -Entity $global:DefaultVIServer -Name 'event.maxAgeEnabled' -ErrorAction Stop
        if ($maxEnabled -and ([string]$maxEnabled.Value -eq 'true') -and $maxAge) {
            $retentionDays = [int]$maxAge.Value
            if ($retentionDays -lt $Days) {
                Write-Warning "vCenter keeps events for $retentionDays day(s). Anything older than that is gone."
            }
        }
    } catch {
        # Reading advanced settings requires Global.Settings, which a read-only account
        # will not have. Losing the warning is acceptable; failing the report is not.
        Write-Verbose "Could not read event retention settings: $($_.Exception.Message)"
    }

    Write-Verbose "Opening event collector for $($typeIds -join ', ') since $sinceUtc UTC"
    $serviceInstance = Get-View @viParameters ServiceInstance
    $eventManager    = Get-View @viParameters $serviceInstance.Content.EventManager

    $spec                = New-Object VMware.Vim.EventFilterSpec
    $spec.Time           = New-Object VMware.Vim.EventFilterSpecByTime
    $spec.Time.BeginTime = $sinceUtc

    $serverSideFilter = $true
    try {
        $spec.EventTypeId = $typeIds
        $collectorRef = $eventManager.CreateCollectorForEvents($spec)
    } catch {
        # Some endpoints reject EventTypeId. I have not been able to establish exactly
        # which, so this fallback is precaution rather than a documented requirement.
        Write-Verbose 'EventTypeId rejected, filtering on the client instead'
        $serverSideFilter = $false
        $spec.EventTypeId = $null
        $collectorRef = $eventManager.CreateCollectorForEvents($spec)
    }

    $collector = Get-View @viParameters $collectorRef
    $rows = [System.Collections.Generic.List[object]]::new()

    try {
        $collector.ResetCollector()
        while ($true) {
            $page = $collector.ReadNextEvents($PageSize)
            if ($null -eq $page -or $page.Count -eq 0) { break }
            Write-Progress -Activity 'Reading vCenter events' -Status "$($rows.Count) matched"

            foreach ($viEvent in $page) {
                if (-not $serverSideFilter -and $typeIds -notcontains $viEvent.GetType().Name) { continue }

                $vmName = ''
                if ($viEvent.Vm) { $vmName = $viEvent.Vm.Name }
                $hostName = ''
                if ($viEvent.Host) { $hostName = $viEvent.Host.Name }
                $dcName = ''
                if ($viEvent.Datacenter) { $dcName = $viEvent.Datacenter.Name }

                $message = ''
                if ($viEvent.FullFormattedMessage) {
                    $message = ($viEvent.FullFormattedMessage -replace '\s+', ' ').Trim()
                }

                $rows.Add([PSCustomObject]@{
                    PSTypeName = 'VSphereReportKit.VMRemovalEvent'
                    Time       = $viEvent.CreatedTime.ToLocalTime()   # UTC on the wire
                    EventType  = $viEvent.GetType().Name
                    User       = $viEvent.UserName
                    VM         = $vmName
                    VMHost     = $hostName
                    Datacenter = $dcName
                    Message    = $message
                })
            }
        }
    } finally {
        try { $collector.DestroyCollector() } catch { }
        Write-Progress -Activity 'Reading vCenter events' -Completed
    }

    # A second, weaker signal. If the oldest event returned sits well inside the window
    # that was requested, the earlier ones have most likely been rolled up. This is an
    # inference rather than a fact, which is why it is phrased as a possibility.
    if ($rows.Count -gt 0) {
        $oldest = ($rows | Sort-Object Time | Select-Object -First 1).Time.ToUniversalTime()
        if (($oldest - $sinceUtc).TotalDays -gt 1) {
            $held = [int][math]::Round(((Get-Date).ToUniversalTime() - $oldest).TotalDays)
            Write-Warning "Oldest event found is $held day(s) old. Earlier ones may have been rolled up."
        }
    }

    $rows | Sort-Object Time -Descending
}

#endregion

#region --------------------------------------------------------------- snapshots

function Get-VMSnapshotReport {
    <#
    .SYNOPSIS
        Snapshots with age and the disk space attributable to each one.

    .DESCRIPTION
        SizeGB is the space attributable to that one snapshot: its state file (DataKey),
        its memory file if it has one (MemoryKey), and the last unit of each disk chain,
        that last unit being the delta the snapshot created. It all comes out of the same
        Get-View, so there's no second pass with Get-Snapshot. The base disk is never
        counted - it is not reclaimed by deleting a snapshot.

        Two things to know before you trust the number. Sizes come from LayoutEx, which
        lags actual growth; pass -Refresh to call RefreshStorageInfo() first (accurate,
        but a per-VM round trip). And the last-chain-unit attribution is verified here
        only against linear chains, so benchmark one VM against
        Get-Snapshot | Select-Object Name, SizeGB before trusting it on a branched tree.

        CreateTime is UTC. Compare it against a local threshold and every row comes out
        wrong by your UTC offset.

        VMs flagged for consolidation with nothing in the snapshot tree are emitted too,
        with Kind = 'OrphanedDelta'. Those are delta disks with no snapshot attached -
        invisible in a normal snapshot report, and often the thing actually eating the
        datastore. Filter them out with Where-Object Kind -eq 'Snapshot' if you'd rather
        not see them.

    .PARAMETER OlderThanDays
        Only snapshots at least this old. 0 (the default) returns everything.

    .PARAMETER Server
        vCenter connection to use.

    .PARAMETER IncludeTemplate
        Include templates. Excluded by default.

    .PARAMETER Refresh
        Call RefreshStorageInfo() on each VM first so sizes are current rather than as
        at snapshot creation. Accurate, but one round trip per VM.

    .EXAMPLE
        Get-VMSnapshotReport -OlderThanDays 30 | Sort-Object SizeGB -Descending | Select-Object -First 20

    .EXAMPLE
        Get-VMSnapshotReport | Measure-Object SizeGB -Sum
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(0, 3650)]
        [int] $OlderThanDays = 0,

        $Server,
        [switch] $IncludeTemplate,
        [switch] $Refresh
    )

    Assert-VIConnection -Server $Server
    $viParameters = Get-ServerParameter -Server $Server

    $properties = @(
        'Name'
        'Snapshot'
        'LayoutEx.File'
        'LayoutEx.Snapshot'
        'Runtime.ConsolidationNeeded'
        'Config.Template'
    )

    Write-Verbose 'Retrieving snapshot layout'
    $views       = @(Get-View @viParameters -ViewType VirtualMachine -Property $properties)
    $nowUtc      = (Get-Date).ToUniversalTime()
    $thresholdUtc = $nowUtc.AddDays(-$OlderThanDays)
    $index       = 0

    foreach ($view in $views) {
        $index++
        if ($index % 50 -eq 0 -or $index -eq $views.Count) {
            Write-Progress -Activity 'Walking snapshot trees' -Status "$index of $($views.Count)" `
                -PercentComplete (($index / [math]::Max(1, $views.Count)) * 100)
        }

        $isTemplate = [bool](Get-SafeProp $view 'Config.Template' $false)
        if ($isTemplate -and -not $IncludeTemplate) { continue }

        if ($Refresh) {
            # LayoutEx reports sizes as they were at snapshot creation. A snapshot that
            # has been quietly growing for six months will still report its birth size
            # unless the VM is refreshed first.
            try { $view.RefreshStorageInfo() }
            catch { Write-Error "Could not refresh storage info for $($view.Name): $($_.Exception.Message)" }
        }

        $consolidate = [bool](Get-SafeProp $view 'Runtime.ConsolidationNeeded' $false)
        $roots       = Get-SafeProp $view 'Snapshot.RootSnapshotList'

        if ($consolidate -and -not $roots) {
            [PSCustomObject]@{
                PSTypeName  = 'VSphereReportKit.VMSnapshot'
                Kind        = 'OrphanedDelta'
                VM          = $view.Name
                VMId        = $(if (Get-SafeProp $view 'MoRef.Value') { "VirtualMachine-$(Get-SafeProp $view 'MoRef.Value')" } else { $null })
                Snapshot    = $null
                SnapshotId  = $null
                ParentId    = $null
                Description = 'Consolidation needed, no snapshot in the tree'
                CreatedOn   = $null
                AgeDays     = $null
                SizeGB      = $null
                State       = $null
                Quiesced    = $false
                Consolidate = $true
            }
        }
        if (-not $roots) { continue }

        $fileSize = @{}
        foreach ($file in @(Get-SafeProp $view 'LayoutEx.File')) {
            if ($null -ne $file) { $fileSize[[int]$file.Key] = [long]$file.Size }
        }

        $snapshotSize = @{}
        foreach ($layout in @(Get-SafeProp $view 'LayoutEx.Snapshot')) {
            if ($null -eq $layout) { continue }
            $bytes = [long]0

            # DataKey is the .vmsn state file. MemoryKey is the separate memory image
            # written when a snapshot includes memory, and omitting it understates those
            # snapshots by the entire guest RAM, which on a large VM is the difference
            # between an accurate report and a misleading one. Older layouts fold memory
            # into the .vmsn and report -1 here, so both keys are read and both guarded.
            foreach ($stateKey in @('DataKey', 'MemoryKey')) {
                $keyProperty = $layout.PSObject.Properties[$stateKey]
                if ($null -eq $keyProperty -or $null -eq $keyProperty.Value) { continue }
                $key = [int]$keyProperty.Value
                if ($key -ge 0 -and $fileSize.ContainsKey($key)) { $bytes += $fileSize[$key] }
            }
            foreach ($disk in @($layout.Disk)) {
                if ($null -eq $disk -or -not $disk.Chain -or $disk.Chain.Count -eq 0) { continue }
                $unit = $disk.Chain[$disk.Chain.Count - 1]
                foreach ($key in @($unit.FileKey)) {
                    if ($fileSize.ContainsKey([int]$key)) { $bytes += $fileSize[[int]$key] }
                }
            }
            $snapshotSize[[string]$layout.Key.Value] = $bytes
        }

        # Push nodes rather than arrays. One node per pop, every child visited exactly
        # once, and no dependence on how deep the tree happens to be. Each entry carries
        # its parent's id, so a consumer can reason about the tree without rebuilding it.
        $vmMoRef = [string](Get-SafeProp $view 'MoRef.Value' '')
        $vmId    = $(if ($vmMoRef) { "VirtualMachine-$vmMoRef" } else { $null })

        $stack = [System.Collections.Stack]::new()
        foreach ($root in @($roots)) {
            if ($null -ne $root) { $stack.Push([PSCustomObject]@{ Node = $root; ParentId = $null }) }
        }

        while ($stack.Count -gt 0) {
            $entry    = $stack.Pop()
            $snapshot = $entry.Node

            if ($snapshot.CreateTime -lt $thresholdUtc) {
                $description = ''
                if ($snapshot.Description) {
                    $description = ($snapshot.Description -replace '\s+', ' ').Trim()
                }

                $sizeGb = $null
                $moRef  = [string]$snapshot.Snapshot.Value
                if ($snapshotSize.ContainsKey($moRef)) {
                    $sizeGb = [math]::Round($snapshotSize[$moRef] / 1GB, 2)
                }

                # PowerCLI addresses a snapshot as VirtualMachineSnapshot-<moref>.
                # Carrying it means anything acting on this report can identify the
                # snapshot exactly, rather than by a name that need not be unique and
                # that Get-Snapshot would in any case treat as a wildcard pattern.
                $snapshotId = $(if ($moRef) { "VirtualMachineSnapshot-$moRef" } else { $null })

                [PSCustomObject]@{
                    PSTypeName  = 'VSphereReportKit.VMSnapshot'
                    Kind        = 'Snapshot'
                    VM          = $view.Name
                    VMId        = $vmId
                    Snapshot    = $snapshot.Name
                    SnapshotId  = $snapshotId
                    ParentId    = $entry.ParentId
                    Description = $description
                    CreatedOn   = $snapshot.CreateTime.ToLocalTime()
                    AgeDays     = [math]::Round(($nowUtc - $snapshot.CreateTime).TotalDays, 1)
                    SizeGB      = $sizeGb
                    State       = [string]$snapshot.State
                    Quiesced    = [bool]$snapshot.Quiesced
                    Consolidate = $consolidate
                }
            }

            foreach ($child in @($snapshot.ChildSnapshotList)) {
                if ($null -ne $child) {
                    $stack.Push([PSCustomObject]@{ Node = $child; ParentId = $snapshotId })
                }
            }
        }
    }

    Write-Progress -Activity 'Walking snapshot trees' -Completed
}

#endregion

#region -------------------------------------------------------------- compliance

function Get-VMHostComplianceReport {
    <#
    .SYNOPSIS
        ESXi host patch compliance, from vLCM images or VUM baselines.

    .DESCRIPTION
        Auto tries Test-LcmClusterCompliance per cluster and falls back to baselines for
        any cluster that isn't image-managed, plus any standalone host. That keeps
        working as an estate moves off VUM.

        Test-Compliance is synchronous unless you pass -RunAsync, and returns nothing.
        No sleep needed - a sleep would only ever have been a guess.

        Baseline patching is deprecated as of vSphere 8.0 and goes away in the next
        major release. Rows only appear for hosts that actually have baselines attached.

        A host that fails is reported with Write-Error and the scan carries on, so one
        permissions problem doesn't cost you the whole run.

    .PARAMETER Mode
        Auto, Image, or Baseline. Defaults to Auto.

    .PARAMETER Server
        vCenter connection to use.

    .EXAMPLE
        Get-VMHostComplianceReport | Where-Object Status -ne 'Compliant'

    .EXAMPLE
        Get-VMHostComplianceReport -Mode Image -ErrorVariable problems
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Auto', 'Image', 'Baseline')]
        [string] $Mode = 'Auto',

        $Server
    )

    Assert-VIConnection -Server $Server
    $viParameters = Get-ServerParameter -Server $Server

    $useImage    = $Mode -in @('Auto', 'Image')
    $useBaseline = $Mode -in @('Auto', 'Baseline')

    $hasLcm = $null -ne (Get-Command -Name Test-LcmClusterCompliance -ErrorAction SilentlyContinue)
    $hasVum = $null -ne (Get-Module -ListAvailable -Name VMware.VumAutomation)

    if ($useBaseline -and -not $hasVum) {
        Write-Warning 'VMware.VumAutomation is not installed, so baseline compliance will be skipped.'
    }
    if ($useImage -and -not $hasLcm) {
        Write-Warning 'vSphere Lifecycle Manager cmdlets are not available, so image compliance will be skipped.'
    }
    if ($useBaseline -and $hasVum) {
        Import-Module VMware.VumAutomation -ErrorAction Stop
    }

    $handledHost = [System.Collections.Generic.HashSet[string]]::new()

    if ($useImage -and $hasLcm) {
        $clusters = @(Get-Cluster @viParameters)
        $index = 0
        foreach ($cluster in $clusters) {
            $index++
            Write-Progress -Activity 'Checking vLCM image compliance' -Status "$($cluster.Name) ($index of $($clusters.Count))" `
                -PercentComplete (($index / [math]::Max(1, $clusters.Count)) * 100)

            # Ignore rather than Stop-and-catch. Every cluster still on baselines fails
            # this call on every run, and in PowerShell a caught exception is recorded in
            # $Error regardless. Three phantom entries per cluster is enough noise that a
            # caller stops reading $Error at all, which is precisely when a real error
            # goes unnoticed. The try/catch remains only for the rarer terminating case.
            $compliance = $null
            try {
                $compliance = Test-LcmClusterCompliance -Cluster $cluster -ErrorAction Ignore
            } catch { }

            if ($null -eq $compliance) {
                Write-Verbose "$($cluster.Name) is not image-managed, leaving it for the baseline pass"
                continue
            }

            $emitted = $false
            foreach ($bucket in @('CompliantHosts', 'NonCompliantHosts', 'IncompatibleHosts', 'UnavailableHosts')) {
                $property = $compliance.PSObject.Properties[$bucket]
                if ($null -eq $property -or $null -eq $property.Value) { continue }

                foreach ($vmhost in @($property.Value)) {
                    $hostName = [string]$vmhost
                    if ($vmhost.PSObject.Properties['Name']) { $hostName = [string]$vmhost.Name }

                    [void]$handledHost.Add($hostName)
                    [PSCustomObject]@{
                        PSTypeName = 'VSphereReportKit.HostCompliance'
                        Source     = 'vLCM image'
                        Entity     = $hostName
                        Target     = $cluster.Name
                        Status     = ($bucket -replace 'Hosts$', '')
                    }
                    $emitted = $true
                }
            }

            if (-not $emitted) {
                $status = 'Unknown'
                if ($compliance.PSObject.Properties['Status']) { $status = [string]$compliance.Status }
                [PSCustomObject]@{
                    PSTypeName = 'VSphereReportKit.HostCompliance'
                    Source     = 'vLCM image'
                    Entity     = $cluster.Name
                    Target     = 'Cluster desired state'
                    Status     = $status
                }
                foreach ($vmhost in @(Get-VMHost @viParameters -Location $cluster)) {
                    [void]$handledHost.Add($vmhost.Name)
                }
            }
        }
        Write-Progress -Activity 'Checking vLCM image compliance' -Completed
    }

    if ($useBaseline -and $hasVum) {
        $pending = @(Get-VMHost @viParameters | Where-Object { -not $handledHost.Contains($_.Name) })
        if ($pending.Count -gt 0) {
            Write-Verbose "Scanning $($pending.Count) host(s) against attached baselines"
            Write-Progress -Activity 'Scanning hosts against baselines' -Status "$($pending.Count) host(s)"
            Test-Compliance -Entity $pending -ErrorAction Stop

            $index = 0
            foreach ($vmhost in $pending) {
                $index++
                Write-Progress -Activity 'Reading baseline compliance' -Status "$($vmhost.Name) ($index of $($pending.Count))" `
                    -PercentComplete (($index / [math]::Max(1, $pending.Count)) * 100)

                try {
                    $results = @(Get-Compliance -Entity $vmhost -ErrorAction Stop)
                } catch {
                    Write-Error "Compliance data unavailable for $($vmhost.Name): $($_.Exception.Message)"
                    continue
                }

                if ($results.Count -eq 0) {
                    [PSCustomObject]@{
                        PSTypeName = 'VSphereReportKit.HostCompliance'
                        Source     = 'Baseline (VUM)'
                        Entity     = $vmhost.Name
                        Target     = '(no baseline attached)'
                        Status     = 'NotApplicable'
                    }
                    continue
                }

                foreach ($result in $results) {
                    # The name of this property has changed between PowerCLI versions,
                    # so both are read. Guessing which one you have is not worth it.
                    $status = 'Unknown'
                    if ($result.PSObject.Properties['Status']) {
                        $status = [string]$result.Status
                    } elseif ($result.PSObject.Properties['ComplianceStatus']) {
                        $status = [string]$result.ComplianceStatus
                    }

                    $baselineName = ''
                    if ($result.PSObject.Properties['Baseline'] -and $null -ne $result.Baseline) {
                        if ($result.Baseline.PSObject.Properties['Name']) { $baselineName = [string]$result.Baseline.Name }
                        else { $baselineName = [string]$result.Baseline }
                    }

                    $entityName = $vmhost.Name
                    if ($result.PSObject.Properties['Entity'] -and $null -ne $result.Entity) {
                        if ($result.Entity.PSObject.Properties['Name']) { $entityName = [string]$result.Entity.Name }
                    }

                    [PSCustomObject]@{
                        PSTypeName = 'VSphereReportKit.HostCompliance'
                        Source     = 'Baseline (VUM)'
                        Entity     = $entityName
                        Target     = $baselineName
                        Status     = $status
                    }
                }
            }
            Write-Progress -Activity 'Reading baseline compliance' -Completed
        }
    }
}

#endregion

#region ------------------------------------------------------------- removal

# Resolve a VM by name without wildcard semantics. PowerCLI resolves -VM and -Name
# by pattern, so 'app-01' will happily match 'app-011'. Asking for the pattern and
# then insisting on an exact string equality is the only way to be certain which
# machine came back.
function Resolve-ExactVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [hashtable] $ViParameters = @{}
    )

    $candidates = @(Get-VM @ViParameters -Name $Name -ErrorAction Stop |
                        Where-Object { $_.Name -eq $Name })

    if ($candidates.Count -eq 0) { throw "No VM named exactly '$Name'." }
    if ($candidates.Count -gt 1) { throw "'$Name' matches $($candidates.Count) VMs exactly. Resolve it by hand." }
    return $candidates[0]
}

# Sums each VM's deltas against the datastores that VM sits on, and reports where the
# commit would not fit. A VM spanning several datastores has its whole total counted
# against each of them, which overstates the requirement; that is the right direction
# to be wrong in when the failure mode is a datastore filling during consolidation.
function Test-SnapshotHeadroom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        [hashtable] $ViParameters = @{}
    )

    $needByStore = @{}
    $freeByStore = @{}

    foreach ($group in ($Targets | Group-Object VM)) {
        $vmDelta = 0
        foreach ($row in $group.Group) {
            if ($row.PSObject.Properties['SizeGB'] -and $null -ne $row.SizeGB) { $vmDelta += $row.SizeGB }
        }
        if ($vmDelta -le 0) { continue }

        try {
            $vm     = Resolve-ExactVM -Name $group.Name -ViParameters $ViParameters
            $stores = @(Get-Datastore @ViParameters -VM $vm -ErrorAction Stop)
        } catch {
            # A headroom check that cannot run is not a reason to refuse the work.
            Write-Verbose "Could not check datastore headroom for $($group.Name): $($_.Exception.Message)"
            continue
        }

        foreach ($store in $stores) {
            if (-not $needByStore.ContainsKey($store.Name)) {
                $needByStore[$store.Name] = 0
                $freeByStore[$store.Name] = [double]$store.FreeSpaceGB
            }
            $needByStore[$store.Name] += $vmDelta
        }
    }

    foreach ($name in $needByStore.Keys) {
        $need = $needByStore[$name]
        $free = $freeByStore[$name]
        if ($need -ge $free) {
            Write-Warning ("Datastore {0} has {1:N1} GB free and up to {2:N1} GB is about to be committed against it. Consolidation may fill it." -f $name, $free, $need)
        } elseif ($need -gt ($free / 2)) {
            Write-Warning ("Datastore {0}: {1:N1} GB free, roughly {2:N1} GB to commit. Tight." -f $name, $free, $need)
        }
    }
}

function Remove-OldVMSnapshot {
    <#
    .SYNOPSIS
        Removes snapshots identified by Get-VMSnapshotReport.

    .DESCRIPTION
        This is the only command in the kit that destroys anything, and it is
        deliberately a separate step rather than a prompt at the end of a report. A
        confirmation appearing immediately after a list gets answered by muscle memory,
        and forty rows someone has skimmed become forty deletions. Reading and deleting
        are different decisions and belong in different commands.

        It takes report rows from the pipeline, so what is deleted is what you looked at:

            Get-VMSnapshotReport -OlderThanDays 30 | Remove-OldVMSnapshot -WhatIf

        ConfirmImpact is High, so it asks about each snapshot unless -Confirm:$false is
        passed. Begin with -WhatIf regardless.

        Snapshots are identified by SnapshotId, the vSphere managed object reference,
        never by name. Get-Snapshot treats -Name as a wildcard pattern, so a snapshot
        called 'Pre-Patch' also matches 'Pre-Patch-2', and a name containing a bracket
        or an asterisk matches something else entirely or nothing at all. Deleting the
        wrong snapshot cannot be undone, so name matching is not used. Rows lacking a
        SnapshotId fall back to an exact, case-sensitive name comparison and say so.

        Removal is ordered newest first, deepest leaf upward. Each deletion then commits
        the smallest delta available, which keeps the consolidation, the stun and the
        free space it needs as small as they can be.

        Three things worth understanding before running it without -WhatIf.

        Removal is the dangerous moment, not creation. Deleting a snapshot commits its
        delta into the previous disk state, which needs free space on the datastore and
        can run for a long time on a large or neglected snapshot. The VM is stunned while
        that finishes. Before any work begins the command totals the space to be
        committed and, where it can read the datastores, warns if it will not fit.

        Rows with Kind 'OrphanedDelta' are skipped. They describe a VM carrying delta
        disks with no snapshot attached; there is nothing here to remove and deletion is
        not the remedy. Use Repair-VMConsolidation for those.

        -RemoveChildren deletes an entire subtree in one operation. Any row in the batch
        that is a descendant of another row is dropped when it is used, because that
        snapshot will already have gone by the time its own turn arrives.

    .PARAMETER InputObject
        Snapshot rows from Get-VMSnapshotReport.

    .PARAMETER RemoveChildren
        Remove the snapshot's children as well. Off by default: the report lists children
        as their own rows, so the usual case is covered without it.

    .PARAMETER RunAsync
        Hand the work to vCenter and return immediately. Result rows then carry a TaskId
        and report only that the task was accepted, not that it succeeded.

    .PARAMETER SkipSpaceCheck
        Skip the per-datastore headroom check. The check costs a lookup per VM.

    .PARAMETER Server
        vCenter connection to use.

    .EXAMPLE
        Get-VMSnapshotReport -OlderThanDays 90 | Remove-OldVMSnapshot -WhatIf

        Shows what would be removed and touches nothing.

    .EXAMPLE
        Get-VMSnapshotReport -OlderThanDays 90 |
            Where-Object SizeGB -gt 50 |
            Remove-OldVMSnapshot

        Prompts for each of the large, old snapshots.

    .EXAMPLE
        $stale = Get-VMSnapshotReport -OlderThanDays 180 | Where-Object Kind -eq 'Snapshot'
        $stale | Remove-OldVMSnapshot -Confirm:$false -ErrorVariable failures

        Unattended. Inspect $failures afterwards; a snapshot that fails is reported and
        the run continues.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject] $InputObject,

        [switch] $RemoveChildren,
        [switch] $RunAsync,
        [switch] $SkipSpaceCheck,
        $Server
    )

    begin {
        Assert-VIConnection -Server $Server
        $viParameters = Get-ServerParameter -Server $Server
        $queued = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) { $queued.Add($InputObject) }
    }

    end {
        # Everything is collected before anything is deleted, so the totals and the
        # ordering below are computed against the whole batch, and so that a caller sees
        # the scale of what they have asked for before the first confirmation.
        $targets = @($queued | Where-Object {
            $_.PSObject.Properties['Snapshot'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Snapshot)
        })

        $skipped = $queued.Count - $targets.Count
        if ($skipped -gt 0) {
            Write-Warning "$skipped row(s) had no snapshot to remove and were skipped. Orphaned deltas need consolidation, not deletion - see Repair-VMConsolidation."
        }
        if ($targets.Count -eq 0) { return }

        # -RemoveChildren takes the whole subtree, so a row that descends from another
        # row in this batch will already be gone when its turn comes. Dropping it here
        # is the difference between a clean run and a run littered with errors about
        # snapshots this command itself removed a moment earlier.
        if ($RemoveChildren) {
            $inBatch = @{}
            foreach ($row in $targets) {
                if ($row.PSObject.Properties['SnapshotId'] -and $row.SnapshotId) { $inBatch[[string]$row.SnapshotId] = $row }
            }
            $parentOf = @{}
            foreach ($row in $targets) {
                if ($row.PSObject.Properties['SnapshotId'] -and $row.SnapshotId) {
                    $parentOf[[string]$row.SnapshotId] = $(if ($row.PSObject.Properties['ParentId']) { [string]$row.ParentId } else { $null })
                }
            }

            $kept = [System.Collections.Generic.List[object]]::new()
            foreach ($row in $targets) {
                $descends = $false
                if ($row.PSObject.Properties['SnapshotId'] -and $row.SnapshotId) {
                    $ancestor = $parentOf[[string]$row.SnapshotId]
                    $guard = 0
                    while ($ancestor -and $guard -lt 64) {
                        if ($inBatch.ContainsKey($ancestor)) { $descends = $true; break }
                        $ancestor = $parentOf[$ancestor]
                        $guard++
                    }
                }
                if ($descends) {
                    Write-Verbose "$($row.VM) / $($row.Snapshot) descends from another snapshot in this batch; -RemoveChildren will take it."
                } else {
                    $kept.Add($row)
                }
            }
            if ($kept.Count -lt $targets.Count) {
                Write-Warning ("{0} row(s) descend from another snapshot in this batch and will be removed by -RemoveChildren rather than individually." -f ($targets.Count - $kept.Count))
            }
            $targets = @($kept)
        }

        # Newest first, which for a chain means deepest leaf upward. Committing a leaf
        # merges the smallest delta that exists; committing a parent first merges
        # everything beneath it.
        $targets = @($targets | Sort-Object @{ Expression = { if ($null -eq $_.AgeDays) { [double]::MaxValue } else { [double]$_.AgeDays } } })

        $totalGb = 0
        foreach ($target in $targets) {
            if ($target.PSObject.Properties['SizeGB'] -and $null -ne $target.SizeGB) { $totalGb += $target.SizeGB }
        }
        if ($totalGb -gt 0) {
            Write-Warning ("About to commit roughly {0:N1} GB across {1} snapshot(s). Consolidation needs free space on the datastore, stuns the VM, and can run for some time." -f $totalGb, $targets.Count)
        }

        if (-not $SkipSpaceCheck) {
            try { Test-SnapshotHeadroom -Targets $targets -ViParameters $viParameters }
            catch { Write-Verbose "Headroom check did not run: $($_.Exception.Message)" }
        }

        foreach ($target in $targets) {
            $label  = "$($target.VM) / $($target.Snapshot)"
            $sizeGb = $null
            if ($target.PSObject.Properties['SizeGB']) { $sizeGb = $target.SizeGB }

            $snapshotId = $null
            if ($target.PSObject.Properties['SnapshotId']) { $snapshotId = [string]$target.SnapshotId }

            # $found rather than $matches: $Matches is an automatic variable.
            $found = @()
            try {
                if ($snapshotId) {
                    # -Id matches exactly. This is the whole reason the report carries it.
                    $found = @(Get-Snapshot @viParameters -Id $snapshotId -ErrorAction Stop)
                } else {
                    Write-Warning "$label has no SnapshotId; falling back to an exact name match. Re-run Get-VMSnapshotReport to get identifiers."
                    $vm = Resolve-ExactVM -Name $target.VM -ViParameters $viParameters
                    $found = @(Get-Snapshot @viParameters -VM $vm -ErrorAction Stop |
                                   Where-Object { $_.Name -ceq [string]$target.Snapshot })
                }
            } catch {
                Write-Error "Could not look up $label : $($_.Exception.Message)"
                continue
            }

            if ($found.Count -eq 0) {
                Write-Error "$label no longer exists. It may have been removed since the report was taken."
                continue
            }
            if ($found.Count -gt 1) {
                # With an Id this should be impossible; by name it is merely unlikely.
                # Either way, refusing is the only safe answer. There is no undo.
                Write-Error "$label matches $($found.Count) snapshots. Remove it by hand rather than have this guess."
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($label, 'Remove snapshot')) {
                # Under -WhatIf, say nothing: the What-if message is the output. A row is
                # only worth emitting when a person actively declined a prompt, which is
                # a fact about the run rather than a rehearsal of it.
                if ($WhatIfPreference) { continue }
                [PSCustomObject]@{
                    PSTypeName = 'VSphereReportKit.SnapshotRemoval'
                    VM         = $target.VM
                    Snapshot   = $target.Snapshot
                    SnapshotId = $snapshotId
                    SizeGB     = $sizeGb
                    Removed    = $false
                    Result     = 'Skipped'
                    TaskId     = $null
                    Message    = 'Not confirmed'
                }
                continue
            }

            try {
                # -Confirm:$false because ShouldProcess above has already asked. Without
                # it PowerCLI asks a second time about the same snapshot.
                $task = Remove-Snapshot -Snapshot $found[0] -RemoveChildren:$RemoveChildren `
                                        -RunAsync:$RunAsync -Confirm:$false -ErrorAction Stop

                $taskId = $null
                $result = 'Removed'
                if ($RunAsync) {
                    $result = 'Submitted'
                    # Keep the handle. Without it the caller has been told the work was
                    # accepted and given no way to find out whether it finished.
                    if ($null -ne $task -and $task.PSObject.Properties['Id']) { $taskId = [string]$task.Id }
                }

                [PSCustomObject]@{
                    PSTypeName = 'VSphereReportKit.SnapshotRemoval'
                    VM         = $target.VM
                    Snapshot   = $target.Snapshot
                    SnapshotId = $snapshotId
                    SizeGB     = $sizeGb
                    Removed    = $true
                    Result     = $result
                    TaskId     = $taskId
                    Message    = ''
                }
            } catch {
                Write-Error "Failed to remove $label : $($_.Exception.Message)"
                [PSCustomObject]@{
                    PSTypeName = 'VSphereReportKit.SnapshotRemoval'
                    VM         = $target.VM
                    Snapshot   = $target.Snapshot
                    SnapshotId = $snapshotId
                    SizeGB     = $sizeGb
                    Removed    = $false
                    Result     = 'Failed'
                    TaskId     = $null
                    Message    = $_.Exception.Message
                }
            }
        }
    }
}

function Repair-VMConsolidation {
    <#
    .SYNOPSIS
        Consolidates VMs carrying delta disks with no snapshot attached.

    .DESCRIPTION
        The remedy for the OrphanedDelta rows Get-VMSnapshotReport produces and
        Remove-OldVMSnapshot refuses. Those VMs have delta disks left behind with nothing
        in the snapshot tree pointing at them, so there is no snapshot to delete; the
        disks have to be consolidated back into the base.

        There is no PowerCLI cmdlet for this, so it calls ConsolidateVMDisks_Task on the
        underlying managed object.

        It is kept separate from Remove-OldVMSnapshot for the same reason removal is kept
        separate from reporting. Consolidation is a distinct operation with its own risks
        and deserves its own decision.

        It carries the same costs as any consolidation: it commits data, needs free space,
        stuns the VM, and can run for a long time.

    .PARAMETER InputObject
        OrphanedDelta rows from Get-VMSnapshotReport, or anything with a VM property.

    .PARAMETER Server
        vCenter connection to use.

    .EXAMPLE
        Get-VMSnapshotReport | Where-Object Kind -eq 'OrphanedDelta' | Repair-VMConsolidation -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject] $InputObject,

        $Server
    )

    begin {
        Assert-VIConnection -Server $Server
        $viParameters = Get-ServerParameter -Server $Server
        $seen = [System.Collections.Generic.HashSet[string]]::new()
    }

    process {
        if ($null -eq $InputObject) { return }

        $vmName = [string]$InputObject.VM
        if ([string]::IsNullOrWhiteSpace($vmName)) { return }

        # One consolidation per VM however many rows named it.
        if (-not $seen.Add($vmName)) { return }

        try {
            $vm = Resolve-ExactVM -Name $vmName -ViParameters $viParameters
        } catch {
            Write-Error "Could not resolve $vmName : $($_.Exception.Message)"
            return
        }

        if (-not $PSCmdlet.ShouldProcess($vmName, 'Consolidate disks')) {
            if ($WhatIfPreference) { return }
            [PSCustomObject]@{
                PSTypeName   = 'VSphereReportKit.Consolidation'
                VM           = $vmName
                Consolidated = $false
                Result       = 'Skipped'
                Message      = 'Not confirmed'
            }
            return
        }

        try {
            $null = $vm.ExtensionData.ConsolidateVMDisks_Task()
            [PSCustomObject]@{
                PSTypeName   = 'VSphereReportKit.Consolidation'
                VM           = $vmName
                Consolidated = $true
                Result       = 'Submitted'
                Message      = 'Consolidation task submitted; track it with Get-Task.'
            }
        } catch {
            Write-Error "Failed to consolidate $vmName : $($_.Exception.Message)"
            [PSCustomObject]@{
                PSTypeName   = 'VSphereReportKit.Consolidation'
                VM           = $vmName
                Consolidated = $false
                Result       = 'Failed'
                Message      = $_.Exception.Message
            }
        }
    }
}

#endregion

#region ------------------------------------------------------------ front end

# A literal, case-insensitive contains across every property. IndexOf rather than -like,
# because a person searching for a VM named with a bracket or an asterisk means those
# characters literally, and should not have to know that PowerShell disagrees.
function Select-ByFilter {
    [CmdletBinding()]
    param(
        [object[]] $Rows,
        [string] $Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) { return $Rows }
    $needle = $Filter.Trim()

    $Rows | Where-Object {
        $matched = $false
        foreach ($property in $_.PSObject.Properties) {
            if ($null -eq $property.Value) { continue }
            if (([string]$property.Value).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matched = $true
                break
            }
        }
        $matched
    }
}

# Read-Host fails in two different ways when nobody is there to answer it. Once stdin
# reaches EOF it returns empty strings indefinitely, and under -NonInteractive it throws.
# Both are the same fact - there is no input to be had - so both are normalised to $null,
# which lets a caller distinguish that from a person who simply pressed Enter.
function Read-Line {
    [CmdletBinding()]
    param([string] $Prompt)

    try   { return Read-Host $Prompt }
    catch { return $null }
}

function Read-WithDefault {
    [CmdletBinding()]
    param([string] $Prompt, [string] $Default)

    $answer = Read-Line ("  {0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Test-VIConnected {
    [CmdletBinding()]
    param()

    $existing = Get-Variable -Name DefaultVIServers -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $existing) { return $false }
    return @($existing.Value | Where-Object { $_.IsConnected }).Count -gt 0
}

# Returns $true only if this function opened the connection. The distinction matters on
# the way out: a session the caller established themselves is theirs, and closing it
# because we happened to borrow it would be a small act of vandalism.
function Connect-IfNeeded {
    [CmdletBinding()]
    param(
        [string] $Server,
        [System.Management.Automation.PSCredential] $Credential,
        [bool] $Interactive
    )

    if (Test-VIConnected) {
        Write-Verbose "Using the existing connection to $($global:DefaultVIServer.Name)"
        return $false
    }

    $target = $Server
    if (-not $target) {
        if (-not $Interactive) {
            throw 'Not connected to vCenter. Pass -Server, or run Connect-VIServer first.'
        }
        $target = Read-Line '  vCenter server'
        if ([string]::IsNullOrWhiteSpace($target)) { throw 'No server given.' }
    }

    $cred = $Credential
    if (-not $cred) { $cred = Get-Credential -Message "Credentials for $target" }
    if (-not $cred) { throw 'No credentials given.' }

    Import-PowerCLICore
    Write-Verbose "Connecting to $target"
    Connect-VIServer -Server $target -Credential $cred -ErrorAction Stop | Out-Null
    return $true
}

function Show-ReportMenu {
    [CmdletBinding()]
    param($Reports)

    $server = 'not connected'
    if (Test-VIConnected) { $server = $global:DefaultVIServer.Name }

    Write-Host ''
    Write-Host '  vSphere reports' -ForegroundColor Cyan -NoNewline
    Write-Host ("   ({0})" -f $server) -ForegroundColor DarkGray
    Write-Host ''

    $index = 0
    foreach ($key in $Reports.Keys) {
        $index++
        Write-Host ("   {0}  " -f $index) -ForegroundColor Yellow -NoNewline
        Write-Host ("{0,-24}" -f $Reports[$key].Label) -NoNewline
        Write-Host $Reports[$key].Blurb -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '   q  ' -ForegroundColor Yellow -NoNewline
    Write-Host 'quit'
    Write-Host ''
}

function Show-ReportResult {
    [CmdletBinding()]
    param(
        [object[]] $Rows,
        [string[]] $Columns
    )

    if (@($Rows).Count -eq 0) {
        Write-Host '  Nothing to report.' -ForegroundColor DarkGray
        return
    }

    # Only the listed columns, so a report remains readable in an eighty-column window.
    # Nothing is discarded; the objects still carry every property. What is shown and
    # what is kept are separate decisions, and conflating them is how tools start lying.
    $Rows | Format-Table -Property $Columns -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host ("  {0} row(s)." -f @($Rows).Count) -ForegroundColor DarkGray

    $path = Read-Line '  Export to CSV? (path, or blank to skip)'
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $Rows | Export-Csv -Path $path.Trim() -NoTypeInformation -Encoding UTF8
        Write-Host ("  Written to {0}" -f $path.Trim()) -ForegroundColor Green
    } catch {
        Write-Host ("  Export failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-VSphereReport {
    <#
    .SYNOPSIS
        Menu front end for the reports, or direct dispatch to one of them.

    .DESCRIPTION
        Run it bare and you get a menu. Pass -Report and it runs that one and gets out
        of the way.

        The two modes behave differently on purpose:

          Menu     - formats results into a table for reading, offers a CSV export,
                     then goes back to the menu.
          -Report  - writes plain objects to the pipeline. Nothing is formatted, so it
                     composes and it schedules.

        If you're already connected to vCenter it uses that session and leaves it alone
        on the way out. If it has to connect itself, it disconnects itself.

    .PARAMETER Report
        Inventory, Tools, Removals, Snapshots or Compliance. Leave it off for the menu.

    .PARAMETER Filter
        Keep only rows where some property contains this text. Menu mode prompts for it.

    .PARAMETER Server
        vCenter to connect to. Ignored if you're already connected.

    .PARAMETER Credential
        Credentials for that connection. Prompts if needed.

    .PARAMETER Days
        Look-back for Removals. Default 14.

    .PARAMETER OlderThanDays
        Age threshold for Snapshots. Default 7.

    .PARAMETER ToolsState
        NotInstalled, Outdated or Any for the Tools report. Default Any.

    .PARAMETER ComplianceMode
        Auto, Image or Baseline. Default Auto.

    .PARAMETER IncludeTemplate
        Include VM templates in the inventory-based reports.

    .PARAMETER IncludeUnmanaged
        Count open-vm-tools (guestToolsUnmanaged) as outdated.

    .EXAMPLE
        Invoke-VSphereReport

        The menu.

    .EXAMPLE
        Invoke-VSphereReport -Report Snapshots -OlderThanDays 30 |
            Export-Csv snaps.csv -NoTypeInformation

    .EXAMPLE
        Invoke-VSphereReport -Report Inventory -Filter vmx-17
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Inventory', 'Tools', 'Removals', 'Snapshots', 'Compliance')]
        [string] $Report,

        [string] $Filter,
        [string] $Server,
        [System.Management.Automation.PSCredential] $Credential,

        [ValidateRange(1, 3650)]
        [int] $Days = 14,

        [ValidateRange(0, 3650)]
        [int] $OlderThanDays = 7,

        [ValidateSet('NotInstalled', 'Outdated', 'Any')]
        [string] $ToolsState = 'Any',

        [ValidateSet('Auto', 'Image', 'Baseline')]
        [string] $ComplianceMode = 'Auto',

        [switch] $IncludeTemplate,
        [switch] $IncludeUnmanaged
    )

    $interactive = -not $PSBoundParameters.ContainsKey('Report')

    # Built per call rather than once at module load. The Arguments and Prompt blocks
    # read this function's parameters, and a scriptblock in PowerShell is not a closure:
    # it resolves variables when it runs, against the scope it was created in. Defined at
    # module scope, that table would find nothing to resolve them against.
    $reports = [ordered]@{
        Inventory = @{
            Label     = 'VM inventory'
            Blurb     = 'OS, hardware version, domain, Tools state'
            Columns   = @('Name', 'OS', 'HardwareVersion', 'Domain', 'PowerState', 'ToolsStatus')
            Arguments = { @{ IncludeTemplate = [bool]$IncludeTemplate } }
            Prompt    = { @{ IncludeTemplate = (Read-WithDefault 'Include templates? (y/n)' 'n') -eq 'y' } }
            Run       = { param($a) Get-VMInventoryReport @a }
        }

        Tools = @{
            Label     = 'VMware Tools'
            Blurb     = 'missing or out of date'
            Columns   = @('Name', 'OS', 'PowerState', 'ToolsStatus', 'ToolsVersion', 'Action')
            Arguments = { @{ State = $ToolsState; IncludeUnmanaged = [bool]$IncludeUnmanaged; IncludeTemplate = [bool]$IncludeTemplate } }
            Prompt    = {
                $state = Read-WithDefault 'State (NotInstalled / Outdated / Any)' 'Any'
                if (@('NotInstalled', 'Outdated', 'Any') -notcontains $state) { $state = 'Any' }
                @{
                    State            = $state
                    IncludeUnmanaged = (Read-WithDefault 'Count open-vm-tools as outdated? (y/n)' 'n') -eq 'y'
                    IncludeTemplate  = $false
                }
            }
            Run       = { param($a) Get-VMToolsReport @a }
        }

        Removals = @{
            Label     = 'Recent removals'
            Blurb     = 'VMs removed from inventory or destroyed'
            Columns   = @('Time', 'EventType', 'User', 'VM', 'VMHost')
            Arguments = { @{ Days = $Days } }
            Prompt    = { @{ Days = [int](Read-WithDefault 'Look back how many days?' '14') } }
            Run       = { param($a) Get-VMRemovalEvent @a }
        }

        Snapshots = @{
            Label     = 'Old snapshots'
            Blurb     = 'age, size, and VMs needing consolidation'
            Columns   = @('VM', 'Snapshot', 'AgeDays', 'SizeGB', 'State', 'Consolidate')
            Arguments = { @{ OlderThanDays = $OlderThanDays; IncludeTemplate = [bool]$IncludeTemplate } }
            Prompt    = {
                @{
                    OlderThanDays   = [int](Read-WithDefault 'Older than how many days? (0 = all)' '7')
                    IncludeTemplate = $false
                }
            }
            Run       = { param($a) Get-VMSnapshotReport @a }
        }

        Compliance = @{
            Label     = 'Host patch compliance'
            Blurb     = 'vLCM images and VUM baselines'
            Columns   = @('Source', 'Entity', 'Target', 'Status')
            Arguments = { @{ Mode = $ComplianceMode } }
            Prompt    = {
                $mode = Read-WithDefault 'Mode (Auto / Image / Baseline)' 'Auto'
                if (@('Auto', 'Image', 'Baseline') -notcontains $mode) { $mode = 'Auto' }
                @{ Mode = $mode }
            }
            Run       = { param($a) Get-VMHostComplianceReport @a }
        }
    }

    $weConnected = Connect-IfNeeded -Server $Server -Credential $Credential -Interactive $interactive

    try {
        if (-not $interactive) {
            # Objects straight to the pipeline. No banner, no table, nothing a caller
            # would then have to parse back out. This mode exists to be composed with.
            $definition = $reports[$Report]
            $arguments  = & $definition.Arguments
            Select-ByFilter -Rows @(& $definition.Run $arguments) -Filter $Filter
            return
        }

        $keys = @($reports.Keys)
        while ($true) {
            Show-ReportMenu -Reports $reports
            $choice = Read-Line ("  Choose [1-{0}, q]" -f $keys.Count)

            # $null means Read-Host threw, which is to say the host was started
            # -NonInteractive. Empty together with redirected stdin means piped input has
            # run out. Without both checks this loop redraws the menu forever, consuming
            # a core and producing nothing. A person at a terminal is never redirected,
            # so pressing Enter by mistake still does the harmless thing.
            if ($null -eq $choice) {
                Write-Host '  No interactive input available.' -ForegroundColor DarkGray
                break
            }
            if ([string]::IsNullOrWhiteSpace($choice)) {
                if ([Console]::IsInputRedirected) {
                    Write-Host '  No more input.' -ForegroundColor DarkGray
                    break
                }
                continue
            }
            $choice = $choice.Trim()

            if (@('q', 'Q', 'quit', 'exit') -contains $choice) { break }

            $number = 0
            if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $keys.Count) {
                Write-Host '  Not one of the options.' -ForegroundColor Red
                continue
            }

            $definition = $reports[$keys[$number - 1]]

            Write-Host ''
            Write-Host ("  {0}" -f $definition.Label) -ForegroundColor Cyan
            Write-Host ('  ' + ('-' * $definition.Label.Length)) -ForegroundColor DarkGray

            $arguments = & $definition.Prompt
            $rowFilter = Read-Line '  Filter (blank for all)'

            try {
                $rows = @(Select-ByFilter -Rows @(& $definition.Run $arguments) -Filter $rowFilter)
                Show-ReportResult -Rows $rows -Columns $definition.Columns
            } catch {
                Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
        }
        Write-Host ''
    } finally {
        if ($weConnected) {
            try { Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-VMInventoryReport'
    'Get-VMToolsReport'
    'Get-VMRemovalEvent'
    'Get-VMSnapshotReport'
    'Get-VMHostComplianceReport'
    'Remove-OldVMSnapshot'
    'Repair-VMConsolidation'
    'Invoke-VSphereReport'
)
