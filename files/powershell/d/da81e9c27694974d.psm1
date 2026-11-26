############################
#
# Copyright (c) Microsoft Corporation
#
# Abstract:
#   SBL script cmdlets
#
############################

using namespace Microsoft.Windows.Storage

Set-StrictMode -Version 3.0

$clusbfltRegKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\clusbflt\Parameters"
$systemFlagsValueName = "SystemFlags"
$busTypeValueName = "SupportedBusTypes"

$cacheRegKeyPath = Join-Path $clusbfltRegKeyPath "StorageBusCache"

#
# Build relative device value table for cache/capacity identification
#
# Assign values to bus/media types s.t. bus * media type produces the relative cache/capacity
# relationships hdd<ssd & sata<sas<nvme<scm
#

$mediaTypes = @( "HDD", "SSD", "SCM" )
$busTypes = @( "SAS", "SATA", "NVME", "SCM" )

$typeValue = @{}
$v = 0
$mediaTypes |% { $typeValue[$_] = $v; $v++ } # media types hdd = 0 so its locked low
$v = 1
$busTypes |% { $typeValue[$_] = $v; $v++ }   # bus types 1-based, thus same-type SSD/HDD are ranked

#
# Build supported bustype mask
#

$supportedBusTypeFlags = 0
foreach ($busType in @(
            [Core.BusType]::Sas,
            [Core.BusType]::Sata,
            [Core.BusType]::Nvme,
            [Core.BusType]::SCM))
{
    $supportedBusTypeFlags = $supportedBusTypeFlags -bor (1 -shl $busType)
}

function CreateErrorRecord
{
    Param
    (
        [String]
        $ErrorId,

        [String]
        $ErrorMessage,

        [System.Management.Automation.ErrorCategory]
        $ErrorCategory,

        [Exception]
        $Exception,

        [Object]
        $TargetObject
    )

    if($Exception -eq $null)
    {
        $Exception = New-Object System.Management.Automation.RuntimeException $ErrorMessage
    }

    $errorRecord = New-Object System.Management.Automation.ErrorRecord @($Exception, $ErrorId, $ErrorCategory, $TargetObject)
    return $errorRecord
}

function LogVerbose
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Verbose ((Get-Date).GetDateTimeFormats('s')[0] + ": $Message")
}

function IsS2DEnabled
{
    $clusRegKeyPath = "HKLM:\Cluster"
    if (Test-Path $clusRegKeyPath)
    {
        $clusRegKey = Get-ItemProperty $clusRegKeyPath -Name S2DEnabled -ErrorAction SilentlyContinue
        if ($clusRegKey.S2DEnabled -eq 1)
        {
            return $true
        }
    }
    return $false
}

