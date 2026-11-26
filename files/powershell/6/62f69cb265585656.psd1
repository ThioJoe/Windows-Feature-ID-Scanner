
@{
    ModuleVersion = '1.0.0.0'
    NestedModules = @("MSFT_DASiteTableEntry.cdxml", "MSFT_DAClientExperienceConfiguration.cdxml")
    FormatsToProcess = @("MSFT_DASiteTableEntry.format.ps1xml", "MSFT_DAClientExperienceConfiguration.format.ps1xml")
    TypesToProcess = @("MSFT_DASiteTableEntry.types.ps1xml", "MSFT_DAClientExperienceConfiguration.types.ps1xml")
    HelpInfoUri = "https://aka.ms/winsvr-2025-pshelp"
    GUID = '{244F8FC0-A410-4b87-8237-7496F557E6D4}'
    Author = 'Microsoft Corporation'
    CompanyName = 'Microsoft Corporation'
    PowerShellVersion = '5.1'
    Copyright = '© Microsoft Corporation. All rights reserved.'
    FunctionsToExport = @("Disable-DAManualEntryPointSelection", "Enable-DAManualEntryPointSelection", "Get-DAClientExperienceConfiguration", "Get-DAEntryPointTableItem", "New-DAEntryPointTableItem", "Remove-DAEntryPointTableItem", "Rename-DAEntryPointTableItem", "Reset-DAClientExperienceConfiguration", "Reset-DAEntryPointTableItem", "Set-DAClientExperienceConfiguration", "Set-DAEntryPointTableItem")
    AliasesToExport = @()
    CmdletsToExport = @()
    CompatiblePSEditions = @('Desktop', 'Core')
}
