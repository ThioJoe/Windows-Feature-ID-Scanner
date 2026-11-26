<#
Copyright (C) Microsoft. All rights reserved.
#>

# String table for localizable messages to be returned to the user. 
$SCStringTable = Data {
    ConvertFrom-StringData @'
    AppliedSettings = User and Application set, log on as this user to start Assigned Access
    ClearedSettings = Cleared Assigned Access, settings reset to factory defaults
    ErrorUserNotFound = User was not found. Enter a valid local account UserName or UserSID
    ErrorAppNotFound = Application was not found.  Enter either a valid AppName or AUMID
    ErrorProvisionedAppNameUsed = The app couldn't be set for assigned access by name at this time, run the cmdlet again using the -AppUserModelId option
    DeletingInstance = Deleting {0}
    ErrorUserDoesNotExist = The assigned access user does not exist: {0}. Run Clear-AssignedAccess to clear assigned access.
    ErrorAppDoesNotExist = The assigned access application does not exist: {0}. Run Clear-AssignedAccess to clear assigned access.
    ErrorCurrentUserNotAllowed = The assigned access user cannot be set to the current logged in account.
    ErrorConnectedUserNotAllowed = You can only set up assigned access for a local standard user account that does not have a Microsoft account associated with it.
    ConfirmSet = Set assigned access application to {0}
    ConfirmClear = Clear assigned access
    ErrorInsufficientPrivilege = This script must be run with Administrator privileges.
'@
}

# C# Interop class/interface to check user connected info
$TypeDefinition = @"
using System;
using System.Runtime.InteropServices;
namespace LockdownWMI
{
    // Declare IEnumUnknown
    [
      ComImport,
      Guid("00000100-0000-0000-C000-000000000046"),
      InterfaceType(ComInterfaceType.InterfaceIsIUnknown)
    ] 
    public interface IEnumUnknown
    {
    }

    // Declare IConnectedUser
    [
      ComImport,
      Guid("9D5F2149-DE8C-45F2-B313-6587A04F771D"),
      InterfaceType(ComInterfaceType.InterfaceIsIUnknown)
    ] 
    public interface IConnectedUser
    {
    }

    // Declare IConnectedUserStore
    [
      ComImport,
      Guid("9EC044BC-B01D-4C18-8634-59BD3FF5DCC1"),
      InterfaceType(ComInterfaceType.InterfaceIsIUnknown)
    ] 
    public interface IConnectedUserStore
    {
        int GetConnectedUserEnum(
                uint                Options,
                ref Guid            pProviderGUID,
                ref IEnumUnknown    ppUserEnum
                );

        int CreateConnectedUser(
                string              LocalUserName,
                string              IdentityUserName,
                ref Guid            ProviderGUID,
                bool                IsAdmin,
                IntPtr              AuthBuffer,
                uint                AuthBufferSize
                );

        int ConnectLocalUser(
                string              LocalPassword,
                ref Guid            ProviderGUID,
                IntPtr              AuthBuffer,
                uint                AuthBufferSize
                );

        int FindConnectedUserByName(
                string              IdentityUserName,
                string              ProviderName,
                ref Guid            pProviderGUID,
                ref IConnectedUser  ppConnectedUser
                );

        int FindConnectedUserBySid(
                IntPtr              Sid,
                uint                SidLength,
                ref IConnectedUser  ppConnectedUser
                );
    }

    // Declare CConnectedUserStore
    [
      ComImport,
      Guid("40AFA0B6-3B2F-4654-8C3F-161DE85CF80E")
    ] 
    public class CConnectedUserStore {}

    public class UserCheck
    {
        public static bool IsConnectedUser(String userSid)
        {
            IConnectedUser connectedUser = null;
            IntPtr intPtrSid = IntPtr.Zero;
            IConnectedUserStore userStore = (IConnectedUserStore)new CConnectedUserStore();
            try {
                bool success = ConvertStringSidToSid(userSid, ref intPtrSid);
                if(success)
                {
                    uint sidLength = GetLengthSid(intPtrSid);
                    userStore.FindConnectedUserBySid(intPtrSid, sidLength, ref connectedUser);
                }
            } catch (Exception)
            {
                connectedUser = null;
            }

            Marshal.FreeHGlobal(intPtrSid);
            return (connectedUser != null);
        }

