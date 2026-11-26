$g_traceRegRoot = "HKU:\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Trace"

function VerifyIsAdmin()
{
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))
    {
        throw "The command must run with Administrator privileges"
    }
}

function AttemptRestartIfNeeded([bool] $Force)
{
    $shouldRestart = $false
    $svc = Get-Service dosvc
    if ($svc.Status -eq "Running")
    {
        # We run as admin so we know we can restart the service
        if ($Force)
        {
            $shouldRestart = $true
        }
        else
        {
            $input = Read-Host "Do you want to restart Delivery Optimization? (this will interrupt active downloads) [y/n]"
            switch ($input)
            {
                {$_.ToLower() -eq "n"} { Write-Host "Changes will take effect the next time the Delivery Optimization service starts."; return }
                {$_.ToLower() -eq "y"} { $shouldRestart = $true; break }
            }
        }
    }

    if ($shouldRestart)
    {
        Stop-Service dosvc
        Start-Service dosvc
    }
    Write-Host "Changes successfully applied."
}

function Enable-DeliveryOptimizationVerboseLogs
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param (
        [Switch]
        $Force = $false
    )
    VerifyIsAdmin
    New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null

    if (!$(Test-Path $g_traceRegRoot))
    {
        New-Item $g_traceRegRoot | Out-Null
    }
    
    $traceFileSize = 150 * 1000
    $traceFolderSize = 200 * 1000
    Write-Host "Setting Delivery Optimization tracing to Verbose and increasing the log limits..."
    New-ItemProperty -Path $g_traceRegRoot -Name "TraceLevel_Override" -PropertyType Dword -Value 5 -Force | out-null
    New-ItemProperty -Path $g_traceRegRoot -Name "TraceFileSizeKBytes" -PropertyType Dword -Value $traceFileSize -Force | out-null
    New-ItemProperty -Path $g_traceRegRoot -Name "TraceFolderSizeKBytes" -PropertyType Dword -Value $traceFolderSize -Force | out-null
    AttemptRestartIfNeeded $Force
}

function Disable-DeliveryOptimizationVerboseLogs
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param (
        [Switch]
        $Force = $false
    )

    VerifyIsAdmin
    New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null

    if (!$(Test-Path $g_traceRegRoot))
    {
        Write-Host "Verbose logging is already disabled, exiting."
        return
    }
    Write-Host "Disabling Delivery Optimization verbose logging..."
    Remove-ItemProperty -Path $g_traceRegRoot -Name "TraceLevel_Override" -Force | out-null
    Remove-ItemProperty -Path $g_traceRegRoot -Name "TraceFileSizeKBytes" -Force | out-null
    Remove-ItemProperty -Path $g_traceRegRoot -Name "TraceFolderSizeKBytes" -Force | out-null

    AttemptRestartIfNeeded $Force
}
