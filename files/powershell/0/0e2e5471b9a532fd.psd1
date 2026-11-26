@{
    GUID="{d6fdb0d8-2b0f-406b-afc6-68f60569ebdf}"
    Author="Microsoft Corporation"
    CompanyName="Microsoft Corporation"
    Copyright="© Microsoft Corporation. All rights reserved."
    ModuleVersion="1.0.0.0"
    PowerShellVersion = '5.1'
    CLRVersion="4.0"
    FormatsToProcess="TroubleshootingPack.Format.ps1xml"
    NestedModules="Microsoft.Windows.Diagnosis.TroubleshootingPack"
    HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
    CmdletsToExport = "Get-TroubleshootingPack","Invoke-TroubleshootingPack"
    CompatiblePSEditions = @("Desktop", "Core")
}
