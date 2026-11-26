$script:modulePath = Split-Path -Parent $PSCommandPath
Import-LocalizedData -BindingVariable LocalizedData -BaseDirectory $modulePath -FileName "LicenseInfoData"

function Get-LocalizedString {
    param([string]$Key)
    return $LocalizedData[$Key]
}

function Get-SubscriptionTypeString {
    param([int]$Type)
    
    switch ($Type) {
        0 { return Get-LocalizedString 'SubscriptionTypeUBS' }
        9999 { return Get-LocalizedString 'SubscriptionTypeInvalid' }
        120 { return Get-LocalizedString 'SubscriptionTypeNotInstalled' }
        default { return (Get-LocalizedString 'SubscriptionTypeUnknown') + " ($Type)" }
    }
}

function Get-SubscriptionStatusString {
    param([int]$Status)
    
    switch ($Status) {
        0 { return Get-LocalizedString 'SubscriptionStatusNotActive' }
        1 { return Get-LocalizedString 'SubscriptionStatusActive' }
        100 { return Get-LocalizedString 'SubscriptionStatusDisabled' }
        110 { return Get-LocalizedString 'SubscriptionStatusExpired' }
        120 { return Get-LocalizedString 'SubscriptionStatusNotInstalled' }
        default { return (Get-LocalizedString 'SubscriptionStatusUnknown') + " ($Status)" }
    }
}

# Maps subscription type value to tool configuration.
# Each entry defines the executable and its command strings for each operation.
# To support a new subscription type, add an entry with its ToolPath and Commands.
$script:SubscriptionToolMap = @{
    0 = @{
        ToolPath = Join-Path $env:SystemRoot "System32\ClipRenew.exe"
        Commands = @{
            Enable  = 'enablesubscription'
            Disable = 'disablesubscription'
            Remove  = 'removesubscription'
            Refresh = 'refreshsubscription'
            Acquire = $null
        }
    }
}

function Get-SubscriptionToolConfig {
    $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
    [int]$type = $licenseService.SubscriptionType
    
    if ($script:SubscriptionToolMap.ContainsKey($type)) {
        return $script:SubscriptionToolMap[$type]
    }
    
    throw ((Get-LocalizedString 'SubscriptionTypeUnsupported') -f $type)
}

function Invoke-SubscriptionTool {
    param(
        [string]$Command,
        [string]$ToolPath
    )
    
    if (-not (Test-Path $ToolPath)) {
        throw ((Get-LocalizedString 'SubscriptionToolNotFound') -f $ToolPath)
    }
    
    $arguments = @()
    if ($Command) {
        $arguments += $Command
    }
    $arguments += 'noshow'
    
    & $ToolPath @arguments | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw ((Get-LocalizedString 'SubscriptionToolFailed') -f $ToolPath, $LASTEXITCODE)
    }
}

<#
.SYNOPSIS
    Gets subscription license info.
    
.DESCRIPTION
    Retrieves Windows subscription licensing information including subscription
    type, status, expiration date, and edition from WMI.
    
.EXAMPLE
    Get-SubscriptionLicenseInfo
#>
function Get-SubscriptionLicenseInfo {
    [CmdletBinding()]
    param ()
    
    Write-Verbose (Get-LocalizedString 'SubscriptionLicenseInfoVerbose')
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            Write-Verbose (Get-LocalizedString 'NoLicenseFound')
            return $null
        }
        
        $result = [PSCustomObject]@{
            SubscriptionType = Get-SubscriptionTypeString -Type $licenseService.SubscriptionType
            SubscriptionTypeValue = $licenseService.SubscriptionType
            SubscriptionStatus = Get-SubscriptionStatusString -Status $licenseService.SubscriptionStatus
            SubscriptionStatusValue = $licenseService.SubscriptionStatus
            SubscriptionExpiry = $licenseService.SubscriptionExpiry
            SubscriptionEdition = $licenseService.SubscriptionEdition
        }
        
        return $result
    }
    catch {
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
        return $null
    }
}

<#
.SYNOPSIS
    Sets subscription license configuration.
    
.DESCRIPTION
    Enables or disables Windows subscription licensing.
    
.PARAMETER Enabled
    Enable or disable subscription licensing.
    
.EXAMPLE
    Set-SubscriptionLicenseInfo -Enabled $true
    Enables subscription licensing.
    
.EXAMPLE
    Set-SubscriptionLicenseInfo -Enabled $false
    Disables subscription licensing.
#>
function Set-SubscriptionLicenseInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [bool]$Enabled
    )
    
    Write-Verbose (Get-LocalizedString 'SubscriptionLicenseInfoVerbose')
    
    try {
        $config = Get-SubscriptionToolConfig
        
        if ($Enabled) {
            Invoke-SubscriptionTool -ToolPath $config.ToolPath -Command $config.Commands.Enable
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'EnableSubscription'
            }
        }
        else {
            Invoke-SubscriptionTool -ToolPath $config.ToolPath -Command $config.Commands.Disable
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'DisableSubscription'
            }
        }
    }
    catch {
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
        return $null
    }
}

<#
.SYNOPSIS
    Performs subscription license operations.
    
.DESCRIPTION
    Executes subscription licensing operations including
    removing subscription licenses, refreshing subscription status, and
    acquiring new subscription licenses.
    
.PARAMETER Remove
    Remove or uninstall the subscription license.
    
.PARAMETER Refresh
    Schedule a subscription license refresh.
    
.PARAMETER Acquire
    Acquire a new subscription license.
    
.EXAMPLE
    Invoke-SubscriptionLicense -Remove
    
.EXAMPLE
    Invoke-SubscriptionLicense -Refresh
    
.EXAMPLE
    Invoke-SubscriptionLicense -Acquire
#>
function Invoke-SubscriptionLicense {
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName='Remove')]
        [switch]$Remove,
        
        [Parameter(ParameterSetName='Refresh')]
        [switch]$Refresh,
        
        [Parameter(ParameterSetName='Acquire')]
        [switch]$Acquire
    )
    
    try {
        $config = Get-SubscriptionToolConfig
        
        if ($Remove) {
            Invoke-SubscriptionTool -ToolPath $config.ToolPath -Command $config.Commands.Remove
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'RemoveSubscription'
            }
        }
        
        if ($Refresh) {
            Invoke-SubscriptionTool -ToolPath $config.ToolPath -Command $config.Commands.Refresh
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'RefreshSubscription'
            }
        }
        
        if ($Acquire) {
            Invoke-SubscriptionTool -ToolPath $config.ToolPath -Command $config.Commands.Acquire
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'AcquireSubscription'
            }
        }
        
        return $null
    }
    catch {
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
        return $null
    }
}

Export-ModuleMember -Function Get-SubscriptionLicenseInfo, Set-SubscriptionLicenseInfo, Invoke-SubscriptionLicense