        [DllImport("Advapi32.dll", EntryPoint="ConvertStringSidToSid", CallingConvention=CallingConvention.Winapi, SetLastError=true)]
        private static extern bool ConvertStringSidToSid(string strSID, ref IntPtr sid);

        [DllImport("Advapi32.dll", EntryPoint="GetLengthSid", CallingConvention = CallingConvention.Winapi, SetLastError=true)]
        private static extern uint GetLengthSid(IntPtr pSid);
    }
}
"@

try { Add-Type -TypeDefinition $TypeDefinition } catch {}

$CommonArgs = @{"namespace"="root\standardcimv2\embedded"}

Import-LocalizedData -BindingVariable SCStringTable -FileName "AssignedAccessMsg.psd1"

function IsCurrentUserAdmin
{
    [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

# .EXTERNALHELP AssignedAccess-help.xml
function Get-AssignedAccess
{
    [CmdletBinding()]
    param()

    if (-Not (IsCurrentUserAdmin))
    {
        throw $SCStringTable.ErrorInsufficientPrivilege
    }

    # Display the instances in WEDL_AssignedAccess 
    $instance = Get-CimInstance -ClassName WEDL_AssignedAccess @CommonArgs
    if(!$instance) {
        return
    }
    
    try {
        $objSID = New-Object System.Security.Principal.SecurityIdentifier($instance.UserSID)
        $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
    } catch {
        Write-Error ($SCStringTable.ErrorUserDoesNotExist -f $instance.UserSID)
        return
    }
    
    # Tokenizing the app user model id to obtain the app package family name, at index [0]
    # aumid = [appx.packagefamilyname]![appxmanifest.id]
    $temp = $instance.AppUserModelId.split("!")
    $appPackageFamilyName = $temp[0]

    # determining the app name by comparing the app package family name        
    $appName = (Get-AppxPackage -User $objUser.Value) | Where-Object -Property 'PackageFamilyName' -eq $appPackageFamilyName | Select-Object -Expand Name -First 1
    if(!$appName) {
        $temp = $appPackageFamilyName.split("_")
        $appName = $temp[0]
    }

    # Outputting the details
    [PSCustomObject] @{
        UserSID = $instance.UserSID;
        UserName = $objUser.Value;
        AppUserModelId = $instance.AppUserModelId;
        AppName = $appName;
    }
}

# .EXTERNALHELP AssignedAccess-help.xml
function Set-AssignedAccess
{
    [CmdletBinding(DefaultParameterSetName="UserNameANDAppName",
        SupportsShouldProcess=$True)]
    param(
        [parameter(ParameterSetName='UserNameANDAppName', Mandatory=$true)]
        [parameter(ParameterSetName='UserNameANDAppId', Mandatory=$true)]
        [String]
        $UserName,

        [parameter(ParameterSetName='UserSidANDAppName', Mandatory=$true)]
        [parameter(ParameterSetName='UserSidANDAppId', Mandatory=$true)]
        [String]
        $UserSID,

        [parameter(ParameterSetName='UserNameANDAppId', Mandatory=$true)]
        [parameter(ParameterSetName='UserSidANDAppId', Mandatory=$true)]
        [alias("AUMID")]
        [String]
        $AppUserModelId,

        [parameter(ParameterSetName='UserNameANDAppName', Mandatory=$true)]
        [parameter(ParameterSetName='UserSidANDAppName', Mandatory=$true)]
        [String]
        $AppName
    )

    if (-Not (IsCurrentUserAdmin))
    {
        throw $SCStringTable.ErrorInsufficientPrivilege
    }

    try {
        # Resolve the user name to its SID if it is passed
        if ($UserName) {
            $objUser = New-Object System.Security.Principal.NTAccount($UserName)
            $UserSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        
        # Validate the SID
        # For UserName passed in, convert it into the format Domain\UserName or MachineName\UserName
        $objSID = New-Object System.Security.Principal.SecurityIdentifier($UserSID)
        $UserName = $objSID.Translate([System.Security.Principal.NTAccount])
        
    } catch {
        throw $SCStringTable.ErrorUserNotFound
    }
    
    # UserName has been converted to Domain\UserName or MachineName\UserName
    # Throw error if UserNamePrefix is not the same as MachineName
    # We do not allow configuring AssignedAccss to domain account from Powershell
    
    $UserNamePrefix = $UserName.Split("\")[0]
    $UserNameSuffix = $UserName.Split("\")[1]
    if(diff $UserNamePrefix $env:COMPUTERNAME)
    {
        throw $SCStringTable.ErrorUserNotFound
    }
    
    # Parse output of the command "net localgroup administrators" and try to find $UserName
    # if it's not found, it's not admin, we can move on
    # otherwise throw an exception because we don't allow admin to be AA account
    $NetEXE = $env:SystemDrive + "\windows\system32\net.exe localgroup administrators"
    $UserStringFromNetCommand = Invoke-Expression $NetEXE | Where {$_ -eq $UserNameSuffix}
    if(!([String]::IsNullOrEmpty($UserStringFromNetCommand)))
    {
        throw $SCStringTable.ErrorUserNotFound
    }    

    # If passed in UserSID is the same as current user, do not apply assigned access and return error
    $CurrentUserSID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(!(diff $CurrentUserSID $UserSID))
    {
        throw $SCStringTable.ErrorCurrentUserNotAllowed
    }

    # If the UserSID represents a user with user connected info (bound with MS account), do not apply assigned access and return error
    if([LockdownWMI.UserCheck]::IsConnectedUser($UserSID))
    {
        throw $SCStringTable.ErrorConnectedUserNotAllowed
    }

    # If the AppName is passed, resolve it to its AppUserModelId
    if ($AppName) {
        # Selects the first object in case Get-AppxPackage returns multiple packages (if multiple versions of the app exist).
        $AppxPkg = ((Get-AppxPackage -User $UserSID -Name $AppName) | Select-Object -First 1)

        if (!$AppxPkg) {
            # try to find a provisioned app (DismAppxPackage) based on $AppName
            #   - if we can find one, throw error and ask user to user -AppUserModelId option
            #     because for provisioned app, we cannot parse AppName into AUMID in powershell
            #   - if not, throw regular error
            $provisionedApp = Get-AppxProvisionedPackage -online | Where-Object {$_.DisplayName -eq $AppName}
            if($provisionedApp) {
                throw $SCStringTable.ErrorProvisionedAppNameUsed
            }
            else {
                throw $SCStringTable.ErrorAppNotFound
            }
        }

        $AppUserModelId = $AppxPkg.PackageFamilyName + "!" + ($AppxPkg | Get-AppxPackageManifest -User $UserSID).Package.Applications.Application.Id
    }
    
    if ($PSCmdlet.ShouldProcess($UserName, ($SCStringTable.ConfirmSet -f $AppUserModelId))) {

        # Check if an instance already exists. We only allow a single instance of WEDL_AssignedAccess.
        $instance = Get-CimInstance -ClassName WEDL_AssignedAccess @CommonArgs
        if ($instance -and $instance.UserSID -eq $UserSID) {
            # Update AppID of existing instance
            $instance | Set-CimInstance -Property @{AppUserModelId=$AppUserModelId} -ErrorAction Stop -Confirm:$false
        } else {
            # If an instance already exists with a different username,
            # delete it before creating a new one.
            if ($instance) {
                Write-Verbose ($SCStringTable.DeletingInstance -f $UserName)
                $instance | Remove-CimInstance -Confirm:$false
            }

            New-CimInstance -ClassName WEDL_AssignedAccess -Property @{UserSID=$UserSID; AppUserModelId=$AppUserModelId} @CommonArgs -ErrorAction Stop -Confirm:$false | Out-Null
        }
        Write-Verbose $SCStringTable.AppliedSettings
    }
}

# .EXTERNALHELP AssignedAccess-help.xml
function Clear-AssignedAccess
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    param()

    if (-Not (IsCurrentUserAdmin))
    {
        throw $SCStringTable.ErrorInsufficientPrivilege
    }

    $instance = Get-CimInstance -ClassName WEDL_AssignedAccess @CommonArgs
    if ($instance) {
        # attempt to translate SID to user name
        try {
            $objSID = New-Object System.Security.Principal.SecurityIdentifier($instance.UserSID)
            $UserName = $objSID.Translate([System.Security.Principal.NTAccount]).Value
        } catch {
            $UserName = $instance.UserSID
        }
        
        if ($PSCmdlet.ShouldProcess($UserName, $SCStringTable.ConfirmClear)) {
            $instance | Remove-CimInstance -Confirm:$false
            Write-Verbose $SCStringTable.ClearedSettings 
        }
    }
}
