$global:DONamespace = "root/Microsoft/Windows/DeliveryOptimization"

enum SettableDownloadMode
{
    CdnOnly = 0
    Lan = 1
    Internet = 3
}

function Set-DODownloadMode
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [SettableDownloadMode] $downloadMode
    )
    Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -MethodName "SetDownloadMode" -Arguments @{downloadMode=[byte]$downloadMode} | out-null
}

function Set-DOMaxBackgroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [Nullable[uint32]] $MaxBackgroundBandwidth,
        [Parameter()] [switch] $Reset        
    )
    if ($Reset -and ($MaxBackgroundBandwidth -ne $null))
    {
        throw [System.ArgumentException] "Can't use a value for MaxBackgroundBandwidth with the Reset flag"
    }
    elseif (!$Reset -and ($MaxBackgroundBandwidth -eq $null))
    {
        throw [System.ArgumentException] "Missing MaxBackgroundBandwidth parameter"
    }
    $Args = @{background=$true}
    if (!$Reset)
    {
        $Args["limitBps"] = [uint32]$MaxBackgroundBandwidth

    }
    Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -MethodName "SetDownloadRateLimitBps" -Arguments $Args | out-null
}

function Set-DOMaxForegroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [Nullable[uint32]] $MaxForegroundBandwidth,
        [Parameter()] [switch] $Reset        
    )
    if ($Reset -and ($MaxForegroundBandwidth -ne $null))
    {
        throw [System.ArgumentException] "Can't use a value for MaxBackgroundBandwidth with the Reset flag"
    }
    elseif (!$Reset -and ($MaxForegroundBandwidth -eq $null))
    {
        throw [System.ArgumentException] "Missing MaxBackgroundBandwidth parameter"
    }
    $Args = @{background=$false}
    if (!$Reset)
    {
        $Args["limitBps"] = [uint32]$MaxForegroundBandwidth

    }
    Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -MethodName "SetDownloadRateLimitBps" -Arguments $Args | out-null
}

function Set-DOPercentageMaxBackgroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [ValidateRange(0, 100)]
        [Nullable[uint32]] $MaxBackgroundBandwidthPercentage,
        [Parameter()] [switch] $Reset        
    )
    if ($Reset -and ($MaxBackgroundBandwidthPercentage -ne $null))
    {
        throw [System.ArgumentException] "Can't use a value for MaxBackgroundBandwidth with the Reset flag"
    }
    elseif (!$Reset -and ($MaxBackgroundBandwidthPercentage -eq $null))
    {
        throw [System.ArgumentException] "Missing MaxBackgroundBandwidth parameter"
    }
    $Args = @{background=$true}
    if (!$Reset)
    {
        $Args["limitPct"] = [byte]$MaxBackgroundBandwidthPercentage

    }
    Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -MethodName "SetDownloadRateLimitPct" -Arguments $Args | out-null
}

function Set-DOPercentageMaxForegroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [ValidateRange(0, 100)]
        [Nullable[uint32]] $MaxForegroundBandwidthPercentage,
        [Parameter()] [switch] $Reset        
    )
    if ($Reset -and ($MaxForegroundBandwidthPercentage -ne $null))
    {
        throw [System.ArgumentException] "Can't use a value for MaxBackgroundBandwidth with the Reset flag"
    }
    elseif (!$Reset -and ($MaxForegroundBandwidthPercentage -eq $null))
    {
        throw [System.ArgumentException] "Missing MaxBackgroundBandwidth parameter"
    }
    $Args = @{background=$false}
    if (!$Reset)
    {
        $Args["limitPct"] = [byte]$MaxForegroundBandwidthPercentage

    }
    Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -MethodName "SetDownloadRateLimitPct" -Arguments $Args | out-null
}

function Delete-DeliveryOptimizationCache
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter()][ValidateNotNullOrEmpty()][string] $FileId,
        [Parameter()][switch] $IncludePinnedFiles,
        [Parameter()] [switch] $Force
    )

    if (!$Force)
    {
        Write-Host "Are you sure you want to delete files in Delivery Optimization Cache? You cannot undo this action."
        Write-Host "Enter [Y] to proceed, any other key to cancel.";
        $key = $Host.UI.RawUI.ReadKey()
        if ([char]::ToLowerInvariant($key.Character) -eq 'y')
        {
            $Force = $true
        }
        Write-Host
    }

    if ($Force)
    {
        Write-Host "Deleting..."
        $Args = @{deletePinned=$IncludePinnedFiles.ToBool()}
        if ($FileId)
        {
            $Args["fileId"] = [string]$FileId
        }
        $Error.Clear()
        try
        {
            Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationFile -MethodName "Delete" -Arguments $Args -ErrorAction Stop | out-null
            Write-Host "Successfully deleted Delivery Optimization cache"
        }
        catch
        {
            if ($_.FullyQualifiedErrorId.Contains("80D0680B"))
            {
                throw "File is not initialized. Please try again later."
            }
            elseif ($_.FullyQualifiedErrorId.Contains("80070490"))
            {
                throw "FileId not found. Please run Get-DeliveryOptimizationStatus again and make sure the file exists."
            }
            elseif ($_.FullyQualifiedErrorId.Contains("0x80D06819"))
            {
                throw "Cannot delete a file that is pinned without using the IncludePinnedFiles switch. Please unpin the file or use the switch."
            }
            else
            {
                throw $_
            }
        }
    }
}

function Set-DeliveryOptimizationStatus
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    Param(
        [Parameter()][string] $FileId,
        [Parameter()][nullable[bool]] $Pin,
        [Parameter()][DateTime] $ExpireOn
    )

    $pinExists = $Pin -ne $null # Needs special treatment because it's bool. Using HasValue or '!' won't work.
    if ($pinExists -and [string]::IsNullOrEmpty($FileId))
    {
        throw "Cannot use pin or unpin without FileId"
    }

    if (!$pinExists -and !$ExpireOn)
    {
        throw "Must provide at least pin or expiration value"
    }

    if ($PinExists)
    {
        $Args = @{pinned=$Pin}
        if ($FileId)
        {
            $Args["fileId"] = [string]$FileId
        }
        try
        {
            Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationFile -MethodName "SetPinned" -Arguments $Args -ErrorAction Stop | out-null
            Write-Host "Pin status succesfully set"
        }
        catch
        {
            if ($_.FullyQualifiedErrorId.Contains("80D06818"))
            {
                throw "Cannot set pinning because file is not peering"
            }
            if ($_.FullyQualifiedErrorId.Contains("0x80070490"))
            {
                throw "FileId not found. Please run Get-DeliveryOptimizationStatus and make sure the file exists."
            }
            throw $_
        }
    }

    if ($ExpireOn)
    {
        if (($ExpireOn - [DateTime]::Now).Days -ge 365)
        {
            throw "Cannot change the expiration by more than 1 year"
        }

        $Args = @{expiration=$ExpireOn}
        if ($FileId)
        {
            $Args["fileId"] = [string]$FileId
        }
        try
        {
            Invoke-CimMethod -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationFile -MethodName "SetExpiration" -Arguments $Args -ErrorAction Stop | out-null
            Write-Host "Expiration is succesfully set"
        }
        catch
        {
            if ($_.FullyQualifiedErrorId.Contains("80070490"))
            {
                throw "FileId not found. Please run Get-DeliveryOptimizationStatus and make sure the file exists."
            }
            throw $_
        }
    }
}
