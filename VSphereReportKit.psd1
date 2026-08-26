@{
    RootModule        = 'VSphereReportKit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd4f8a61c-3b27-4e95-9c0a-7e1f6b2d84a3'

    Author            = 'Ian Garner Morley'
    Description       = 'vCenter reporting: VM inventory, VMware Tools status, removal events, snapshot age and size, and ESXi patch compliance. The Get-* commands emit objects with no formatting; Invoke-VSphereReport adds a terminal menu over them. Remove-OldVMSnapshot is the one command that writes, and supports -WhatIf and -Confirm.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FormatsToProcess  = @('VSphereReportKit.format.ps1xml')

    # PowerCLI is deliberately NOT in RequiredModules. Declaring it there forces a full
    # PowerCLI import on every Import-Module, and makes this module unimportable - and
    # so untestable - on any machine without it. The functions check at runtime instead.
    # ExternalModuleDependencies records the dependency without enforcing it.
    FunctionsToExport = @(
        'Get-VMInventoryReport'
        'Get-VMToolsReport'
        'Get-VMRemovalEvent'
        'Get-VMSnapshotReport'
        'Get-VMHostComplianceReport'
        'Remove-OldVMSnapshot'
        'Repair-VMConsolidation'
        'Invoke-VSphereReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags                     = @('VMware', 'vCenter', 'PowerCLI', 'Reporting', 'vSphere')
            ExternalModuleDependencies = @('VCF.PowerCLI')
            ReleaseNotes             = 'Extracted from the WinForms dashboard. Terminal front end folded in as Invoke-VSphereReport.'
        }
    }
}
