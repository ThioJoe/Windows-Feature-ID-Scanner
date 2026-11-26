@{

# Root module
RootModule = 'LAPS.psm1'

# Version number of this module.
ModuleVersion = '1.0.0.0'

# ID used to uniquely identify this module
GUID = '8eb7ddf9-7890-49ae-9af1-3b41d7e63c41'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft'

# Copyright statement for this module
Copyright = '© Microsoft Corporation. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Provides cmdlets for configuration and usage of Windows LAPS (Local Administrator Password Solution)'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '5.1'

# Name of the Windows PowerShell host required by this module
PowerShellHostName = ''

# Minimum version of the Windows PowerShell host required by this module
PowerShellHostVersion = ''

# Minimum version of the .NET Framework required by this module
DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module
CLRVersion = ''

# Processor architecture (None, X86, Amd64, IA64) required by this module
ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
RequiredModules = @()

# Assemblies that must be loaded prior to importing this module
RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module
ScriptsToProcess = @()

# Type files (.ps1xml) to be loaded when importing this module
TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
FormatsToProcess = @()

# Modules to import as nested modules of the module specified in ModuleToProcess
NestedModules = @('lapspsh.dll')

# Functions to export from this module
FunctionsToExport = @(
    'Get-LapsAADPassword',
    'Get-LapsDiagnostics')

# Cmdlets to export from this module
CmdletsToExport = @(
    'Find-LapsADExtendedRights',
    'Get-LapsADPassword',
    'Invoke-LapsPolicyProcessing',
    'Reset-LapsPassword',
    'Set-LapsADAuditing',
    'Set-LapsADComputerSelfPermission',
    'Set-LapsADPasswordExpirationTime',
    'Set-LapsADReadPasswordPermission',
    'Set-LapsADResetPasswordPermission',
    'Update-LapsADSchema')

# Variables to export from this module
VariablesToExport = ''

# Aliases to export from this module
AliasesToExport = ''

# List of all modules packaged with this module
ModuleList = @()

# List of all files packaged with this module
FileList = @()

# Private data to pass to the module specified in ModuleToProcess
PrivateData = ''

# PS Editions
CompatiblePSEditions = @('Desktop','Core')

# Help link
HelpInfoUri= "https://aka.ms/winsvr-2025-pshelp"

}

