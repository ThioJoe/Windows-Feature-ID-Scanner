@{  
    GUID = "{B9AF2675-4726-42FD-ADAB-38228176A516}"  
    Author = "Microsoft Corporation"  
    CLRVersion = "4.0"  
    CompanyName = "Microsoft Corporation"  
    Copyright = "(c) Microsoft Corporation. All rights reserved."  
    AliasesToExport = @()  
    FunctionsToExport = "Delete-DeliveryOptimizationCache",
                        "Disable-DeliveryOptimizationVerboseLogs",
                        "Enable-DeliveryOptimizationVerboseLogs",
                        "Get-DeliveryOptimizationStatus",
                        "Get-DeliveryOptimizationPerfSnap",
                        "Get-DeliveryOptimizationPerfSnapThisMonth",
                        "Get-DOConfig",
                        "Get-DODownloadMode",
                        "Get-DOPercentageMaxForegroundBandwidth",
                        "Get-DOPercentageMaxBackgroundBandwidth",
                        "Set-DeliveryOptimizationStatus",
                        "Set-DODownloadMode",
                        "Set-DOMaxBackgroundBandwidth",
                        "Set-DOMaxForegroundBandwidth",
                        "Set-DOPercentageMaxForegroundBandwidth", 
                        "Set-DOPercentageMaxBackgroundBandwidth"
    CmdletsToExport = "Get-DeliveryOptimizationLog",
                      "Get-DeliveryOptimizationLogAnalysis"
    PowerShellVersion = '5.1'
    ModuleVersion = "1.0.3.0"
    NestedModules = @('Microsoft.Windows.DeliveryOptimization.AdminCommands', 'DeliveryOptimizationVerboseLogs.psm1', 'DeliveryOptimizationSettings.psm1', 'DeliveryOptimizationStatus.psm1')
    
    # Location from which to download updateable help
    HelpInfoURI = "https://aka.ms/winsvr-2025-pshelp"

    CompatiblePSEditions = @('Core','Desktop')
}
