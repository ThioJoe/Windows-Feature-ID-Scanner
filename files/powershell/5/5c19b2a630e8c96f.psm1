$script:modulePath = Split-Path -Parent $PSCommandPath
Import-LocalizedData -BindingVariable LocalizedData -BaseDirectory $modulePath -FileName "LicenseInfoData"

function Get-LocalizedString {
    param([string]$Key)
    return $LocalizedData[$Key]
}


<#
.SYNOPSIS
    Get Active Directory license info
    
.DESCRIPTION
    Retrieves AD-based licensing information, including activation objects and forest installation ID.
    
.PARAMETER ForestInstallationId
    Product key to get forest installation ID for
    
.PARAMETER ActivationObjects
    List all AD activation objects
    
.EXAMPLE
    Get-ADLicenseInfo
    
.EXAMPLE
    Get-ADLicenseInfo -ForestInstallationId "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    
.EXAMPLE
    Get-ADLicenseInfo -ActivationObjects
#>
function Get-ADLicenseInfo {
    [CmdletBinding(DefaultParameterSetName='Default')]
    param (
        [Parameter(ParameterSetName='ForestInstallationId')]
        [string]$ForestInstallationId,
        
        [Parameter(ParameterSetName='ActivationObjects')]
        [switch]$ActivationObjects
    )
    
    Write-Verbose (Get-LocalizedString 'ADLicenseInfoVerbose')
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            Write-Verbose (Get-LocalizedString 'NoLicenseFound')
            return $null
        }
        
        if ($ForestInstallationId) {
            $osProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match 'Windows' } |
                         Select-Object -First 1
            
            if ($osProduct) {
                return [PSCustomObject]@{
                    ProductKey=$ForestInstallationId
                    ForestInstallationId = $osProduct.OfflineInstallationId
                }
            }
            
            return $null
        }
        
        if ($ActivationObjects) {
            try {
                if (Get-Module -ListAvailable -Name ActiveDirectory) {
                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                    
                    $searchBase = (Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
                    $activationObjectsPath = "CN=Activation Objects,CN=Microsoft SPP,$searchBase"
                    
                    $adObjects = Get-ADObject -SearchBase $activationObjectsPath -Filter * -Properties * -ErrorAction Stop
                    
                    return $adObjects | ForEach-Object {
                        [PSCustomObject]@{
                            DistinguishedName = $_.DistinguishedName
                            Name= $_.Name
                            ObjectClass = $_.ObjectClass
                            Created = $_.Created
                            Modified = $_.Modified
                        }
                    }
                }
                else {
                    $rootDSE = [ADSI]"LDAP://RootDSE"
                    $configNC = $rootDSE.configurationNamingContext
                    $activationObjectsPath = "LDAP://CN=Activation Objects,CN=Microsoft SPP,$configNC"
                    
                    $searcher = New-Object System.DirectoryServices.DirectorySearcher
                    $searcher.SearchRoot = [ADSI]$activationObjectsPath
                    $searcher.Filter = "(objectClass=*)"
                    $results = $searcher.FindAll()
                    
                    return $results | ForEach-Object {
                        [PSCustomObject]@{
                            DistinguishedName = if ($_.Properties["distinguishedName"].Count -gt 0) { $_.Properties["distinguishedName"][0] } else { $null }
                            Name = if ($_.Properties["name"].Count -gt 0) { $_.Properties["name"][0] } else { $null }
                            ObjectClass = if ($_.Properties["objectClass"].Count -gt 0) { $_.Properties["objectClass"][0] } else { $null }
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Unable to query Active Directory activation objects: $_"
                return $null
            }
        }
        
        $osProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'Windows' } |
                     Select-Object -First 1
        
        if ($osProduct) {
            return [PSCustomObject]@{
                Name = $osProduct.Name
                Description= $osProduct.Description
                ActivationID = $osProduct.ID
                LicenseStatus = switch ($osProduct.LicenseStatus) {
                    0 { Get-LocalizedString 'LicenseStatusUnlicensed' }
                    1 { Get-LocalizedString 'LicenseStatusLicensed' }
                    2 { Get-LocalizedString 'LicenseStatusOOBGrace' }
                    3 { Get-LocalizedString 'LicenseStatusOOTGrace' }
                    4 { Get-LocalizedString 'LicenseStatusNonGenuineGrace' }
                    5{ Get-LocalizedString 'LicenseStatusNotification' }
                    6 { Get-LocalizedString 'LicenseStatusExtendedGrace' }
                    default { (Get-LocalizedString 'LicenseStatusUnknown') + " ($($osProduct.LicenseStatus))" }
                }
                ADActivationObjectName = $osProduct.ADActivationObjectName
                ADActivationObjectDN = $osProduct.ADActivationObjectDN
                ADActivationCsvlkPid = $osProduct.ADActivationCsvlkPid
                ADActivationCsvlkSkuId = $osProduct.ADActivationCsvlkSkuId
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

<#
.SYNOPSIS
    Perform AD licensing operations
    
.DESCRIPTION
    Run AD-based licensing tasks including activation and managing activation objects.
    
.PARAMETER ActivateOnline
    Activate online via Active Directory
    
.PARAMETER ActivateForest
    Activate using AD forest
    
.PARAMETER ProductKey
    Product key to use for activation
    
.PARAMETER ConfirmationID
    Confirmation ID for offline activation
    
.PARAMETER ActivationObjectName
    Name of the activation object
    
.PARAMETER DeleteActivationObjects
    Delete activation object by DN or RDN
    
.EXAMPLE
    Invoke-ADLicense -ActivateOnline -ProductKey "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    Does online AD activation.
    
.EXAMPLE
    Invoke-ADLicense -ActivateForest -ProductKey "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" -ConfirmationID "123456"
    Does forest AD activation.
    
.EXAMPLE
    Invoke-ADLicense -DeleteActivationObjects "CN=MyActivationObject,CN=Activation Objects,CN=Microsoft SPP,CN=Configuration,DC=contoso,DC=com"
    Deletes the activation object.
#>
function Invoke-ADLicense {
    [CmdletBinding(DefaultParameterSetName='None')]
    param (
        [Parameter(ParameterSetName='ActivateOnline')]
        [switch]$ActivateOnline,
        
        [Parameter(ParameterSetName='ActivateForest')]
        [switch]$ActivateForest,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ProductKey,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ConfirmationID,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ActivationObjectName,
        
        [Parameter(ParameterSetName='DeleteActivationObjects')]
        [string]$DeleteActivationObjects
    )
    
    Write-Verbose (Get-LocalizedString 'ADLicenseInfoVerbose')
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            Write-Verbose (Get-LocalizedString 'NoLicenseFound')
            return $null
        }
        
        if ($ActivateOnline -or $ActivateForest) {
            if ($ProductKey) {
                Invoke-CimMethod -InputObject $licenseService -MethodName InstallProductKey -Arguments @{
                    ProductKey = $ProductKey
                } -ErrorAction Stop | Out-Null
            }
            
            # Get the Windows product
            $osProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                         Where-Object { $_.Name -match 'Windows' } |
                         Select-Object -First 1
            
            if (-not $osProduct) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }
            
            if ($ActivateOnline) {
                $args = @{}
                if ($ActivationObjectName) {
                    $args.Add('ActivationObjectName', $ActivationObjectName)
                }
                
                Invoke-CimMethod -InputObject $osProduct -MethodName Activate -Arguments $args -ErrorAction Stop | Out-Null
            }
            elseif ($ActivateForest) {
                if ($ConfirmationID) {
                    $args = @{
                        ConfirmationId = $ConfirmationID
                    }
                    if ($ActivationObjectName) {
                        $args.Add('ActivationObjectName', $ActivationObjectName)
                    }
                    
                    Invoke-CimMethod -InputObject $osProduct -MethodName DepositOfflineConfirmationId -Arguments $args -ErrorAction Stop | Out-Null
                }
            }
            
            return [PSCustomObject]@{
                Success= $true
                Operation = if ($ActivateOnline) { 'ActivateOnline' } else { 'ActivateForest' }
                ProductKey = $ProductKey
                ActivationObjectName = $ActivationObjectName
            }
        }
        
        if ($DeleteActivationObjects) {
            try {
                # Try to use Active Directory module if available
                if (Get-Module -ListAvailable -Name ActiveDirectory) {
                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                    
                    if ($DeleteActivationObjects -match '^CN=') {
                        Remove-ADObject -Identity $DeleteActivationObjects -Confirm:$false -ErrorAction Stop
                    }
                    else {
                        $rootDSE = Get-ADRootDSE -ErrorAction Stop
                        $configNC = $rootDSE.configurationNamingContext
                        $fullDN = "CN=$DeleteActivationObjects,CN=Activation Objects,CN=Microsoft SPP,$configNC"
                        Remove-ADObject -Identity $fullDN -Confirm:$false -ErrorAction Stop
                    }
                }
                else {
                    if ($DeleteActivationObjects -match '^CN=') {
                        $objectPath = "LDAP://$DeleteActivationObjects"
                    }
                    else {
                        $rootDSE = [ADSI]"LDAP://RootDSE"
                        $configNC = $rootDSE.configurationNamingContext
                        $objectPath = "LDAP://CN=$DeleteActivationObjects,CN=Activation Objects,CN=Microsoft SPP,$configNC"
                    }
                    
                    $adObject = [ADSI]$objectPath
                    $adObject.DeleteTree()
                }
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation= 'DeleteActivationObject'
                    ActivationObject = $DeleteActivationObjects
                }
            }
            catch {
                Write-Verbose "Unable to delete activation object: $_"
                throw (Get-LocalizedString 'InvalidActivationObject')
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

Export-ModuleMember -Function Get-ADLicenseInfo, Invoke-ADLicense
