$script:modulePath = Split-Path -Parent $PSCommandPath
$script:WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
Import-LocalizedData -BindingVariable LocalizedData -BaseDirectory $modulePath -FileName "LicenseInfoData"

function Get-LocalizedString {
    param([string]$Key)
    return $LocalizedData[$Key]
}

function Format-ContextualValue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PropertyName,
        
        [Parameter(Mandatory=$false)]
        $Value
    )
    
    if ($Value -eq 4294967295) {
        switch -Wildcard ($PropertyName) {
            'KeyManagementService*Count' { return 'N/A' }
            'KeyManagementService*Requests' { return 'N/A' }
            default { return 'Not Set' }
        }
    }
    
    return $Value
}

<#
.SYNOPSIS
    Gets KMS license info
    
.DESCRIPTION
    Retrieves KMS licensing configuration including server, port, domain,
    activation intervals, and request counts.
    
.EXAMPLE
    Get-KmsLicenseInfo
#>
function Get-KmsLicenseInfo {
    [CmdletBinding()]
    param ()
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        $osProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
                     Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon } |
                     Select-Object -First 1
        
        if (-not $licenseService) {
            return $null
        }
        
        $result = [PSCustomObject]@{
            KeyManagementServiceMachine = $licenseService.KeyManagementServiceMachine
            KeyManagementServicePort = $licenseService.KeyManagementServicePort
            KeyManagementServiceLookupDomain = $licenseService.KeyManagementServiceLookupDomain
            IsKeyManagementServiceMachine = $licenseService.IsKeyManagementServiceMachine
            KeyManagementServiceListeningPort = $licenseService.KeyManagementServiceListeningPort
            KeyManagementServiceDnsPublishing = $licenseService.KeyManagementServiceDnsPublishing
            KeyManagementServiceHostCaching = $licenseService.KeyManagementServiceHostCaching
            KeyManagementServiceLowPriority = $licenseService.KeyManagementServiceLowPriority
            KeyManagementServiceCurrentCount = Format-ContextualValue -PropertyName 'KeyManagementServiceCurrentCount' -Value $licenseService.KeyManagementServiceCurrentCount
            KeyManagementServiceUnlicensedRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceUnlicensedRequests' -Value $licenseService.KeyManagementServiceUnlicensedRequests
            KeyManagementServiceLicensedRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceLicensedRequests' -Value $licenseService.KeyManagementServiceLicensedRequests
            KeyManagementServiceOOBGraceRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceOOBGraceRequests' -Value $licenseService.KeyManagementServiceOOBGraceRequests
            KeyManagementServiceOOTGraceRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceOOTGraceRequests' -Value $licenseService.KeyManagementServiceOOTGraceRequests
            KeyManagementServiceNonGenuineGraceRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceNonGenuineGraceRequests' -Value $licenseService.KeyManagementServiceNonGenuineGraceRequests
            KeyManagementServiceTotalRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceTotalRequests' -Value $licenseService.KeyManagementServiceTotalRequests
            KeyManagementServiceNotificationRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceNotificationRequests' -Value $licenseService.KeyManagementServiceNotificationRequests
            KeyManagementServiceFailedRequests = Format-ContextualValue -PropertyName 'KeyManagementServiceFailedRequests' -Value $licenseService.KeyManagementServiceFailedRequests
        }
        
        if ($osProduct) {
            $result | Add-Member -NotePropertyName VLActivationInterval -NotePropertyValue $osProduct.VLActivationInterval
            $result | Add-Member -NotePropertyName VLRenewalInterval -NotePropertyValue $osProduct.VLRenewalInterval
            $result | Add-Member -NotePropertyName DiscoveredKeyManagementServiceMachineName -NotePropertyValue $osProduct.DiscoveredKeyManagementServiceMachineName
            $result | Add-Member -NotePropertyName DiscoveredKeyManagementServiceMachinePort -NotePropertyValue $osProduct.DiscoveredKeyManagementServiceMachinePort
        }
        
        return $result
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Set KMS license configuration
    
.DESCRIPTION
    Configures KMS settings including server, port, domain, activation intervals,
    DNS publishing, host caching, and priority.
    
.PARAMETER ServerName
    KMS server machine name
    
.PARAMETER Port
    KMS client port number
    
.PARAMETER Domain
    KMS lookup domain
    
.PARAMETER ActivationInterval
    Activation interval in minutes
    
.PARAMETER RenewalInterval
    Renewal interval in minutes
    
.PARAMETER ListeningPort
    KMS server listening port number
    
.PARAMETER Priority
    KMS priority (Normal or Low)
    
.PARAMETER DnsPublishing
    Enable or disable DNS publishing
    
.PARAMETER HostCaching
    Enable or disable host caching
    
.EXAMPLE
    Set-KmsLicenseInfo -ServerName "kms.contoso.com"
    
.EXAMPLE
    Set-KmsLicenseInfo -ServerName "kms.contoso.com" -Port 1688
    
.EXAMPLE
    Set-KmsLicenseInfo -ActivationInterval 120 -RenewalInterval 10080
