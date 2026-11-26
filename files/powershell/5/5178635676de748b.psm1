Import-LocalizedData -BindingVariable stringTable


#########################################################################################
# Copyright (c) Microsoft Corporation
#
# BitLocker PowerShell Module
#
#
#########################################################################################

$E_NOTFOUND = 2147943568
$E_KEYREQUIRED = 2150694941
$E_AUTOUNLOCK_ENABLED = 2150694953
$E_VOLUMEBOUND = 2150694943
$E_FAIL = 2147500037
$TPM_E_DEACTIVATED = 2150105094
$FVE_E_NOT_DECRYPTED = 2150694969
$S_FALSE = 1

$FVE_HARDWARE_TEST_NOT_FAILED_OR_PENDING = 0
$FVE_HARDWARE_TEST_FAILED = 1
$FVE_HARDWARE_TEST_PENDING = 2

$DEFAULT_DISCOVERY_VOLUME_TYPE = "<default>"

$MINIMUM_REQUIRED_RECOVERY_PROTECTORS_WITH_TPM = 2
$MINIMUM_REQUIRED_RECOVERY_PROTECTORS_WITHOUT_TPM = 3

$FVE_CONV_FLAG_DATAONLY = 1

$FVE_FORCE_ENCRYPTION_TYPE_UNSPECIFIED = 0
$FVE_FORCE_ENCRYPTION_TYPE_SOFTWARE = 1
$FVE_FORCE_ENCRYPTION_TYPE_HARDWARE = 2

$FVE_PROVISIONING_MODIFIER_USED_SPACE = 256

#########################################################################################
# Internal Function: Get-ExceptionForHrInternal
#
# Returns the COMException for a given HRESULT
#
# Ex: Get-ExceptionForHrInternal 2147942402
#
# Input: Unsigned integer - Must be a valid HRESULT
#
# Return: COMException class corresponding to the HRESULT.
#########################################################################################
function Get-ExceptionForHrInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [System.UInt32]
          $HrUInt32)
    process
    {
            $HrHexString = [string]::Format("0x{0:X}", $HrUInt32)
            $ExceptionForHr = [System.Runtime.InteropServices.Marshal]::GetExceptionForHR($HrHexString)

            $ExceptionForHr
    }
}

#########################################################################################
# Internal Function: IsNanoPowerShell
#
# Determines if this module is running on Nano PowerShell instead of full PowerShell.
#
# Return: Boolean describing the PowerShell environment.
#
#########################################################################################

function IsNanoPowerShell
{
    if ($PSEdition -eq "Core") 
    { 
        return $true
    }
    else
    {
        return $false
    }
}

