#
# Module manifest for module 'Microsoft.Windows.Bcd.Cmdlets'
#

# .ExternalHelp Microsoft.Windows.Bcd.Cmdlets.dll-Help.xml

@{

# Version number of this module.
ModuleVersion = '1.0.0'

# ID used to uniquely identify this module
GUID = 'a036f7aa-a3f6-435e-bc8e-924afd181240'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '(c) 2020 Microsoft. All rights reserved.'

# Format files (.ps1xml) to be loaded when importing this module
FormatsToProcess = @("Microsoft.Windows.Bcd.Cmdlets.Format.ps1xml")

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
NestedModules = @("Microsoft.Windows.Bcd.Cmdlets.dll")

# Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
CmdletsToExport = @(
    "Copy-BcdEntry",
    "Disable-BcdElementBootDebug",
    "Disable-BcdElementBootEms",
    "Disable-BcdElementDebug",
    "Disable-BcdElementEms",
    "Disable-BcdElementEventLogging",
    "Disable-BcdElementHypervisorDebug",
    "Enable-BcdElementBootDebug",
    "Enable-BcdElementBootEms",
    "Enable-BcdElementDebug",
    "Enable-BcdElementEms",
    "Enable-BcdElementEventLogging",
    "Enable-BcdElementHypervisorDebug",
    "Export-BcdStore",
    "Get-BcdEntry",
    "Get-BcdEntryDebugSettings",
    "Get-BcdEntryHypervisorSettings",
    "Get-BcdStore",
    "Import-BcdStore",
    "New-BcdEntry",
    "New-BcdStore",
    "Remove-BcdElement",
    "Remove-BcdEntry",
    "Set-BcdBootDefault",
    "Set-BcdBootDisplayOrder",
    "Set-BcdBootSequence",
    "Set-BcdBootTimeout",
    "Set-BcdBootToolsDisplayOrder",
    "Set-BcdDebugSettings",
    "Set-BcdElement",
    "Set-BcdHypervisorSettings"
)

# List of all files packaged with this module
FileList = "Microsoft.Windows.Bcd.Cmdlets.dll-Help.xml"

CompatiblePSEditions = 'Core', 'Desktop'

# HelpInfo URI of this module
HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
}
