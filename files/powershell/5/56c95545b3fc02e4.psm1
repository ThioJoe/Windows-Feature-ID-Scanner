<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

Import-Module Hyper-V
Import-Module Storage

$VirtualizationNamespace = 'root\virtualization\v2'

# Only SCSI is supported at this time
[flagsattribute()]
Enum ControllerType
{
    SCSI = 1
}

class VMDirectVirtualDisk
{
    [String]
    $VirtualDiskUniqueId

    [String]
    $VirtualDiskFriendlyName

    [System.UInt32]
    $ControllerLocation

    [System.UInt32]
    $ControllerNumber

    [ControllerType]
    $ControllerType

    [String]
    $Id

    [Guid]
    $VMId

    [String]
    $VMName

    [CimSession]
    $CimSession

    [String]
    $ComputerName
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

    if ($Exception -eq $null)
    {
        $Exception = New-Object System.Management.Automation.RuntimeException $ErrorMessage
    }

    $errorRecord = New-Object System.Management.Automation.ErrorRecord @($Exception, $ErrorId, $ErrorCategory, $TargetObject)

    return $errorRecord
}

function Get-VMDirectVirtualDisk
{
    Param
    (
        #### --------------------------------- Parameter Sets --------------------------------- ####

        [System.String[]]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VMName,

        [Microsoft.HyperV.PowerShell.VirtualMachine[]]
        [Parameter(
            ParameterSetName  = 'ByVM',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VM,

        [Microsoft.HyperV.PowerShell.VMDriveController[]]
        [Parameter(
            ParameterSetName  = 'ByVMDriveController',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VMDriveController,

        #### ----------------------------- Common Method Parameters ----------------------------- ####

        [CimSession[]]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false)]
        $CimSession,

        [ControllerType]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 1)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 1)]
        $ControllerType,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 2)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 2)]
        $ControllerNumber,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 3)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 3)]
        [Parameter(
            ParameterSetName  = 'ByVMDriveController',
            Mandatory         = $false)]
        $ControllerLocation
    )

    Process
    {
        $CimSessionPassed = $true

        try
        {
            # Get the instance controllers
            $vms         = @()
            $controllers = @()

            switch ($psCmdlet.ParameterSetName)
            {
                "ByVMName"
                {
                    if (!$PSBoundParameters.ContainsKey('CimSession'))
                    {
                        $CimSession       = New-CimSession -ErrorAction Stop
                        $CimSessionPassed = $false
                    }

                    $vms = Get-VM -Name $VMName `
                                  -CimSession $CimSession `
                                  -ErrorAction Stop
                }

                "ByVM"
                {
                    $vms = $VM
                }

                "ByVMDriveController"
                {
                    $controllers = $VMDriveController
                }
            }

            if ($controllers.Count -eq 0)
            {
                if ($PSBoundParameters.ContainsKey('ControllerNumber'))
                {
                    $controllers = Get-VMScsiController -VM $vms `
                                                        -ControllerNumber $ControllerNumber `
                                                        -ErrorAction Stop
                }
                else
                {
                    $controllers = Get-VMScsiController -VM $vms `
                                                        -ErrorAction Stop
                }
            }

            foreach ($controller in $controllers)
            {
                # Get the current CIM session
                $currentCimSession = $controller.CimSession

                # Cache virtual disks in the current CIM session for later use
                $virtualDisks = Get-VirtualDisk -CimSession $currentCimSession `
                                                -ErrorAction Stop

                # No virtual disks were found in the current CIM session
                if ($null -eq $virtualDisks -or
                    $virtualDisks.Count -eq 0)
                {
                    continue
                }

                # Get the current VM
                $currentVm = Get-VM -Id $controller.VMId `
                                    -CimSession $currentCimSession `
                                    -ErrorAction Stop

                # Get the associated controller resource
                $computerSystem = Get-CimInstance -ClassName 'Msvm_ComputerSystem' `
                                                  -CimSession $currentCimSession `
                                                  -Namespace $VirtualizationNamespace `
                                                  -Filter "Name='$($currentVm.Id)'" `
                                                  -ErrorAction Stop

                if ($null -eq $computerSystem)
                {
                    $error = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                               -ErrorMessage "No virtual machines found with id equal to '$($currentVm.Id)'." `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }

                $virtualSystemSettingData = Get-CimAssociatedInstance -InputObject $computerSystem `
                                                                      -CimSession $currentCimSession `
                                                                      -ResultClassName 'Msvm_VirtualSystemSettingData' `
                                                                      -ErrorAction Stop

                $virtualSystemSettingData = $virtualSystemSettingData | Where-Object -FilterScript `
                                            {
                                                $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
                                            }

                $controllerResource = Get-CimAssociatedInstance -InputObject $virtualSystemSettingData `
                                                                -CimSession $currentCimSession `
                                                                -ResultClassName 'Msvm_ResourceAllocationSettingData' `
                                                                -ErrorAction Stop

                $controllerResource = $controllerResource | Where-Object -FilterScript `
                                    {
                                        $_.ResourceType -eq 6 -and
                                        $_.InstanceID   -eq $controller.Id
                                    }

                # Get the associated luns
                $lunSettingDataEntries = Get-CimAssociatedInstance -InputObject $controllerResource `
                                                                   -CimSession $currentCimSession `
                                                                   -ResultClassName 'Msvm_VirtualLogicalUnitSettingData' `
                                                                   -ErrorAction Stop

                # Filter luns by controller location
                if ($PSBoundParameters.ContainsKey('ControllerLocation'))
                {
                    $lunSettingDataEntries = $lunSettingDataEntries | Where-Object -FilterScript `
                                            {
                                                $_.AddressOnParent -eq $ControllerLocation
                                            }
                }

                # Enumerate virtual disks with an associated lun
                foreach ($virtualDisk in $virtualDisks)
                {
                    # Ignore luns not associated with a virtual disk
                    $virtualDiskId = $virtualDisk.ObjectId.Split('{}')[7]

                    $lunSettingData = $lunSettingDataEntries | Where-Object -FilterScript `
                    {
                        $_.Connection -like "*$virtualDiskId*"
                    }

                    if ($null -eq $lunSettingData)
                    {
                        continue
                    }

                    $vmDirectVirtualDisk = [VMDirectVirtualDisk]::new()

                    $vmDirectVirtualDisk.VirtualDiskUniqueId     = $virtualDisk.UniqueId
                    $vmDirectVirtualDisk.VirtualDiskFriendlyName = $virtualDisk.FriendlyName
                    $vmDirectVirtualDisk.ControllerLocation      = $lunSettingData.AddressOnParent
                    $vmDirectVirtualDisk.ControllerNumber        = $controller.ControllerNumber
                    $vmDirectVirtualDisk.ControllerType          = [ControllerType]::SCSI
                    $vmDirectVirtualDisk.Id                      = $lunSettingData.InstanceID
                    $vmDirectVirtualDisk.VMId                    = $currentVm.VMId
                    $vmDirectVirtualDisk.VMName                  = $currentVm.Name
                    $vmDirectVirtualDisk.CimSession              = $currentCimSession
                    $vmDirectVirtualDisk.ComputerName            = $currentVm.ComputerName

                    $vmDirectVirtualDisk
                }
            }
        }
        finally
        {
            if ((-not $CimSessionPassed) -and
                $CimSession)
            {
                $CimSession | Remove-CimSession
                $CimSession = $null
            }
        }
    }
}

function Add-VMDirectVirtualDisk
{
    Param
    (
        #### --------------------------------- Parameter Sets --------------------------------- ####

        [System.String[]]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VMName,

        [Microsoft.HyperV.PowerShell.VirtualMachine[]]
        [Parameter(
            ParameterSetName  = 'ByVM',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VM,

        [Microsoft.HyperV.PowerShell.VMDriveController]
        [Parameter(
            ParameterSetName  = 'ByVMDriveController',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VMDriveController,

        #### ----------------------------- Common Method Parameters ----------------------------- ####

        [CimSession[]]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false)]
        $CimSession,

        [ControllerType]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 1)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 1)]
        $ControllerType,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 2)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 2)]
        $ControllerNumber,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false,
            Position          = 3)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false,
            Position          = 3)]
        [Parameter(
            ParameterSetName  = 'ByVMDriveController',
            Mandatory         = $false)]
        $ControllerLocation,

        # Analog to Path parameter in Add-VMHardDiskDrive
        [String]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false)]
        [Parameter(
            ParameterSetName  = 'ByVM',
            Mandatory         = $false)]
        [Parameter(
            ParameterSetName  = 'ByVMDriveController',
            Mandatory         = $false)]
        [ValidateNotNullOrEmpty()]
        $VirtualDiskUniqueId
    )

    Process
    {
        $CimSessionPassed = $true

        try
        {
            # Get the instance VM(s)
            $vms = @()

            switch ($psCmdlet.ParameterSetName)
            {
                "ByVMName"
                {
                    if (!$PSBoundParameters.ContainsKey('CimSession'))
                    {
                        $CimSession       = New-CimSession -ErrorAction Stop
                        $CimSessionPassed = $false
                    }

                    $vms = Get-VM -Name $VMName `
                                  -CimSession $CimSession `
                                  -ErrorAction Stop
                }

                "ByVM"
                {
                    $vms = $VM
                }

                "ByVMDriveController"
                {
                    $vms = Get-VM -Name $VMDriveController.VMName `
                                  -CimSession $VMDriveController.CimSession `
                                  -ErrorAction Stop
                }
            }

            foreach ($currentVm in $vms)
            {
                # Get the current CIM session
                $currentCimSession = $currentVm.CimSession

                # Get the Virtual System Management Service
                $vmms = Get-CimInstance -ClassName 'Msvm_VirtualSystemManagementService' `
                                        -CimSession $currentCimSession `
                                        -Namespace $VirtualizationNamespace `
                                        -ErrorAction Stop

                if ($null -eq $vmms)
                {
                    $error = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                               -ErrorMessage "Could not find Virtual System Management Service." `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }

                $computerSystem = Get-CimInstance -ClassName 'Msvm_ComputerSystem' `
                                                  -CimSession $currentCimSession `
                                                  -Namespace $VirtualizationNamespace `
                                                  -Filter "Name='$($currentVm.Id)'" `
                                                  -ErrorAction Stop

                if ($null -eq $computerSystem)
                {
                    $error = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                               -ErrorMessage "No virtual machines found with id equal to '$($currentVm.Id)'." `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }

                $virtualSystemSettingData = Get-CimAssociatedInstance -InputObject $computerSystem ` `
                                                                      -CimSession $currentCimSession `
                                                                      -ResultClassName 'Msvm_VirtualSystemSettingData' `
                                                                      -ErrorAction Stop

                $virtualSystemSettingData = $virtualSystemSettingData | Where-Object -FilterScript `
                                            {
                                                $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
                                            }

                # Get associated controller resources
                $controllerResources = Get-CimAssociatedInstance -InputObject $virtualSystemSettingData `
                                                                 -CimSession $currentCimSession `
                                                                 -ResultClassName 'Msvm_ResourceAllocationSettingData' `
                                                                 -ErrorAction Stop

                $controllerResources = $controllerResources | Where-Object -FilterScript `
                                       {
                                           $_.ResourceType -eq 6
                                       }

                # Cache VM controllers for later use
                $controllers = Get-VMScsiController -VM $currentVm `
                                                    -ErrorAction Stop

                $controller = $null

                # Get the controller resource associated with the specified controller
                if ($PSBoundParameters.ContainsKey('VMDriveController'))
                {
                    $controller = $VMDriveController
                }

                # Get the controller resource associated with the specified controller number
                if ($PSBoundParameters.ContainsKey('ControllerNumber'))
                {
                    $controller = $controllers | Where-Object -FilterScript `
                    {
                        $_.ControllerNumber -eq $ControllerNumber
                    }

                    if ($null -eq $controller)
                    {
                        $controllerResources = $null
                    }
                }

                if ($null -ne $controller)
                {
                    $controllerResources = $controllerResources | Where-Object -FilterScript `
                                           {
                                               $_.InstanceID -eq $controller.Id
                                           }
                }

                # Hyper-V enforces a max of 64 locations per controller
                $minlocation = 0
                $maxlocation = 63

                if ($PSBoundParameters.ContainsKey('ControllerLocation')) {

                    $minlocation = $ControllerLocation
                    $maxLocation = $ControllerLocation
                }

                $found = $false

                foreach ($controllerResource in $controllerResources)
                {
                    # Get the associated controller
                    $controller = $controllers | Where-Object -FilterScript `
                    {
                        $_.Id -eq $controllerResource.InstanceID
                    }

                    # Get the VM hdds associated with the current controller
                    $vmHdds = $controller | Get-VMHardDiskDrive -ErrorAction Stop

                    # Get the luns associated with the current controller
                    $lunSettingDataEntries = Get-CimAssociatedInstance -InputObject $controllerResource `
                                                                       -CimSession $currentCimSession `
                                                                       -ResultClassName 'Msvm_VirtualLogicalUnitSettingData' `
                                                                       -ErrorAction Stop

                    # Find the next available location on the current controller
                    for ($location = $minlocation; $location -le $maxLocation; $location++)
                    {
                        $vmHdd = $vmHdds | Where-Object -FilterScript `
                        {
                            $_.ControllerLocation -eq $location
                        }

                        $lunSettingData = $lunSettingDataEntries | Where-Object -FilterScript `
                        {
                            $_.AddressOnParent -eq $location
                        }

                        if ($null -eq $vmHdd -and
                            $null -eq $lunSettingData)
                        {
                            $found = $true
                            break
                        }
                    }

                    # No available locations on the current controller
                    if (-not $found)
                    {
                        continue
                    }

                    # Attach the virtual disk
                    $virtualDisk = Get-VirtualDisk -UniqueId $VirtualDiskUniqueId `
                                                   -CimSession $currentCimSession `
                                                   -ErrorAction Stop

                    $poolId        = $virtualDisk.ObjectId.Split('{}')[5]
                    $virtualDiskId = $virtualDisk.ObjectId.Split('{}')[7]

                    $lunAllocationCapabilities = Get-CimInstance -ClassName 'Msvm_AllocationCapabilities' `
                                                                 -CimSession $currentCimSession `
                                                                 -Namespace $VirtualizationNamespace `
                                                                 -Filter "ResourceType=32768 and ResourceSubType='Microsoft:Hyper-V:Storage Logical Unit'" `
                                                                 -ErrorAction Stop

                    $lunSettingsDefineCapabilities = Get-CimInstance -ClassName 'Msvm_SettingsDefineCapabilities' `
                                                                     -CimSession $currentCimSession `
                                                                     -Namespace $VirtualizationNamespace `
                                                                     -ErrorAction Stop

                    $lunSettingsDefineCapabilities = $lunSettingsDefineCapabilities | Where-Object -FilterScript `
                    {
                        $_.GroupComponent.InstanceID -eq $lunAllocationCapabilities.InstanceID -and
                        $_.ValueRange                -eq 0
                    }

                    $lunSettingData = Get-CimInstance -ClassName Msvm_VirtualLogicalUnitSettingData `
                                                      -CimSession $currentCimSession `
                                                      -Namespace $VirtualizationNamespace `
                                                      -ErrorAction Stop

                    $lunSettingData = $lunSettingData | Where-Object -FilterScript `
                    {
                        $_.InstanceID -eq $lunSettingsDefineCapabilities.PartComponent.InstanceID
                    }

                    $lunSettingData.Parent               = "\\$($currentVm.ComputerName)\$($VirtualizationNamespace):Msvm_ResourceAllocationSettingData.InstanceID=`"$($controllerResource.InstanceID.Replace('\', '\\'))`""
                    $lunSettingData.AddressOnParent      = $location
                    $lunSettingData.Connection           = "{$poolId}{$virtualDiskId}"
                    $lunSettingData.StorageSubsystemType = 'space'

                    $cimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()

                    $embeddedInstanceBuffer = $cimSerializer.Serialize($lunSettingData,
                                                                    [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)

                    $embeddedInstance = [System.Text.Encoding]::Unicode.GetString($embeddedInstanceBuffer)

                    $result = Invoke-CimMethod -InputObject $vmms `
                                               -MethodName 'AddResourceSettings' `
                                               -CimSession $currentCimSession `
                                               -Arguments @{ 'AffectedConfiguration' = $virtualSystemSettingData; 'ResourceSettings' = @($embeddedInstance) } `
                                               -ErrorAction Stop

                    if ($result.ReturnValue -ne 0 -and
                        $result.ReturnValue -ne 4096)
                    {
                        $error = CreateErrorRecord -ErrorId "InvalidOperation" `
                                                   -ErrorMessage "Operation failed with error code $($result.ReturnValue)" `
                                                   -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                                   -Exception $null `
                                                   -TargetObject $null

                        $psCmdlet.WriteError($error)
                        return
                    }

                    # Wait for the job to complete
                    if ($result.ReturnValue -eq 4096)
                    {
                        $job = $null

                        while ($true)
                        {
                            $job = Get-CimInstance -ClassName Msvm_ConcreteJob `
                                                   -CimSession $currentCimSession `
                                                   -Namespace $VirtualizationNamespace `
                                                   -Filter "InstanceID='$($result.Job.InstanceID)'" `
                                                   -ErrorAction Stop

                            if ($null -eq $job -or
                                $job.JobState -gt 4)
                            {
                                break
                            }

                            Start-Sleep -Seconds 1
                        }

                        if ($null -ne $job -and
                            $job.ErrorCode -ne 0)
                        {
                            $error = CreateErrorRecord -ErrorId "InvalidOperation" `
                                                       -ErrorMessage $job.ErrorDescription `
                                                       -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                                       -Exception $null `
                                                       -TargetObject $null

                            $psCmdlet.WriteError($error)
                            return
                        }
                    }

                    break
                }

                if (-not $found)
                {
                    $error = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                               -ErrorMessage "The operation could not be completed because no available locations were found on the disk controller." `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }
            }
        }
        finally
        {
            if ((-not $CimSessionPassed) -and
                $CimSession)
            {
                $CimSession | Remove-CimSession
                $CimSession = $null
            }
        }
    }
}

function Remove-VMDirectVirtualDisk
{
    Param
    (
        #### --------------------------------- Parameter Sets --------------------------------- ####

        [System.String]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        [ValidateNotNullOrEmpty()]
        $VMName,

        # Analog to VMHardDiskDrive parameter in Remove-VMHardDiskDrive
        [VMDirectVirtualDisk[]]
        [Parameter(
            ParameterSetName  = 'ByVirtualDisk',
            ValueFromPipeline = $true,
            Mandatory         = $true,
            Position          = 0)]
        $VirtualDisk,

        #### ----------------------------- Common Method Parameters ----------------------------- ####

        [CimSession[]]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $false)]
        $CimSession,

        [ControllerType]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $true,
            Position          = 1)]
        $ControllerType,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $true,
            Position          = 2)]
        $ControllerNumber,

        [System.Int32]
        [Parameter(
            ParameterSetName  = 'ByVMName',
            Mandatory         = $true,
            Position          = 3)]
        $ControllerLocation
    )

    Process
    {
        $CimSessionPassed = $true

        try
        {
            # Get the VM Direct virtual disks to be removed
            $vmDirectVirtualDisks = @()

            switch ($psCmdlet.ParameterSetName)
            {
                "ByVMName"
                {
                    if (!$PSBoundParameters.ContainsKey('CimSession'))
                    {
                        $CimSession       = New-CimSession -ErrorAction Stop
                        $CimSessionPassed = $false
                    }

                    $vmDirectVirtualDisks = Get-VMDirectVirtualDisk -VMName $VMName `
                                                                    -CimSession $CimSession `
                                                                    -ControllerType $ControllerType `
                                                                    -ControllerNumber $ControllerNumber `
                                                                    -ControllerLocation $ControllerLocation `
                                                                    -ErrorAction Stop
                }

                "ByVirtualDisk"
                {
                    $vmDirectVirtualDisks = $VirtualDisk
                }
            }

            # Remove the VM Direct virtual disks
            foreach ($vmDirectVirtualDisk in $vmDirectVirtualDisks)
            {
                # Get the current CIM session
                $currentCimSession = $vmDirectVirtualDisk.CimSession

                # Get the Virtual System Management Service
                $vmms = Get-CimInstance -ClassName 'Msvm_VirtualSystemManagementService' `
                                        -CimSession $currentCimSession `
                                        -Namespace $VirtualizationNamespace `
                                        -ErrorAction Stop

                if ($null -eq $vmms)
                {
                    $error = CreateErrorRecord -ErrorId "ObjectNotFound" `
                                               -ErrorMessage "Could not find Virtual System Management Service." `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }

                # Get the associated VM
                $currentVm = Get-VM -Id $vmDirectVirtualDisk.VMId `
                                    -CimSession $currentCimSession `
                                    -ErrorAction Stop

                $computerSystem = Get-CimInstance -ClassName 'Msvm_ComputerSystem' `
                                                  -CimSession $currentCimSession `
                                                  -Namespace $VirtualizationNamespace `
                                                  -Filter "Name='$($currentVm.Id)'" `
                                                  -ErrorAction Stop

                $virtualSystemSettingData = Get-CimAssociatedInstance -InputObject $computerSystem ` `
                                                                      -CimSession $currentCimSession `
                                                                      -ResultClassName 'Msvm_VirtualSystemSettingData' `
                                                                      -ErrorAction Stop

                $virtualSystemSettingData = $virtualSystemSettingData | Where-Object -FilterScript `
                                            {
                                                $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
                                            }

                # Get the associated controller
                $controller = Get-VMScsiController -VM $currentVm `
                                                   -ControllerNumber $vmDirectVirtualDisk.ControllerNumber `
                                                   -ErrorAction Stop

                $controllerResource = Get-CimAssociatedInstance -InputObject $virtualSystemSettingData `
                                                                -CimSession $currentCimSession `
                                                                -ResultClassName 'Msvm_ResourceAllocationSettingData' `
                                                                -ErrorAction Stop

                $controllerResource = $controllerResource | Where-Object -FilterScript `
                                      {
                                          $_.ResourceType -eq 6 -and
                                          $_.InstanceID   -eq $controller.Id
                                      }

                # Get the associated virtual disk
                $msftVirtualDisk = Get-VirtualDisk -UniqueId $vmDirectVirtualDisk.VirtualDiskUniqueId `
                                                   -CimSession $currentCimSession `
                                                   -ErrorAction Stop

                $poolId        = $msftVirtualDisk.ObjectId.Split('{}')[5]
                $virtualDiskId = $msftVirtualDisk.ObjectId.Split('{}')[7]

                $virtualDiskDescriptor = "{$poolId}{$virtualDiskId}"

                $lunSettingData = Get-CimAssociatedInstance -InputObject $controllerResource `
                                                            -CimSession $currentCimSession `
                                                            -ResultClassName 'Msvm_VirtualLogicalUnitSettingData' `
                                                            -ErrorAction Stop

                $lunSettingData = $lunSettingData | Where-Object -FilterScript `
                {
                    $_.Connection -eq $virtualDiskDescriptor
                }

                # Remove the virtual disk from the VM
                $result = Invoke-CimMethod -InputObject $vmms `
                                           -CimSession $currentCimSession `
                                           -MethodName 'RemoveResourceSettings' `
                                           -Arguments @{ 'ResourceSettings' = [CimInstance[]]$lunSettingData } `
                                           -ErrorAction Stop

                if ($result.ReturnValue -ne 0 -and
                    $result.ReturnValue -ne 4096)
                {
                    $error = CreateErrorRecord -ErrorId "InvalidOperation" `
                                               -ErrorMessage "Operation failed with error code $($result.ReturnValue)" `
                                               -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                               -Exception $null `
                                               -TargetObject $null

                    $psCmdlet.WriteError($error)
                    return
                }

                # Wait for the job to complete
                if ($result.ReturnValue -eq 4096)
                {
                    $job = $null

                    while ($true)
                    {
                        $job = Get-CimInstance -ClassName Msvm_ConcreteJob `
                                               -CimSession $currentCimSession `
                                               -Namespace $VirtualizationNamespace `
                                               -Filter "InstanceID='$($result.Job.InstanceID)'" `
                                               -ErrorAction Stop

                        if ($null -eq $job -or
                            $job.JobState -gt 4)
                        {
                            break
                        }

                        Start-Sleep -s 1
                    }

                    if ($null -ne $job -and
                        $job.ErrorCode -ne 0)
                    {
                        $error = CreateErrorRecord -ErrorId "InvalidOperation" `
                                                   -ErrorMessage $job.ErrorDescription `
                                                   -ErrorCategory ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
                                                   -Exception $null `
                                                   -TargetObject $null

                        $psCmdlet.WriteError($error)
                        return
                    }
                }
            }
        }
        finally
        {
            if ((-not $CimSessionPassed) -and
                $CimSession)
            {
                $CimSession | Remove-CimSession
                $CimSession = $null
            }
        }
    }
}