function EnforceNoS2D
{
    $return = IsS2DEnabled
    if ($return)
    {
        $errorObject = CreateErrorRecord -ErrorId "Cluster S2D is enabled" `
                                         -ErrorMessage "StorageBusCache Cmdlets cannot be run on a cluster S2D setup" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
    }

    return $return
}

function EnforceTargetPresent
{
    if (-not (Test-Path $clusbfltRegKeyPath))
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "Storage Bus target driver registry key not found" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return $false
    }

    $true
}

function GetGuidFromObjectId
{
    Param(
        [string]
        [Parameter(
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        $ObjectId
        )

    process {

        if ($ObjectId -match "PD:({.*})")
        {
            $matches[1]
        }
    }
}

function GetDevicePath
{
    [CmdletBinding()]
    Param(
        [Parameter(ParameterSetName = "ByGuid")]
        [ValidateNotNullOrEmpty()]
        [string]
        $Guid,

        [Parameter(ParameterSetName = "ByObjectId")]
        [ValidateNotNullOrEmpty()]
        [string]
        $ObjectId
        )

    switch($PSCmdlet.ParameterSetName)
    {
        "ByGuid"     { $guid = $Guid; break; }
        "ByObjectId" { $guid = GetGuidFromObjectId $ObjectId; break; }
    }

    "\\?\Disk" + $guid
}

function IsDeviceDisabled
{
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Guid
    )

    #
    # Test whether a device is disabled/blocked (e.g. Disable-StorageBusDisk)
    # If a device is disabled the target will release it and therefore it is not queryable on
    # the storage bus; as a result, we must look directly at the persisted attributes in the
    # registry.
    #

    $devicePath = Join-Path $clusbfltRegKeyPath "Disks\$Guid"
    if (Test-Path $devicePath)
    {
        $deviceKey = Get-ItemProperty $devicePath
        if ($null -ne (Get-Member -Name Attributes -MemberType NoteProperty -InputObject $deviceKey) -and
            0     -ne ($deviceKey.Attributes -band [StorageBusCache.DiskAttribute]::Disabled))
        {
            # Device is disabled (blocklisted)
            return $true
        }
    }

    $false
}

function GetAllDisks
{
    Param ()

    $deviceTable = @{}
    # Get disk drives visible to PnP, skipping storage spaces virtual disks, if any
    $pnpDrives = Get-PnpDevice -Class DiskDrive | ? FriendlyName -ne "Microsoft Storage Space Device"
    $systemDisks = Get-Disk | ? { $_.IsSystem -eq $true -or $_.IsBoot -eq $true }
    $systemDisks = $systemDisks | Get-PhysicalDisk

    foreach ($drive in $pnpDrives)
    {
        # Obtain device guid
        $devicePathPrefix = "\\?\" + $($drive.DeviceID -replace "\\",'#')

        $devicePath = $devicePathPrefix + "#{" + [Core.DeviceMgmt]::GUID_DEVINTERFACE_DISK + "}"
        $disk = [StorageBusCache.DeviceMgmt]::GetStorageBusDisk($devicePath)

        if ($disk.Guid -eq [GUID]::Empty.ToString())
        {
            $hiddenDevicePath = $devicePathPrefix + "#{" + [Core.DeviceMgmt]::GUID_DEVINTERFACE_HIDDEN_DISK  + "}"
            $disk = [StorageBusCache.DeviceMgmt]::GetStorageBusDisk($hiddenDevicePath)

            if ($disk.Guid -eq [GUID]::Empty.ToString())
            {
                continue
            }
        }

        # Check if this is boot or system drive
        $sysDisk = $systemDisks | ? ObjectId -match $disk.Guid
        if ($sysDisk)
        {
            # Skipping
            continue
        }

        # Add to device table
        if ($disk.Guid -notin $deviceTable.Keys)
        {
            $deviceTable.Add($disk.Guid, $disk)
        }
    }

    return $deviceTable
}

function Set-StorageBusCache
{
    [CmdletBinding()]
    Param
    (
        [System.UInt64]
        [Parameter(
            Mandatory = $false)]
        $CacheMetadataReserveBytes,

        [Microsoft.Windows.Storage.StorageBusCache.CacheModeSet]
        [Parameter(
            Mandatory = $false)]
        $CacheModeHDD,

        [Microsoft.Windows.Storage.StorageBusCache.CacheModeSet]
        [Parameter(
            Mandatory = $false)]
        $CacheModeSSD,

        [System.UInt32]
        [Parameter(
            Mandatory = $false)]
        [ValidateSet(8, 16, 32, 64)]
        $CachePageSizeKBytes,

        [System.UInt32]
        [Parameter(
            Mandatory = $false)]
        [ValidateRange(5, 90)]
        $SharedCachePercent,

        [Microsoft.Windows.Storage.StorageBusCache.ProvisionMode]
        [Parameter(
            Mandatory = $false)]
        $ProvisionMode
    )

    # Get current parameters and dynamically build cache parameter list - there is a 1:1 correspondance of parameter/property/reg value
    $curParam = Get-StorageBusCache
    $cacheParam = (Get-Member -InputObject $curParam |? MemberType -eq Property).Name
    $updatedParam = @()

    if (-not (Test-Path $cacheRegKeyPath))
    {
        $null = New-Item $cacheRegKeyPath -Force
    }

    # Modification guardrails

    if ($PSBoundParameters.ContainsKey("ProvisionMode") -and $curParam.Enabled)
    {
        $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                        -ErrorMessage "Provision mode may not be changed after storage bus is enabled" `
                                        -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                        -Exception $null `
                                        -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    if ($PSBoundParameters.ContainsKey("CacheMetadataReserveBytes") -and $curParam.ProvisionMode -ne ([StorageBusCache.ProvisionMode]::Cache))
    {
        $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                        -ErrorMessage "CacheMetadataReserveBytes is not applicable to current provisioning mode ($($curParam.ProvisionMode))" `
                                        -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                        -Exception $null `
                                        -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    if ($PSBoundParameters.ContainsKey("SharedCachePercent") -and $curParam.ProvisionMode -ne ([StorageBusCache.ProvisionMode]::Shared))
    {
        $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                        -ErrorMessage "SharedCachePercent is not applicable to current provisioning mode ($($curParam.ProvisionMode))" `
                                        -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                        -Exception $null `
                                        -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    foreach ($boundParam in $PSBoundParameters.Keys)
    {
        # Only update changed cache parameters
        if ($boundParam -in $cacheParam -and $curParam.$boundParam -ne $PSBoundParameters[$boundParam])
        {
            switch ($PSBoundParameters[$boundParam].GetTypeCode())
            {
                ([TypeCode]::UInt32) { $t = [Microsoft.Win32.RegistryValueKind]::DWord }
                ([TypeCode]::UInt64) { $t = [Microsoft.Win32.RegistryValueKind]::QWord }
                default { $t = [Microsoft.Win32.RegistryValueKind]::String }
            }
            $updatedParam += $boundParam
            Set-ItemProperty -Path $cacheRegKeyPath -Name $boundParam -Value $PSBoundParameters[$boundParam] -Type $t
        }
    }

    if ($updatedParam.Count)
    {
        LogVerbose ("Updated {0}" -f $($updatedParam -join ", "))

        # React to changes in CacheModeHDD/SSD
        # Per device type, enumerate bindings and set appropriate binding attributes
    }
}

function GetRegValue
{
    [CmdletBinding()]
    Param (
        [Parameter()]
        [object]
        $Container,

        [Parameter()]
        [string]
        $KeyName,

        # Parameter help description
        [Parameter()]
        [string]
        $ValueName,

        # Parameter help description
        [Parameter()]
        [object]
        $DefaultValue
    )

    if (Test-Path $KeyName)
    {
        # Get-ItemPropertyValue and Get-ItemProperty will emit errors for values that do not exist,
        # so unpack it directly from the key object. It will be $null if no values are present, and
        # Get-Member also cleanly returns $null if DNE.
        $k = Get-ItemProperty -Path $KeyName

        if ($null -ne $k -and ($k | Get-Member -Name $ValueName))
        {
            $v = $k.$ValueName
        }
        else
        {
            $v = $DefaultValue
        }
    }
    else
    {
        $v = $DefaultValue
    }

    # Place in container or return direct
    if ($null -ne $Container)
    {
        $Container.$ValueName = $v
    }
    else
    {
        $v
    }
}

function Get-StorageBusCache
{
    [CmdletBinding()]
    Param
    (
    )

    [StorageBusCache.StorageBusCacheParameters] $p = [StorageBusCache.StorageBusCacheParameters]::new()

    GetRegValue $p $cacheRegKeyPath 'ProvisionMode' ([StorageBusCache.ProvisionMode]::Shared)
    GetRegValue $p $cacheRegKeyPath 'CacheMetadataReserveBytes' 32GB
    GetRegValue $p $cacheRegKeyPath 'SharedCachePercent' 15

    GetRegValue $p $cacheRegKeyPath 'CacheModeHDD' ([StorageBusCache.CacheMode]::ReadWrite)
    GetRegValue $p $cacheRegKeyPath 'CacheModeSSD' ([StorageBusCache.CacheMode]::WriteOnly)
    GetRegValue $p $cacheRegKeyPath 'CachePageSizeKBytes' 16

    # Cache is enabled if the supported bus types have been armed/set non zero.
    if (0 -ne (GetRegValue $null $clusbfltRegKeyPath $busTypeValueName 0)) {
        $p.Enabled = $true
    }
    else {
        $p.Enabled = $false
    }

    $p
}

function Get-StorageBusTargetDevice
{
    # Deconstruction alias for the BFlt instance
    # Filter converts the empty case from $null to an actual absence of objects

    $i = Get-StorageBusTargetDeviceInstance

    if ($null -ne $i -and $null -ne $i.PathInfo)
    {
        $i.PathInfo
    }
}

function Get-StorageBusTargetCacheStore
{
    # Deconstruction alias for the BFlt instance
    # Filter converts the empty case from $null to an actual absence of objects

    $i = Get-StorageBusTargetCacheStoresInstance

    if ($null -ne $i -and $null -ne $i.CacheStoreInfo)
    {
        $i.CacheStoreInfo
    }
}

# State transitions for validating arrival/departure of devices from the Storage Bus
enum SurfaceStates {
    Undefined = 0
    SurfaceToTarget = 1
    SurfaceToClient = 2
    SurfaceToProvider = 3
    SurfaceCacheStore = 4

    CheckPartition = 100
}

function WaitForDeviceSurface
{
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory = $true)]
        [string[]]
        $DeviceGuid,

        # Timeout (s)
        [Parameter()]
        [int]
        $Timeout = 300,

        # Progress Activity (null -> no progress reporting)
        [Parameter(
            Mandatory = $true)]
        [string]
        $Activity,

        # Base percentage for reporting progress
        [Parameter(
            Mandatory = $true)]
        [int]
        $BasePercentage,

        # Phase percentage for reporting progress
        [Parameter(
            Mandatory = $true)]
        [int]
        $PhasePercentage
    )

    $timeStart = Get-Date

    # Verify progress through the surfacing process. This is done through a basic state machine tracking the asynchronous process.
    #       arrival at target (target device) - Get-StorageBusTargetDevice
    #       arrival at client (client device) - Get-StorageBusClientDevice
    #       arrival at spaceport/provider (physical disk) - Get-PhysicalDisk (unscoped)

    $n = 0
    $nt = $DeviceGuid.Count

    # Empty state data and all devices validating target
    # Device data provides a scratch pad for a given device
    $stateData = @{}
    $deviceState = @{}
    $deviceData = @{}
    foreach ($device in $DeviceGuid)
    {
        $deviceState[$device] = [SurfaceStates]::SurfaceToTarget
    }

    LogVerbose "Starting wait for device surfacing ($nt devices)"

    while ($deviceState.Count)
    {
        foreach ($device in @($deviceState.Keys)) {

            do {

                $curState = $deviceState[$device]
                $data = $stateData[$curState]

                LogVerbose "$device : $curState"

                switch ($curState)
                {
                    ([SurfaceStates]::SurfaceToTarget)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-StorageBusTargetDevice)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device is in the target, move to client validation
                        if ($data.DeviceGuid -contains $device)
                        {
                            $d = $data |? DeviceGuid -eq $device
                            if ($d.Attributes -contains 'Orphan')
                            {
                                # Allow 10 seconds for orphan devices to bind, then give up
                                # and assume this is permanent (cache device absent)
                                $deviceData[$device] += 1
                                if ($deviceData[$device] -gt 10)
                                {
                                    $deviceState.Remove($device)
                                    LogVerbose "$device : ORPHANED"
                                    $n += 1
                                }
                                break
                            }

                            # Clean up device data if present
                            $deviceData.Remove($device)

                            # If the device arrives cache stores, their load is next;
                            # else move directly to client surfacing.
                            if ($d.Attributes -contains 'HasCachePartition')
                            {
                                $deviceState[$device] = [SurfaceStates]::SurfaceCacheStore
                            }
                            else
                            {
                                $deviceState[$device] = [SurfaceStates]::SurfaceToClient
                            }
                            LogVerbose "$device : $curState -> $($deviceState[$device])"
                        }
                        break
                    }
                    ([SurfaceStates]::SurfaceCacheStore)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-StorageBusTargetCacheStore)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # Wait for any cache stores pending load on this device
                        if ($data |? DeviceGuid -eq $device |? Status -eq STATUS_PENDING)
                        {
                            break
                        }

                        $deviceState[$device] = [SurfaceStates]::SurfaceToClient
                        LogVerbose "$device : $curState -> $($deviceState[$device])"
                        break
                    }
                    ([SurfaceStates]::SurfaceToClient)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-StorageBusClientDevice)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device is in the client, move to provider validation
                        if ($data.DeviceGuid -contains $device)
                        {
                            $deviceState[$device] = [SurfaceStates]::SurfaceToProvider
                            LogVerbose "$device : $curState -> $($deviceState[$device])"
                        }
                        break
                    }
                    ([SurfaceStates]::SurfaceToProvider)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-PhysicalDisk)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device is in the provider, we are complete - remove it from the set requiring validation
                        if ($data |? ObjectId -match $device)
                        {
                            $deviceState.Remove($device)
                            LogVerbose "$device : SURFACED"
                            $n += 1
                        }
                        break
                    }
                }

                # continue if device moved to a new state

            } while ($deviceState.Contains($device) -and $deviceState[$device] -ne $curState)
        }

        # Empty the state data so that we refresh on the next tick (if needed)
        $stateData.Clear()

        # Check timeout if not complete?
        if ($deviceState.Count)
        {
            $waited = [int] ((Get-Date) - $timeStart).TotalSeconds
            if (0 -lt $Timeout -and $waited -gt $Timeout)
            {
                $errorObject = CreateErrorRecord -ErrorId "Timeout" `
                                                 -ErrorMessage "Timed out waiting for device(s) to be surfaced: $(($deviceState.Keys |% { $_, $deviceState[$_] -join ':'}) -join ', ')" `
                                                 -ErrorCategory ([System.Management.Automation.ErrorCategory]::OperationTimeout) `
                                                 -Exception $null `
                                                 -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                break
            }

            Write-Progress -Activity $Activity -Status "Device arrival on Storage Bus ($n of $nt))" -CurrentOperation "Waiting $($waited)s so far$(if (0 -ne $Timeout) {" ($($Timeout)s timeout)"})" -PercentComplete ($BasePercentage + $PhasePercentage*($n/$nt))
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Progress -Activity $Activity -Status "Device arrival on Storage Bus" -CurrentOperation "Complete" -PercentComplete ($BasePercentage + $PhasePercentage*($n/$nt))
}

function WaitForDeviceDeparture
{
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory = $true)]
        [string[]]
        $DeviceGuid,

        # Timeout (s)
        [Parameter()]
        [int]
        $Timeout = 300,

        # Progress Activity (null -> no progress reporting)
        [Parameter(
            Mandatory = $true)]
        [string]
        $Activity,

        # Base percentage for reporting progress
        [Parameter(
            Mandatory = $true)]
        [int]
        $BasePercentage,

        # Phase percentage for reporting progress
        [Parameter(
            Mandatory = $true)]
        [int]
        $PhasePercentage
    )

    $timeStart = Get-Date

    $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods

    # Verify progress through the departure process. This is done through a basic state machine tracking the asynchronous process.
    #       leaving the client (client device) - Get-StorageBusClientDevice
    #       leaving the target (target device) - Get-StorageBusTargetDevice
    #       entering the provider (if unpartitioned/disabled) - GetPhysicalDisk (unscoped)

    $n = 0
    $nt = $DeviceGuid.Count

    # Empty state data and all devices validating client
    $stateData = @{}
    $deviceState = @{}
    foreach ($device in $DeviceGuid)
    {
        $deviceState[$device] = [SurfaceStates]::CheckPartition
    }

    LogVerbose "Starting wait for device departure ($nt devices)"

    while ($deviceState.Count)
    {
        foreach ($device in @($deviceState.Keys)) {

            do {

                $curState = $deviceState[$device]
                $data = $stateData[$curState]

                LogVerbose "$device : $curState"

                switch ($curState)
                {
                    ([SurfaceStates]::CheckPartition)
                    {
                        # Check device for a capacity metadata partition - if present and the device is not disabled, it
                        # will remain claimed by the target to guard against data partitions being mounted and diverging
                        # from the state in the cache. The wait is complete if this is true.

                        $devicePath = GetDevicePath -Guid $device
                        $deviceLayout = [Core.DeviceMgmt]::GetDriveLayout($devicePath)

                        # Any device we claimed will be GPT, but be safe about the unions.
                        if ($deviceLayout.PartitionStyle -eq 'GPT' -and
                            ($deviceLayout.PartitionEntry |? { $_.Gpt.PartitionName -eq 'Microsoft SBL Cache Hdd' }) -and
                            -not (IsDeviceDisabled $device)) {

                                $deviceState.Remove($device)
                                LogVerbose "$device : INITIALIZED CAPACITY"
                                $n += 1
                        }
                        else {

                            # Move to client departure validation
                            $deviceState[$device] = [SurfaceStates]::SurfaceToClient
                            LogVerbose "$device : $curState -> $($deviceState[$device])"
                        }

                        break
                    }
                    ([SurfaceStates]::SurfaceToClient)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-StorageBusClientDevice)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device has left the client, move to target departure validation
                        if ($data.DeviceGuid -notcontains $device)
                        {
                            $deviceState[$device] = [SurfaceStates]::SurfaceToTarget
                            LogVerbose "$device : $curState -> $($deviceState[$device])"
                        }
                        break
                    }
                    ([SurfaceStates]::SurfaceToTarget)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-StorageBusTargetDevice)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device has left the target, move to provider arrival validation
                        if ($data.DeviceGuid -notcontains $device)
                        {
                            $deviceState[$device] = [SurfaceStates]::SurfaceToProvider
                            LogVerbose "$device : $curState -> $($deviceState[$device])"
                        }
                        break
                    }
                    ([SurfaceStates]::SurfaceToProvider)
                    {
                        # Acquire data to validate state?
                        if ($null -eq $data)
                        {
                            $data = @(Get-PhysicalDisk)
                            LogVerbose "Acquired data for $_ ($($data.Count) elements)"
                            if ($data.Count -eq 0) { break }

                            $stateData[$_] = $data
                        }

                        # If device is in the provider, we are complete - remove it from the set requiring validation
                        if ($data |? ObjectId -match $device)
                        {
                            $deviceState.Remove($device)
                            LogVerbose "$device : SURFACED"
                            $n += 1
                        }
                        break
                    }
                }

                # continue if device moved to a new state

            } while ($deviceState.Contains($device) -and $deviceState[$device] -ne $curState)
        }

        # Empty the state data so that we refresh on the next tick (if needed)
        $stateData.Clear()

        # Check timeout if not complete?
        if ($deviceState.Count)
        {
            $waited = [int] ((Get-Date) - $timeStart).TotalSeconds
            if (0 -lt $Timeout -and $waited -gt $Timeout)
            {
                $errorObject = CreateErrorRecord -ErrorId "Timeout" `
                                                 -ErrorMessage "Timed out waiting for device(s) to be depart: $(($deviceState.Keys |% { $_, $deviceState[$_] -join ':'}) -join ', ')" `
                                                 -ErrorCategory ([System.Management.Automation.ErrorCategory]::OperationTimeout) `
                                                 -Exception $null `
                                                 -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                break
            }

            Write-Progress -Activity $Activity -Status "Device departure from Storage Bus ($n of $nt))" -CurrentOperation "Waiting $($waited)s so far$(if (0 -ne $Timeout) {" ($($Timeout)s timeout)"})" -PercentComplete ($BasePercentage + $PhasePercentage*($n/$nt))
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Progress -Activity $Activity -Status "Device departure from Storage Bus" -CurrentOperation "Complete" -PercentComplete ($BasePercentage + $PhasePercentage*($n/$nt))
}

function SetStorageBusProfile
{
    [CmdletBinding()]
    Param
    (
        [System.Boolean]
        [Parameter(
            Mandatory = $false)]
        $ClaimFlash = $true
    )

    # Set Profile
    try
    {
        $systemFlags = 0;
        if ($ClaimFlash)
        {
            $systemFlags = [StorageBusCache.DeviceMgmt]::Standalone_Profile_Claim_Flash
        }
        else
        {
            $systemFlags = [StorageBusCache.DeviceMgmt]::Standalone_Profile_Default
        }

        # Set profile in memory via clusbflt control
        [StorageBusCache.DeviceMgmt]::SetClusBFltSystemFlags($systemFlags) | Out-Null

        # Set the bus types registry key in clusbflt registry
        if (Test-Path $clusbfltRegKeyPath)
        {
            New-ItemProperty -Path $clusbfltRegKeyPath -Name $systemFlagsValueName -Value $systemFlags -PropertyType DWord -Force | Out-Null
        }
        else
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                             -ErrorMessage "ClusBFlt registry key not found" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                         -ErrorMessage $null `
                                         -ErrorCategory $_.CategoryInfo.Category `
                                         -Exception $_.Exception `
                                         -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }
}