#>
function Set-KmsLicenseInfo {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$ServerName,
        
        [Parameter()]
        [int]$Port,
        
        [Parameter()]
        [string]$Domain,
        
        [Parameter()]
        [int]$ActivationInterval,
        
        [Parameter()]
        [int]$RenewalInterval,
        
        [Parameter()]
        [int]$ListeningPort,
        
        [Parameter()]
        [ValidateSet('Normal', 'Low')]
        [string]$Priority,
        
        [Parameter()]
        [bool]$DnsPublishing,
        
        [Parameter()]
        [bool]$HostCaching
    )
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            return $null
        }
        
        if ($PSBoundParameters.ContainsKey('ServerName')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetKeyManagementServiceMachine -Arguments @{
                MachineName = $ServerName
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('Port')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetKeyManagementServicePort -Arguments @{
                PortNumber = $Port
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('Domain')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetKeyManagementServiceLookupDomain -Arguments @{
                LookupDomain = $Domain
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('ActivationInterval')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetVLActivationInterval -Arguments @{
                ActivationInterval = $ActivationInterval
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('RenewalInterval')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetVLRenewalInterval -Arguments @{
                RenewalInterval = $RenewalInterval
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('ListeningPort')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetKeyManagementServiceListeningPort -Arguments @{
                PortNumber = $ListeningPort
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('Priority')) {
            $enableLowPriority = ($Priority -eq 'Low')
            Invoke-CimMethod -InputObject $licenseService -MethodName EnableKeyManagementServiceLowPriority -Arguments @{
                EnableLowPriority = $enableLowPriority
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('DnsPublishing')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName DisableKeyManagementServiceDnsPublishing -Arguments @{
                DisablePublishing = (-not $DnsPublishing)
            } -ErrorAction Stop | Out-Null
        }
        
        if ($PSBoundParameters.ContainsKey('HostCaching')) {
            Invoke-CimMethod -InputObject $licenseService -MethodName DisableKeyManagementServiceHostCaching -Arguments @{
                DisableCaching = (-not $HostCaching)
            } -ErrorAction Stop | Out-Null
        }
        
        return [PSCustomObject]@{
            Success = $true
        }
    }
    catch {
        $errException = $_.Exception
        $hr = $null
        $errMsg = $null
        if ($errException.PSObject.Properties['ErrorData'] -and $errException.ErrorData) {
            $errorCode = $errException.ErrorData.CimInstanceProperties['error_Code']
            if ($errorCode) { $hr = $errorCode.Value }
            $winMsg = $errException.ErrorData.CimInstanceProperties['error_WindowsErrorMessage']
            if ($winMsg -and $winMsg.Value) { $errMsg = $winMsg.Value }
        }
        if (-not $errMsg) { $errMsg = $errException.Message }
        return [PSCustomObject]@{
            Success = $false
            ErrorCode = if ($hr) { "0x{0:X8}" -f $hr } else { $null }
            ErrorMessage = if ($errMsg) { $errMsg } else { "$_" }
        }
    }
}

<#
.SYNOPSIS
    Perform KMS license operations
    
.DESCRIPTION
    Clears KMS server, port, domain, and listening port configurations.
    
.PARAMETER ClearServer
    Clear KMS server configuration
    
.PARAMETER ClearPort
    Clear KMS client port
    
.PARAMETER ClearDomain
    Clear KMS lookup domain
    
.PARAMETER ClearListeningPort
    Clear KMS server listening port
    
.EXAMPLE
    Invoke-KmsLicense -ClearServer
    
.EXAMPLE
    Invoke-KmsLicense -ClearDomain
#>
function Invoke-KmsLicense {
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName='ClearServer')]
        [switch]$ClearServer,
        
        [Parameter(ParameterSetName='ClearPort')]
        [switch]$ClearPort,
        
        [Parameter(ParameterSetName='ClearDomain')]
        [switch]$ClearDomain,
        
        [Parameter(ParameterSetName='ClearListeningPort')]
        [switch]$ClearListeningPort
    )
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            return $null
        }
        
        if ($ClearServer) {
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearKeyManagementServiceMachine -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ClearServer'
            }
        }
        
        if ($ClearPort) {
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearKeyManagementServicePort -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ClearPort'
            }
        }
        
        if ($ClearDomain) {
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearKeyManagementServiceLookupDomain -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ClearDomain'
            }
        }
        
        if ($ClearListeningPort) {
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearKeyManagementServiceListeningPort -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ClearListeningPort'
            }
        }
        
        return $null
    }
    catch {
        $errException = $_.Exception
        $hr = $null
        $errMsg = $null
        if ($errException.PSObject.Properties['ErrorData'] -and $errException.ErrorData) {
            $errorCode = $errException.ErrorData.CimInstanceProperties['error_Code']
            if ($errorCode) { $hr = $errorCode.Value }
            $winMsg = $errException.ErrorData.CimInstanceProperties['error_WindowsErrorMessage']
            if ($winMsg -and $winMsg.Value) { $errMsg = $winMsg.Value }
        }
        if (-not $errMsg) { $errMsg = $errException.Message }
        return [PSCustomObject]@{
            Success = $false
            ErrorCode = if ($hr) { "0x{0:X8}" -f $hr } else { $null }
            ErrorMessage = if ($errMsg) { $errMsg } else { "$_" }
        }
    }
}

Export-ModuleMember -Function Get-KmsLicenseInfo, Set-KmsLicenseInfo, Invoke-KmsLicense