#########################################################################################
# Internal Function: Decrypt-SecureStringInternal
#
# Returns a clear text string that had been protected by a SecureString.
#
# Input: SecureString - a password
#
# Return: String contained within the SecureString
#########################################################################################
function Decrypt-SecureStringInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [System.Security.SecureString]
          $SecurePassword
    )
    process
    {
        if (IsNanoPowerShell)
        {
            $intPtr = [System.Security.SecureStringMarshal]::SecureStringToCoTaskMemUnicode($SecurePassword)
            $ClearTextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($intPtr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($intPtr)
        }
        else
        {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            $ClearTextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        return $ClearTextPassword
    }
}

#########################################################################################
# Internal Function: Get-Win32EncryptableVolumeInternal
#
# Returns Win32_EncryptableVolume WMI objects that describes volume [or volumes]
#
# Ex: Get-Win32EncryptableVolumeInternal c: - returns volume information for drive c:
#     Get-Win32EncryptableVolumeInternal    - returns all volumes with volume information. Only for encryptable volumes
#
# Input: String - volume name. Could be: drive letter or volume id or a directory that corresponds to a mounted volume.
#                 This is an optional parameter.
#
# Return: WMI object [Microsoft.Management.Infrastructure.CimInstance] that is a Win32_EncryptableVolume
#########################################################################################
function Get-Win32EncryptableVolumeInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $false)]
          [string]
          $MountPoint)

    process
    {
        Write-Debug "Begin Get-Win32EncryptableVolumeInternal($MountPoint)"

        $Win32EncryptableVolumes = `
            Get-CimInstance `
                -Namespace "root\cimv2\Security\MicrosoftVolumeEncryption" `
                -ClassName Win32_EncryptableVolume

        if (!$Win32EncryptableVolumes)
        {
            Write-Debug "No Win32_EncryptableVolume objects have been returned by Get-CimInstance"
        }

        if (!$MountPoint)
        {
            #
            # MountPoint is not set so all Win32_EncryptableVolumes are returned
            #

            $Win32EncryptableVolume = $null

            Write-Debug "No Filtering of Win32_EncryptableVolumes"
        }
        elseif ($MountPoint -match "^[a-zA-Z]$" -or $MountPoint -match "^[a-zA-Z]:$" -or $MountPoint -match "^[a-zA-Z]:\$")
        {
            #
            # MountPoint is a drive letter followed by an optional colon with an optional slash. ex: "c" or "c:" or "c:\"
            #
            $DriveLetter = $MountPoint.TrimEnd("\")
            if (!$DriveLetter.EndsWith(":"))
            {
                $DriveLetter = $DriveLetter + ":"  # WMI needs to have the colon at the end
            }

            Write-Debug "Filtering Win32_EncryptableVolumes by $DriveLetter"

            $Win32EncryptableVolume = $Win32EncryptableVolumes | where {$_.DriveLetter -eq $DriveLetter}

            #If there is no encryptable volume then fall through and report the error
        }
        elseif ($MountPoint -match "^\\\\\?\\Volume\{[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\}\\$")
        {
            # 
            # MountPoint is a device id. An example of a valid device id is: \\?\Volume{cb96dd9a-4f54-11e0-8d6c-806e6f6e6963}\
            #
            $DeviceId = $MountPoint

            Write-Debug "Filtering Win32_EncryptableVolumes by $DeviceId"

            $Win32EncryptableVolume = $Win32EncryptableVolumes | where {$_.DeviceId -eq $DeviceId}

            #If there is no encryptable volume then fall through and report the error
        }
        else
        {
            #
            # MountPoint is a directory that is mounted to a volume. Get the volume that it belongs to.
            #

            $MsftVolume = Get-Volume -FilePath $MountPoint

            if (!$MsftVolume)
            {
                Write-Debug "No volume can be found mounted at $MountPoint"
                # Fall through and report error
            }
            else
            {
                $DeviceId = $MsftVolume.UniqueId
 
                Write-Debug "Volume at $MountPoint has Device Id $DeviceId. Filtering Win32_EncryptableVolumes by this Device Id."
            
                $Win32EncryptableVolume = $Win32EncryptableVolumes | where {$_.DeviceID -eq $DeviceId}
            }
        }


        if ($Win32EncryptableVolume)
        {
            $Win32EncryptableVolume
            Write-Debug "End Get-Win32EncryptableVolumeInternal. Return $Win32EncryptableVolume"
        }
        elseif (!$MountPoint -and $Win32EncryptableVolumes)
        {
            # $null for $MountPoint means return all encryptable volumes
            $Win32EncryptableVolumes
            Write-Debug "End Get-Win32EncryptableVolumeInternal. Return $Win32EncryptableVolumes"
        }
        else
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_NOTFOUND
            $ErrorMessage = [string]::Format($stringTable.ErrorMountPointNotFound, $MountPoint)
            Write-Error -Exception $ExceptionForHr -Message $ErrorMessage
        }
    }
}

#########################################################################################
# Internal Function: Read-UserSecretInternal
#
# Returns a single SecureString that is a secret [password or pin] entered
# by the user. This secret is confirmed by requiring the user to enter it
# twice and verifying that they are the same.
#
# If the two secrets are not the same then we re-prompt the user for both secrets.
# 
# Ex: Read-UserSecretInternal -Message "Enter Password:" -ConfirmMessage "Confirm Password:" -NotMatchMessage "Passwords do not match. Re-enter"
#
# Input: Message String - Output to user to enter the secret
#        Confirm Message String - Output to user to confirm secret
#        NotMessage Message String - Output to the user if the two secrets 
#                                    do not match
#
# Return: One of the SecureStrings that the user entered.
#########################################################################################
function Read-UserSecretInternal
{
    
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $Message,

          [Parameter(Position = 1, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $ConfirmMessage,

          [Parameter(Position = 2, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $NotMatchMessage)

    process
    {

        #
        # Break out of this loop when the two secrets entered by the user
        # match
        #
        while ($true) 
        {
            Write-Host $Message -NoNewLine
            $Secret1 = Read-Host -AsSecureString
            Write-Host $ConfirmMessage -NoNewLine
            $Secret2 = Read-Host -AsSecureString


            $ClearTextPassword1 = Decrypt-SecureStringInternal $Secret1
            $ClearTextPassword2 = Decrypt-SecureStringInternal $Secret2

            if ($ClearTextPassword1 -eq $ClearTextPassword2)
            {
                break
            }

            #
            # The two secrets don't match so tell the user and ask user again
            #

            Write-Host $NotMatchMessage
        }

        # Clear the clear text password strings.
        $ClearTextPassword1 = ""
        $ClearTextPassword1 = ""

        return $Secret1
    }

}

#########################################################################################
# Internal Function: Get-BitLockerVolumeInternal
#
# Returns a single BitLockerVolume structure that describes a volume
#
# Ex: Get-BitLockerVolumeInternal c: - returns volume information for drive c:
#
# Input: String - volume name. Could be: drive letter or volume id
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume
#########################################################################################
function Get-BitLockerVolumeInternal
{
    
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint)
    process
    {
        Write-Debug "Begin Get-BitLockerVolumeInternal($MountPoint)"

        $FREE_SPACE_WIPE_IN_PROGRESS     = 2
        $FREE_SPACE_WIPE_SUSPENDED       = 3
        $BYTES_IN_GIGABYTE               = 1024*1024*1024

        #######
        # Get Win32_EncryptableVolume
        #######

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        if (!$Win32EncryptableVolume)
        {
            Write-Debug "The following operation failed: Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint"
            return
        }

        #######
        # Get MSFT_Volume associated with Win32_EncryptableVolume.
        # Use Win32_EncryptableVolume.DeviceID
        #######

        $WmiVolumeFilter = "UniqueID = '$($Win32EncryptableVolume.DeviceID.Replace("\", "\\"))'"
        $MsftVolume =  Get-CimInstance MSFT_Volume -NameSpace 'Root\Microsoft\Windows\Storage' -Filter $WmiVolumeFilter
        if (!$MsftVolume)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_NOTFOUND
            $ErrorMessage = [string]::Format($stringTable.ErrorVolumeNotFound, $Win32EncryptableVolume.DeviceId)
            Write-Error -Exception $ExceptionForHr -Message $ErrorMessage

            Write-Debug "Filter: $WmiVolumeFilter"
            return
        }

        #
        # This matches WMI .Net's $Win32EncryptableVolume.__SERVER. 
        # MI .Net exposes $Win32EncryptableVolume.CimSystemProperties.ServerName as "localhost"
        #
        $ComputerName = $env:computername 

        #
        # Overwrite the passed in $MountPoint parameter with the the info from Win32_EncryptableVolume
        #
        if ($Win32EncryptableVolume.DriveLetter)
        {
            $MountPoint = $Win32EncryptableVolume.DriveLetter
        }
        else
        {
            $MountPoint = $Win32EncryptableVolume.DeviceID
        }

        #######
        # Get LockStatus. Win32_EncryptableVolume::GetLockStatus
        #######

        $LockStatusResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetLockStatus
        if ($LockStatusResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $LockStatusResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return
        }
        $LockStatus = $LockStatusResult.LockStatus

        Write-Debug "ComputerName: $ComputerName. MountPoint: $MountPoint. LockStatus: $LockStatus"
        
        #######
        # Get EncryptionMethod. Win32_EncryptableVolume::GetEncryptionMethod
        #######

        $EncryptionMethodResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetEncryptionMethod
        if ($EncryptionMethodResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $EncryptionMethodResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return
        }
        $EncryptionMethod = $EncryptionMethodResult.EncryptionMethod

        Write-Debug "EncryptionMethod: $EncryptionMethod"

        #######
        # Get EncryptionMethodFlags. Win32_EncryptableVolume::GetEncryptionMethodFlags
        #######

        $EncryptionMethodFlags = $EncryptionMethodResult.EncryptionMethodFlags

        Write-Debug "EncryptionMethodFlags: $EncryptionMethodFlags"

        #######
        # AutoUnlock. Win32_EncryptableVolume::IsAutoUnlockEnabled
        # This will determine if autounlock is enabled for the volume and what the
        # protector id is. This is relevant only for data volumes.
        # Failure is ok. It means the setting does not apply to this volume.
        #######

        $AutoUnlockEnabledResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName IsAutoUnlockEnabled
        $AutoUnlockKeyProtectorId = $null

        if ($AutoUnlockEnabledResult.ReturnValue -ne 0)
        {
            Write-Debug "Win32EncryptableVolume.IsAutoUnlockEnabled() returned error $AutoUnlockEnabledResult.ReturnValue"
            $AutoUnlockEnabled = $null
        }
        else
        {
            $AutoUnlockEnabled = $AutoUnlockEnabledResult.IsAutoUnlockEnabled
            if ($AutoUnlockEnabled -eq $true)
            {
                $AutoUnlockKeyProtectorId = $AutoUnlockEnabledResult.VolumeKeyProtectorID
            }
        }

        Write-Debug "AutoUnlockEnabled: $AutoUnlockEnabled. AutoUnlockKeyProtectorId: $AutoUnlockKeyProtectorId"

        #######
        # AutoUnlockKeyStored. Win32_EncryptableVolume::IsAutoUnlockKeyStored
        # This will determine if autounlock keys are stored in the volume.
        # This is only applicable to OS volumes.
        # Failure is ok. It means the setting does not apply to this volume.
        #######

        $AutoUnlockKeyStoredResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName IsAutoUnlockKeyStored
        if ($AutoUnlockKeyStoredResult.ReturnValue -ne 0)
        {
            Write-Debug "Win32EncryptableVolume.IsAutoUnlockKeyStored() returned error $AutoUnlockKeyStoredResult.ReturnValue"
            $AutoUnlockKeyStored = $null
        }
        else
        {
            $AutoUnlockKeyStored = $AutoUnlockKeyStoredResult.IsAutoUnlockKeyStored
        }

        Write-Debug "AutoUnlockKeyStored: $AutoUnlockKeyStored"

        #######
        # Get MetaDataVersion. Win32_EncryptableVolume::GetVersion()
        #######

        $MetaDataVersionResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetVersion
        if ($MetaDataVersionResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $MetaDataVersionResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return
        }
        $MetaDataVersion = $MetaDataVersionResult.Version
        Write-Debug "MetaDataVersion: $MetaDataVersion"


        #######
        # Get ConversionStatus, WipingStatus, EncryptionPercentage, WipePercentage.
        # Win32_EncryptableVolume::GetConversionStatus()
        # We make these calls only on unlocked volumes. Otherwise, the values are initialized to $null
        #######

        if ($LockStatus -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeLockStatus]::Unlocked)
        {
            $ConversionStatusResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetConversionStatus
            if ($ConversionStatusResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $ConversionStatusResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return
            }
            $ConversionStatus      = $ConversionStatusResult.ConversionStatus
            $WipingStatus          = $ConversionStatusResult.WipingStatus
            $EncryptionPercentage  = $ConversionStatusResult.EncryptionPercentage
            $WipePercentage        = $ConversionStatusResult.WipingPercentage
            Write-Debug "ConversionStatus: $ConversionStatus. WipingStatus: $WipingStatus. EncryptionPercentage: $EncryptionPercentage. WipePercentage: $WipePercentage"

        
            if ($ConversionStatus -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::FullyEncrypted -and $WipingStatus -eq $FREE_SPACE_WIPE_IN_PROGRESS)
            {
                $VolumeStatus = [Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::FullyEncryptedWipeInProgress
            }
            elseif ($ConversionStatus -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::FullyEncryptedWipeInProgress -and $WipingStatus -eq $FREE_SPACE_WIPE_SUSPENDED)  
            {
                $VolumeStatus = [Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::FullyEncryptedWipeSuspended
            }
            else
            {
                $VolumeStatus = $ConversionStatus
            }
        }
        else
        {
            $ConversionStatus      = $null
            $WipingStatus          = $null
            $VolumeStatus          = $null
            $WipePercentage        = $null
            $EncryptionPercentage  = $null
        }

        #######
        # Get ProtectionStatus
        # Win32_EncryptableVolume::GetProtectionStatus()
        #######

        $ProtectionStatusResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetProtectionStatus
        if ($ProtectionStatusResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $ProtectionStatusResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return
        }
        $ProtectionStatus = $ProtectionStatusResult.ProtectionStatus
        Write-Debug "ProtectionStatus: $ProtectionStatus."
        
        #######
        # Get VolumeType [OS, Data] and capacity from MSFT_Volume
        #######

        if ($MsftVolume.DriveLetter -eq $env:SystemDrive[0])
        {
            $VolumeType = [Microsoft.BitLocker.Structures.BitLockerVolumeType]::OperatingSystem
        }
        else
        {
            $VolumeType = [Microsoft.BitLocker.Structures.BitLockerVolumeType]::Data
        }

        $CapacityGB = $MsftVolume.Size / $BYTES_IN_GIGABYTE

        Write-Debug "VolumeType: $VolumeType. CapacityGB: $CapacityGB"

        #######
        # Get list of key protector ids Win32_EncryptableVolume::GetKeyProtectors
        # For each key protector id we do:
        #   - Get key protector type Win32_EncryptableVolume::GetKeyProtectorType
        #   - For Unlocked volumes we also get extra data for external key, numerical password
        #     and public key, and tpm network key.
        #######


        $KeyProtectorIdsResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectors
        if ($KeyProtectorIdsResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorIdsResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return
        }
        $KeyProtectorIds = $KeyProtectorIdsResult.VolumeKeyProtectorID
        Write-Debug "KeyProtectorIds: $KeyProtectorIds"
        
        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtector[]]$KeyProtectors = $null
        for ($i=0; $i -lt $KeyProtectorIds.Length; $i++)
        {
            $KeyProtectorId               = $KeyProtectorIds[$i]
            $KeyProtectorTypeResult       = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectorType -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}
            if ($KeyProtectorTypeResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorTypeResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return
            }
            $KeyProtectorType             = $KeyProtectorTypeResult.KeyProtectorType

            Write-Debug "KeyProtector[$i] = KeyProtectorId: $KeyProtectorId. KeyProtectorType: $KeyProtectorType"

            $KeyProtectorFileName         = $null
            $KeyProtectorRecoveryPassword = $null
            $KeyProtectorThumbprint       = $null
            $KeyProtectorCertificateType  = $null
            $AutoUnlockProtector          = $null   # true or false only for external key protector type
        

            if ($LockStatus -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeLockStatus]::Unlocked)
            {

                if ($KeyProtectorType -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::ExternalKey)
                {
                    $KeyProtectorFileNameResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetExternalKeyFileName -Arguments @{VolumeKeyProtectorID = $keyProtectorId}
                    if ($KeyProtectorFileNameResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorFileNameResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        return
                    }
                    $KeyProtectorFileName = $KeyProtectorFileNameResult.FileName

                    if ($AutoUnlockKeyProtectorId -ne $null)
                    {
                        if ($AutoUnlockKeyProtectorId -eq $KeyProtectorId)
                        {
                            $AutoUnlockProtector = $true
                        }
                        else
                        {
                            $AutoUnlockProtector = $false
                        }
                    }  
                    Write-Debug "KeyProtectorFileName: $KeyProtectorFileName. AutoUnlockProtector: $AutoUnlockProtector"

                }
                elseif ($KeyProtectorType -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::RecoveryPassword)
                {
                    $KeyProtectorRecoveryPasswordResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectorNumericalPassword -Arguments @{VolumeKeyProtectorID = $keyProtectorId}
                    if ($KeyProtectorRecoveryPasswordResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorRecoveryPasswordResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        return
                    }
                    $KeyProtectorRecoveryPassword = $KeyProtectorRecoveryPasswordResult.NumericalPassword
                    Write-Debug "KeyProtectorRecoveryPassword found"
                }
                elseif ($KeyProtectorType -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::PublicKey -or $KeyProtectorType -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmNetworkKey)
                {
                    $KeyProtectorCertificateResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectorCertificate -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}
                    if ($KeyProtectorCertificateResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorCertificateResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        return
                    }
                    $KeyProtectorThumbprint = $KeyProtectorCertificateResult.CertThumbprint
                    $KeyProtectorCertificateType = $KeyProtectorCertificateResult.CertType
                    Write-Debug "KeyProtectorThumbprint: $KeyProtectorThumbprint. KeyProtectorCertificateType: $KeyProtectorCertificateType"
                }

            }

            $KeyProtector = new-object Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtector -argumentlist $KeyProtectorId,$AutoUnlockProtector,$KeyProtectorType,$KeyProtectorFileName,$KeyProtectorRecoveryPassword,$KeyProtectorCertificateType,$KeyProtectorThumbprint
            $KeyProtectors = $KeyProtectors + $KeyProtector
        }
        

        $BitLockerVolume = new-object Microsoft.BitLocker.Structures.BitLockerVolume -argumentlist $ComputerName, $MountPoint, $EncryptionMethod, $EncryptionMethodFlags, $AutoUnlockEnabled, $AutoUnlockKeyStored, $MetaDataVersion, $VolumeStatus, $ProtectionStatus, $LockStatus, $EncryptionPercentage, $WipePercentage, $VolumeType, $CapacityGB, $KeyProtectors

        $BitLockerVolume
        Write-Debug "End Get-BitLockerVolumeInternal. Return $BitLockerVolume"
    }
}

#########################################################################################
# Get-BitLockerVolume
#
# Returns BitLockerVolume structures that describes a volume [or volumes]
#
# Ex: Get-BitLockerVolume c: - returns volume information for drive c:
#     Get-BitLockerVolume    - returns volume information for all volumes that are encryptable
#
# Input: String[] - array of volume names. Could be: drive letter or volume id or mounted directory
#                   This is an optional input parameter.
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Get-BitLockerVolume
{

    [CmdletBinding()]
    Param(
          [Parameter(Position = 0, Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [string[]]
          $MountPoint)

    process
    {
        Write-Debug "Begin Get-BitLockerVolume($MountPoint)"

        if ($MountPoint)
        {
            $MountPoint | ForEach-Object -process {Get-BitLockerVolumeInternal -MountPoint $_}
        }
        else
        {
            $AllWin32EncryptableVolume = Get-Win32EncryptableVolumeInternal
            $AllWin32EncryptableVolume | ForEach-Object -process { if ($_.DriveLetter) {Get-BitLockerVolumeInternal -MountPoint $_.DriveLetter} else {Get-BitLockerVolumeInternal -MountPoint $_.DeviceId} }
        }
        
        Write-Debug "End Get-BitLockerVolume"
    }

}

#########################################################################################
# Suspend-BitLocker
#
# Returns BitLockerVolume structures that describes the volumes which have been suspended.
# Suspended means that the key protectors have been disabled. The drive contents are still
# encrypted and if encryption or decryption is in progress then this cmdlet will not change
# that. To stop the encryption or decryption process you need to call the WMI method
# PauseConversion.
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#        RebootCount - Number of reboots until the volume has its key protectors re-enabled. 0 means 
#                      never enable key protectors automatically after a reboot. You need to Resume-BitLocker.
#                      For data volumes, it doesn't make sense to specify a value; if you do the WMI layer
#                      returns an error. For OS volumes, the default
#                      is determined by the WMI layer which is 1.
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Suspend-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]

    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $false)]
          [ValidateRange(0,15)]
          [int]
          $RebootCount = -1)

    process
    {
       Write-Debug "Begin Suspend-BitLocker($MountPoint, $RebootCount)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point whose protectors
       # can be disabled then the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume     =  Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                if ($RebootCount -ne -1)
                {
                    $DisableKeyProtectorsResult =  Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DisableKeyProtectors -Arguments @{DisableCount = [uint32]$RebootCount}
                }
                else
                {
                    $DisableKeyProtectorsResult =  Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DisableKeyProtectors
                }

                if ($DisableKeyProtectorsResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $DisableKeyProtectorsResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can be suspended"
        }

        Write-Debug "End Suspend-BitLocker. Return $BitLockerVolume"
    }
}

#########################################################################################
# Resume-BitLocker
#
# Returns BitLockerVolume structures that describes the volumes which have been resumed.
# Resumed means that the key protectors have been enabled. The drive contents are still
# encrypted and if encryption or decryption is paused then this cmdlet will not change
# that. To resume the encryption or decryption process you need to call the WMI method 
# ResumeConversion.
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Resume-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint)
    process
    {
       Write-Debug "Begin Resume-BitLocker($MountPoint)"

       <#
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point whose protectors
       # can be disabled then the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #>
       [string[]]$ValidMountPoint = $null


       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume     =  Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                $EnableKeyProtectorsResult  =  Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName EnableKeyProtectors

                if ($EnableKeyProtectorsResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $EnableKeyProtectorsResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }

        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can be resumed"
        }


        Write-Debug "End Resume-BitLocker. Return $BitLockerVolume"
    }
}

#########################################################################################
# Lock-BitLocker
#
# Returns BitLockerVolume structures that describes the volumes which have been locked.
# Locked means volume is dismounted and the volume's encryption key is removed from system memory.
# The contents of the volume remain inacessible until it is unlocked.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        Bool          - ForceDismount flag. If $true the disk is forcefully dismounted
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Lock-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Mandatory = $false)]
          [Alias("fd")]
          [System.Management.Automation.SwitchParameter]
          $ForceDismount = $false)

    process
    {
       Write-Debug "Begin Lock-BitLocker($MountPoint)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume  =  Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                $LockResult              =  Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName Lock -Arguments @{ForceDismount = $ForceDismount.IsPresent}

                if ($LockResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $LockResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can be locked"
        }

        Write-Debug "End Lock-BitLocker. Return $BitLockerVolume"
    }
}

#########################################################################################
# Unlock-PasswordInternal
#
# Returns BitLockerVolume structure that describes the volume after it was unlocked
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        SecureString     - password to use for unlocking
#
# Return: 0 for success
#########################################################################################
function Unlock-PasswordInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [System.Security.SecureString]
          $Password
    )
    process
    {
        Write-Debug "Begin Unlock-PasswordInternal"

        #
        # Convert secure string to cleartext.
        #

        $ClearTextPassword = Decrypt-SecureStringInternal $Password

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $UnlockResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName UnlockWithPassphrase -Arguments @{PassPhrase = $ClearTextPassword}

        # Clear the clear text password string
        $ClearTextPassword = ""

        if ($UnlockResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $UnlockResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $UnlockResult.ReturnValue
        }

        Write-Debug "End Unlock-PasswordInternal"

        return 0
    }
}

#########################################################################################
# Unlock-RecoveryPasswordInternal
#
# Returns BitLockerVolume structure that describes the volume after it was unlocked
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        String           - recovery password to use for unlocking
#
# Return: 0 for success
#########################################################################################
function Unlock-RecoveryPasswordInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [string]
          $RecoveryPassword
    )
    process
    {
        Write-Debug "Begin Unlock-RecoveryPasswordInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $UnlockResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName UnlockWithNumericalPassword -Arguments @{NumericalPassword = $RecoveryPassword}

        if ($UnlockResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $UnlockResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $UnlockResult.ReturnValue
        }

        Write-Debug "End Unlock-RecoveryPasswordInternal"

        return 0
    }
}

#########################################################################################
# Unlock-RecoveryKeyInternal
#
# Returns BitLockerVolume structure that describes the volume after it was unlocked
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        String           - recovery key to use for unlocking
#
# Return: 0 for success
#########################################################################################
function Unlock-RecoveryKeyInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [string]
          $RecoveryKeyPath
    )
    process
    {
        Write-Debug "Begin Unlock-RecoveryKeyInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint

        $GetExternalKeyFromFileResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetExternalKeyFromFile -Arguments @{PathWithFileName = $RecoveryKeyPath}

        if ($GetExternalKeyFromFileResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $GetExternalKeyFromFileResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $GetExternalKeyFromFileResult.ReturnValue
        }

        $UnlockResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName UnlockWithExternalKey -Arguments @{ExternalKey = $GetExternalKeyFromFileResult.ExternalKey}

        if ($UnlockResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $UnlockResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $UnlockResult.ReturnValue
        }

        Write-Debug "End Unlock-RecoveryKeyInternal"

        return 0
    }
}

#########################################################################################
# Unlock-BitLocker
#
# Returns BitLockerVolume structures that describes the volumes which have been unlocked.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        Protector     - protector to use for unlocking
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Unlock-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          #
          # Password Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="OnlyPasswordParameterSet")]
          [Alias("pw")]
          [System.Security.SecureString]
          $Password,

          #
          # Recovery Password Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="OnlyRecoveryPasswordParameterSet")]
          [ValidateNotNullOrEmpty()]
          [Alias("rp")]
          [String]
          $RecoveryPassword,

          #
          # Recovery Key Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="OnlyRecoveryKeyParameterSet")]
          [ValidateNotNullOrEmpty()]
          [Alias("rk")]
          [String]
          $RecoveryKeyPath,

          #
          # Ad Account Or Group Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="OnlyAdAccountOrGroupParameterSet")]
          [System.Management.Automation.SwitchParameter]
          $AdAccountOrGroup
    )

    process
    {
       Write-Debug "Begin Unlock-BitLocker($MountPoint)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                if ($PsCmdlet.ParameterSetName -eq "OnlyPasswordParameterSet")
                {
                    $Result = Unlock-PasswordInternal $BitLockerVolumeInternal.MountPoint $Password
                }
                elseif ($PsCmdlet.ParameterSetName -eq "OnlyRecoveryPasswordParameterSet")
                {
                    $Result = Unlock-RecoveryPasswordInternal $BitLockerVolumeInternal.MountPoint $RecoveryPassword
                }
                elseif ($PsCmdlet.ParameterSetName -eq "OnlyRecoveryKeyParameterSet")
                {
                    $Result = Unlock-RecoveryKeyInternal $BitLockerVolumeInternal.MountPoint $RecoveryKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "OnlyAdAccountOrGroupParameterSet")
                {
                    $Result = Unlock-AdAccountOrGroupInternal $BitLockerVolumeInternal.MountPoint
                }

                if ($Result -ne 0)
                {
                    Write-Debug "Unlock-BitLocker failed for $BitLockerVolumeInternal.MountPoint"
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can be unlocked"
        }

        Write-Debug "End Unlock-BitLocker. Return $BitLockerVolume"
    }
}

#########################################################################################
# Add-RecoveryPasswordProtectorInternal
#
# Returns BitLockerVolume structure that describes the volume with the new recovery password protector
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        RecoveryPassword - recovery password protector to add. Can be empty.
#
# Return: 0 for success
#########################################################################################
function Add-RecoveryPasswordProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $false)]
          [string]
          $RecoveryPassword,

          [Parameter(Mandatory = $false)]
          [System.Management.Automation.SwitchParameter]
          $SuppressWarningMessage = $false
    )
    process
    {
        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint

        if ($RecoveryPassword -eq "")
        {
            $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithNumericalPassword -Arguments @{FriendlyName = $null; NumericalPassword = $null}
        }
        else
        {
            $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithNumericalPassword -Arguments @{FriendlyName = $null; NumericalPassword = $RecoveryPassword}
        }

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        if (!$SuppressWarningMessage)
        {
            $KeyProtectorId = $AddKeyProtectorResult.VolumeKeyProtectorID

            $RecoveryPasswordResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectorNumericalPassword -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}
            if ($RecoveryPasswordResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $RecoveryPasswordResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return $RecoveryPasswordResult.ReturnValue
            }
            $RecoveryPassword = $RecoveryPasswordResult.NumericalPassword
            Write-Debug "RecoveryPassword added"

            $Message = [string]::Format($stringTable.WarningWriteDownRecoveryPassword, $RecoveryPassword, [Environment]::NewLine)
            Write-Warning $Message
        }

        return 0
    }
}

#########################################################################################
# Add-PasswordProtectorInternal
#
# Adds a passphrase protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        SecureString     - password
#
# Return: 0 for success
#########################################################################################
function Add-PasswordProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $false)]
          [System.Security.SecureString]
          $Password
    )
    process
    {
        if ($Password -eq $null)
        {
            $Password = Read-UserSecretInternal -Message $stringTable.PasswordPrompt -ConfirmMessage $stringTable.ConfirmPasswordPrompt -NotMatchMessage $stringTable.NoMatchPassword
        }

        #
        # Convert secure string to cleartext.
        #
        $ClearTextPassword = Decrypt-SecureStringInternal $Password

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithPassphrase -Arguments @{FriendlyName = $null; PassPhrase = $ClearTextPassword}

        # Clear the clear text password string
        $ClearTextPassword = ""

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        return 0
    }
}

#########################################################################################
# Remove-KeyProtectorByTypeInternal
#
# Deletes one key protector of the type specified by $ProtectorType
#
# Input: String - volume name. Could be: drive letter or volume id or mounted directory
#        uint32 - protector type of protector that is to be deleted
#
# Return: 0 for success
#########################################################################################
function Remove-KeyProtectorByTypeInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]
          $ProtectorType
    )
    process
    {
        #
        # Get key protectors of type $ProtectorType
        #

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $KeyProtectorIdsResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetKeyProtectors -Arguments @{KeyProtectorType = [uint32]$ProtectorType}

        if ($KeyProtectorIdsResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $KeyProtectorIdsResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $KeyProtectorIdsResult.ReturnValue
        }
        if ($KeyProtectorIdsResult.VolumeKeyProtectorID.Count -ne 1)
        {
            #
            # Return success
            #

            return 0
        }

        $Result = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $KeyProtectorIdsResult.VolumeKeyProtectorID[0]}
        if ($Result.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        return 0
    }
}

#########################################################################################
# Add-TpmProtectorInternal
#
# Adds a TPM protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#
# Return: 0 for success
#########################################################################################
function Add-TpmProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint
    )
    process
    {
        Write-Debug "Begin Add-TpmProtectorInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithTPM -Arguments @{FriendlyName = $null; PlatformValidationProfile = $null}

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        #
        # Delete all other TPM based protectors
        #

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPin
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPinStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        Write-Debug "End Add-TpmProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-TpmAndPinProtectorInternal
#
# Adds a TPMAndPin protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        SecureString     - Pin
#
# Return: 0 for success
#########################################################################################
function Add-TpmAndPinProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $false)]
          [System.Security.SecureString]
          $Pin
    )
    process
    {
        Write-Debug "Begin Add-TpmAndPinProtectorInternal"

        if ($Pin -eq $null)
        {
            $Pin = Read-UserSecretInternal -Message $stringTable.PinPrompt -ConfirmMessage $stringTable.ConfirmPinPrompt -NotMatchMessage $stringTable.NoMatchPin
        }

        #
        # Convert secure string to cleartext.
        #
        $ClearTextPin = Decrypt-SecureStringInternal $Pin

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithTPMAndPin -Arguments @{FriendlyName = $null; PlatformValidationProfile = $null; PIN = $ClearTextPin}

        # Clear the clear text pin
        $ClearTextPin = ""

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        #
        # Delete all other TPM based protectors
        #

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint Tpm
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPinStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        Write-Debug "End Add-TpmAndPinProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-TpmAndStartupKeyProtectorInternal
#
# Adds a TPMAndStartupKey protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        String           - Startup Key path
#
# Return: 0 for success
#########################################################################################
function Add-TpmAndStartupKeyProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [String]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [String]
          $StartupKeyPath
    )
    process
    {
        Write-Debug "Begin Add-TpmAndStartupKeyProtectorInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithTPMAndStartupKey -Arguments @{ExternalKey = $null; FriendlyName = $null; PlatformValidationProfile = $null}

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        $SaveExternalKeyResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName SaveExternalKeyToFile -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorId; Path = $StartupKeyPath}
        if ($SaveExternalKeyResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $SaveExternalKeyResult.ReturnValue
            Write-Error -Exception $ExceptionForHr

            #
            # Remove previously added protector
            #

            $r = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorID}

            return $SaveExternalKeyResult.ReturnValue
        }

        #
        # Delete all other TPM based protectors
        #

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint Tpm
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPin
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPinStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        Write-Debug "End Add-TpmAndStartupKeyProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-TpmAndPinAndStartupKeyProtectorInternal
#
# Adds a TPMAndPinAndStartupKey protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        SecureString     - Pin
#        String           - Startup Key path
#
# Return: 0 for success
#########################################################################################
function Add-TpmAndPinAndStartupKeyProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [String]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [String]
          $StartupKeyPath,

          [Parameter(Position = 2, Mandatory = $false)]
          [System.Security.SecureString]
          $Pin
    )
    process
    {
        Write-Debug "Begin Add-TpmAndPinAndStartupKeyProtectorInternal"

        if ($Pin -eq $null)
        {
            $Pin = Read-UserSecretInternal -Message $stringTable.PinPrompt -ConfirmMessage $stringTable.ConfirmPinPrompt -NotMatchMessage $stringTable.NoMatchPin
        }

        #
        # Convert secure string to cleartext.
        #
        $ClearTextPin = Decrypt-SecureStringInternal $Pin

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithTPMAndPinAndStartupKey -Arguments @{ExternalKey = $null; FriendlyName = $null; PIN = $ClearTextPin; PlatformValidationProfile = $null}

        # Clear the clear text pin
        $ClearTextPin = ""

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        $SaveExternalKeyResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName SaveExternalKeyToFile -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorId; Path = $StartupKeyPath}
        if ($SaveExternalKeyResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $SaveExternalKeyResult.ReturnValue
            Write-Error -Exception $ExceptionForHr

            #
            # Remove previously added protector
            #

            $r = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorID}

            return $SaveExternalKeyResult.ReturnValue
        }

        #
        # Delete all other TPM based protectors
        #

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint Tpm
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmPin
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        $Result = Remove-KeyProtectorByTypeInternal $MountPoint TpmStartupKey
        if ($Result -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $Result
            Write-Error -Exception $ExceptionForHr
            return $Result.ReturnValue
        }

        Write-Debug "End Add-TpmAndPinAndStartupKeyProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-ExternalKeyProtectorInternal
#
# Adds an ExternalKey protector to a volume (Startup Key, Recovery Key)
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        String           - External Key path
#
# Return: 0 for success
#########################################################################################
function Add-ExternalKeyProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [String]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [String]
          $ExternalKeyPath
    )
    process
    {
        Write-Debug "Begin Add-ExternalKeyProtectorInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithExternalKey -Arguments @{ExternalKey = $null; FriendlyName = $null}

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        $SaveExternalKeyResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName SaveExternalKeyToFile -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorId; Path = $ExternalKeyPath}
        if ($SaveExternalKeyResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $SaveExternalKeyResult.ReturnValue
            Write-Error -Exception $ExceptionForHr

            #
            # Remove previously added protector
            #

            $r = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $AddKeyProtectorResult.VolumeKeyProtectorID}

            return $SaveExternalKeyResult.ReturnValue
        }

        Write-Debug "End Add-ExternalKeyProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-SidProtectorInternal
#
# Adds a SID protector to a volume
#
# Input: String           - volume name. Could be: drive letter or volume id or mounted directory
#        String           - SID
#
# Return: 0 for success
#########################################################################################
function Add-SidProtectorInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [String]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true)]
          [String]
          $Sid,

          [Parameter(Position = 2, Mandatory = $true)]
          [bool]
          $Service
    )
    process
    {
        Write-Debug "Begin Add-SidProtectorInternal"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint

        $flags = 0
        if ($Service -eq $true)
        {
            $flags = 1 # 1 means FVE_DPAPI_NG_FLAG_UNLOCK_AS_SERVICE_ACCOUNT
        }

        $User = [System.Security.Principal.NTAccount]($Sid)

        try
        {
            $SidStr = $User.Translate([System.Security.Principal.SecurityIdentifier])
        }
        catch
        {
            #
            # Failed to translate, so try to use what the user gave us
            #

            try
            {
                $SidStr = [System.Security.Principal.SecurityIdentifier]($Sid)
            }
            catch
            {
                Write-Error -Exception $_.Exception
                return 1
            }
        }

        $AddKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithAdSid -Arguments @{FriendlyName = $null; SidString = $SidStr.Value; Flags = [uint32]$flags}

        if ($AddKeyProtectorResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $AddKeyProtectorResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $AddKeyProtectorResult.ReturnValue
        }

        Write-Debug "End Add-SidProtectorInternal"

        return 0
    }
}

#########################################################################################
# Add-BitLockerKeyProtector
#
# Returns BitLockerVolume structures that describe the volumes with the new protector.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        KeyProtector  - key protector to add
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Add-BitLockerKeyProtector
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          # 
          # Password Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="PasswordProtector")]
          [Alias("pwp")]
          [System.Management.Automation.SwitchParameter]
          $PasswordProtector,

          [Parameter(Mandatory = $false, ParameterSetName="PasswordProtector", Position = 1)]
          [Alias("pw")]
          [System.Security.SecureString]
          $Password,

          # 
          # Recovery Password Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryPasswordProtector")]
          [Alias("rpp")]
          [System.Management.Automation.SwitchParameter]
          $RecoveryPasswordProtector,

          [Parameter(Mandatory = $false, ParameterSetName="RecoveryPasswordProtector", Position = 1)]
          [ValidateNotNullOrEmpty()]
          [Alias("rp")]
          [String]
          $RecoveryPassword,

          # 
          # Startup Key Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="StartupKeyProtector")]
          [Alias("skp")]
          [System.Management.Automation.SwitchParameter]
          $StartupKeyProtector,

          [Parameter(Mandatory = $true, ParameterSetName="StartupKeyProtector", Position = 1)]
          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 1)]
          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector", Position = 1)]
          [Alias("sk")]
          [String]
          $StartupKeyPath,

          # 
          # Sid Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="SidProtector")]
          [Alias("sidp")]
          [System.Management.Automation.SwitchParameter]
          $ADAccountOrGroupProtector,

          [Parameter(Mandatory = $true, ParameterSetName="SidProtector", Position = 1)]
          [Alias("sid")]
          [String]
          $ADAccountOrGroup,

          [Parameter(Mandatory = $false, ParameterSetName="SidProtector")]
          [System.Management.Automation.SwitchParameter]
          $Service,

          # 
          # TPM And Pin And StartupKey Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector")]
          [Alias("tpskp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndPinAndStartupKeyProtector,

# Defined in the StartupKeyProtector section above
#          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 1)]
#          [String]
#          $StartupKeyPath,

          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 2)]
          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinProtector", Position = 1)]
          [Alias("p")]
          [System.Security.SecureString]
          $Pin,


          # 
          # TPM And Pin Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinProtector")]
          [Alias("tpp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndPinProtector,

# Defined in TPM And Pin And Startup Key Protector section above
#          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinProtector", Position = 1)]
#          [System.Security.SecureString]
#          $Pin,


          # 
          # TPM And StartupKey Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector")]
          [Alias("tskp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndStartupKeyProtector,

# Defined in the StartupKeyProtector section above
#          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector", Position = 1)]
#          [String]
#          $StartupKeyPath,

          # 
          # TPM Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmProtector")]
          [Alias("tpmp")]
          [System.Management.Automation.SwitchParameter]
          $TpmProtector,

          # 
          # Recovery Key Protector
          #

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryKeyProtector")]
          [Alias("rkp")]
          [System.Management.Automation.SwitchParameter]
          $RecoveryKeyProtector,

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryKeyProtector", Position = 1)]
          [Alias("rk")]
          [String]
          $RecoveryKeyPath
    )
    process
    {
        Write-Debug "Begin Add-BitLockerKeyProtector"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                if ($PsCmdlet.ParameterSetName -eq "RecoveryPasswordProtector")
                {
                    $Result = Add-RecoveryPasswordProtectorInternal $BitLockerVolumeInternal.MountPoint $RecoveryPassword
                }
                elseif ($PsCmdlet.ParameterSetName -eq "PasswordProtector")
                {
                    $Result = Add-PasswordProtectorInternal $BitLockerVolumeInternal.MountPoint $Password
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmProtector")
                {
                    $Result = Add-TpmProtectorInternal $BitLockerVolumeInternal.MountPoint
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndPinProtector")
                {
                    $Result = Add-TpmAndPinProtectorInternal $BitLockerVolumeInternal.MountPoint $Pin
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndStartupKeyProtector")
                {
                    $Result = Add-TpmAndStartupKeyProtectorInternal $BitLockerVolumeInternal.MountPoint $StartupKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndPinAndStartupKeyProtector")
                {
                    $Result = Add-TpmAndPinAndStartupKeyProtectorInternal $BitLockerVolumeInternal.MountPoint $StartupKeyPath $Pin
                }
                elseif ($PsCmdlet.ParameterSetName -eq "StartupKeyProtector")
                {
                    $Result = Add-ExternalKeyProtectorInternal $BitLockerVolumeInternal.MountPoint $StartupKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "RecoveryKeyProtector")
                {
                    $Result = Add-ExternalKeyProtectorInternal $BitLockerVolumeInternal.MountPoint $RecoveryKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "SidProtector")
                {
                    $Result = Add-SidProtectorInternal $BitLockerVolumeInternal.MountPoint $ADAccountOrGroup $Service
                }

                if ($Result -ne 0)
                {
                    Write-Debug "Add-BitLockerKeyProtector failed for $BitLockerVolumeInternal.MountPoint"
                    continue
                }
                
                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided"
        }

       Write-Debug "End Add-BitLockerKeyProtector"
    }
}

#########################################################################################
# Remove-BitLockerKeyProtector
#
# Returns BitLockerVolume structures that describe the volumes after the protector is deleted.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        String        - ID of key protector to be removed
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Remove-BitLockerKeyProtector
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [Alias("id")]
          [string]
          $KeyProtectorId
    )
    process
    {
       Write-Debug "Begin Remove-BitLockerKeyProtector($MountPoint, $KeyProtectorId)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume   = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint

                $DraKeyProtector = $BitLockerVolumeInternal.KeyProtector | 
                                        where {$_.KeyProtectorId -eq $KeyProtectorId -and
                                               $_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::PublicKey -and 
                                               [uint32]$_.KeyCertificateType -band [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorCertificateTypes]::DataRecoveryAgent -eq [uint32][Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorCertificateTypes]::DataRecoveryAgent}

                if ($DraKeyProtector -ne $null)
                {
                    Write-Error -Message $stringTable.ErrorRemoveDraProtector
                    continue
                }

                $NkpProtector = $BitLockerVolumeInternal.KeyProtector |
                                        where {$_.KeyProtectorId -eq $KeyProtectorId -and
                                               $_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmNetworkKey}

                if ($NkpProtector -ne $null)
                {
                    Write-Error -Message $stringTable.ErrorRemoveNkpProtector
                    continue
                }

                $DeleteKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}

                if ($DeleteKeyProtectorResult.ReturnValue -eq $E_KEYREQUIRED)
                {
                    $DisableKeyProtectorsResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DisableKeyProtectors
                    if ($DisableKeyProtectorsResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $DisableKeyProtectorsResult
                        Write-Error -Exception $ExceptionForHr
                        continue
                    }

                    $DeleteKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}
                }

                if ($DeleteKeyProtectorResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $DeleteKeyProtectorResult.ReturnValue
                    if ($DeleteKeyProtectorResult.ReturnValue -eq $E_VOLUMEBOUND)
                    {
                        $ErrorMessage = [string]::Format($stringTable.ErrorVolumeBoundAlready)
                        Write-Error -Exception $ExceptionForHr -Message $ErrorMessage
                    }
                    else
                    {
                        Write-Error -Exception $ExceptionForHr
                    }
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid combination of mountpoint / protector id found"
        }

        Write-Debug "End Remove-BitLockerKeyProtector. Return $BitLockerVolume"
    }
}

#########################################################################################
# Backup-BitLockerKeyProtector
#
# Returns BitLockerVolume structures that describe the volumes after the protector is backed up.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        String        - ID of key protector to be backed up
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Backup-BitLockerKeyProtector
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $KeyProtectorId
    )
    process
    {
       Write-Debug "Begin Backup-BitLockerKeyProtector($MountPoint, $KeyProtectorId)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume   = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                $BackupKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName BackupRecoveryInformationToActiveDirectory -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}

                if ($BackupKeyProtectorResult.ReturnValue -eq $S_FALSE)
                {
                    $ErrorMessage = [string]::Format($stringTable.ErrorGroupPolicyDisabledBackup)
                    Write-Error -Message $ErrorMessage
                    continue
                }
                elseif ($BackupKeyProtectorResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $BackupKeyProtectorResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid combination of mountpoint / protector id found"
        }

        Write-Debug "End Backup-BitLockerKeyProtector. Return $BitLockerVolume"
    }
}

#########################################################################################
# BackupToAAD-BitLockerKeyProtector
#
# Returns BitLockerVolume structures that describe the volumes after the protector is backed up.
#
# Input: String[]      - array of volume names. Could be: drive letter or volume id or mounted directory
#        String        - ID of key protector to be backed up
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function BackupToAAD-BitLockerKeyProtector
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Position = 1, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $KeyProtectorId
    )
    process
    {
       Write-Debug "Begin BackupToAAD-BitLockerKeyProtector($MountPoint, $KeyProtectorId)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point then
       # the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume   = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                $BackupKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName BackupRecoveryInformationToCloudDomain -Arguments @{VolumeKeyProtectorID = $KeyProtectorId}

                if ($BackupKeyProtectorResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $BackupKeyProtectorResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }
        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid combination of mountpoint / protector id found"
        }

        Write-Debug "End BackupToAAD-BitLockerKeyProtector. Return $BitLockerVolume"
    }
}

#########################################################################################
# Enable-BitLockerAutoUnlock
#
# Returns BitLockerVolume structures that describes the volumes which have auto unlock enabled.
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Enable-BitLockerAutoUnlock
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(     
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint)

    process
    {
       Write-Debug "Begin Enable-BitLockerAutoUnlock($MountPoint)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point that can
       # have auto unlock enabled then the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume     = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint
                
                $IsAutoUnlockEnabledResult  = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName IsAutoUnlockEnabled
            
                if ($IsAutoUnlockEnabledResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsAutoUnlockEnabledResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                if ($IsAutoUnlockEnabledResult.IsAutoUnlockEnabled -eq $false)
                {
                    $ProtectKeyWithExternalKeyResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ProtectKeyWithExternalKey
                    if ($ProtectKeyWithExternalKeyResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $ProtectKeyWithExternalKeyResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        continue
                    }

                    Write-Debug ("Added Protector: " + $ProtectKeyWithExternalKeyResult.VolumeKeyProtectorID)

                    $EnableAutoUnlockResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName EnableAutoUnlock -Arguments @{VolumeKeyProtectorID = $ProtectKeyWithExternalKeyResult.VolumeKeyProtectorID}
                    if ($EnableAutoUnlockResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $EnableAutoUnlockResult.ReturnValue

                        $DeleteKeyProtectorResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DeleteKeyProtector -Arguments @{VolumeKeyProtectorID = $ProtectKeyWithExternalKeyResult.VolumeKeyProtectorID}
                        $ExceptionForDebug = Get-ExceptionForHrInternal -HrUInt32 $DeleteKeyProtectorResult.ReturnValue
                        Write-Debug ("Could not enable auto-unlock. Clean up result: " + $ExceptionForDebug)

                        Write-Error -Exception $ExceptionForHr
                        continue
                    }
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }

        } 

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can have auto unlock enabled"
        }


        Write-Debug "End Enable-BitLockerAutoUnlock. Return $BitLockerVolume"
    }
}



#########################################################################################
# Disable-BitLockerAutoUnlock
#
# Returns BitLockerVolume structures that describes the volumes which have auto unlock disabled.
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Disable-BitLockerAutoUnlock
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint)

    process
    {
       Write-Debug "Begin Disable-BitLockerAutoUnlock($MountPoint)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point that can
       # have auto unlock enabled then the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume     = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint

                $IsAutoUnlockEnabledResult  = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName IsAutoUnlockEnabled

                if ($IsAutoUnlockEnabledResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsAutoUnlockEnabledResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                if ($IsAutoUnlockEnabledResult.IsAutoUnlockEnabled -eq $true)
                {

                    $DisableAutoUnlockResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName DisableAutoUnlock
                    if ($DisableAutoUnlockResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $DisableAutoUnlockResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        continue
                    }
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }

        }

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can have auto unlock enabled"
        }


        Write-Debug "End Disable-BitLockerAutoUnlock. Return $BitLockerVolume"
    }
}


#########################################################################################
# Disable-BitLocker
#
# Returns BitLockerVolume structures that describe the volumes which have been disabled.
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Disable-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint)

    process
    {
       Write-Debug "Begin Disable-BitLocker($MountPoint)"

       #########
       # ValidMountPoint is a subset of the elements of MountPoint array.
       # If MountPoint array contains an element that is not a valid mount point that can
       # have auto unlock enabled then the mount point is not part of ValidMountPoint
       # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
       #
       # If "-whatif" is used then ValidMountPoint is always $null
       #########
       [string[]]$ValidMountPoint = $null

       for($i=0; $i -lt $MountPoint.Count; $i++)
       {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if (!$BitLockerVolumeInternal)
            {
                $m = $MountPoint[$i]
                Write-Debug "The following operation failed: Get-BitLockerVolumeInternal -MountPoint $m"
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                $Win32EncryptableVolume      = Get-Win32EncryptableVolumeInternal -MountPoint $BitLockerVolumeInternal.MountPoint

                if ($BitLockerVolumeInternal.VolumeType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeType]::OperatingSystem)
                {
                    $IsAutoUnlockKeyStoredResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName IsAutoUnlockKeyStored
                
                    if ($IsAutoUnlockKeyStoredResult.ReturnValue -ne 0)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsAutoUnlockKeyStoredResult.ReturnValue
                        Write-Error -Exception $ExceptionForHr
                        continue
                    }

                    if ($IsAutoUnlockKeyStoredResult.IsAutoUnlockKeyStored -eq $true)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_AUTOUNLOCK_ENABLED
                        Write-Error -Exception $ExceptionForHr

                        continue
                    }
                }

                $DecryptResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName Decrypt
                if ($DecryptResult.ReturnValue -ne 0)
                {
                    $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $DecryptResult.ReturnValue
                    Write-Error -Exception $ExceptionForHr
                    continue
                }

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]
            }

        }

        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can be decrypted"
        }


        Write-Debug "End Disable-BitLocker. Return $BitLockerVolume"
    }
}



#########################################################################################
# Clear-BitLockerAutoUnlock
#
# Returns BitLockerVolume structure that describes the OS volume which has had auto unlock
# keys cleared.
#
# Input: None
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Clear-BitLockerAutoUnlock
{
    [CmdletBinding()]
    Param()
    process
    {
        Write-Debug "Begin Clear-BitLockerAutoUnlock."

        $OsBitLockerVolume = Get-BitLockerVolume | where {$_.VolumeType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeType]::OperatingSystem}

        if ($OsBitLockerVolume -eq $null)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_NOTFOUND
            $ErrorMessage = [string]::Format($stringTable.ErrorOperatingSystemMountPointNotFound)
            Write-Error -Exception $ExceptionForHr -Message $ErrorMessage

        }
        Write-Debug "Operating system volume to operate on: $OsBitLockerVolume."

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $OsBitLockerVolume.MountPoint

        $ClearKeysResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName ClearAllAutoUnlockKeys
            
        if ($ClearKeysResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $ClearKeysResult.ReturnValue
            Write-Error -Exception $ExceptionForHr

            $OsBitLockerVolume = $null
        }
        else
        {
            #
            # Since we modified the OS Volume by clearing all auto unlock keys, we should
            # get a fresh BitLockerVolume
            #
            $OsBitLockerVolume = Get-BitLockerVolume $OsBitLockerVolume
        }

        $OsBitLockerVolume

        Write-Debug "End Clear-BitLockerAutoUnlock. Return $OsBitLockerVolume"
    }
}


#########################################################################################
# Unlock-AdAccountOrGroupInternal
#
# Returns BitLockerVolume structure that describes an unlocked volume. The volume is unlocked
# based on the current user/machine token.
#
# Input: MountPoint
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume
#########################################################################################
function Unlock-AdAccountOrGroupInternal
{
    Param(
          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint)

    process
    {
        Write-Debug "Begin Unlock-AdAccountOrGroupInternal($MountPoint)"

        $BitLockerVolume        = $null
        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint

        $UnlockWithAdSidResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName UnlockWithAdSid

        if ($UnlockWithAdSidResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $UnlockWithAdSidResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $UnlockWithAdSidResult.ReturnValue
        }

        return 0
        Write-Debug "End Unlock-AdAccountOrGroupInternal. Return $BitLockerVolume"
    }
}

#########################################################################################
# Test-SystemEntropyForBitLocker
#
# Returns true or false
#
# Input: None
#
# Return: $true or $false
#########################################################################################
function Test-SystemEntropyForBitLockerInternal
{
    process
    {
        Write-Debug "Start Test-SystemEntropyForBitLockerInternal"

        $IsWinPe = $false

        $RegistyItem = Get-Item HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT -ErrorAction SilentlyContinue

        if ($RegistryItem -eq $null)
        {
            return $true
        }

        $IsWinPe = $true
        Write-Debug "WinPe: $IsWinPe"

        $Win32Tpm = Get-CimInstance -ClassName Win32_Tpm -Namespace "root\CIMV2\Security\MicrosoftTpm"

        if ($Win32Tpm -eq $null)
        {
            Write-Debug "Tpm WMI object could not not be created"
            return $false
        }


        $IsEnabled              = $false
        $IsActivated            = $false

        $IsEnabledResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsEnabled
        if ($IsEnabledResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsEnabledResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
        }
        else
        {
            $IsEnabled = $IsEnabledResult.IsEnabled
        }

        $IsActivatedResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsActivated
        if ($IsActivatedResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsActivatedResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
        }
        else
        {
            $IsActivated = $IsActivatedResult.IsActivated
        }

        Write-Debug "End Test-SystemEntropyForBitLockerInternal. IsEnabled: $IsEnabled   IsActivated: $IsActivated"
        return $IsEnabled -and $IsActivated
    }
}


#########################################################################################
# Test-TpmProtectorNeededInternal
#
# Returns true or false
#
# Input: None
#
# Return: $true or $false
#########################################################################################
function Test-TpmProtectorNeededInternal
{
    Param(
          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $ParameterSetNameFromEnableBitLocker)

    process
    {
        Write-Debug "Begin Test-TpmProtectorNeededInternal"

        $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint
        if ($BitLockerVolumeInternal -eq $false)
        {
            Write-Debug "End Test-TpmProtectorNeededInternal. Return $false. BitLockerVolume not valid"
            return $false
        }

        if ($BitLockerVolumeInternal.VolumeType -ne [Microsoft.BitLocker.Structures.BitLockerVolumeType]::OperatingSystem)
        {
            Write-Debug "End Test-TpmProtectorNeededInternal. Return $false. BitLockerVolume is not an OS volume"
            return $false
        }

        $DoesPasswordProtectorExist = $BitLockerVolumeInternal.KeyProtector | where-object {$_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::Password}
        $IsTpmReady = Test-TpmForBitLockerInternal

        if ($IsTpmReady -eq $true)
        {
            $AnyTpmKeyProtectorType   = [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::Tpm,
                                        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmNetworkKey,
                                        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmPin,
                                        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmPinStartupKey,
                                        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmStartupKey

            $DoesAnyTpmProtectorExist = $BitLockerVolumeInternal.KeyProtector | where-object {$AnyTpmKeyProtectorType -contains $_.KeyProtectorType}

            #
            # Check if we don't have the following:
            #  -  Password protector
            #  -  ANY Tpm protector
            #  -  User trying to add a password protector
            #  -  User trying to add ANY Tpm protector
            #
            if ($DoesPasswordProtectorExist -eq $null                                       -and
                $DoesAnyTpmProtectorExist -eq $null                                         -and
                $ParameterSetNameFromEnableBitLocker -ne "PasswordProtector"                -and
                $ParameterSetNameFromEnableBitLocker -ne "TpmProtector"                     -and
                $ParameterSetNameFromEnableBitLocker -ne "TpmAndStartupKeyProtector"        -and
                $ParameterSetNameFromEnableBitLocker -ne "TpmAndPinProtector"               -and
                $ParameterSetNameFromEnableBitLocker -ne "TpmAndPinAndStartupKeyProtector")
            {
                 Write-Debug "End Test-TpmProtectorNeededInternal. Return $true"
                 return $true
            }

         }

        return $false
        Write-Debug "End Test-TpmProtectorNeededInternal. Return $false"
    }

}


#########################################################################################
# Test-TpmForBitLockerInternal
#
# Returns true or false
#
# Input: None
#
# Return: $true or $false
#########################################################################################
function Test-TpmForBitLockerInternal
{
    process
    {
        Write-Debug "Begin Test-TpmForBitLockerInternal"

        $IsEnabled              = $false
        $IsOwned                = $false
        $IsActivated            = $false
        $IsSrkAuthCompatible    = $false

        $Win32Tpm = Get-CimInstance -ClassName Win32_Tpm -Namespace "root\CIMV2\Security\MicrosoftTpm"

        if ($Win32Tpm -eq $null)
        {
            Write-Debug "Tpm WMI object could not not be created"
            return $false
        }

        $IsEnabledResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsEnabled
        if ($IsEnabledResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsEnabledResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
         }
        else
        {
            $IsEnabled = $IsEnabledResult.IsEnabled
        }

        $IsOwnedResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsOwned
        if ($IsOwnedResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsOwnedResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
        }
        else
        {
            $IsOwned = $IsOwnedResult.IsOwned
        }

        $IsActivatedResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsActivated
        if ($IsActivatedResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsActivatedResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
        }
        else
        {
            $IsActivated = $IsActivatedResult.IsActivated
        }

        $IsSrkAuthCompatibleResult = Invoke-CimMethod -InputObject $Win32Tpm -MethodName IsSrkAuthCompatible
        if ($IsSrkAuthCompatibleResult.ReturnValue -ne 0)
        {
            $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $IsSrkAuthCompatibleResult.ReturnValue
            Write-Error -Exception $ExceptionForHr
            return $false
        }
        else
        {
            $IsSrkAuthCompatible = $IsSrkAuthCompatibleResult.IsSrkAuthCompatible
        }


        Write-Debug "End Test-TpmForBitLockerInternal. IsEnabled: $IsEnabled   IsOwned: $IsOwned    IsActivated: $IsActivated    IsSrkAuthCompatible: $IsSrkAuthCompatible"

        return $IsEnabled -and $IsOwned -and $IsActivated -and $IsSrkAuthCompatible
    }
}

function Enable-BitLockerInternal
{
    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Mandatory = $false)]
          [Microsoft.BitLocker.Structures.BitLockerVolumeEncryptionMethodOnEnable]
          $EncryptionMethod,

          [Parameter(Mandatory = $true)]
          [bool]
          $SkipHardwareTest,

          [Parameter(Mandatory = $true)]
          [bool]
          $UsedSpaceOnly)

    process
    {
        Write-Debug "Begin Enable-BitLockerInternal. MountPoint: $MountPoint   EncryptionMethod: $EncryptionMethod   SkipHardwareTest: $SkipHardwareTest    UsedSpaceOnly: $UsedSpaceOnly"

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        if ($Win32EncryptableVolume -eq $null)
        {
            Write-Debug "Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint returned null"
            return
        }

        $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint
        if ($BitLockerVolumeInternal -eq $null)
        {
            Write-Debug "Get-BitLockerVolumeInternal -MountPoint $MountPoint returned null"
            return
        }

        $EncryptionFlags = 0
        if ($UsedSpaceOnly -eq $true)
        {
            $EncryptionFlags = $FVE_CONV_FLAG_DATAONLY
        }


        $IntegerEncryptionMethod = 0 # None which means WMI layer picks encryption method
        if ($EncryptionMethod -ne $null)
        {
            [int]$IntegerEncryptionMethod = $EncryptionMethod
        }


        if ($SkipHardwareTest -eq $true)
        {
            $EncryptResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName Encrypt -Arguments @{EncryptionMethod = [uint32]$IntegerEncryptionMethod; EncryptionFlags = [uint32]$EncryptionFlags}
            if ($EncryptResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $EncryptResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return
            }
        }
        else
        {
            $EncryptResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName EncryptAfterHardwareTest -Arguments @{EncryptionMethod = [uint32]$IntegerEncryptionMethod; EncryptionFlags = [uint32]$EncryptionFlags}
            if ($EncryptResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $EncryptResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return
            }
        }

        $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint
        $BitLockerVolumeInternal
        Write-Debug "End Enable-BitLockerInternal. BitLockerVolumeInternal: $BitLockerVolumeInternal"
    }
}

#########################################################################################
#
#########################################################################################
function Show-BitLockerRequiredActionsInternal
{
    Param(
          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,

          [Parameter(Mandatory = $true)]
          [bool]
          $SkipHardwareTest)

    process
    {
        Write-Debug "Begin Show-BitLockerRequiredActionsInternal. MountPoint: $MountPoint   SkipHardwareTest: $SkipHardwareTest"


        $HardwareTestStatus = $FVE_HARDWARE_TEST_NOT_FAILED_OR_PENDING
        $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint

        if ($BitLockerVolumeInternal -eq $null)
        {
            Write-Debug "Get-BitLockerVolumeInternal -MountPoint $MountPoint returned null"
            return
        }

        $AnyExternalKeyProtectorType = [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::ExternalKey,
                                       [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmAndExternalKey,
                                       [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::TpmAndPinAndExternalKey

        $RecoveryKeyProtector    = $BitLockerVolumeInternal.KeyProtector | Where {$_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::RecoveryPassword} | Select-Object -First 1
        $AnyExternalKeyProtector = $BitLockerVolumeInternal.KeyProtector | Where {$AnyExternalKeyProtectorType -contains $_.KeyProtectorType} | Select-Object -First 1


        if ($SkipHardwareTest -eq $false)
        {
            $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
            if ($Win32EncryptableVolume -eq $null)
            {
                Write-Debug "Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint returned null"
                return
            }

            $HardwareTestStatusResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName GetHardwareTestStatus
            if ($HardwareTestStatusResult.ReturnValue -ne 0)
            {
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $HardwareTestStatusResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return
            }

            $HardwareTestStatus = $HardwareTestStatusResult.TestStatus
        }

        if ($HardwareTestStatus -eq $FVE_HARDWARE_TEST_NOT_FAILED_OR_PENDING -and
            $RecoveryKeyProtector -eq $null)
        {
            Write-Debug "End Show-BitLockerRequiredActionsInternal. HardwareTestStatus is not failed or pending"
            return   
        }



        if ($RecoveryKeyProtector -ne $null    -and 
            $HardwareTestStatus -eq $FVE_HARDWARE_TEST_NOT_FAILED_OR_PENDING)
        {
            $Message = [string]::Format($stringTable.WarningWriteDownRecoveryPassword, $RecoveryKeyProtector.RecoveryPassword, [Environment]::NewLine)
            Write-Warning $Message
        }
        elseif ($RecoveryKeyProtector -ne $null    -and 
            $AnyExternalKeyProtector -ne $null -and 
            $HardwareTestStatus -eq $FVE_HARDWARE_TEST_PENDING)
        {
            $Message = [string]::Format($stringTable.WarningWriteDownRecoveryPasswordInsertExternalKeyRestart, $RecoveryKeyProtector.RecoveryPassword, [Environment]::NewLine)
            Write-Warning $Message
        }
        elseif ($RecoveryKeyProtector -eq $null     -and
                 $AnyExternalKeyProtector -ne $null -and 
                 $HardwareTestStatus -eq $FVE_HARDWARE_TEST_PENDING)
        {
            $Message = [string]::Format($stringTable.WarningInsertExternalKeyRestart, [Environment]::NewLine)
            Write-Warning $Message
        }
        elseif ($RecoveryKeyProtector -ne $null     -and
                 $AnyExternalKeyProtector -eq $null -and 
                 $HardwareTestStatus -eq $FVE_HARDWARE_TEST_PENDING)
        {
            $Message = [string]::Format($stringTable.WarningWriteDownRecoveryPasswordRestart, $RecoveryKeyProtector.RecoveryPassword, [Environment]::NewLine)
            Write-Warning $Message
        }      
        elseif ($RecoveryKeyProtector -eq $null     -and
                 $AnyExternalKeyProtector -eq $null -and 
                 $HardwareTestStatus -eq $FVE_HARDWARE_TEST_PENDING)
        {
            $Message = [string]::Format($stringTable.WarningRestart, [Environment]::NewLine)
            Write-Warning $Message
        }
        elseif ($HardwareTestStatus -eq $FVE_HARDWARE_TEST_FAILED)
        {
            $Message = [string]::Format($StringTable.WarningHardwareTestFailed, [Environment]::NewLine)
            Write-Warning $Message
        }

    }
}

#########################################################################################
#
#########################################################################################
function Get-RecoveryKeyProtectorsCountInternal
{
    Param(
          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint)

    process
    {
        $RecoveryKeyProtectorTypes = [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::PublicKey,
                                     [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::Sid,
                                     [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::ExternalKey,
                                     [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::Password,
                                     [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::RecoveryPassword

        [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtector[]] $KeyProtectors = (Get-BitLockerVolumeInternal -MountPoint $MountPoint).KeyProtector | where {$RecoveryKeyProtectorTypes -contains $_.KeyProtectorType}
        if ($KeyProtectors -eq $null)
        {
            return 0
        }

        return $KeyProtectors.Count
    }
}

#########################################################################################
#
#########################################################################################

function Set-BitLockerVolumeInternal
{
    Param(
          [Parameter(Mandatory = $true)]
          [ValidateNotNullOrEmpty()]
          [string]
          $MountPoint,
      
          [Parameter(Mandatory = $true)]
          [ValidateRange(0,2)] #[($FVE_FORCE_ENCRYPTION_TYPE_UNSPECIFIED,$FVE_FORCE_ENCRYPTION_TYPE_HARDWARE)]
          [int]
          $ForceEncryptionType,

          [Parameter(Mandatory = $true)]
          [bool]
          $UsedSpaceOnly)

    process
    {
        [int]$InitializationFlags = $ForceEncryptionType

        $Win32EncryptableVolume = Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint
        if ($Win32EncryptableVolume -eq $null)
        {
            Write-Debug "Get-Win32EncryptableVolumeInternal -MountPoint $MountPoint returned null"
            return $null
        }

        if ($UsedSpaceOnly -eq $true)
        {
            $InitializationFlags += $FVE_PROVISIONING_MODIFIER_USED_SPACE;
        }

        $PrepareVolumeResult = Invoke-CimMethod -InputObject $Win32EncryptableVolume -MethodName PrepareVolumeEx -Arguments @{DiscoveryVolumeType = $DEFAULT_DISCOVERY_VOLUME_TYPE; InitializationFlags = [uint32]$InitializationFlags}
        if ($PrepareVolumeResult.ReturnValue -ne 0)
        {
            if (($PrepareVolumeResult.ReturnValue -ne $FVE_E_NOT_DECRYPTED) -or
                (($InitializationFlags -ne 0) -and
                 ($InitializationFlags -ne $FVE_PROVISIONING_MODIFIER_USED_SPACE)))
            {
                #
                # The volume may have been previously implicitly initialized
                # through adding protectors. So we should not fail unless we
                # were passing some explicit initialization flags.
                # We also allow remapping on used-space flag because we are
                # going to pass used-space flag later when starting conversion.
                #
                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $PrepareVolumeResult.ReturnValue
                Write-Error -Exception $ExceptionForHr
                return $null
            }
        }

        Get-BitLockerVolumeInternal -MountPoint $MountPoint
    }
}

#########################################################################################
# Enable-BitLocker
#
# Returns BitLockerVolume structures that describes volumes with bitlocker enabled. 
#
# Input: String[]    - array of volume names. Could be: drive letter or volume id or mounted directory
#
# Return: Microsoft.BitLocker.Structures.BitLockerVolume[]
#########################################################################################

#.ExternalHelp Bitlocker.psm1-help.xml
function Enable-BitLocker
{
    [CmdletBinding(SupportsShouldProcess=$true)]

    Param(
          [Parameter(Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
          [ValidateNotNullOrEmpty()]
          [string[]]
          $MountPoint,

          [Parameter(Mandatory = $false)]
          [Microsoft.BitLocker.Structures.BitLockerVolumeEncryptionMethodOnEnable]
          $EncryptionMethod,

          [Parameter(Mandatory = $false)]
          [System.Management.Automation.SwitchParameter]
          $HardwareEncryption = $false,

          [Parameter(Mandatory = $false)]
          [System.Management.Automation.SwitchParameter]
          [Alias("s")]
          $SkipHardwareTest = $false,

          [Parameter(Mandatory = $false)]
          [System.Management.Automation.SwitchParameter]
          [Alias("qe")]
          $UsedSpaceOnly = $false,

          # 
          # Password Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="PasswordProtector")]
          [Alias("pwp")]
          [System.Management.Automation.SwitchParameter]
          $PasswordProtector = $false,

          [Parameter(Mandatory = $false, ParameterSetName="PasswordProtector", Position = 1)]
          [Alias("pw")]
          [System.Security.SecureString]
          $Password,

          # 
          # Recovery Password Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryPasswordProtector")]
          [Alias("rpp")]
          [System.Management.Automation.SwitchParameter]
          $RecoveryPasswordProtector = $false,

          [Parameter(Mandatory = $false, ParameterSetName="RecoveryPasswordProtector", Position = 1)]
          [ValidateNotNullOrEmpty()]
          [Alias("rp")]
          [String]
          $RecoveryPassword,

          # 
          # Startup Key Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="StartupKeyProtector")]
          [Alias("skp")]
          [System.Management.Automation.SwitchParameter]
          $StartupKeyProtector = $false,

          [Parameter(Mandatory = $true, ParameterSetName="StartupKeyProtector", Position = 1)]
          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 1)]
          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector", Position = 1)]
          [Alias("sk")]
          [String]
          $StartupKeyPath,

          # 
          # Active Directory Account Or Group Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="AdAccountOrGroupProtector")]
          [Alias("sidp")]
          [System.Management.Automation.SwitchParameter]
          $AdAccountOrGroupProtector = $false,

          [Parameter(Mandatory = $false, ParameterSetName="AdAccountOrGroupProtector")]
          [System.Management.Automation.SwitchParameter]
          $Service = $false,

          [Parameter(Mandatory = $true, ParameterSetName="AdAccountOrGroupProtector", Position = 1)]
          [Alias("sid")]
          [String]
          $AdAccountOrGroup,

          # 
          # TPM And Pin And StartupKey Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector")]
          [Alias("tpskp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndPinAndStartupKeyProtector = $false,

          # Defined in the StartupKeyProtector section above
          #          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 1)]
          #          [String]
          #          $StartupKeyPath,

          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinAndStartupKeyProtector", Position = 2)]
          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinProtector", Position = 1)]
          [Alias("p")]
          [System.Security.SecureString]
          $Pin,


          # 
          # TPM And Pin Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndPinProtector")]
          [Alias("tpp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndPinProtector = $false,

          # Defined in TPM And Pin And Startup Key Protector section above
          #          [Parameter(Mandatory = $false, ParameterSetName="TpmAndPinProtector", Position = 1)]
          #          [System.Security.SecureString]
          #          $Pin,


          # 
          # TPM And StartupKey Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector")]
          [Alias("tskp")]
          [System.Management.Automation.SwitchParameter]
          $TpmAndStartupKeyProtector = $false,

          # Defined in the StartupKeyProtector section above
          #          [Parameter(Mandatory = $true, ParameterSetName="TpmAndStartupKeyProtector", Position = 1)]
          #          [String]
          #          $StartupKeyPath,

          # 
          # TPM Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="TpmProtector")]
          [Alias("tpmp")]
          [System.Management.Automation.SwitchParameter]
          $TpmProtector = $false,

          # 
          # Recovery Key Protector 
          #

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryKeyProtector")]
          [Alias("rkp")]
          [System.Management.Automation.SwitchParameter]
          $RecoveryKeyProtector = $false,

          [Parameter(Mandatory = $true, ParameterSetName="RecoveryKeyProtector", Position = 1)]
          [Alias("rk")]
          [String]
          $RecoveryKeyPath)

    process
    {

        Write-Debug "Begin Enable-BitLocker"

        #########
        # ValidMountPoint is a subset of the elements of MountPoint array.
        # If MountPoint array contains an element that is not a valid mount point then
        # the mount point is not part of ValidMountPoint
        # Only those BitLockerVolume structures are returned that are part of ValidMountPoint
        #
        # If "-whatif" is used then ValidMountPoint is always $null
        #########
        [string[]]$ValidMountPoint = $null


        if ($HardwareEncryption -eq $true -and $UsedSpaceOnly -eq $true)
        {
            $UsedSpaceOnly = $false
            Write-Warning $stringTable.WarningUsedSpaceOnlyAndHardwareEncryption
        }

        for($i=0; $i -lt $MountPoint.Count; $i++)
        {
            $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
            if ($BitLockerVolumeInternal -eq $null)
            {
                Write-Debug ("The following operation failed: Get-BitLockerVolumeInternal -MountPoint " + $MountPoint[$i])
                continue
            }

            Write-Debug ("MountPoint: " + $BitLockerVolumeInternal.MountPoint)

            $IsFullyDecrypted = $BitLockerVolumeInternal.VolumeStatus -eq [Microsoft.BitLocker.Structures.BitLockerVolumeStatus]::FullyDecrypted
            $IsOsVolume       = $BitLockerVolumeInternal.VolumeType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeType]::OperatingSystem

            if ($pscmdlet.ShouldProcess($BitLockerVolumeInternal.MountPoint))
            {
                if ($IsFullyDecrypted -eq $true)
                {
                    $IsSystemEntropyReady = Test-SystemEntropyForBitLockerInternal
                    if ($IsSystemEntropyReady -eq $false)
                    {
                        $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $TPM_E_DEACTIVATED
                        Write-Error -Exception $ExceptionForHr
                        continue
                    }

                    if ($HardwareEncryption -eq $true)
                    {
                        $BitLockerVolumeInternal = Set-BitLockerVolumeInternal -MountPoint $MountPoint[$i] -ForceEncryptionType $FVE_FORCE_ENCRYPTION_TYPE_HARDWARE -UsedSpaceOnly $false
                    }
                    else
                    {
                        $BitLockerVolumeInternal = Set-BitLockerVolumeInternal -MountPoint $MountPoint[$i] -ForceEncryptionType $FVE_FORCE_ENCRYPTION_TYPE_UNSPECIFIED -UsedSpaceOnly $UsedSpaceOnly
                    }

                    Write-Debug "Set-BitLockerVolumeInternal returned $BitLockerVolumeInternal"
                    if ($BitLockerVolumeInternal -eq $null)
                    {
                        continue
                    }

                    if ($IsOsVolume -eq $true)
                    {
                        $IsTpmReady = Test-TpmForBitLockerInternal

                        if ($IsTpmReady -eq $true)
                        {
                            $IsTpmProtectorNeeded = Test-TpmProtectorNeededInternal -MountPoint $MountPoint[$i] -ParameterSetNameFromEnableBitLocker $PsCmdlet.ParameterSetName

                            if ($IsTpmProtectorNeeded -eq $true)
                            {
                                $BitLockerVolumeInternal = Add-BitLockerKeyProtector -TpmProtector -MountPoint $BitLockerVolumeInternal
                                Write-Debug "Add-BitLockerKeyProtector returned $BitLockerVolumeInternal"
                                if ($BitLockerVolumeInternal -eq $null)
                                {
                                    continue
                                }
                            }
                        }
                        else
                        {
                            $DoesPasswordProtectorExist     = $BitLockerVolumeInternal.KeyProtector | where-object {$_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::Password}
                            $DoesExternalKeyProtectorExist  = $BitLockerVolumeInternal.KeyProtector | where-object {$_.KeyProtectorType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeKeyProtectorType]::ExternalKey}

                            if ($DoesPasswordProtectorExist -eq $null               -and
                                $DoesExternalKeyProtectorExist -eq $null            -and
                                $PsCmdlet.ParameterSetName -ne "PasswordProtector"  -and
                                $PsCmdlet.ParameterSetName -ne "StartupKeyProtector")
                            {
                                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_FAIL
                                Write-Error -Exception $ExceptionForHr -Message $stringTable.ErrorExternalKeyOrPasswordRequired
                                continue
                            }
                        }

                        if ($PsCmdlet.ParameterSetName -eq "AdAccountOrGroupProtector")
                        {                        
                            $RecoveryKeyProtectorCount = Get-RecoveryKeyProtectorsCountInternal -MountPoint $MountPoint[$i]
                            $IsTpmAvailable = Test-TpmForBitLockerInternal
                            if ( ($RecoveryKeyProtectorCount -lt $MINIMUM_REQUIRED_RECOVERY_PROTECTORS_WITH_TPM -and $IsTpmAvailable -eq $true) -or ($RecoveryKeyProtectorCount -lt $MINIMUM_REQUIRED_RECOVERY_PROTECTORS_WITHOUT_TPM -and $IsTpmAvailable -eq $false))
                            {
                                $ExceptionForHr = Get-ExceptionForHrInternal -HrUInt32 $E_FAIL
                                Write-Error -Exception $ExceptionForHr -Message $stringTable.ErrorSidProtectorRequiresAdditionalRecoveryProtector
                                continue
                            }
                        }
                    } # end if OS Volume
                } #end if VolumeStatus -eq FullyDecrypted


                if ($PsCmdlet.ParameterSetName -eq "PasswordProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -PasswordProtector -Password $Password
                }
                elseif ($PsCmdlet.ParameterSetName -eq "RecoveryPasswordProtector")
                {
                    #
                    # We call the internal add protector method because we
                    # don't want it to output the recovery password. This cmdlet will do it.
                    #

                    $nResult = 0

                    if ([string]::IsNullOrEmpty($RecoveryPassword))
                    {
                        $nResult = Add-RecoveryPasswordProtectorInternal $MountPoint[$i] -SuppressWarningMessage
                    }
                    else
                    {
                        $nResult = Add-RecoveryPasswordProtectorInternal $MountPoint[$i] $RecoveryPassword -SuppressWarningMessage
                    }

                    if ($nResult -eq 0)
                    {
                         $BitLockerVolumeInternal = Get-BitLockerVolumeInternal -MountPoint $MountPoint[$i]
                    }
                }
                elseif ($PsCmdlet.ParameterSetName -eq "StartupKeyProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -StartupKeyProtector -StartupKeyPath $StartupKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "AdAccountOrGroupProtector")
                {
                    if ($Service -eq $false)
                    {
                        $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -AdAccountOrGroupProtector -AdAccountOrGroup $AdAccountOrGroup
                    }
                    else
                    {
                        $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -AdAccountOrGroupProtector -AdAccountOrGroup $AdAccountOrGroup -Service
                    }
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndPinAndStartupKeyProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -TpmAndPinAndStartupKeyProtector -StartupKeyPath $StartupKeyPath -Pin $Pin
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndPinProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -TpmAndPinProtector -Pin $Pin
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmAndStartupKeyProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -TpmAndStartupKeyProtector -StartupKeyPath $StartupKeyPath
                }
                elseif ($PsCmdlet.ParameterSetName -eq "TpmProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -TpmProtector
                }
                elseif ($PsCmdlet.ParameterSetName -eq "RecoveryKeyProtector")
                {
                    $BitLockerVolumeInternal = Add-BitLockerKeyProtector -MountPoint $MountPoint[$i] -RecoveryKeyProtector -RecoveryKeyPath $RecoveryKeyPath
                }

                if ($BitLockerVolumeInternal -eq $null)
                {
                    Write-Debug ("Add-BitLockerKeyProtector did not return a bitlocker volume. ParameterSet: " + $PSCmdlet.ParameterSetName)
                    continue
                }


                if ($BitLockerVolumeInternal.VolumeType -eq [Microsoft.BitLocker.Structures.BitLockerVolumeType]::Data -or
                    $IsFullyDecrypted -ne $true)
                {
                    $NeedHardwareTest = $false
                }
                else
                {
                    $NeedHardwareTest = !$SkipHardwareTest
                }

                if ($EncryptionMethod -ne $null)
                {
                    $BitLockerVolumeInternal = Enable-BitLockerInternal -MountPoint $BitLockerVolumeInternal -EncryptionMethod $EncryptionMethod -SkipHardwareTest (!$NeedHardwareTest) -UsedSpaceOnly $UsedSpaceOnly
                }
                else
                {
                    $BitLockerVolumeInternal = Enable-BitLockerInternal -MountPoint $BitLockerVolumeInternal -SkipHardwareTest (!$NeedHardwareTest) -UsedSpaceOnly $UsedSpaceOnly
                }
                Write-Debug "Enable-BitLockerInternal returned $BitLockerVolumeInternal. EncryptionMethod: $EncryptionMethod   NeedHardwareTest: $NeedHardwareTest    UsedSpaceOnly: $UsedSpaceOnly"


                if ($BitLockerVolumeInternal -eq $null)
                {
                    Write-Debug ("Could not enable bitlocker on " + $MountPoint[$i])
                    continue
                }


                Show-BitLockerRequiredActionsInternal -MountPoint $BitLockerVolumeInternal -SkipHardwareTest (!$NeedHardwareTest)

                $ValidMountPoint = $ValidMountPoint + $MountPoint[$i]

            } #end ShouldProcess
        } #end for each MountPoint


        Write-Debug "ValidMountPoint: $ValidMountPoint"

        if ($ValidMountPoint)
        {
            $BitLockerVolume = Get-BitLockerVolume -MountPoint $ValidMountPoint

            $BitLockerVolume
        }
        else
        {
            Write-Debug "No valid mount point was provided that can have bitlocker enabled"
        }


        Write-Debug "End Enable-BitLocker $BitLockerVolume"

    } #end process record
}