function Set-StorageBusProfile
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        [System.Boolean]
        [Parameter(
            Mandatory = $false)]
        $ClaimFlash = $true,

        [System.Boolean]
        [Parameter(
            Mandatory = $false)]
        $AutoConfig = $true
    )

    if (EnforceNoS2D -or -not (EnforceTargetPresent))
    {
        return
    }

    # Set Profile
    SetStorageBusProfile -ClaimFlash $ClaimFlash

    # Enable after Setting profile
    Enable-StorageBusCache -AutoConfig $AutoConfig
}

function Enable-StorageBusCache
{
    [CmdletBinding(ConfirmImpact="High")]
    Param (
        # Timeout for surfacing
        [Parameter(
            Mandatory = $false)]
        [int]
        $Timeout = 300,

        [System.Boolean]
        [Parameter(
            Mandatory = $false)]
        $AutoConfig = $true
    )

    if (EnforceNoS2D -or -not (EnforceTargetPresent))
    {
        return
    }

    # Set the default profile if it has not been set yet (note calling the utility function, not the exposed cmdlet)
    if ($null -eq (Get-ItemProperty $clusbfltRegKeyPath | Get-Member -Name $systemFlagsValueName ))
    {
        SetStorageBusProfile
    }

    # Set the bus types registry key in clusbflt registry
    New-ItemProperty -Path $clusbfltRegKeyPath -Name $busTypeValueName -Value $supportedBusTypeFlags -Force | Out-Null

    # Claim disks
    try
    {
        Write-Progress -Activity "Enable Storage Bus Cache" -Status "Get devices" -PercentComplete 0

        # Enumerate all eligible disks
        $devices = @(Get-StorageBusDisk)
        $candidateDevices = @()

        # 0-10 : get & candidate checks
        $basePercentage = 0
        $phasePercentage = 10
        $n = 1
        $nt = $devices.Count

        foreach ($device in $devices)
        {
            Write-Progress -Activity "Enable Storage Bus Cache" -Status "Check candidate device ($n of $nt)" -CurrentOperation "Check device $($device.Guid)" -PercentComplete ($basePercentage + $phasePercentage*($n/$nt))

            # Check if disk is clusbflt candidate
            $devicePath = GetDevicePath -Guid $device.Guid
            if (-not [StorageBusCache.DeviceMgmt]::IsClusBFltCandidate($devicePath, $supportedBusTypeFlags))
            {
                continue
            }

            $n += 1
            $candidateDevices += $device
        }

        # 10-20: reauction trigger for candidate devices
        $basePercentage = 10
        $phasePercentage = 10
        $n = 1
        $nt = $candidateDevices.Count

        foreach ($device in $candidateDevices)
        {
            Write-Progress -Activity "Enable Storage Bus Cache" -Status "Enable device ($n of $nt)" -CurrentOperation "Claim device $($device.Guid)" -PercentComplete ($basePercentage + $phasePercentage*($n/$nt))

            # Reauction the disk
            $devicePath = GetDevicePath -Guid $device.Guid
            [Core.DeviceMgmt]::ReauctionDevice($devicePath) | Out-Null

            $n += 1
        }

        if ($candidateDevices.Count -eq 0)
        {
            $errorObject = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                            -ErrorMessage "No devices found to for the storage bus: $($busTypes -join ', ') supported" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # 20-100: wait for surfacing
        WaitForDeviceSurface -DeviceGuid $candidateDevices.Guid -Timeout $Timeout -Activity "Enable Storage BusCache" -BasePercentage 20 -PhasePercentage 80

        if ($AutoConfig)
        {
            Update-StorageBusCache
        }
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                         -ErrorMessage $null `
                                         -ErrorCategory $_.CategoryInfo.Category `
                                         -Exception $_.Exception `
                                         -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }

    Write-Progress -Activity "Enable Storage Bus Cache" -Completed
}

function Disable-StorageBusCache
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        # Timeout for departure
        [Parameter(
            Mandatory = $false)]
        [int]
        $Timeout = 300,

        [Parameter(
            Mandatory = $false)]
        [switch]
        $Force
    )

    if (EnforceNoS2D -or -not (EnforceTargetPresent))
    {
        return
    }

    # We should not release any bound devices unless -Force is specified
    if (-not $Force)
    {
        Write-Progress -Activity "Disable Storage Bus Cache" -Status "Check for existing bindings" -CurrentOperation "Get existing bindings" -PercentComplete 0

        if (Get-StorageBusBinding)
        {
            $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                             -ErrorMessage "Found existing cache bindings" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        Write-Progress -Activity "Disable Storage Bus Cache" -Status "Check for existing bindings" -CurrentOperation "Complete" -PercentComplete 20
    }

    # Clear the bus types registry key in clusbflt registry
    New-ItemProperty -Path $clusbfltRegKeyPath -Name $busTypeValueName -Value 0 -Force | Out-Null

    # Now release all devices.
    try
    {
        # Enumerate all eligible disks - only claimed disks?
        $devices = @(Get-StorageBusDisk)

        # 20-40 : reauction to unclaim
        $basePercentage = 20
        $phasePercentage = 20
        $n = 1
        $nt = $devices.Count

        foreach ($device in $devices)
        {
            Write-Progress -Activity "Disable Storage Bus Cache" -Status "Disable device ($n of $nt)" -CurrentOperation "Check device $($device.Guid)" -PercentComplete ($basePercentage + $phasePercentage*($n/$nt))

            $devicePath = GetDevicePath -Guid $device.Guid
            # Check if disk is clusbflt candidate
            if (-not [StorageBusCache.DeviceMgmt]::IsClusBFltCandidate($devicePath, $supportedBusTypeFlags))
            {
                continue
            }

            Write-Progress -Activity "Disable Storage Bus Cache" -Status "Disable device ($n of $($nt)" -CurrentOperation "Release device $($device.Guid)" -PercentComplete ($basePercentage + $phasePercentage*($n/$nt))

            # Reauction the disk
            [Core.DeviceMgmt]::ReauctionDevice($devicePath) | Out-Null

            $n += 1
        }

        # 40-100: wait for departure
        WaitForDeviceDeparture -DeviceGuid $devices.Guid -Timeout $Timeout -Activity "Disable Storage Bus Cache" -BasePercentage 40 -PhasePercentage 60
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                         -ErrorMessage $null `
                                         -ErrorCategory $_.CategoryInfo.Category `
                                         -Exception $_.Exception `
                                         -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }

    Write-Progress -Activity "Disable Storage Bus Cache" -Completed
}

function Get-StorageBusDisk
{
    [CmdletBinding( DefaultParameterSetName = "ByGuid")]
    Param
    (
        #### -------------------- Parameter sets ------------------------------------- ####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $false)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt32]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $false)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $false)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods
    $paths = Get-StorageBusTargetDevice

    # Get all disks on this system
    $devices = GetAllDisks
    $physicalDisks = Get-PhysicalDisk

    # If device is claimed, update its properties based on path properties
    foreach ($deviceGuid in $devices.Keys)
    {
        $phyDisk = $physicalDisks | ? ObjectId -Match $deviceGuid

        if ($phyDisk)
        {
            # Set properties based on physical disk information
            $devices[$deviceGuid].BusType = $phyDisk.BusType
            $devices[$deviceGuid].Number = $phyDisk.DeviceId
        }

        $path = @($paths | ? DeviceGuid -Match $deviceGuid)

        if ($path.Count -eq 0)
        {
            # Device is not claimed, but check if there is a claimed cache partition
            if ($phyDisk)
            {
                # If the partition is claimed, the device guid on the path
                $path = @($paths | ? DeviceNumber -eq $phyDisk.DeviceId)
            }
        }

        if ($path.Count)
        {
            # Only first is needed
            $path = $path[0]

            if (-not $phyDisk)
            {
                # Set properties based on SBL path information since
                # device is claimed but not exposed above SBL
                $devices[$deviceGuid].BusType = $path.BusType
                $devices[$deviceGuid].Number = $path.DeviceNumber
            }

            # The following properties are SBL specific
            if ($path.Attributes -notcontains 'Partition')
            {
                # Path does not correspond to cache partition from an unclaimed device
                $devices[$deviceGuid].IsClaimed = $true
            }

            if ($path.Attributes -contains 'Solid' -or
                $path.Attributes -contains 'Partition')
            {
                $devices[$deviceGuid].IsCache = $true
            }
            else
            {
                $devices[$deviceGuid].IsCache = $false
            }
        }
    }

    # Enumerate the paths based on input
    # Emit any matching devices directly on the pipeline so that empty v. $null is respected
    switch ($psCmdlet.ParameterSetName)
    {
        "ByGuid"
        {
            $devices.Values | ? Guid -match $Guid
        }

        "ByNumber"
        {
            $devices.Values | ? Number -eq $Number
        }

        "ByPhysicalDisk"
        {
            $diskGuid = $PhysicalDisk.ObjectId -Replace '.*:' -Replace '"'
            $devices.Values | ? Guid -match $diskGuid
        }
    }
}

function Get-StorageBusBinding
{
    [CmdletBinding( DefaultParameterSetName = "ByGuid", ConfirmImpact="None" )]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            ValueFromPipeline = $true,
            Mandatory         = $false)]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk

    )

    begin {

        # Get once and pivot out required devices as needed
        $disks = @(Get-StorageBusDisk)
    }

    process {

        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         {
                # Get all bound? Iterate cache and orphan devices, else query given device.
                if ($Guid.Length -eq 0)
                {
                    $devices = @($disks |? IsCache)
                    Get-StorageBusTargetDevice |? { $_.PathType -eq "Engaged" -and $_.Attributes -contains "Orphan" } |% {
                        $devices += @($disks |? Guid -eq $_.DeviceGuid)
                    }
                }
                else
                {
                    $devices = @($disks |? Guid -eq $Guid)
                }
                break
            }
            "ByNumber"       { $devices = @($disks |? Number -eq $Number); break; }
            "ByPhysicalDisk" { $devices = @($disks |? Number -eq $PhysicalDisk.DeviceId); break; }
        }

        $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods
        $paths = @(Get-StorageBusTargetDevice)
        $cs = @(Get-StorageBusTargetCacheStore)

        try
        {
            foreach ($device in $devices)
            {
                if ($device.IsCache)
                {
                    $pathid = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Read_Write, 0, 0, 0)

                    if ($pathid.PathId -eq 0)
                    {
                        # This could be unclaimed cache device with claimed cache partition
                        $pathid.PathId = ($paths | ? DeviceNumber -eq $device.Number).Id
                    }

                    if ($pathid.PathId -ne 0 -and $null -ne $cs)
                    {
                        $cache = $cs | ? PathId -eq $pathid.PathId

                        if ($cache)
                        {
                            $ssdBindingRecords = $pm.QuerySsdBindingRecords($pathid.PathId, $cache.Id).BindingRecords.BindingRecords

                            foreach ($bindingRecord in $ssdBindingRecords)
                            {
                                if (($bindingRecord.Flags -band [StorageBusCache.CacheStoreBindingAttribute]::Enabled) -ne 0)
                                {
                                    $capacityDevice = $disks |? Guid -eq $bindingRecord.DeviceGuid

                                    [StorageBusCache.StorageBusBinding]$storageBusBinding = [StorageBusCache.StorageBusBinding]::new()
                                    $storageBusBinding.DeviceGuid = $capacityDevice.Guid
                                    $storageBusBinding.DeviceNumber = $capacityDevice.Number
                                    $storageBusBinding.CacheDeviceGuid = $device.Guid
                                    $storageBusBinding.CacheDeviceNumber = $device.Number
                                    $storageBusBinding.CacheStoreGuid = $cache.Id
                                    $storageBusBinding.psBase.Attributes = $bindingRecord.Flags
                                    $storageBusBinding.CacheMode = GetCacheModeFromBindingAttributes $bindingRecord.Flags
                                    $storageBusBinding.IsCacheSuspended = $false

                                    if (($bindingRecord.Flags -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache) -ne 0)
                                    {
                                        $storageBusBinding.IsCacheSuspended = $true
                                    }

                                    $storageBusBinding.DirtyByteCount = $bindingRecord.cDirtyPages * $cache.PageSize
                                    $storageBusBinding.TotalByteCount = $bindingRecord.cDirtyPages * $cache.PageSize
                                    $storageBusBinding.HotReadByteCount = $bindingRecord.cPagesL2 * $cache.PageSize

                                    # Return binding
                                    $storageBusBinding
                                }
                            }
                        }
                    }
                }
                else
                {
                    $egPath = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Engaged, 0, 0, 0)

                    if ($egPath.PathId -ne 0)
                    {
                        $hddBinding = $pm.QueryHddBinding($egPath.PathId)
                        $cache = $cs | ? Id -eq $hddBinding.BindingInfo.CacheStoreId

                        # If cache is present, look up the full binding information
                        # If cache is not present, this is an orphaned capacity device bound to a removed/failed/absent cache device/store
                        # and we will return information limited to the binding record on the capacity device
                        if ($null -ne $cache)
                        {
                            $cachePath = $paths | ? Id -eq $cache.PathId
                            $cacheDevice = $disks |? Guid -eq $cachePath.DeviceGuid

                            if (-not $cacheDevice)
                            {
                                # This could be unclaimed cache device with claimed cache partition
                                $cacheDevice = $disks |? Number -eq $cachePath.DeviceNumber
                            }

                            # Obtain binding record that matches binding Id
                            $bindingRecord = $pm.QuerySsdBindingRecords($cache.PathId, $cache.Id).BindingRecords.BindingRecords | ? BindingId -eq $hddBinding.BindingInfo.BindingId
                        }

                        [StorageBusCache.StorageBusBinding]$storageBusBinding = [StorageBusCache.StorageBusBinding]::new()
                        $storageBusBinding.DeviceGuid = $device.Guid
                        $storageBusBinding.DeviceNumber = $device.Number
                        $storageBusBinding.CacheDeviceGuid = $hddBinding.BindingInfo.CacheStoreDeviceId
                        $storageBusBinding.CacheStoreGuid = $hddBinding.BindingInfo.CacheStoreId

                        # Cache present, use device/binding information
                        if ($null -ne $cache)
                        {
                            $storageBusBinding.CacheDeviceNumber = $cacheDevice.Number
                            $storageBusBinding.psBase.Attributes = $bindingRecord.Flags
                            $storageBusBinding.CacheMode = GetCacheModeFromBindingAttributes $bindingRecord.Flags
                            $storageBusBinding.IsCacheSuspended = $false

                            if (($bindingRecord.Flags -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache) -ne 0)
                            {
                                $storageBusBinding.IsCacheSuspended = $true
                            }

                            $storageBusBinding.DirtyByteCount = $bindingRecord.cDirtyPages * $cache.PageSize
                            $storageBusBinding.TotalByteCount = $bindingRecord.cDirtyPages * $cache.PageSize
                            $storageBusBinding.HotReadByteCount = $bindingRecord.cPagesL2 * $cache.PageSize

                        }

                        # Cache absent, indicate orphan/unknown
                        else
                        {
                            $storageBusBinding.CacheDeviceNumber = [System.UInt32]::MaxValue
                            $storageBusBinding.psBase.Attributes = [StorageBusCache.CacheStoreBindingAttribute]::Default
                            $storageBusBinding.CacheMode = [StorageBusCache.CacheMode]::Orphaned
                            $storageBusBinding.IsCacheSuspended = $true

                            # Strictly unknown - missing path information?
                            $storageBusBinding.DirtyByteCount = 0
                            $storageBusBinding.TotalByteCount = 0
                            $storageBusBinding.HotReadByteCount = 0
                        }

                        # Return binding
                        $storageBusBinding
                    }
                }
            }
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
}

