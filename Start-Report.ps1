#Requires -Version 5.1
# Copy the folder anywhere and run this. Imports the module sitting next to it, so
# nothing has to be installed or added to PSModulePath.
Import-Module (Join-Path $PSScriptRoot 'VSphereReportKit') -Force
Invoke-VSphereReport @args
