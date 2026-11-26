@{
    GUID              = '78a7a38c-a446-43fe-b643-9abacf843112'
    Author            = 'Microsoft Corporation'
    CompanyName       = 'Microsoft Corporation'
    Copyright         = '(C) Microsoft Corporation. All rights reserved.'
    NestedModules     = @('MSFT_OdbcDriverTask_v1.0.cdxml',
                          'MSFT_OdbcDsnTask_v1.0.cdxml',
                          'MSFT_OdbcPerfCounterTask_v1.0.cdxml', 
                          'MSFT_WdacBidTraceTask_v1.0.cdxml')
    FormatsToProcess  = @('Wdac.format.ps1xml')
    TypesToProcess    = @('Wdac.types.ps1xml')
    ModuleVersion     = '1.0.0.0'
    AliasesToExport   = @()

    FunctionsToExport = @('Get-OdbcDriver', 
                          'Set-OdbcDriver', 
                          'Get-OdbcDsn', 
                          'Add-OdbcDsn', 
                          'Set-OdbcDsn', 
                          'Remove-OdbcDsn', 
                          'Get-OdbcPerfCounter', 
                          'Enable-OdbcPerfCounter', 
                          'Disable-OdbcPerfCounter', 
                          'Get-WdacBidTrace', 
                          'Enable-WdacBidTrace', 
                          'Disable-WdacBidTrace')

    PowerShellVersion = '5.1'
    HelpInfoUri       = 'https://aka.ms/winsvr-2025-pshelp'
    CompatiblePSEditions = @('Desktop', 'Core')
}