function Enable-StorageBusDisk
{
    [CmdletBinding(ConfirmImpact="None")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    begin {

        if (EnforceNoS2D)
        {
            return
        }

        $devices = @()
        $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods
    }

    process {

        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         { $device = Get-StorageBusDisk -Guid $Guid; break; }
            "ByNumber"       { $device = Get-StorageBusDisk -Number $Number; break; }
            "ByPhysicalDisk" { $device = Get-StorageBusDisk -Guid (GetGuidFromObjectId $PhysicalDisk.ObjectId); break; }
        }

        if ($null -eq $device)
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                            -ErrorMessage "Device not found" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # Filter out claimed devices
        if ($device.IsClaimed)
        {
            return
        }

        try
        {
            # Have clusbflt claim the drive
            $dm.SetDeviceAttributes($device.Guid, [StorageBusCache.DiskAttribute]::Default, [StorageBusCache.DiskAttribute]::All)

            # Reauction the disk
            $devicePath = GetDevicePath -Guid $device.Guid
            [Core.DeviceMgmt]::ReauctionDevice($devicePath) | Out-Null

            $devices += $device.Guid
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }

    end {

        try
        {
            # Wait for devices to surface
            if ($devices.Count)
            {
                WaitForDeviceSurface -DeviceGuid $devices -Activity "Enable Storage Bus Disk" -BasePercentage 0 -PhasePercentage 100
            }
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
}

function Disable-StorageBusDisk
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    begin {

        if (EnforceNoS2D)
        {
            return
        }

        $devices = @()
        $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods
    }

    process {

        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         { $device = @(Get-StorageBusDisk -Guid $Guid); break; }
            "ByNumber"       { $device = @(Get-StorageBusDisk -Number $Number); break; }
            "ByPhysicalDisk" { $device = @(Get-StorageBusDisk -Guid (GetGuidFromObjectId $PhysicalDisk.ObjectId)); break; }
        }

        if ($device.Count -eq 0)
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                            -ErrorMessage "Device not found" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # Filter out unclaimed devices
        if (-not $device.IsClaimed)
        {
            return
        }

        if ($device.IsCache)
        {
            # Reject unbinding bound cache devices
            $boundDevices = Get-StorageBusBinding -Guid $device.Guid

            if ($boundDevices)
            {
                $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                                -ErrorMessage "Cache device is currently bound" `
                                                -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                                -Exception $null `
                                                -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                return
            }
        }
        else
        {
            # Remove bindings from capacity dev
            Remove-StorageBusBinding -Guid $device.Guid
        }

        try
        {
            # Have clusbflt unclaim the drive
            $dm.SetDeviceAttributes($device.Guid, [StorageBusCache.DiskAttribute]::Disabled, [StorageBusCache.DiskAttribute]::All)

            # Reauction the disk
            $devicePath = GetDevicePath -Guid $device.Guid
            [Core.DeviceMgmt]::ReauctionDevice($devicePath) | Out-Null

            $devices += $device.Guid
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }

    end {

        try
        {
            # Wait for devices to surface
            if ($devices.Count)
            {
                WaitForDeviceDeparture -DeviceGuid $devices -Activity "Disable Storage Bus Disk" -BasePercentage 0 -PhasePercentage 100
            }
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
}

function Resume-StorageBusDisk
{
    [CmdletBinding(ConfirmImpact="Low")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    begin {

        if (EnforceNoS2D)
        {
            return
        }

        $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods
    }

    process {

        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         { $device = Get-StorageBusDisk -Guid $Guid; break; }
            "ByNumber"       { $device = Get-StorageBusDisk -Number $Number; break; }
            "ByPhysicalDisk" { $device = Get-StorageBusDisk -Number $PhysicalDisk.DeviceId; break; }
        }

        if ($null -eq $device)
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                            -ErrorMessage "Device not found" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        if ($device.IsCache)
        {
            # Resume all bound capacity devices
            $boundDevices = Get-StorageBusBinding -Guid $device.Guid
            foreach ($boundDevice in $boundDevices)
            {
                Resume-StorageBusDisk -Guid $boundDevice.DeviceGuid
            }
        }
        else
        {
            try
            {
                $egPath = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Engaged, 0, 0, 0)
                if ($egPath.PathId -ne 0)
                {
                    # Obtain the capacity device binding info
                    $binding = $pm.QueryHddBinding($egPath.PathId).BindingInfo

                    # Obtain the cache store
                    $cs = Get-WmiObject -namespace "root\wmi" ClusBfltCacheStoresInformation
                    $cache = $cs.CacheStoreInfo | ? Id -Match $binding.CacheStoreId

                    # Obtain binding record that matches binding Id
                    $bindingRecord = $pm.QuerySsdBindingRecords($cache.PathId, $cache.Id).BindingRecords.BindingRecords | ? BindingId -Match $binding.BindingId

                    if ($null -ne $bindingRecord)
                    {
                        # Set cache binding attribute back to default
                        $pm.SetSsdBindingAttributes($cache.PathId, [StorageBusCache.CacheStoreBindingAttribute]::Default, [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache, $cache.Id, $binding.BindingId)
                    }
                }
            }
            catch
            {
                $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                                -ErrorMessage $null `
                                                -ErrorCategory $_.CategoryInfo.Category `
                                                -Exception $_.Exception `
                                                -TargetObject $_.TargetObject

                $psCmdlet.WriteError($errorObject)
                return
            }
        }
    }
}

function Suspend-StorageBusDisk
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    begin {

        if (EnforceNoS2D)
        {
            return
        }

        $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods`
    }

    process {

        # Any device to suspend should be surfaced to the client side of the bus
        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         { $device = Get-StorageBusClientDevice |? DeviceGuid -eq $Guid; break; }
            "ByNumber"       { $device = Get-StorageBusClientDevice |? DeviceNumber -eq $Number; break; }
            "ByPhysicalDisk" { $device = Get-StorageBusClientDevice |? DeviceNumber -eq $PhysicalDisk.DeviceId; break; }
        }

        if ($null -eq $device)
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                            -ErrorMessage "Device not found" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        if ($device.Attributes -contains "HasCachePartition")
        {
            # First suspend all bound capacity devices
            $boundDevices = Get-StorageBusBinding -Guid $device.DeviceGuid
            foreach ($boundDevice in $boundDevices)
            {
                Suspend-StorageBusDisk -Guid $boundDevice.DeviceGuid
            }
        }
        else
        {
            try
            {
                $egPath = $pm.GetPathIdByDeviceGuid($device.DeviceGuid, [StorageBusCache.PathType]::Engaged, 0, 0, 0)
                if ($egPath.PathId -ne 0)
                {
                    # Obtain the capacity device binding info
                    $binding = $pm.QueryHddBinding($egPath.PathId).BindingInfo

                    # Obtain the cache store
                    $cache = Get-StorageBusTargetCacheStore | ? Id -Match $binding.CacheStoreId

                    # Obtain binding record that matches binding Id
                    $bindingRecord = $pm.QuerySsdBindingRecords($cache.PathId, $cache.Id).BindingRecords.BindingRecords | ? BindingId -Match $binding.BindingId

                    if ($null -ne $bindingRecord -and ($bindingRecord.Flags -band [StorageBusCache.CacheStoreBindingAttribute]::Enabled) -ne 0)
                    {
                        # Disable Write cache
                        $pm.SetSsdBindingAttributes($cache.PathId, [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache, [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache, $cache.Id, $binding.BindingId)

                        # Wait for dirty page count to go down to 0 for this cache binding
                        # This should be split out to an end clause and done in parallel for all suspended devices
                        while ($true)
                        {
                            if ($bindingRecord.cDirtyPages -eq 0 -and $bindingRecord.cDirtySlots -eq 0)
                            {
                                break
                            }

                            Start-Sleep -Seconds 1
                            $bindingRecord = $pm.QuerySsdBindingRecords($cache.PathId, $cache.Id).BindingRecords.BindingRecords | ? BindingId -Match $binding.BindingId
                        }
                    }
                }
            }
            catch
            {
                $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                                    -ErrorMessage $null `
                                                    -ErrorCategory $_.CategoryInfo.Category `
                                                    -Exception $_.Exception `
                                                    -TargetObject $_.TargetObject

                $psCmdlet.WriteError($errorObject)
                return
            }
        }
    }
}

function New-StorageBusCacheStore
{
    [CmdletBinding(ConfirmImpact="Low")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('Id')]
        $Guid,

        [System.UInt32]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        #### -------------------- Common parameters -------------------------------------####

        [System.UInt32]
        [Parameter(
            ParameterSetName = 'ByGuid',
            Mandatory        = $false)]
        [Parameter(
            ParameterSetName = 'ByNumber',
            Mandatory        = $false)]
        [ValidateSet(8, 16, 32, 64)]
        [Alias('PageSize')]
        $CachePageSizeKBytes,

        [System.UInt64]
        [Parameter(
            ParameterSetName = 'ByGuid',
            Mandatory        = $false)]
        [Parameter(
            ParameterSetName = 'ByNumber',
            Mandatory        = $false)]
        [Alias('$ReserveCapacity')]
        $CacheMetadataReserveBytes,

        [System.UInt32]
        [Parameter(
            ParameterSetName = 'ByGuid',
            Mandatory        = $false)]
        [Parameter(
            ParameterSetName = 'ByNumber',
            Mandatory        = $false)]
        [ValidateRange(5, 90)]
        $SharedCachePercent
    )

    if (EnforceNoS2D)
    {
        return
    }

    switch ($psCmdlet.ParameterSetName)
    {
        "ByGuid"        { $cacheDevice = Get-StorageBusClientDevice |? DeviceGuid -eq $Guid; break; }
        "ByNumber"      { $cacheDevice = Get-StorageBusClientDevice |? Number -eq $Number; break; }
    }

    # Ensure exactly one cache device is obtained
    if ($null -eq $cacheDevice)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "Specified cache device not found" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    if ($cacheDevice.Attributes -notcontains "Solid")
    {
        $errorObject = CreateErrorRecord -ErrorId "InvalidArgument" `
                                         -ErrorMessage "Specified cache device is not a solid state device" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    Write-Progress -Activity "Create New Cache Store" -PercentComplete 0

    # Get cache parameters for autoconfiguration and populate with overrides provided on command line
    # Note that this does NOT persist a change, it is a common property bag to land the effective values
    $curParam = Get-StorageBusCache
    $cacheParam = (Get-Member -InputObject $curParam |? MemberType -eq Property).Name

    foreach ($p in $PSBoundParameters.Keys) {
        if ($p -in $cacheParam)
        {
             $curParam.$_ = $PSBoundParameters[$_]
        }
    }

    $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods
    $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods

    # Determine how much reserve we will leave based on provisioning mode:
    # Cache - fixed value ; Shared - percentage of capacity
    if ($curParam.ProvisionMode -eq [StorageBusCache.ProvisionMode]::Cache)
    {
        $reserve = $curParam.CacheMetadataReserveBytes;
    }
    else
    {
        $pd = Get-PhysicalDisk -DeviceNumber $cachedevice.DeviceNumber

        if ($null -eq $pd)
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                            -ErrorMessage "Physical disk object corresponding to storage bus device number $($cachedevice.DeviceNumber) not found" `
                                            -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                            -Exception $null `
                                            -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # Round down to nearest 128MiB - note that shared cache percent is the percent for cache, and the reserve is everything remaining (100 - sp%)
        $reserve = [math]::Floor((100 - $curParam.SharedCachePercent) * $pd.Size / 128MB / 100) * 128MB;
    }

    $deviceAttributes = $dm.GetDeviceAttributes($cacheDevice.DeviceGuid)

    try
    {
        # Create cache store
        $dm.SetDeviceAttributes($cacheDevice.DeviceGuid, [StorageBusCache.DiskAttribute]::Maintenance, [StorageBusCache.DiskAttribute]::All)

        $mmPath = $pm.GetPathIdByDeviceGuid($cacheDevice.DeviceGuid, [StorageBusCache.PathType]::Maintenance, 0, 0, 0)

        if ($mmPath)
        {
            # Pre-initialize the device if raw/unpartitioned
            $devicePath = GetDevicePath -Guid $cacheDevice.DeviceGuid
            $deviceLayout = [Core.DeviceMgmt]::GetDriveLayout($devicePath)

            if ($deviceLayout.PartitionStyle -eq [Core.PartitionStyle]::Raw)
            {
                $pm.ReInitializeDisk($mmPath.PathId, 0)
            }

            $pm.CreateSsdCacheStore($mmPath.PathId, 0, $reserve, $curParam.CachePageSizeKBytes * 1KB)
        }
        else
        {
            $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                             -ErrorMessage "Device path not found after setting Maintenance mode" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                         -ErrorMessage $null `
                                         -ErrorCategory $_.CategoryInfo.Category `
                                         -Exception $_.Exception `
                                         -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }
    finally
    {
        $dm.SetDeviceAttributes($cacheDevice.DeviceGuid, $deviceAttributes.Attributes, [StorageBusCache.DiskAttribute]::All)
    }

    try
    {
        WaitForDeviceSurface -Activity "Create New Cache Store" -DeviceGuid $cacheDevice.DeviceGuid -BasePercentage 50 -PhasePercentage 50
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                        -ErrorMessage $null `
                                        -ErrorCategory $_.CategoryInfo.Category `
                                        -Exception $_.Exception `
                                        -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }
}

# Forward map of cache mode to applied binding attributes
function GetBindingAttributesFromCacheMode
{
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory = $true)]
        [Microsoft.Windows.Storage.StorageBusCache.CacheMode]
        $CacheMode,

        [Parameter(
            Mandatory = $true)]
        [System.Boolean]
        $IsSolid
    )

    # Persistent readahead is always disabled. Replaced with VRC (as whole-system flag, not binding) in current releases.
    $mode = [StorageBusCache.CacheStoreBindingAttribute]::Enabled -bor [StorageBusCache.CacheStoreBindingAttribute]::Disable_Read_Ahead_Cache

    switch ($CacheMode)
    {
        ([StorageBusCache.CacheMode]::ReadOnly) {
            $mode = $mode -bor [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache
            break
        }
        ([StorageBusCache.CacheMode]::ReadWrite) {
            # nothing
            break
        }
        ([StorageBusCache.CacheMode]::WriteOnly) {
            $mode = $mode -bor [StorageBusCache.CacheStoreBindingAttribute]::Disable_Read_Cache
            break
        }
    }

    # Apply delayed destage to solid state devices with write cache
    if ($IsSolid -and -not ($mode -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache))
    {
        $mode = $mode -bor [StorageBusCache.CacheStoreBindingAttribute]::Delay_Destage
    }

    $mode
}

# Reverse map of binding attributes to displayed cache mode
function GetCacheModeFromBindingAttributes
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [Microsoft.Windows.Storage.StorageBusCache.CacheStoreBindingAttribute]
        $CacheStoreBindingAttributes
    )

    if (-not ($CacheStoreBindingAttributes -band [StorageBusCache.CacheStoreBindingAttribute]::Enabled))
    {
        return [StorageBusCache.CacheMode]::Disabled
    }
    else
    {
        if ($CacheStoreBindingAttributes -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Write_Cache)
        {
            # we do not expect write and read to be disabled without actually being disabled, but for the sake of it:
            if (-not ($CacheStoreBindingAttributes -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Read_Cache))
            {
                return [StorageBusCache.CacheMode]::ReadOnly
            }
        }
        elseif ($CacheStoreBindingAttributes -band [StorageBusCache.CacheStoreBindingAttribute]::Disable_Read_Cache)
        {
            return [StorageBusCache.CacheMode]::WriteOnly
        }

        return [StorageBusCache.CacheMode]::ReadWrite
    }
}

function New-StorageBusBinding
{
    [CmdletBinding(ConfirmImpact="Low")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('CacheId')]
        $CacheGuid,

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('CapacityId')]
        $CapacityGuid,

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $CacheNumber,

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $CapacityNumber
    )

    if (EnforceNoS2D)
    {
        return
    }

    switch ($psCmdlet.ParameterSetName)
    {
        "ByGuid"        { $cacheDevice = Get-StorageBusClientDevice |? DeviceGuid -eq $CacheGuid; $capacityDevice = Get-StorageBusClientDevice |? DeviceGuid -eq $CapacityGuid; break; }
        "ByNumber"      { $cacheDevice = Get-StorageBusClientDevice |? Number -eq $CacheNumber;   $capacityDevice = Get-StorageBusClientDevice |? Number -eq $CapacityNumber; break; }
    }

    # Ensure exactly one cache device is obtained
    if ($null -eq $cacheDevice)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "Specified cache device not found" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    if ($cacheDevice.Attributes -notcontains "Solid")
    {
        $errorObject = CreateErrorRecord -ErrorId "InvalidArgument" `
                                         -ErrorMessage "Specified cache device is not a solid state device" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    # Ensure exactly one capacity device is obtained
    if (-not $capacityDevice)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "Specified capacity device not found" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    # Get cache parameters for autoconfiguration and populate with overrides provided on command line
    # Note that this does NOT persist a change, it is a common property bag to land the effective values
    $curParam = Get-StorageBusCache
    $cacheParam = (Get-Member -InputObject $curParam |? MemberType -eq Property).Name

    foreach ($p in $PSBoundParameters.Keys) {
        if ($p -in $cacheParam)
        {
             $curParam.$_ = $PSBoundParameters[$_]
        }
    }

    $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods
    $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods
    $cs = Get-StorageBusTargetCacheStore
    $paths = Get-StorageBusTargetDevice

    $deviceAttributes = $dm.GetDeviceAttributes($capacityDevice.DeviceGuid)

    try
    {
        # Obtain the cache store
        $cache = $cs | ? DeviceGuid -Match $cacheDevice.DeviceGuid

        if ($null -eq $cache)
        {
            # This could be unclaimed cache device with claimed cache partition
            $cachePath = $paths | ? DeviceNumber -eq $cacheDevice.Number
            if ($cachePath)
            {
                $cache = $cs | ? DeviceGuid -Match $cachePath.DeviceGuid
            }
        }

        if ($null -eq $cache)
        {
            # No cache store found so create cache store
            New-StorageBusCacheStore -Guid $cacheDevice.DeviceGuid

            # Obtain the cache store
            $cs = Get-StorageBusTargetCacheStore
            $cache = $cs | ? DeviceGuid -Match $cacheDevice.DeviceGuid

            if (-not $cache)
            {
                $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                                 -ErrorMessage "No cache store found on cache device " + $cacheDevice.DeviceGuid `
                                                 -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                                 -Exception $null `
                                                 -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                return
            }
        }

        # Check if the capacity device is already bound
        $egPath = $pm.GetPathIdByDeviceGuid($capacityDevice.DeviceGuid, [StorageBusCache.PathType]::Engaged, 0, 0, 0)

        if ($egPath.PathId -eq 0)
        {
            # Bind Capacity device to cache store
            $dm.SetDeviceAttributes($capacityDevice.DeviceGuid, [StorageBusCache.DiskAttribute]::Maintenance, [StorageBusCache.DiskAttribute]::All)
            $mmPath = $pm.GetPathIdByDeviceGuid($capacityDevice.DeviceGuid, [StorageBusCache.PathType]::Maintenance, 0, 0, 0)

            if ($mmPath.PathId -ne 0)
            {
                # Determine cache attributes to apply based on capacity device type
                $capacityPath = @($paths |? DeviceGuid -eq $capacityDevice.DeviceGuid)[0]

                if ($capacityPath.Attributes -contains 'Solid')
                {
                    $cacheAttributes = GetBindingAttributesFromCacheMode $curParam.CacheModeSSD $true
                }
                else
                {
                    $cacheAttributes = GetBindingAttributesFromCacheMode $curParam.CacheModeHDD $false
                }

                $pm.PrepareHddForCache($mmPath.PathId, 0)
                $pm.BindHddToCacheStore($mmPath.PathId, $cacheAttributes, $cache.Id)
            }
            else
            {
                $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                                 -ErrorMessage "Device path not found after setting Maintenance mode" `
                                                 -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                                 -Exception $null `
                                                 -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                return
            }
        }
        else
        {
            $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                             -ErrorMessage "Capacity device is already bound" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                         -ErrorMessage $null `
                                         -ErrorCategory $_.CategoryInfo.Category `
                                         -Exception $_.Exception `
                                         -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }
    finally
    {
        $dm.SetDeviceAttributes($capacityDevice.DeviceGuid, $deviceAttributes.Attributes, [StorageBusCache.DiskAttribute]::All)
    }

    try
    {
        WaitForDeviceSurface -DeviceGuid $capacityDevice.DeviceGuid -Activity "Surfacing newly bound device" -BasePercentage 50 -PhasePercentage 50
    }
    catch
    {
        $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                        -ErrorMessage $null `
                                        -ErrorCategory $_.CategoryInfo.Category `
                                        -Exception $_.Exception `
                                        -TargetObject $_.TargetObject

        $psCmdlet.WriteError($errorObject)
        return
    }
}

function Remove-StorageBusBinding
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk,

        [Microsoft.Windows.Storage.StorageBusCache.StorageBusBinding]
        [Parameter(
            ParameterSetName  = 'ByBinding',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Binding
    )

    begin {

        if (EnforceNoS2D)
        {
            return
        }

        $devices = @()
    }

    process {

        switch ($psCmdlet.ParameterSetName)
        {
            "ByGuid"         { $device = Get-StorageBusDisk -Guid $Guid; break; }
            "ByNumber"       { $device = Get-StorageBusDisk -Number $Number; break; }
            "ByPhysicalDisk" { $device = Get-StorageBusDisk  -Guid (GetGuidFromObjectId $PhysicalDisk.ObjectId); break; }
            "ByBinding"      { $device = Get-StorageBusDisk -Guid $Binding.DeviceGuid; break }
        }

        # Filter out unclaimed devices
        if (-not $device.IsClaimed)
        {
            return
        }

        $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods
        $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods

        if ($device.IsCache)
        {
            # First unbind all bound capacity devices
            $boundDevices = Get-StorageBusBinding -Guid $device.Guid
            foreach ($boundDevice in $boundDevices)
            {
                Remove-StorageBusBinding -Guid $boundDevice.DeviceGuid
            }
        }
        else
        {
            try
            {
                $deviceAttributes = $dm.GetDeviceAttributes($device.Guid)

                $egPath = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Engaged, 0, 0, 0)

                if ($egPath.PathId -ne 0)
                {
                    # Disable write cache and drain IOs
                    Suspend-StorageBusDisk -Guid $device.Guid

                    # Unbind HDD
                    $dm.SetDeviceAttributes($device.Guid, [StorageBusCache.DiskAttribute]::Maintenance, [StorageBusCache.DiskAttribute]::All)
                    $mmPath = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Maintenance, 0, 0, 0)

                    if ($mmPath.PathId -ne 0)
                    {
                        $pm.UnBindHdd($mmPath.PathId, 0)
                        $devices += $device.Guid
                    }
                    else
                    {
                        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                                        -ErrorMessage "Device path not found after setting Maintenance mode" `
                                                        -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                                        -Exception $null `
                                                        -TargetObject $null

                        $psCmdlet.WriteError($errorObject)
                        return
                    }
                }
            }
            catch
            {
                $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                                -ErrorMessage $null `
                                                -ErrorCategory $_.CategoryInfo.Category `
                                                -Exception $_.Exception `
                                                -TargetObject $_.TargetObject

                $psCmdlet.WriteError($errorObject)
                return
            }
            finally
            {
                $dm.SetDeviceAttributes($device.Guid, $deviceAttributes.Attributes, [StorageBusCache.DiskAttribute]::All)
            }
        }
    }

    end {

        try
        {
            # Wait for devices to surface
            if ($devices.Count)
            {
                WaitForDeviceSurface -DeviceGuid $devices -Activity "Surfacing unbound device" -BasePercentage 50 -PhasePercentage 50
            }
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                            -ErrorMessage $null `
                                            -ErrorCategory $_.CategoryInfo.Category `
                                            -Exception $_.Exception `
                                            -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
    }
}

function Clear-StorageBusDisk
{
    [CmdletBinding(ConfirmImpact="High")]
    Param
    (
        #### -------------------- Parameter sets -------------------------------------####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByGuid',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Id")]
        $Guid,

        [System.UInt16]
        [Parameter(
            ParameterSetName  = 'ByNumber',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $Number,

        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ParameterSetName  = 'ByPhysicalDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    if (EnforceNoS2D)
    {
        return
    }

    switch ($psCmdlet.ParameterSetName)
    {
        "ByGuid"         { $devices = Get-StorageBusDisk -Guid $Guid; break; }
        "ByNumber"       { $devices = Get-StorageBusDisk -Number $Number; break; }
        "ByPhysicalDisk" { $devices = Get-StorageBusDisk -Number $PhysicalDisk.DeviceId; break; }
    }

    # Filter out unclaimed devices
    $devices = $devices | ? IsClaimed -eq $true

    $dm = Get-WmiObject -namespace "root\wmi" ClusBfltDeviceMethods
    $pm = Get-WmiObject -namespace "root\wmi" ClusBfltPathMethods

    foreach ($device in $devices)
    {
        $deviceAttributes = $dm.GetDeviceAttributes($device.Guid)

        try
        {
            $dm.SetDeviceAttributes($device.Guid, [StorageBusCache.DiskAttribute]::Maintenance, [StorageBusCache.DiskAttribute]::All)
            $mmPath = $pm.GetPathIdByDeviceGuid($device.Guid, [StorageBusCache.PathType]::Maintenance, 0, 0, 0)

            if ($mmPath.PathId -ne 0)
            {
                # Remove all cache partitions on the disk
                $devicePath = GetDevicePath -Guid $device.Guid
                [StorageBusCache.DeviceMgmt]::CleanupSblCachePartitions($devicePath) | Out-Null
            }
            else
            {
                $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                                 -ErrorMessage "Device path not found after setting Maintenance mode" `
                                                 -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                                 -Exception $null `
                                                 -TargetObject $null

                $psCmdlet.WriteError($errorObject)
                return
            }
        }
        catch
        {
            $errorObject = CreateErrorRecord -ErrorId $_.FullyQualifiedErrorId `
                                             -ErrorMessage $null `
                                             -ErrorCategory $_.CategoryInfo.Category `
                                             -Exception $_.Exception `
                                             -TargetObject $_.TargetObject

            $psCmdlet.WriteError($errorObject)
            return
        }
        finally
        {
            $dm.SetDeviceAttributes($device.Guid, $deviceAttributes.Attributes, [StorageBusCache.DiskAttribute]::All)
        }
    }
}

function ClassifyPhysicalDisk
{
    [CmdletBinding()]
    param(
        [Microsoft.Management.Infrastructure.CimInstance]
        [PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_PhysicalDisk")]
        [Parameter(
            ValueFromPipeline = $true,
            Mandatory         = $false)]
        [ValidateNotNullOrEmpty()]
        $PhysicalDisk
    )

    begin {
        $disk = @()
    }

    process {

        # Assign relative value for each device by bus/mediatype
        # Should account for a set cachedevicemodel

        $disk += $PhysicalDisk | Add-Member -Force -NotePropertyName SbValue -NotePropertyValue ($typeValue[$_.BusType] * $typeValue[$_.MediaType]) -PassThru
    }

    end {

        # Group to identify cache/capacity devices and slice into first/best and rest
        ($best, $rest) = $disk | Group-Object SbValue | Sort-Object @{ Expression = { [int]$_.Name}} -Descending

        # If there is only one group then there are no identified cache devices
        if ($null -eq $rest)
        {
            return $null, $best.Group
        }

        # Return cache and capacity elements
        # Note that there may be more than one capacity/rest group; return deconstructs the groups
        $best.Group, $rest.Group
    }
}

function Update-StorageBusCache
{
    [CmdletBinding()]
    Param (
        [switch]
        $NoBind,

        [switch]
        $NoPool,

        [switch]
        $NoCacheUsage,

        [switch]
        $NoTiers
    )

    if (EnforceNoS2D)
    {
        return
    }

    $curParam = Get-StorageBusCache

    # check for bus enabled
    if (-not $curParam.Enabled)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotEnabled" `
                                         -ErrorMessage "Storage Bus is not enabled" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::NotEnabled) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    $subSystem = Get-StorageSubSystem -Model 'Windows Storage'

    if ($null -eq $subSystem)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "The Windows storage subsystem is not available" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    # Get client devices and corresponding physicaldisk
    # Note this autoexcludes disabled devices

    $clientDisk = @(Get-StorageBusClientDevice |? DeviceType -eq Disk)
    $physicalDisk = @($subSystem | Get-PhysicalDisk)
    $sbusPhysicalDisk = @($physicalDisk |? DeviceId -in $clientDisk.Number)

    # Classify physicaldisk into cache/capacity
    $cacheDisk, $capacityDisk = $sbusPhysicalDisk | ClassifyPhysicalDisk

    if ($null -eq $cacheDisk)
    {
        $errorObject = CreateErrorRecord -ErrorId "NotFound" `
                                         -ErrorMessage "Storage Bus does not have identifiable cache devices" `
                                         -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                         -Exception $null `
                                         -TargetObject $null

        $psCmdlet.WriteError($errorObject)
        return
    }

    # Look for existing pools using these physicaldisk
    $pools = @($sbusPhysicalDisk | Get-StoragePool |? IsPrimordial -eq $false | Sort-Object -Unique -Property ObjectId)

    switch ($pools.Count) {
        0 { $pool = $null; break }
        1 { $pool = $pools[0]; break }
        default {
            $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                                -ErrorMessage "Storage Bus contains more than one pool, autoconfiguration of pool not possible" `
                                                -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                                -Exception $null `
                                                -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }
    }

    # If there are client devices which are neither hybrid (cached) nor have cache partitions
    # (are cache devices), attempt to bind. Need to handle orphan, which will only be at the target.

    if (-not $NoBind -and ($clientDisk |? { $_.Attributes -notcontains 'Hybrid' -and $_.Attributes -notcontains 'HasCachePartition'}))
    {
        # Build list of unbound capacity devices

        $binding = @(Get-StorageBusBinding)
        if ($binding.Count)
        {
            $unboundPhysicalDisk = @($capacityDisk |? DeviceId -notin $binding.DeviceNumber)
        }
        else
        {
            $unboundPhysicalDisk = $capacityDisk
        }

        # Build table of binding counts. Initialize with all cache disks at zero, then update with
        # any existing bindings. This is used for binding and any required cache initialization.

        $bindCount = @{}
        $cacheDisk.ObjectId | GetGuidFromObjectId |% {
            $bindCount[$_] = 0
        }

        foreach ($b in $binding)
        {
            $bindCount[$b.CacheDeviceGuid] += 1
        }

        # Now if there are actually unbound capacity devices, bind them.

        if ($unboundPhysicalDisk.Count)
        {
            # Build ordered list of cache devices to bind to

            $bindOrder = @($bindCount.Keys | Sort-Object @{ Expression = {$bindCount[$_]}})

            # Now bind unbound capacity devices starting at the first candidate cache device

            $nextCache = 0
            foreach ($ubd in $unboundPhysicalDisk)
            {
                New-StorageBusBinding -CacheGuid $bindOrder[$nextCache] -CapacityGuid (GetGuidFromObjectId $ubd.ObjectId)
                $bindCount[$bindOrder[$nextCache]] += 1

                # Loop back to first cache device if we're at the end.
                if (($nextCache + 1) -eq $bindOrder.Count)
                {
                    $nextCache = 0
                    continue
                }

                # If this device now has more bound than its neighbor, move forward in the list.
                # Else we keep binding to the current device.
                if ($bindCount[$bindOrder[$nextCache]] -gt $bindCount[$bindOrder[$nextCache + 1]])
                {
                    $nextCache += 1
                }
            }
        }

        # Now, if there are cache devices with no bound capacity devices, make sure there are cache stores on them
        # so that their cache reserve will be claimable by Spaces/other use.
        #
        # Note that it is strictly unlikely there are no cache stores at all at this point since we asserted that
        # there were both identifiable cache and capacity devices, so there must be some bindings. Be safe though.

        $cs = @(Get-StorageBusTargetCacheStore)

        foreach ($ubd in @($bindCount.Keys |? { $bindCount[$_] -eq 0 }))
        {
            $cacheDeviceGuid = (GetGuidFromObjectId $ubd.ObjectId)
            if ($cs.Count -eq 0 -or $cacheDeviceGuid -notin $cs.DeviceGuid)
            {
                New-StorageBusCacheStore -Guid $cacheDeviceGuid
            }
        }
    }

    # If there are poolable physicaldisks, attempt to pool. Note that binding will not have
    # changed this.

    $poolablePhysicalDisks = @($sbusPhysicalDisk |? CanPool)

    if (-not $NoPool -and $poolablePhysicalDisks.Count)
    {
        # Pool autoconfiguration is not possible if there are unbound/initialized disks - if this was permitted,
        # Spaces would claim the entire disk and make it impossible to bind later without a wipe/redo.
        #
        # Refresh list of bindings capacity devices (perhaps due to binding errors).

        $binding = @(Get-StorageBusBinding)
        if (-not $binding.Count -or ($capacityDisk |? DeviceId -notin $binding.DeviceNumber))
        {
            $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                             -ErrorMessage "Storage Bus has unbound capacity devices, autoconfiguration of pool not possible" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # List of uninitialized cache devices
        $cs = @(Get-StorageBusTargetCacheStore)
        if (-not $cs.Count -or ($cacheDisk |? { (GetGuidFromObjectId $_.ObjectId) -notin $cs.DeviceGuid }))
        {
            $errorObject = CreateErrorRecord -ErrorId "InvalidOperation" `
                                             -ErrorMessage "Storage Bus has uninitialized cache devices, autoconfiguration of pool not possible" `
                                             -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                             -Exception $null `
                                             -TargetObject $null

            $psCmdlet.WriteError($errorObject)
            return
        }

        # Create pool?
        if ($null -eq $pool)
        {
            $pool = New-StoragePool -FriendlyName "Storage Bus Cache on $env:COMPUTERNAME" `
                                    -PhysicalDisks $poolablePhysicalDisks `
                                    -FaultDomainAwarenessDefault PhysicalDisk `
                                    -ResiliencySettingNameDefault Simple `
                                    -ProvisioningTypeDefault Fixed `
                                    -StorageSubSystemUniqueId $subSystem.UniqueId
        }
        else
        {
            Add-PhysicalDisk -StoragePool $pool -PhysicalDisks $poolablePhysicalDisks
        }
    }

    if (-not $NoCacheUsage)
    {
        # Cache provisioning mode has minimum reserve and sets cache devices for journal-only usage.
        # Shared provisioning mode puts the devices in autoselect to be allocated based on tiers.

        if ($curParam.ProvisionMode -eq [StorageBusCache.ProvisionMode]::Cache)
        {
            $cacheDisk |? Usage -ne Journal | Set-PhysicalDisk -Usage Journal
        }
        else
        {
            $cacheDisk |? Usage -ne AutoSelect | Set-PhysicalDisk -Usage AutoSelect
        }
    }

    if (-not $NoTiers)
    {
        $curTiers = $pool | Get-StorageTier

        # Group and sort autoselect media by type relative value
        # This handles both cache mode (no journal/cache devices) and shared mode (everything)
        $mediaGroup = @($pool | Get-PhysicalDisk -Usage AutoSelect | Group-Object -Property MediaType -NoElement | Sort-Object { $typeValue[$_.Name] })

        # Tiers are only defined for shared mode if there are two types of allocatable media.
        # Tiers cannot distinguish media if everything is a single media type.
        if ($curParam.ProvisionMode -eq [StorageBusCache.ProvisionMode]::Cache -or
            $mediaGroup.Count -gt 1)
        {
            # Lay out the <Resilience>on<Media> named tiers
            foreach ($mt in $mediaGroup.Name)
            {
                foreach ($rt in "Mirror", "Parity")
                {
                    $tierName = "$($rt)On$($mt)"

                    # Create tier if it does not already exist
                    if ($null -eq ($curTiers |? FriendlyName -eq $tierName))
                    {
                        # Use 1-fault resilient layouts if insufficient devices are available for 2-fault
                        if (($rt -eq "Mirror" -and @($sbusPhysicalDisk |? MediaType -eq $mt).Count -gt 2) -or
                            ($rt -eq "Parity" -and @($sbusPhysicalDisk |? MediaType -eq $mt).Count -gt 3))
                        {
                            $fdr = 2
                        }
                        else
                        {
                            $fdr = 1
                        }

                        $null = $pool | New-StorageTier -FriendlyName $tierName -PhysicalDiskRedundancy $fdr -ResiliencySettingName $rt -MediaType $mt
                    }
                }
            }

            # Lay out the role-named tiers

            # Lay out single or multiple media types, depending on media content
            # If Shared, already know there are two (SSD/HDD, SCM/SSD, etc.). Cache may have only one.
            $ct = $mediaGroup[0].Name
            if ($mediaGroup.Count -gt 1)
            {
                $pt = $mediaGroup[1].Name
            }
            else
            {
                $pt = $ct
            }

            foreach ($tierName in "Capacity", "Performance")
            {
                switch ($tierName)
                {
                    "Capacity" { $mt = $ct; $rt = "Parity" }
                    "Performance" { $mt = $pt; $rt = "Mirror" }
                }

                if ($null -eq ($curTiers |? FriendlyName -eq $tierName))
                {
                    if (($rt -eq "Mirror" -and @($sbusPhysicalDisk |? MediaType -eq $mt).Count -gt 2) -or
                        ($rt -eq "Parity" -and @($sbusPhysicalDisk |? MediaType -eq $mt).Count -gt 3))
                    {
                        $fdr = 2
                    }
                    else
                    {
                        $fdr = 1
                    }

                    $null = $pool | New-StorageTier -FriendlyName $tierName -PhysicalDiskRedundancy $fdr -ResiliencySettingName $rt -MediaType $mt
                }
            }
        }
    }
}