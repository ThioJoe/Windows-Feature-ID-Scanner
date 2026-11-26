# Copyright (c) Microsoft Corporation. All rights reserved.
# Collects supported native UOP provider diagnostics; never uploads or changes policy.
Set-StrictMode -Version 3.0

$script:AauProviderId = 'Microsoft.Windows.Update.AutomaticAppUpdater'
$script:AauExecutableName = 'svchost.exe'
$script:AauServiceName = 'wuappupsvc'
$script:CspProviderId = "$script:AauProviderId.CSP"
# Mirrors ProviderPaths.h; Validate-PackageStaging.ps1 guards the native/manifest/PowerShell contract.
$script:UopLogRootRelativePath = 'Logs\UOPProviders'
$script:UopStateRootRelativePath = 'Microsoft\UOPProviders'
$script:UopPayloadRootRelativePath = 'UOPProviders'
# Decoder outputs retained beside each ETL snapshot, keyed by their private workspace names.
$script:UopDecoderOutputSuffixes = [ordered]@{
    x = '.xml'; m = '.schema.man'; d = '.metadata.xml'
    s = '.summary.txt'; o = '.decoder.txt'; e = '.decoder-errors.txt'
}

function Test-UopProviderFamily {
    param([string]$Identity, [string]$Root)
    return [string]::Equals($Identity, $Root, [StringComparison]::OrdinalIgnoreCase) -or
        ($null -ne $Identity -and $Identity.StartsWith("$Root.", [StringComparison]::OrdinalIgnoreCase))
}

function Test-UopCspProvider {
    param([string]$Identity)
    return (Test-UopProviderFamily -Identity $Identity -Root $script:CspProviderId) -or
        [string]::Equals($Identity, 'Microsoft.Windows.Update.AppUpdateCSP', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-UopLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$CheckNetworkDrive = $true,
        [switch]$RejectControlCharacters
    )

    if ($Path -notmatch '^[a-zA-Z]:\\' -or $Path.IndexOf(':', 2) -ge 0 -or
        ($RejectControlCharacters -and $Path -match '[\x00-\x1f]')) {
        throw "Only local, fully qualified filesystem paths without alternate streams are supported: $Path"
    }
    if ($CheckNetworkDrive) {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
        if ($drive.DriveType -eq [IO.DriveType]::Network) {
            throw "Network output/input paths are not supported: $Path"
        }
    }
    $current = $Path
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not supported in diagnostic paths: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Test-UopCompilerTempDirectory {
    param([AllowNull()][string]$Path)

    # Windows PowerShell hands temporary file paths to csc.exe, which cannot use characters
    # outside the ANSI code page and fails, or hangs, as those paths approach MAX_PATH. csc.exe
    # also reports an 8.3 alias by the folder's real, possibly non-ASCII or long path. Aliases
    # contain '~', and no path with '~' is used.
    return -not [string]::IsNullOrEmpty($Path) -and $Path.Length -le 200 -and -not $Path.Contains('~') -and
        $Path -cmatch '\A[A-Za-z]:\\[\x20-\x7e]*\z' -and [IO.Directory]::Exists($Path)
}

function New-UopPrivateCompilerDirectory {
    param([Parameter(Mandatory = $true)][string]$Parent)

    # The shared Windows temporary folder is usable only through a new directory that
    # grants access to the collecting user alone, so no other user can replace compiler output.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $user = $identity.User }
    finally { $identity.Dispose() }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($user)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user,
        [Security.AccessControl.FileSystemRights]::FullControl,
        ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    $path = Join-Path $Parent "UOP.$([Guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($path, $security)
    # CreateDirectory adopts an existing directory; never use one this user does not own.
    $owner = [IO.Directory]::GetAccessControl($path).GetOwner([Security.Principal.SecurityIdentifier])
    if (-not $user.Equals($owner)) { return $null }
    return $path
}

function Get-UopCompilerTempDirectory {
    # Prefer the folder csc.exe would use (TMP, then TEMP, as Windows resolves it), then a new
    # private folder under the Windows temporary folder. 8.3 aliases are not candidates: csc.exe
    # reports them by the folder's real path.
    $temporaryFolders = @(@($env:TMP, $env:TEMP) | Where-Object { -not [string]::IsNullOrEmpty($_) } |
        Select-Object -Unique)
    foreach ($folder in $temporaryFolders) {
        if (Test-UopCompilerTempDirectory $folder) { return [pscustomobject]@{ Path = $folder; Owned = $false } }
    }
    $windowsTemp = Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'
    $creationFailure = $null
    if (Test-UopCompilerTempDirectory $windowsTemp) {
        $privateFolder = $null
        # The private folder is the last candidate; when it cannot be created, the failure below names the cause.
        try { $privateFolder = New-UopPrivateCompilerDirectory -Parent $windowsTemp }
        catch [UnauthorizedAccessException] { $creationFailure = $_.Exception.Message }
        catch [IO.IOException] { $creationFailure = $_.Exception.Message }
        if ($null -ne $privateFolder) { return [pscustomobject]@{ Path = $privateFolder; Owned = $true } }
    }
    throw ("Cannot compile the collector's native helper: no temporary folder has a usable path. " +
        "TMP/TEMP ('$($temporaryFolders -join "', '")') must be an existing folder whose path is ASCII, at most " +
        "200 characters and contains no '~' (an 8.3 alias), and no private folder " +
        "could be created under '$windowsTemp'$(if ($creationFailure) { " ($creationFailure)" }). " +
        'Set TEMP and TMP to such a folder (for example C:\Temp) and rerun.')
}

function Add-UopNativeType {
    param([Parameter(Mandatory = $true)][string]$TypeDefinition)

    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compiles in memory, without csc.exe or a temporary folder.
        Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
        return
    }
    $directory = Get-UopCompilerTempDirectory
    # csc.exe also reads TMP/TEMP for its own intermediate files, through the ANSI code page: a TEMP
    # outside it fails with CS0016 ("The directory name is invalid") whatever folder CodeDom gets.
    # Both name the compiler folder while csc.exe runs and are restored afterwards. The change is
    # process-wide, so another runspace that reads them in that window sees the compiler folder.
    $savedTemporaryFolders = @{}
    foreach ($name in @('TMP', 'TEMP')) {
        $savedTemporaryFolders[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        foreach ($name in @('TMP', 'TEMP')) { [Environment]::SetEnvironmentVariable($name, $directory.Path, 'Process') }
        $parameters = [CodeDom.Compiler.CompilerParameters]::new()
        [void]$parameters.ReferencedAssemblies.Add('System.dll')
        $parameters.GenerateInMemory = $true
        $parameters.TempFiles = [CodeDom.Compiler.TempFileCollection]::new($directory.Path, $false)
        try { Add-Type -TypeDefinition $TypeDefinition -CompilerParameters $parameters -ErrorAction Stop }
        finally { $parameters.TempFiles.Delete() }
    }
    finally {
        foreach ($name in @('TMP', 'TEMP')) {
            [Environment]::SetEnvironmentVariable($name, $savedTemporaryFolders[$name], 'Process')
        }
        if ($directory.Owned) {
            try { [IO.Directory]::Delete($directory.Path, $true) }
            catch {
                Write-Warning "Could not remove the private compiler folder '$($directory.Path)': $($_.Exception.Message)"
            }
        }
    }
}

function Initialize-UopNativeType {
    # Compile once per session; a re-imported module reuses the loaded type.
    if (-not ('UopProviderDiagnostics.OutputDirectoryPin' -as [type])) {
        Add-UopNativeType -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace UopProviderDiagnostics
{
    public sealed class OutputDirectoryPin : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode,
            ExactSpelling = true, SetLastError = true)]
        private static extern SafeFileHandle OpenFile(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode,
            ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectory(string path, ref SecurityAttributes security);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information,
            [Out] byte[] descriptor, uint length, out uint needed);

        private readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();

        private static void ValidateCollectionRoot(SafeFileHandle handle, string path)
        {
            uint needed;
            if (GetKernelObjectSecurity(handle, 5, null, 0, out needed) ||
                Marshal.GetLastWin32Error() != 122)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect collection root security: " + path);
            if (needed < 20 || needed > 131072)
                throw new IOException("Collection root security descriptor has an unsupported size: " + path);
            byte[] buffer = new byte[(int)needed];
            if (!GetKernelObjectSecurity(handle, 5, buffer, (uint)buffer.Length, out needed))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect collection root security: " + path);
            RawSecurityDescriptor security = new RawSecurityDescriptor(buffer, 0);
            SecurityIdentifier user;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { user = identity.User; }
            if (!user.Equals(security.Owner))
                throw new IOException("Collection root is not owned by the collecting user: " + path);
            if (security.DiscretionaryAcl == null)
                throw new IOException("Collection root has unrestricted access: " + path);
            const int writeMask = (int)(FileSystemRights.Write | FileSystemRights.Delete |
                FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions |
                FileSystemRights.TakeOwnership) | 0x50000000;
            foreach (GenericAce entry in security.DiscretionaryAcl)
            {
                QualifiedAce rule = entry as QualifiedAce;
                if (rule == null)
                    throw new IOException("Collection root has an unsupported access rule: " + path);
                if ((rule.AceFlags & AceFlags.InheritOnly) != 0 || rule.AceQualifier == AceQualifier.AccessDenied)
                    continue;
                if (rule.AceQualifier != AceQualifier.AccessAllowed)
                    throw new IOException("Collection root has an unsupported access rule: " + path);
                if ((rule.AccessMask & writeMask) != 0 && !user.Equals(rule.SecurityIdentifier) &&
                    !rule.SecurityIdentifier.IsWellKnown(WellKnownSidType.LocalSystemSid) &&
                    !rule.SecurityIdentifier.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid))
                    throw new IOException("Collection root grants write access to another identity: " + path);
            }
        }

        public static void CreatePrivate(string path)
        {
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                security.SetOwner(identity.User);
                security.AddAccessRule(new FileSystemAccessRule(identity.User, FileSystemRights.FullControl,
                    inheritance, PropagationFlags.None, AccessControlType.Allow));
            }
            GCHandle descriptor = GCHandle.Alloc(security.GetSecurityDescriptorBinaryForm(), GCHandleType.Pinned);
            try
            {
                SecurityAttributes attributes = new SecurityAttributes();
                attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                attributes.Descriptor = descriptor.AddrOfPinnedObject();
                if (!CreateDirectory(path, ref attributes))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create private collection directory: " + path);
            }
            finally { descriptor.Free(); }
        }

        private void Pin(string path, bool create, bool denyWrite)
        {
            // Deny delete sharing throughout. The collection root additionally
            // denies write sharing to exclude handles used for reparse mutation.
            uint share = denyWrite ? 1u : 3u;
            uint access = denyWrite ? 0x20081u : 0x81u;
            SafeFileHandle handle = OpenFile(path, access, share, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                if (!create || (error != 2 && error != 3))
                    throw new Win32Exception(error, "Cannot pin output directory: " + path);
                try { CreatePrivate(path); }
                catch (Win32Exception exception)
                {
                    if (exception.NativeErrorCode != 183) throw;
                }
                handle = OpenFile(path, access, share, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            }
            try
            {
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot pin output directory: " + path);
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect output directory: " + path);
                if ((information.Attributes & 0x410) != 0x10)
                    throw new IOException("Output component is not a directory or is a reparse point: " + path);
                if (denyWrite) ValidateCollectionRoot(handle, path);
                handles.Add(handle);
                handle = null;
            }
            finally
            {
                if (handle != null) handle.Dispose();
            }
        }

        public static OutputDirectoryPin Open(string path, bool createMissing, bool denyLeafWrite)
        {
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            if (root.Length != 3 || root[1] != ':' || full.IndexOf(':', 2) >= 0)
                throw new ArgumentException("A local drive path without alternate streams is required.", "path");
            OutputDirectoryPin pin = new OutputDirectoryPin();
            try
            {
                string[] components = full.Substring(root.Length).Split(
                    new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
                pin.Pin(root, false, denyLeafWrite && components.Length == 0);
                string current = root;
                for (int index = 0; index < components.Length; ++index)
                {
                    current = Path.Combine(current, components[index]);
                    pin.Pin(current, createMissing, denyLeafWrite && index == components.Length - 1);
                }
                return pin;
            }
            catch
            {
                pin.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            for (int index = handles.Count - 1; index >= 0; --index) handles[index].Dispose();
            handles.Clear();
        }
    }

    // The folder Windows designates for this process's temporary files: GetTempPath2 where
    // kernel32 exports it, otherwise GetTempPath. Both return the same per-user folder for
    // callers other than SYSTEM, which the collector refuses.
    public static class TemporaryFolder
    {
        [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern IntPtr GetModuleHandle(string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, BestFitMapping = false)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);

        [DllImport("kernel32.dll", EntryPoint = "GetTempPath2W", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint GetTempPath2(uint length, [Out] char[] buffer);

        [DllImport("kernel32.dll", EntryPoint = "GetTempPathW", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint GetTempPath(uint length, [Out] char[] buffer);

        // Returns null when Windows reports no temporary folder.
        public static string GetPath()
        {
            // Both functions return at most MAX_PATH + 1 characters plus the terminator.
            char[] buffer = new char[262];
            IntPtr kernel32 = GetModuleHandle("kernel32.dll");
            bool hasTempPath2 = kernel32 != IntPtr.Zero && GetProcAddress(kernel32, "GetTempPath2W") != IntPtr.Zero;
            uint length = hasTempPath2 ? GetTempPath2((uint)buffer.Length, buffer) : GetTempPath((uint)buffer.Length, buffer);
            if (length == 0 || length >= buffer.Length) return null;
            return new string(buffer, 0, (int)length);
        }
    }

    // Reports a missing path without raising an exception. PowerShell records even a caught
    // exception in the caller's $Error and -ErrorVariable, so normal absence must not throw.
    public static class PathProbe
    {
        [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesW", CharSet = CharSet.Unicode,
            ExactSpelling = true, SetLastError = true)]
        private static extern uint GetFileAttributes(string path);

        // True only when Windows reports the path, or one of its parents, as not found. Access
        // denial and every other result return false, so the caller's own checks report them.
        // Paths of MAX_PATH or more keep the caller's .NET path handling.
        public static bool IsMissing(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length >= 260) return false;
            if (GetFileAttributes(path) != uint.MaxValue) return false;
            int error = Marshal.GetLastWin32Error();
            return error == 2 || error == 3;
        }
    }
}
'@
    }
}

function Open-UopOutputDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$CreateMissing,
        [switch]$DenyLeafWrite
    )

    Assert-UopLocalPath -Path $Path -RejectControlCharacters
    Initialize-UopNativeType
    [UopProviderDiagnostics.OutputDirectoryPin]::Open($Path, $CreateMissing.IsPresent, $DenyLeafWrite.IsPresent)
}

function Get-UopTempDirectory {
    # A session that compiled an earlier helper lacks TemporaryFolder; decoding then uses the bundle.
    Initialize-UopNativeType
    if (-not ('UopProviderDiagnostics.TemporaryFolder' -as [type])) { return $null }
    $path = [UopProviderDiagnostics.TemporaryFolder]::GetPath()
    if ([string]::IsNullOrEmpty($path)) { return $null }
    if ($path.Length -gt 3) { $path = $path.TrimEnd('\') }
    return $path
}

function Assert-AauLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-UopLocalPath -Path $Path
}

function Assert-UopNativeProcess {
    param(
        [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem,
        [bool]$Is64BitProcess = [Environment]::Is64BitProcess
    )

    # The module is serviced only for native PowerShell; under WOW64 the System32 module and
    # tracerpt paths resolve to other files, so stop before discovery or output.
    if ($Is64BitOperatingSystem -and -not $Is64BitProcess) {
        throw ('Get-UOPProviderLogs requires 64-bit Windows PowerShell on 64-bit Windows. Run it from ' +
            '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe (from a 32-bit process, use ' +
            '%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe).')
    }
}

function Get-UopCollectorContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        [pscustomobject]@{
            UserSid = if ($null -ne $identity.User) { $identity.User.Value } else { '' }
            IsService = $identity.Groups -contains [Security.Principal.SecurityIdentifier]::new('S-1-5-6')
            ImpersonationLevel = $identity.ImpersonationLevel
            ProfilePath = [Environment]::GetFolderPath('UserProfile')
            LocalAppDataPath = [Environment]::GetFolderPath('LocalApplicationData')
        }
    }
    finally { $identity.Dispose() }
}

function Get-UopProviderLogName {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    # Registry identities are labels, not trusted filesystem paths. Never sanitize
    # two different identities into the same filename or accept Windows device names.
    if ($ProviderId.Length -gt 200 -or $ProviderId -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or
        $ProviderId -match '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw "ProviderId cannot be used as a log filename: $(ConvertTo-AauLogText $ProviderId). Use an explicit -LogPath."
    }
    if ($ProviderId -ieq $script:AauProviderId) { $ProviderId = $script:AauProviderId }
    return "$ProviderId.log"
}

function Get-UopCollectionRoot {
    $localAppData = (Get-UopCollectorContext).LocalAppDataPath
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Directory]::Exists($localAppData)) {
        throw 'Default collection requires an existing Windows LocalApplicationData folder. Specify a safe explicit LogPath instead.'
    }
    Join-Path ([IO.Path]::GetFullPath($localAppData)) 'UOPProviderLogs'
}

function Get-UopCspLogPath {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    Join-Path ([IO.Path]::GetDirectoryName($LogPath)) `
        "$([IO.Path]::GetFileNameWithoutExtension($LogPath)).CSP.log"
}

function Get-UopReportingLogPath {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $stem = [IO.Path]::GetFileNameWithoutExtension($LogPath)
    $name = if ($stem -ieq $script:AauProviderId) { 'AAUReportingEvents.log' }
        else { "$stem.AAUReportingEvents.log" }
    Join-Path ([IO.Path]::GetDirectoryName($LogPath)) $name
}

function Assert-UopOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [object[]]$SourceSets = @(),
        [switch]$Force,
        [switch]$AllowMissingParent
    )

    Assert-AauLocalPath -Path $OutputPath
    $outputDirectory = [IO.Path]::GetDirectoryName($OutputPath)
    $protectedCanonical = Get-UopProviderDirectories -ProviderId $script:AauProviderId
    # Earlier deployments may still own these paths; exclusion does not enable legacy input discovery.
    $protectedDirectories = @(
        ([Environment]::GetFolderPath('Windows'))
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $script:UopStateRootRelativePath)
        $protectedCanonical.InputPath
        $protectedCanonical.StatePath
        (Join-Path ([Environment]::GetFolderPath('Windows')) "Logs\UOPProvider\$script:AauProviderId")
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "Microsoft\UOPProvider\$script:AauProviderId")
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Logs\AutomaticAppUpdater')
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\UOPProvider\AutomaticAppUpdater')
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\UOPProviders\AutomaticAppUpdater')
    )
    foreach ($privateDirectory in $protectedDirectories) {
        if ($OutputPath.StartsWith("$privateDirectory\", [StringComparison]::OrdinalIgnoreCase) -or
            $OutputPath.Equals($privateDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Output must be outside the protected Windows and UOP provider directories. Specify -LogPath with a file in an existing directory outside these roots, or omit it to use the default UOPProviderLogs collection directory."
        }
    }
    if ([IO.File]::Exists($outputDirectory)) {
        throw "Output parent must be a directory, not a file: $outputDirectory"
    }
    if (-not $AllowMissingParent -and -not [IO.Directory]::Exists($outputDirectory)) {
        throw "Output parent directory must already exist: $outputDirectory"
    }
    foreach ($sourceSet in $SourceSets) {
        $sourceDirectory = [IO.Path]::GetFullPath($sourceSet.Directory).TrimEnd('\')
        if ($OutputPath.StartsWith("$sourceDirectory\", [StringComparison]::OrdinalIgnoreCase) -or
            $sourceDirectory.StartsWith("$OutputPath\", [StringComparison]::OrdinalIgnoreCase) -or
            $OutputPath.Equals($sourceDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Output must be outside the input/state directories and cannot replace an input ancestor.'
        }
    }
    if ([IO.Directory]::Exists($OutputPath)) {
        throw "LogPath must name a file, not a directory: $OutputPath"
    }
    if ([IO.File]::Exists($OutputPath) -and -not $Force) {
        throw "Output already exists. Use -Force for intentional replacement: $OutputPath"
    }
}

function Copy-UopStreamBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Source,
        [Parameter(Mandatory = $true)][IO.Stream]$Destination,
        [Parameter(Mandatory = $true)][long]$Length
    )

    # Returns the SHA-256 of the bytes copied from the current position, or $null when the
    # source ends before Length bytes because it was truncated meanwhile.
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = [byte[]]::new(65536)
        $remaining = $Length
        while ($remaining -gt 0) {
            $read = $Source.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($read -eq 0) { return $null }
            $Destination.Write($buffer, 0, $read)
            [void]$hash.TransformBlock($buffer, 0, $read, $null, 0)
            $remaining -= $read
        }
        [void]$hash.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [BitConverter]::ToString($hash.Hash).Replace('-', '')
    }
    finally { $hash.Dispose() }
}

function Test-UopSnapshotCurrent {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Source,
        [Parameter(Mandatory = $true)][long]$Length,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    # A second read through the snapshot's own handle. A preallocated ETL keeps its length and
    # timestamp while it is written, so only its bytes show that a copy may be torn.
    if ($Source.Length -ne $Length) { return $false }
    $Source.Position = 0
    return (Copy-UopStreamBytes -Source $Source -Destination ([IO.Stream]::Null) -Length $Length) -eq $Sha256
}

function Copy-AauSnapshot {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [long]$MaximumBytes = [long]::MaxValue
    )

    Assert-AauLocalPath -Path $Source.FullName
    # Share read, write and delete so producers keep claiming, writing and rotating their files.
    $inputStream = [IO.File]::Open($Source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $outputStream = $null
    $sha256 = $null
    $stable = $false
    $attempts = 0
    try {
        # A source written during its copy is copied once more. A second change is reported, not hidden.
        do {
            $attempts++
            $before = [IO.File]::GetLastWriteTimeUtc($Source.FullName)
            $currentLength = $inputStream.Length
            if ($currentLength -gt $MaximumBytes) {
                if ($null -eq $sha256) {
                    throw "Input byte budget exceeded for '$($Source.FullName)' ($currentLength bytes; $MaximumBytes remaining)."
                }
                break
            }
            if ($null -eq $outputStream) {
                $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                    [IO.FileShare]::None)
            }
            else { $outputStream.SetLength(0) }
            $inputStream.Position = 0
            $copiedHash = Copy-UopStreamBytes -Source $inputStream -Destination $outputStream -Length $currentLength
            if ($null -eq $copiedHash) {
                if ($attempts -lt 2) { continue }
                throw "Source was truncated during collection: $($Source.FullName)"
            }
            $sha256 = $copiedHash
            $length = $currentLength
            $lastWriteTimeUtc = $before
            # Bytes decide: timestamps of a file open for writing can lag behind its content.
            $stable = Test-UopSnapshotCurrent -Source $inputStream -Length $length -Sha256 $sha256
        } while (-not $stable -and $attempts -lt 2)
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        $inputStream.Dispose()
    }
    [pscustomobject]@{
        Source = $Source.FullName
        Snapshot = $Destination
        Length = $length
        LastWriteTimeUtc = $lastWriteTimeUtc.ToString('o')
        UnchangedDuringCopy = $stable
        CopyAttempts = $attempts
        SHA256 = $sha256
    }
}

function Get-UopEtlSequence {
    param([Parameter(Mandatory = $true)][string]$Name)

    # AAU and CSP name each ETL <prefix>.YYYYMMDD.HHMMSS.mmm.<sequence>.etl. The local time in the name
    # can repeat when daylight saving ends; the sequence is one past every existing file of that prefix.
    # Any other name, a sequence with a leading zero, or one beyond UInt64 has no sequence ($null).
    $match = [regex]::Match($Name, '\A([A-Za-z0-9]+)\.[0-9]{8}\.[0-9]{6}\.[0-9]{3}\.([1-9][0-9]{0,19})\.etl\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $sequence = [UInt64]0
    if (-not $match.Success -or -not [UInt64]::TryParse($match.Groups[2].Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$sequence)) {
        return $null
    }
    [pscustomobject]@{ Prefix = $match.Groups[1].Value.ToUpperInvariant(); Sequence = $sequence }
}

function Get-UopEtlDecodeOrder {
    param([object[]]$Plans = @())

    # Newest first. The directory-listing time of the ETL still being written can lag behind its
    # predecessor's, so within one prefix the file-name sequence decides. Across prefixes, and for names
    # without a sequence, the last-write time read when each snapshot was taken decides. A sequenced file
    # is at least as new as every earlier file of its prefix, so it inherits their newest snapshot time.
    # Remaining ties fall back to prefix, sequence and path, so the order is deterministic.
    $items = @(foreach ($plan in $Plans) {
        $parsed = Get-UopEtlSequence -Name $plan.Source.Name
        [pscustomobject]@{
            Plan = $plan
            Prefix = $(if ($null -ne $parsed) { $parsed.Prefix } else { '' })
            Sequence = $(if ($null -ne $parsed) { $parsed.Sequence } else { [UInt64]0 })
            Time = $(if ($null -ne $plan.SnapshotTimeUtc) { $plan.SnapshotTimeUtc } else { [DateTime]::MinValue })
        }
    })
    foreach ($prefixGroup in @($items | Where-Object Prefix | Group-Object Prefix)) {
        $newest = [DateTime]::MinValue
        foreach ($item in @($prefixGroup.Group | Sort-Object Sequence, @{ Expression = { $_.Plan.Source.FullName } })) {
            if ($item.Time -gt $newest) { $newest = $item.Time }
            $item.Time = $newest
        }
    }
    $items | Sort-Object @{ Expression = 'Time'; Descending = $true }, @{ Expression = 'Prefix'; Descending = $false },
        @{ Expression = 'Sequence'; Descending = $true }, @{ Expression = { $_.Plan.Source.FullName }; Descending = $true } |
        ForEach-Object Plan
}

function Test-UopTextEndsWithNewline {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -eq 0) { return $true }
        [void]$stream.Seek(-1, [IO.SeekOrigin]::End)
        return $stream.ReadByte() -eq 10
    }
    finally { $stream.Dispose() }
}

function Test-UopSourceRemoved {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][Exception]$Exception)

    # Retention can delete a listed file before its snapshot. A file that is still being
    # deleted fails to open with access denied, so that case also requires the file to be gone.
    $cause = $Exception.GetBaseException()
    return $cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException] -or
        ($cause -is [UnauthorizedAccessException] -and -not [IO.File]::Exists($Path))
}

function Get-UopFailureCode {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    # Report a native status only when the failure carries one; script failures have none.
    $cause = $Exception.GetBaseException()
    if ($cause -is [ComponentModel.Win32Exception]) {
        return '0x{0:X8}' -f (0x80070000 -bor ($cause.NativeErrorCode -band 0xffff))
    }
    if ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException] -or
        $cause -is [Runtime.InteropServices.ExternalException]) {
        return '0x{0:X8}' -f $cause.HResult
    }
    return $null
}

function Get-UopSourceCounts {
    param([object[]]$Sources = @())

    [pscustomobject]@{
        Discovered = $Sources.Count
        Snapshotted = @($Sources | Where-Object { $null -ne $_.SnapshotPath }).Count
        Decoded = @($Sources | Where-Object Status -eq 'Decoded').Count
        PartiallyDecoded = @($Sources | Where-Object Status -eq 'PartiallyDecoded').Count
        Skipped = @($Sources | Where-Object Status -eq 'Skipped').Count
        Failed = @($Sources | Where-Object Status -eq 'Failed').Count
        ChangedDuringCopy = @($Sources | Where-Object ChangedDuringCopy).Count
    }
}

function Format-UopSourceCounts {
    param([Parameter(Mandatory = $true)][psobject]$Counts)

    "$($Counts.Discovered) discovered, $($Counts.Snapshotted) snapshotted, $($Counts.Decoded) decoded, " +
        "$($Counts.PartiallyDecoded) partially decoded, $($Counts.Skipped) skipped, $($Counts.Failed) failed, " +
        "$($Counts.ChangedDuringCopy) changed during copy"
}

# A later outcome adds its reason to a source record and never hides an earlier one, such as
# ChangedDuringCopy, whose flag alone does not say why.
function Add-UopSourceReason {
    param([Parameter(Mandatory = $true)][psobject]$Record, [Parameter(Mandatory = $true)][string]$Reason)

    $Record.Reason = if ([string]::IsNullOrEmpty($Record.Reason)) { $Reason } else { "$($Record.Reason) $Reason" }
}

function Read-UopProviderIds {
    param([Parameter(Mandatory = $true)]$RegistrationRoot)

    foreach ($name in $RegistrationRoot.GetSubKeyNames()) {
        $key = $RegistrationRoot.OpenSubKey($name, $false)
        if ($null -eq $key) { throw "Provider registration disappeared during discovery: $name" }
        try {
            $id = $key.GetValue('ProviderId', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
                throw "Provider registration has no valid ProviderId: $name"
            }
            $id
        }
        finally { $key.Dispose() }
    }
}

function Get-UopRegisteredProviderId {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $root = $baseKey.OpenSubKey('SOFTWARE\Microsoft\WindowsUpdate\UOPProviders\System', $false)
        if ($null -eq $root) { return }
        try { Read-UopProviderIds -RegistrationRoot $root }
        finally { $root.Dispose() }
    }
    finally { $baseKey.Dispose() }
}

function Get-UopProviderDirectories {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    # Internal path derivation only. Dispatch must recognize/canonicalize a registered ID first;
    # a derived directory does not imply that this module has an adapter for that provider.
    [pscustomobject]@{
        InputPath = Join-Path ([Environment]::GetFolderPath('Windows')) "$script:UopLogRootRelativePath\$ProviderId"
        StatePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "$script:UopStateRootRelativePath\$ProviderId"
        PayloadPath = Join-Path ([Environment]::GetFolderPath('Windows')) "System32\$script:UopPayloadRootRelativePath\$ProviderId"
    }
}

function Get-AauDefaultDirectories {
    $canonical = Get-UopProviderDirectories -ProviderId $script:AauProviderId
    [pscustomobject]@{
        InputPath = $canonical.InputPath
        StatePath = $canonical.InputPath
    }
}

function Get-UopSourceFiles {
    param([string]$Directory, [string]$Pattern)

    # Missing default roots are normal before the first provider run. Access denial is not:
    # attribute lookup distinguishes the two, whereas Get-Item reports both as "not found".
    # Probe for absence first: a caught exception would still add an error record to the
    # caller's $Error and -ErrorVariable for this normal state.
    Initialize-UopNativeType
    if (('UopProviderDiagnostics.PathProbe' -as [type]) -and
        [UopProviderDiagnostics.PathProbe]::IsMissing($Directory)) { return }
    # These catches cover a session that compiled an earlier helper, and a folder removed after the probe.
    try { $attributes = [IO.File]::GetAttributes($Directory) }
    catch [IO.FileNotFoundException] { return }
    catch [IO.DirectoryNotFoundException] { return }
    if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw "Expected a diagnostics directory: $Directory" }
    Assert-AauLocalPath -Path $Directory
    Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $Pattern }
}

function ConvertFrom-AauEventXml {
    param(
        [Parameter(Mandatory = $true)][xml]$EventXml,
        [Parameter(Mandatory = $true)][string]$SourceFile
    )

    $eventNode = $EventXml.DocumentElement
    $system = $eventNode.SelectSingleNode("*[local-name()='System']")
    if ($null -eq $system) {
        throw "Decoder event has no System metadata: $SourceFile"
    }
    $provider = $system.SelectSingleNode("*[local-name()='Provider']")
    if ($null -eq $provider) {
        throw "Decoder event has no provider identity: $SourceFile"
    }

    # tracerpt places classic ETL header/system records under the kernel trace
    # provider. Relogger metadata has no emitting provider identity at all.
    if ($provider.GetAttribute('Guid') -ieq '{68fdd900-4a3e-11d1-84f4-0000f80464e3}' -or
        $provider.GetAttribute('Guid') -ieq '{9e814aad-3204-11d2-9a82-006008a86939}' -or
        ([string]::IsNullOrEmpty($provider.GetAttribute('Guid')) -and
            [string]::IsNullOrEmpty($provider.GetAttribute('Name')))) {
        return
    }
    $time = $system.SelectSingleNode("*[local-name()='TimeCreated']")
    if ($null -eq $time -or -not $time.HasAttribute('SystemTime')) {
        throw "Decoder event has no timestamp: $SourceFile"
    }
    $timestamp = [DateTimeOffset]::Parse($time.GetAttribute('SystemTime'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    $emissionTimestamp = $timestamp
    $timestampSource = 'EventHeader'
    $execution = $system.SelectSingleNode("*[local-name()='Execution']")
    $correlation = $system.SelectSingleNode("*[local-name()='Correlation']")
    # Schema-neutral by design: SimpleTrace code-flow observations, WorkflowEvent business reports,
    # CspOperationResult telemetry facts and future named fields remain distinct decoder records.
    # Preserve XML scalar representations (especially UInt64/HRESULT/availability flags) without coercion,
    # and retain SourceFunction/SourceLine, correlation and type metadata rather than reconstructing them.
    $fields = @($eventNode.SelectNodes("*[local-name()='EventData']//*[local-name()='Data' or local-name()='ComplexData']") |
        ForEach-Object {
            $attributes = [ordered]@{}
            foreach ($attribute in $_.Attributes) {
                $attributes[$attribute.Name] = $attribute.Value
            }
            $fieldPath = $_.GetAttribute('Name')
            $parent = $_.ParentNode
            while ($parent.LocalName -ne 'EventData') {
                $fieldPath = "$($parent.GetAttribute('Name')).$fieldPath"
                $parent = $parent.ParentNode
            }
            [pscustomobject]@{
                Name = $_.GetAttribute('Name')
                Path = $fieldPath
                Kind = $_.LocalName
                Value = $(if ($_.LocalName -eq 'Data') { $_.InnerText } else { $null })
                Attributes = $attributes
                Xml = $_.OuterXml
            }
        })
    if ($fields.Count -eq 0 -or @($fields | Where-Object { [string]::IsNullOrEmpty($_.Name) }).Count -gt 0 -or
        $null -ne $eventNode.SelectSingleNode("*[local-name()='EventData']/*[local-name()='Binary']")) {
        throw "Event payload is not decoded into named fields in '$SourceFile'. Raw ETL is preserved; use a matching Windows decoder."
    }
    $metadata = [ordered]@{}
    foreach ($node in $system.ChildNodes) {
        $metadata[$node.LocalName] = $node.OuterXml
    }
    $rendering = $eventNode.SelectSingleNode("*[local-name()='RenderingInfo']")
    $eventNameNode = $eventNode.SelectSingleNode("*[local-name()='RenderingInfo']/*[local-name()='EventName']")
    if ($null -eq $eventNameNode) {
        $eventNameNode = $eventNode.SelectSingleNode("*[local-name()='RenderingInfo']/*[local-name()='Task']")
    }
    $extended = $eventNode.SelectSingleNode("*[local-name()='ExtendedTracingInfo']")
    $component = @($fields | Where-Object Name -eq 'Component' | Select-Object -First 1)
    $eventName = if ($null -ne $eventNameNode) { $eventNameNode.InnerText } else { $null }
    $processId = if ($null -ne $execution) { $execution.GetAttribute('ProcessID') } else { $null }
    $threadId = if ($null -ne $execution) { $execution.GetAttribute('ThreadID') } else { $null }
    if ($eventName -in @('SimpleTrace', 'WilFailure') -or
        ($eventName -eq 'Failure' -and (Test-UopCspProvider $provider.GetAttribute('Name')))) {
        # Deferred WIL emission runs on a worker. Use the original capture identity/time,
        # while retaining the complete ETW header and original payload in the JSON sidecar.
        foreach ($field in $fields) {
            if ($field.Path -ne $field.Name) { continue }
            $id = [uint32]0
            if ($field.Name -in @('ProcessId', 'ThreadId') -and
                [uint32]::TryParse($field.Value, [ref]$id) -and $id -ne 0) {
                if ($field.Name -eq 'ProcessId') { $processId = $field.Value.Trim() }
                else { $threadId = $field.Value.Trim() }
            }
            elseif ($field.Name -eq 'TimestampUtc') {
                if ([string]::IsNullOrWhiteSpace($field.Value)) { continue }
                $captured = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($field.Value, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$captured)) {
                    throw "Invalid captured timestamp in '$SourceFile': $($field.Value)"
                }
                $timestamp = $captured.ToUniversalTime()
                $timestampSource = 'Captured'
            }
        }
    }
    [pscustomobject]@{
        TimestampUtc = $timestamp.ToString('o')
        EmissionTimestampUtc = $emissionTimestamp.ToString('o')
        TimestampSource = $timestampSource
        Provider = $provider.GetAttribute('Name')
        ProviderId = $provider.GetAttribute('Guid')
        EventName = $eventName
        Component = $(if ($component.Count -gt 0) { $component[0].Value } else { $provider.GetAttribute('Name') })
        ProcessId = $processId
        ThreadId = $threadId
        ActivityId = $(if ($null -ne $correlation) { $correlation.GetAttribute('ActivityID') } else { $null })
        RelatedActivityId = $(if ($null -ne $correlation) { $correlation.GetAttribute('RelatedActivityID') } else { $null })
        SourceFile = $SourceFile
        Fields = $fields
        SystemMetadata = $metadata
        RenderingMetadata = $(if ($null -ne $rendering) { $rendering.OuterXml } else { $null })
        ExtendedMetadata = $(if ($null -ne $extended) { $extended.OuterXml } else { $null })
    }
}

function Sort-AauDecodedEvents {
    param([AllowEmptyCollection()][object[]]$Events = @())

    $sequence = [long]0
    foreach ($eventRecord in $Events) {
        $eventRecord | Add-Member NoteProperty CollectionSequence $sequence -Force
        $sequence++
    }
    # Equal timestamps do not establish causal order. Preserve ingestion order,
    # not provider/file alphabetization, and retain that tie breaker in the sidecar.
    $Events | Sort-Object @{
        Expression = {
            [DateTimeOffset]::Parse($_.TimestampUtc,
                [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.Ticks
        }
    }, CollectionSequence
}

function Read-AauDecodedEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [long]$MaximumBytes = 536870912
    )

    if ([IO.FileInfo]::new($Path).Length -gt $MaximumBytes) {
        throw "Decoded XML byte budget exceeded for '$SourceFile'. Raw ETL and decoder output are preserved."
    }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = $MaximumBytes
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        while (-not $reader.EOF) {
            if ($reader.NodeType -eq [Xml.XmlNodeType]::Element -and $reader.LocalName -eq 'Event') {
                $document = [Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.LoadXml($reader.ReadOuterXml())
                ConvertFrom-AauEventXml -EventXml $document -SourceFile $SourceFile
            }
            else {
                [void]$reader.Read()
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function ConvertTo-AauLogText {
    param([AllowNull()][string]$Value)

    # Keep one physical line per event; never interpret payload text as log structure. ' | '
    # separates fields, so a '|' in payload text becomes the literal text \u007C.
    return [regex]::Replace($Value, '[\p{Cc}\p{Cf}]', ' ').Trim().Replace('|', '\u007C')
}

function Format-AauResult {
    param([string]$Value)

    $number = 0L
    if ($Value -match '^0x[0-9a-fA-F]{1,8}$') {
        $number = [Convert]::ToInt64($Value.Substring(2), 16)
    }
    elseif (-not [long]::TryParse($Value, [ref]$number) -or
        $number -lt [int]::MinValue -or $number -gt [uint32]::MaxValue) {
        return $Value
    }
    return '0x{0:X8}' -f ($number -band 4294967295L)
}

function Test-AauSameGuid {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)

    $leftGuid = [Guid]::Empty
    $rightGuid = [Guid]::Empty
    return [Guid]::TryParse($Left, [ref]$leftGuid) -and [Guid]::TryParse($Right, [ref]$rightGuid) -and
        $leftGuid -eq $rightGuid
}

function Set-UopPolicyCoverage {
    param([Collections.IEnumerable]$Events)

    # This describes observed capture coverage, not delivery/ingestion or policy effectiveness.
    # Preserve original Fields. Never deduplicate copied/overlapping events or invent missing rows.
    $groups = @{}
    foreach ($event in $Events) {
        if ($event.EventName -ne 'PolicyStatusCritical' -or
            -not (Test-AauSameGuid $event.ProviderId '{584f8d8e-9a40-4c95-ad7b-1602a9895a5f}')) { continue }
        $coverage = [pscustomobject]@{
            PartCoverage = 'Invalid'; MissingPartCount = $null
            Reason = ''; PayloadLocation = 'DecodedEvents.jsonl'; ConflictFlags = $null
        }
        $event | Add-Member -NotePropertyName PolicyCoverage -NotePropertyValue $coverage -Force
        $group = $null
        try {
            $values = @{}
            $duplicates = $false
            foreach ($field in $event.Fields) {
                if ($field.Kind -ne 'Data' -or $field.Path -ne $field.Name) { continue }
                if ($values.ContainsKey($field.Name)) { $duplicates = $true }
                else { $values[$field.Name] = ([string]$field.Value).Trim() }
            }
            $snapshot = [guid]::Empty
            $process = [uint32]0
            if (-not [guid]::TryParse($values['snapshotId'], [ref]$snapshot) -or $snapshot -eq [guid]::Empty -or
                -not (Test-AauSameGuid $event.ActivityId $snapshot.ToString()) -or
                -not [uint32]::TryParse($event.ProcessId, [ref]$process) -or $process -eq 0) {
                throw [FormatException]::new('Missing or inconsistent snapshot/activity/process identity.')
            }
            # Include schema identity so parts from different schemas are never combined.
            $key = "$process/$snapshot/$($values['schemaVersion'])"
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = @{
                    Records = [Collections.Generic.List[object]]::new()
                    Indices = [Collections.Generic.HashSet[uint32]]::new()
                    Expected = $null; Duplicate = $false; Invalid = $false; ConflictFlags = $null
                }
            }
            $group = $groups[$key]
            $group.Records.Add($coverage)
            if ($duplicates) { throw [FormatException]::new('Duplicate top-level payload fields.') }
            if ($values['schemaVersion'] -notin @('1', '2')) {
                throw [FormatException]::new('Unsupported policy detail schema; raw fields retained.')
            }
            if ($values['schemaVersion'] -eq '2') {
                $conflicts = [byte]0
                if (-not [byte]::TryParse($values['conflictFlags'], [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$conflicts) -or
                    ($conflicts -band 0xfc) -ne 0) {
                    throw [FormatException]::new('Invalid or unavailable conflictFlags; raw fields retained.')
                }
                $coverage.ConflictFlags = $conflicts
                if ($null -eq $group.ConflictFlags) { $group.ConflictFlags = $conflicts }
                elseif ($group.ConflictFlags -ne $conflicts) {
                    throw [FormatException]::new('Conflicting conflictFlags within one snapshot.')
                }
            }
            if (-not $values.ContainsKey('policyStatus') -or [string]::IsNullOrEmpty($values['policyStatus']) -or
                ($values['policyStatus'].Length + 1) * 2 -gt 12 * 1024) {
                throw [FormatException]::new('Missing or oversized policyStatus payload.')
            }
            $numbers = @{}
            $names = @('partIndex', 'partCount')
            foreach ($name in $names) {
                $number = [uint64]0
                if (-not [uint64]::TryParse($values[$name], [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                    throw [FormatException]::new("Invalid or unavailable $name.")
                }
                $numbers[$name] = $number
            }
            if ($numbers.partCount -eq 0 -or $numbers.partCount -gt [uint32]::MaxValue -or
                $numbers.partIndex -ge $numbers.partCount) {
                throw [FormatException]::new('Invalid part indices/counts.')
            }
            # Policy snapshots are never truncated; every row is carried by some part.
            if ($values.ContainsKey('truncated') -or $values.ContainsKey('omittedRows') -or
                $values.ContainsKey('snapshotIncludedRows') -or $values.ContainsKey('maximumParts') -or
                $values.ContainsKey('maximumRows')) {
                throw [FormatException]::new('Policy snapshots cannot carry truncation fields.')
            }
            if ($null -eq $group.Expected) { $group.Expected = $numbers.partCount }
            elseif ($group.Expected -ne $numbers.partCount) {
                throw [FormatException]::new('Conflicting partCount within one snapshot.')
            }
            if (-not $group.Indices.Add([uint32]$numbers.partIndex)) { $group.Duplicate = $true }
        }
        catch [FormatException] {
            $coverage.Reason = $_.Exception.Message
            if ($null -ne $group) { $group.Invalid = $true }
        }
    }
    foreach ($group in $groups.Values) {
        $status = 'Invalid'
        $missing = $null
        if (-not $group.Invalid) {
            $missing = ([decimal]$group.Expected - $group.Indices.Count).ToString([Globalization.CultureInfo]::InvariantCulture)
            $status = if ($group.Duplicate) { 'Duplicate' }
                elseif ($group.Indices.Count -ne $group.Expected) { 'Missing' }
                else { 'Complete' }
        }
        foreach ($coverage in $group.Records) {
            $coverage.PartCoverage = $status
            $coverage.MissingPartCount = $missing
            if ($status -eq 'Invalid' -and -not $coverage.Reason) {
                $coverage.Reason = 'Conflicting or invalid part metadata.'
            }
        }
    }
}

function Format-AauEvent {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $values = @{}
    foreach ($field in $Event.Fields) {
        if ($field.Kind -eq 'Data' -and $field.Path -eq $field.Name) {
            # tracerpt pads numeric XML values; preserve those bytes in Fields, not the readable view.
            $values[$field.Name] = ([string]$field.Value).Trim()
        }
    }
    $result = ''
    foreach ($name in @('Result', 'HResult')) {
        if ($values.ContainsKey($name) -and $values[$name]) {
            $result = Format-AauResult $values[$name]
            break
        }
    }
    $isCspEvent = Test-UopCspProvider $Event.Provider
    $isWilFailure = $Event.EventName -in @('WilFailure', 'WilFailureEvent') -or
        ($isCspEvent -and $Event.EventName -eq 'Failure')
    $severity = 'Information'
    if ($values.ContainsKey('Verbosity')) {
        $severityNames = @{ '0' = 'Error'; '1' = 'Warning'; '2' = 'Information'; '3' = 'Verbose' }
        if ($severityNames.ContainsKey($values['Verbosity'])) {
            $severity = $severityNames[$values['Verbosity']]
        }
    }
    elseif ($Event.SystemMetadata.Contains('Level')) {
        $level = ([xml]$Event.SystemMetadata.Level).DocumentElement.InnerText
        $levelNames = @{ '1' = 'Critical'; '2' = 'Error'; '3' = 'Warning'; '4' = 'Information'; '5' = 'Verbose' }
        if ($levelNames.ContainsKey($level)) {
            $severity = $levelNames[$level]
        }
    }
    if ($result -match '^0x[89A-F]' -or $isWilFailure) {
        $severity = 'Error'
    }
    $component = $Event.Component
    if (Test-UopCspProvider $component) { $component = 'AppUpdateCSP' }
    elseif ((Test-UopProviderFamily -Identity $component -Root $script:AauProviderId) -or
        $component -in @('Microsoft.Windows.AutomaticAppUpdater', 'Microsoft.Windows.AutomaticAppUpdater.Diagnostics')) {
        $component = 'AAU'
    }
    $operation = $Event.EventName
    if ($values['OperationName']) { $operation = $values['OperationName'] }
    if ($values['StageName']) { $operation += "/$($values['StageName'])" }
    $hasNamedCspOperation = $isCspEvent -and $values['Operation'] -and $values['Operation'] -notmatch '^\d+$'
    if ($hasNamedCspOperation) {
        $operation = $values['Operation']
        if ($values['Phase']) { $operation += "/$($values['Phase'])" }
    }
    if (-not $operation) { $operation = 'Event' }
    $failureTypes = @{ '0' = 'thrown'; '1' = 'returned'; '2' = 'logged'; '3' = 'fail-fast' }
    if ($isWilFailure -and $values.ContainsKey('FailureType') -and $failureTypes.ContainsKey($values['FailureType'])) {
        $operation = "Failure $($failureTypes[$values['FailureType']])"
    }
    # The failure kind follows a field separator the collector writes, outside the payload text.
    $operationSuffix = ''
    if ($isWilFailure) {
        $failureKind = $operation
        $failureCode = if ($result -match '^0x[0-9A-Fa-f]{8}$') { $result.Substring(2) } else { 'unavailable' }
        $module = $values['SourceModule']
        if (-not $module) { $module = $values['ProcessName'] }
        $module = if ($module) { ($module -split '[\\/]')[-1] } else { 'module-unavailable' }
        $file = $values['SourceFile']
        if (-not $file) { $file = $values['File'] }
        $file = if ($file) { ($file -split '[\\/]')[-1] } else { '' }
        $fileLine = $values['SourceLine']
        if (-not $fileLine) { $fileLine = $values['Line'] }
        $operation = "*FAILED* [$failureCode] $module"
        if ($file) {
            $operation += ", $file"
            if ($fileLine) { $operation += " @$fileLine" }
        }
        $operationSuffix = " | $(ConvertTo-AauLogText $failureKind)"
    }
    $isScanDisposition = $Event.EventName -eq 'WorkflowEvent' -and
        $values['OperationName'] -eq 'Scan' -and $values['StageName'] -eq 'Disposition'
    if ($isScanDisposition -and $result) {
        if ($result -match '^0x[89A-F]') { $operation = 'Scan failed.' }
        elseif ($result -eq '0x00000000' -and $values.ContainsKey('ItemCount')) {
            $operation = "Scan completed; updates=$($values['ItemCount'])."
        }
    }
    $message = ConvertTo-AauLogText $values['Message']
    if ($Event.EventName -eq 'SimpleTrace' -and $message) {
        $operation = $message
        $message = ''
    }
    $timestamp = [TimeZoneInfo]::ConvertTime(
        [DateTimeOffset]::Parse($Event.TimestampUtc, [Globalization.CultureInfo]::InvariantCulture), $TimeZone)
    $scenario = if ($Event.PSObject.Properties['Scenario']) { "AAU/$($Event.Scenario) " } else { '' }
    $line = '{0} {1,6} {2,6} {3}{4,-18} {5,-11} {6}' -f
        $timestamp.ToString('yyyy/MM/dd HH:mm:ss.fffffff zzz', [Globalization.CultureInfo]::InvariantCulture),
        $Event.ProcessId, $Event.ThreadId, $scenario, (ConvertTo-AauLogText $component), $severity,
        ((ConvertTo-AauLogText $operation) + $operationSuffix)
    if ($message) { $line += " $message" }
    $details = [Collections.Generic.List[string]]::new()
    if ($Event.PSObject.Properties['PolicyCoverage']) {
        $coverage = $Event.PolicyCoverage
        $details.Add("PolicyParts=$($coverage.PartCoverage)")
        if ($null -ne $coverage.MissingPartCount) { $details.Add("MissingParts=$($coverage.MissingPartCount)") }
        $details.Add('PolicyPayload=DecodedEvents.jsonl')
        if ($coverage.Reason) { $details.Add("PolicyCoverageReason=$(ConvertTo-AauLogText $coverage.Reason)") }
    }
    if ($result -and $result -ne '0x00000000' -and -not $isWilFailure) {
        $resultLabel = if ($Event.EventName -eq 'WorkflowEvent') { 'OperationHResult' } else { 'Result' }
        $details.Add("$resultLabel=$result")
    }

    # File/line is sufficient to navigate source, without template-expanded compiler signatures.
    $source = ''
    foreach ($name in @('SourceFile', 'File')) {
        if ($values[$name]) {
            $source = ($values[$name] -split '[\\/]')[-1]
            break
        }
    }
    $sourceLine = $values['SourceLine']
    if (-not $sourceLine) { $sourceLine = $values['Line'] }
    if ($sourceLine -and $sourceLine -ne '0') {
        if ($source) { $source += ":$sourceLine" }
        else { $details.Add("SourceLine=$sourceLine") }
    }
    if ($source -and -not $isWilFailure) { $details.Add("Source=$(ConvertTo-AauLogText $source)") }
    if (-not $isWilFailure -and $values['SourceModule'] -and $values['SourceModule'] -ne $values['ProcessName']) {
        $details.Add("Module=$(ConvertTo-AauLogText $values['SourceModule'])")
    }
    if ($values['JobId'] -and $values['JobId'] -notmatch '^\{?00000000-0000-0000-0000-000000000000\}?$') {
        $details.Add("Job=$(ConvertTo-AauLogText $values['JobId'])")
    }
    foreach ($name in @('ActivityId', 'RelatedActivityId')) {
        $value = [string]$Event.$name
        if ($name -eq 'RelatedActivityId' -and (Test-AauSameGuid $value $values['JobId'])) { continue }
        if ($value -and $value -notmatch '^\{?00000000-0000-0000-0000-000000000000\}?$') {
            $label = if ($name -eq 'ActivityId') { 'Activity' } else { 'RelatedActivity' }
            $details.Add("$label=$(ConvertTo-AauLogText $value)")
        }
    }
    $omitted = @('SchemaVersion', 'Component', 'ComponentId', 'Verbosity', 'Message',
        'Result', 'HResult', 'SourceFile', 'File', 'SourceLine', 'Line', 'SourceFunction', 'Function',
        'OperationName', 'StageName', 'JobId', 'SourceModule', 'HasWorkflowContext', 'PointerBits', 'FrameCount', 'Terminal')
    foreach ($field in $Event.Fields) {
        $name = [string]$field.Name
        $value = ([string]$field.Value).Trim()
        if ($name -eq 'policyStatus' -and $Event.PSObject.Properties['PolicyCoverage']) { continue }
        if ($field.Kind -ne 'Data' -or $name -in $omitted -or
            $field.Path -match '(?i)stack|address|returnaddr|calleraddr|function|signature' -or
            $name -match 'Available$' -or [string]::IsNullOrWhiteSpace($value)) { continue }
        if (($name -eq 'Operation' -and $values['OperationName']) -or
            ($name -eq 'Stage' -and $values['StageName'])) { continue }
        if ($hasNamedCspOperation -and $name -in @('Operation', 'Phase')) { continue }
        if ($name -eq 'RootActivityId' -and (Test-AauSameGuid $value $values['JobId'])) { continue }
        if ($isWilFailure -and ($name -eq 'ProcessName' -or
                ($name -eq 'FailureType' -and $failureTypes.ContainsKey($value)))) { continue }
        if ($isScanDisposition -and (($name -in @('Disposition', 'OutcomeCode') -and $value -eq '0') -or
                ($name -eq 'ItemCount' -and $operation.StartsWith('Scan completed;')))) { continue }
        if ($Event.EventName -eq 'WorkflowEvent' -and $value -eq '0' -and
            (($name -eq 'Progress' -and $values['StageName'] -ne 'Progress') -or
                ($name -eq 'Disposition' -and $values['StageName'] -ne 'Disposition'))) { continue }
        if ($name -eq 'SourceModule' -and $value -eq $values['ProcessName']) { continue }
        if (($name -eq 'ProcessId' -and $value -eq $Event.ProcessId) -or
            ($name -eq 'ThreadId' -and $value -eq $Event.ThreadId) -or
            ($name -eq 'OriginalWilThreadId' -and $value -eq $Event.ThreadId)) { continue }
        if ($name -eq 'TimestampUtc') {
            $captured = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$captured) -and $captured -eq $timestamp) { continue }
        }
        $availability = $values["${name}Available"]
        if ($name -eq 'DurationMilliseconds') { $availability = $values['DurationAvailable'] }
        if ($availability -in @('false', '0')) { continue }
        if ($name -eq 'ContextResult' -and $values['ContextAvailable'] -in @('false', '0')) { continue }
        if ($value -match '^\{?00000000-0000-0000-0000-000000000000\}?$' -or
            ($value -eq 'false' -and $name -match 'Truncated$|^(Terminal|RebootRequired|HasWorkflowContext|CorrelationOverflow)$') -or
            ($value -match '^(0|0x0+)$' -and $name -in @('Flags', 'FailureFlags', 'ContextResult', 'NtStatus',
                'OriginatingContextId', 'CurrentContextId', 'OriginalWilThreadId'))) {
            continue
        }
        if ($name -match '(Result|HResult|ExtendedError)$' -or $name -eq 'NtStatus') { $value = Format-AauResult $value }
        $label = $field.Path
        if ($name -in @('__TlgCV__', 'CorrelationVector')) { $label = 'CV' }
        $details.Add("$(ConvertTo-AauLogText $label)=$(ConvertTo-AauLogText $value)")
    }
    if ($details.Count -gt 0) { $line += ' | ' + ($details -join ' | ') }
    return $line
}

function Wait-UopDecoderExit {
    param($Process, [int]$TimeoutSeconds)

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        # Stop only our decoder. Never terminate another collection or leave our process behind.
        try { $Process.Kill() }
        catch [InvalidOperationException] {
            if (-not $Process.HasExited) { throw }
        }
        $Process.WaitForExit()
        throw "tracerpt exceeded the $TimeoutSeconds-second timeout. Raw ETL and partial decoder output are preserved."
    }
    # The timed wait does not guarantee completion of redirected stdout/stderr callbacks.
    $Process.WaitForExit()
}

function Start-UopDecoderProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )

    # Process.Start keeps the handle from process creation, so the exit code of a decoder that
    # exits before it is awaited stays readable; Windows PowerShell's Start-Process closes that
    # handle before returning. Output bytes are copied unchanged into the evidence files.
    $startInfo = [Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $outputs = [Collections.Generic.List[IO.FileStream]]::new()
    $process = $null
    try {
        foreach ($path in @($OutputPath, $ErrorPath)) {
            $outputs.Add([IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read))
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $pipes = @($process.StandardOutput, $process.StandardError)
        $drains = @(
            $pipes[0].BaseStream.CopyToAsync($outputs[0])
            $pipes[1].BaseStream.CopyToAsync($outputs[1])
        )
        [pscustomobject]@{ Process = $process; Pipes = $pipes; Drains = $drains; Outputs = $outputs.ToArray() }
    }
    catch {
        if ($null -ne $process) {
            # Never leave our own decoder running; InvalidOperationException means it already exited.
            try { if (-not $process.HasExited) { $process.Kill() } }
            catch [InvalidOperationException] { }
            $process.WaitForExit()
            $process.Dispose()
        }
        foreach ($stream in $outputs) { $stream.Dispose() }
        throw
    }
}

function Complete-UopDecoderProcess {
    param([Parameter(Mandatory = $true)][psobject]$Run, [int]$TimeoutSeconds)

    # Returns the decoder's exit code once it has exited and its output is drained.
    Wait-UopDecoderExit -Process $Run.Process -TimeoutSeconds $TimeoutSeconds
    if (@($Run.Drains).Count -gt 0 -and
        -not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Run.Drains), $TimeoutSeconds * 1000)) {
        throw "tracerpt output was not complete $TimeoutSeconds seconds after it exited. Raw ETL and partial decoder output are preserved."
    }
    $exitCode = $null
    try { $exitCode = $Run.Process.ExitCode }
    catch { throw "tracerpt exit code unavailable: $($_.Exception.GetBaseException().Message) Raw ETL and decoder output are preserved." }
    if ($exitCode -isnot [int]) {
        throw 'tracerpt exit code unavailable; the decoder result cannot be confirmed. Raw ETL and decoder output are preserved.'
    }
    return $exitCode
}

function Stop-UopDecoderProcess {
    param([Parameter(Mandatory = $true)][psobject]$Run)

    # Stops only this collection's own decoder, then releases its handle and output files.
    # Returns $true once the decoder's exit is confirmed.
    $process = $Run.Process
    try {
        if (-not $process.HasExited) {
            try { $process.Kill() }
            catch [InvalidOperationException] {
                if (-not $process.HasExited) { throw }
            }
            $process.WaitForExit()
        }
        return $true
    }
    finally {
        foreach ($stream in @($Run.Outputs)) { $stream.Dispose() }
        # Process.Dispose leaves redirected pipes open. Close them once their copies finished;
        # closing a pipe under a pending synchronous read can block, so an unfinished copy keeps it.
        if (@($Run.Drains | Where-Object { -not $_.IsCompleted }).Count -eq 0) {
            foreach ($pipe in @($Run.Pipes)) { $pipe.Dispose() }
        }
        $process.Dispose()
    }
}

function Assert-UopDecoderPaths {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if ($path.Length -ge 260) {
            throw "Decoder path is too long ($($path.Length) characters; maximum 259): '$path'. Choose a shorter -LogPath."
        }
    }
}

function Get-UopOverlongPath {
    param([string[]]$FilePaths = @(), [string[]]$DirectoryPaths = @())

    # Without long-path support Windows rejects file paths of 260 or more characters, and
    # directory creation that leaves no room for an 8.3 child name (248 or more).
    foreach ($path in $DirectoryPaths) {
        if ($path.Length -ge 248) { return [pscustomobject]@{ Path = $path; Maximum = 247 } }
    }
    foreach ($path in $FilePaths) {
        if ($path.Length -ge 260) { return [pscustomobject]@{ Path = $path; Maximum = 259 } }
    }
}

function Assert-UopCollectorPathLength {
    param([string[]]$FilePaths = @(), [string[]]$DirectoryPaths = @())

    $overlong = Get-UopOverlongPath -FilePaths $FilePaths -DirectoryPaths $DirectoryPaths
    if ($null -ne $overlong) {
        throw ("Collector path is too long ($($overlong.Path.Length) characters; maximum $($overlong.Maximum)): " +
            "'$($overlong.Path)'. Choose a shorter -LogPath.")
    }
}

function Get-UopBundlePath {
    param([Parameter(Mandatory = $true)][string]$OutputPath, [Parameter(Mandatory = $true)][string]$CollectionId)

    Join-Path ([IO.Path]::GetDirectoryName($OutputPath)) "UOPProviderLogs.$CollectionId.diagnostics"
}

function Get-UopRetainedReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [AllowNull()][string]$SnapshotPath
    )

    # An unpublished reporting copy duplicates its bundle snapshot. Naming it after that
    # snapshot keeps failure retention within the snapshot's path budget.
    $name = if ($Scenario -eq 'Reporting') {
        'Collected.' + $SnapshotPath.Substring($BundlePath.Length + 1).Replace('\', '.')
    } else { "Collected.$Scenario.log" }
    Join-Path $BundlePath $name
}

function Assert-UopCollectionPathLength {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string[]]$ReportPaths,
        [Parameter(Mandatory = $true)][string]$CollectionId,
        [switch]$IncludeSourceNames
    )

    # Every path fixed by the output location is checked before anything is created, so
    # -WhatIf and the real run agree. Source names in the AAU layout are bounded by the
    # short snapshot name, its longest decoder output, its retained copy, and the CSP-text
    # and archive copies beside the reports (each staged with a .<id>.tmp suffix).
    $bundlePath = Get-UopBundlePath -OutputPath $OutputPath -CollectionId $CollectionId
    $outputDirectory = [IO.Path]::GetDirectoryName($OutputPath)
    $files = @(
        foreach ($name in @('Collection.json', 'DecodedEvents.jsonl', 'Collected.UOP.log', 'Collected.CSP.log')) {
            Join-Path $bundlePath $name
        }
        foreach ($path in $ReportPaths) { $path; "$path.$CollectionId.tmp" }
        if ($IncludeSourceNames) {
            $longestSuffix = @($script:UopDecoderOutputSuffixes.Values | Sort-Object Length)[-1]
            Join-Path $bundlePath "Source9999.etl$longestSuffix"
            Join-Path $bundlePath 'Collected.Source9999.log'
            $stem = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
            $reportingStem = [IO.Path]::GetFileNameWithoutExtension((Get-UopReportingLogPath -LogPath $OutputPath))
            "$(Join-Path $outputDirectory "$stem.AppUpdateCSP.7.log").$CollectionId.tmp"
            "$(Join-Path $outputDirectory "$reportingStem.9999.log").$CollectionId.tmp"
        }
    )
    Assert-UopCollectorPathLength -FilePaths $files -DirectoryPaths @($outputDirectory, $bundlePath)
}

function Get-UopSnapshotLayout {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$SourceName,
        [Parameter(Mandatory = $true)][int]$Index,
        [bool]$IsDuplicateName,
        [bool]$Decode,
        [bool]$HasReportCopy
    )

    # Keep the original name when every retained path fits. Otherwise keep the same bytes
    # under a short per-source name; the manifest maps it back to the original source.
    $folder = 'Source{0:D4}' -f $Index
    $original = if ($IsDuplicateName) { Join-Path (Join-Path $BundlePath $folder) $SourceName }
        else { Join-Path $BundlePath $SourceName }
    $shortened = Join-Path $BundlePath "$folder$([IO.Path]::GetExtension($SourceName))"
    foreach ($path in @($original, $shortened)) {
        $directory = [IO.Path]::GetDirectoryName($path)
        $retained = @(
            $path
            if ($Decode) { foreach ($suffix in $script:UopDecoderOutputSuffixes.Values) { "$path$suffix" } }
            if ($HasReportCopy) { Get-UopRetainedReportPath -BundlePath $BundlePath -Scenario 'Reporting' -SnapshotPath $path }
        )
        if ($null -eq (Get-UopOverlongPath -FilePaths $retained -DirectoryPaths @($directory))) {
            return [pscustomobject]@{ Directory = $directory; Path = $path; Shortened = $path -ne $original }
        }
    }
    Assert-UopCollectorPathLength -FilePaths $retained -DirectoryPaths @($directory)
}

function New-UopSourcePlan {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$Source,
        [Parameter(Mandatory = $true)][int]$Index,
        [bool]$IsDuplicateName,
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ReportingOutputPath,
        [Parameter(Mandatory = $true)][string]$CollectionId,
        [object[]]$SourceSets = @(),
        [bool]$Decode,
        [switch]$Force
    )

    $folder = 'Source{0:D4}' -f $Index
    $scenario = if ($Source.Extension -ine '.etl') { 'Reporting' }
        elseif ($Source.Name -like 'AppUpdateCSP.*') { 'CSP' } else { 'UOP' }
    # Text evidence is also published byte-for-byte beside the reports under documented names.
    $reportKind = $null
    $reportPath = $null
    if ($Source.Name -ieq 'AAUReportingEvents.log') {
        $reportKind = 'ReportingLog'
        $reportPath = $ReportingOutputPath
    }
    elseif ($Source.Name -match '^AppUpdateCSP\.[0-7]\.log$') {
        $reportKind = 'CspText'
        $name = "$([IO.Path]::GetFileNameWithoutExtension($OutputPath)).$($Source.Name)"
        if ($IsDuplicateName) { $name = "$folder.$name" }
        $reportPath = Join-Path ([IO.Path]::GetDirectoryName($OutputPath)) $name
    }
    elseif ($scenario -eq 'Reporting') {
        $reportKind = 'ReportingArchive'
        $stem = [IO.Path]::GetFileNameWithoutExtension($ReportingOutputPath)
        if ($IsDuplicateName) { $stem += ".$folder" }
        $reportPath = Join-Path ([IO.Path]::GetDirectoryName($ReportingOutputPath)) `
            "$stem$($Source.Name.Substring('AAUReportingEvents'.Length))"
    }
    if ($reportKind -in @('CspText', 'ReportingArchive')) {
        Assert-UopOutputPath -OutputPath $reportPath -SourceSets $SourceSets -Force:$Force
    }
    if ($null -ne $reportPath) {
        Assert-UopCollectorPathLength -FilePaths @($reportPath, "$reportPath.$CollectionId.tmp")
    }
    $layout = Get-UopSnapshotLayout -BundlePath $BundlePath -SourceName $Source.Name -Index $Index `
        -IsDuplicateName $IsDuplicateName -Decode ($Decode -and $scenario -ne 'Reporting') `
        -HasReportCopy ($null -ne $reportPath)
    [pscustomobject]@{
        Source = $Source
        Scenario = $scenario
        # Decoded events name their source file, independent of the retained snapshot name.
        Label = $(if ($IsDuplicateName) { "$folder\$($Source.Name)" } else { $Source.Name })
        SnapshotDirectory = $layout.Directory
        SnapshotPath = $layout.Path
        Shortened = $layout.Shortened
        ReportKind = $reportKind
        ReportPath = $reportPath
        # Last-write time read when the source was copied. Orders decoding where the name has no
        # writer sequence; the directory-listing time of a file still being written can lag.
        SnapshotTimeUtc = $null
        # Events decoded from this source, merged into the collection in source order.
        Events = [Collections.Generic.List[object]]::new()
        # Public per-source outcome. Status ends as Collected, Decoded, PartiallyDecoded, Skipped or Failed.
        Record = [pscustomobject]@{
            Name = $Source.Name; Source = $Source.FullName; Scenario = $scenario; Status = 'Discovered'
            SnapshotPath = $null; EventCount = $null; Reason = $null; HResult = $null; ChangedDuringCopy = $false
        }
    }
}

function Get-UopPathAttributeMask {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Union of the attributes of the path and every existing ancestor.
    $mask = 0
    $current = $Path
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $mask = $mask -bor [int][IO.File]::GetAttributes($current)
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $mask
}

function Test-UopPathHasReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Mirrors Assert-UopLocalPath as a predicate so optional workspace parents can be
    # declared ineligible (for example a redirected temporary folder) without a failure.
    return ((Get-UopPathAttributeMask -Path $Path) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
}

function Test-UopCloudSyncedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # A synchronized folder can expose decoder copies to its sync client, whose locks can also
    # break transfer and cleanup, even without a reparse point. OneDrive is recognized by its
    # per-user roots and by Windows cloud-file attributes (recall on open or on data access,
    # pinned, unpinned). Other sync clients cannot be detected in general.
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '\A[A-Za-z]:\\') { continue }
        $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $cloudFileAttributes = 0x40000 -bor 0x80000 -bor 0x100000 -bor 0x400000
    return ((Get-UopPathAttributeMask -Path $fullPath) -band $cloudFileAttributes) -ne 0
}

function New-UopTempWorkspaceError {
    param([Parameter(Mandatory = $true)][string]$TempDirectory, [Parameter(Mandatory = $true)][Exception]$Exception)

    # The original exception stays inner so callers still see the genuine Win32 cause.
    [IO.IOException]::new(("Cannot create the temporary decoder folder in '$TempDirectory': " +
        "$($Exception.GetBaseException().Message) Raw ETLs are still collected. Allow folder creation there " +
        'or set TEMP and TMP to a writable local folder and rerun, or rerun with -RawOnly to collect raw logs ' +
        'without decoding.'), $Exception)
}

function Invoke-UopEtlDecoder {
    param([string]$Decoder, [string]$SnapshotPath, [int]$TimeoutSeconds = 120)

    # Decode in a private folder under the collecting user's temporary folder, then move the
    # outputs beside the retained snapshot. When that folder is unavailable or ineligible, the
    # owned snapshot directory inside the bundle is the only fallback.
    $root = [IO.Path]::GetDirectoryName($SnapshotPath)
    $temp = Get-UopTempDirectory
    $useTemp = -not [string]::IsNullOrWhiteSpace($temp) -and $temp.Length -lt 248 -and $temp -match '\A[A-Za-z]:\\' -and
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($temp)).DriveType -ne [IO.DriveType]::Network -and
        -not (Test-UopPathHasReparsePoint -Path $temp) -and -not (Test-UopCloudSyncedPath -Path $temp)
    $tempNames = @{
        i = 'input.etl'; x = 'events.xml'; m = 'schema.man'; d = 'metadata.xml'
        s = 'summary.txt'; o = 'decoder.txt'; e = 'decoder-errors.txt'
    }
    $rootPin = $null
    $workspace = $null
    $workspacePin = $null
    $decoderStopped = $true
    $failure = $null
    $preservationFailure = $null
    $outputs = [ordered]@{}
    foreach ($name in $script:UopDecoderOutputSuffixes.Keys) {
        $outputs[$name] = "$SnapshotPath$($script:UopDecoderOutputSuffixes[$name])"
    }
    try {
        # Names need uniqueness, not secrecy: create atomically and never adopt a collision.
        for ($attempt = 0; $attempt -lt 16; ++$attempt) {
            if ($useTemp) {
                $workspaceRoot = $temp
                $leaf = 'UOPDecode.' + [IO.Path]::GetRandomFileName().Replace('.', '')
            }
            else {
                $workspaceRoot = $root
                $width = 1 + [int][Math]::Floor($attempt / 4)
                $letters = [IO.Path]::GetRandomFileName() -replace '[^a-z]', ''
                if ($letters.Length -lt $width) { continue }
                $leaf = $letters.Substring(0, $width)
                if ($leaf -match '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z') { continue }
            }
            $candidate = Join-Path $workspaceRoot $leaf
            # A taken name is skipped before creation, so the normal case raises no exception.
            if ([IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate)) { continue }
            $paths = @{}
            foreach ($name in @('i') + @($outputs.Keys)) {
                $filename = if ($useTemp) { $tempNames[$name] } else { $name }
                $paths[$name] = Join-Path $candidate $filename
            }
            if ($useTemp -and @($paths.Values | Where-Object { $_.Length -ge 260 }).Count -gt 0) {
                $useTemp = $false
                continue
            }
            Assert-UopDecoderPaths -Paths @($paths.Values)
            if ($null -eq $rootPin) {
                # A missing temporary folder falls back to the bundle. Probe for it first: a caught
                # exception would record an error even though decoding then succeeds.
                if ($useTemp -and ('UopProviderDiagnostics.PathProbe' -as [type]) -and
                    [UopProviderDiagnostics.PathProbe]::IsMissing($workspaceRoot)) {
                    $useTemp = $false
                    continue
                }
                try { $rootPin = Open-UopOutputDirectory -Path $workspaceRoot }
                catch {
                    $cause = $_.Exception.GetBaseException()
                    if ($useTemp -and $cause -is [ComponentModel.Win32Exception] -and
                        $cause.NativeErrorCode -in @(2, 3)) {
                        $useTemp = $false
                        continue
                    }
                    if ($useTemp) { throw (New-UopTempWorkspaceError -TempDirectory $temp -Exception $_.Exception) }
                    throw
                }
            }
            try { [UopProviderDiagnostics.OutputDirectoryPin]::CreatePrivate($candidate) }
            catch {
                if ($_.Exception.GetBaseException() -is [ComponentModel.Win32Exception] -and
                    $_.Exception.GetBaseException().NativeErrorCode -eq 183) { continue }
                if ($useTemp) { throw (New-UopTempWorkspaceError -TempDirectory $temp -Exception $_.Exception) }
                throw
            }
            $workspace = $candidate
            break
        }
        if ($null -eq $workspace) { throw "Cannot create a unique private decoder workspace beneath '$workspaceRoot'." }
        $workspacePin = Open-UopOutputDirectory -Path $workspace -DenyLeafWrite
        $rootPin.Dispose()
        $rootPin = $null
        [IO.File]::Copy($SnapshotPath, $paths.i, $false)
        $decoderArguments = @($paths.i, '-o', $paths.x, '-of', 'XML', '-y',
            '-export', $paths.m, '-int', $paths.d, '-summary', $paths.s)
        # Every argument is a fixed switch or a Windows filename (which cannot contain a quote).
        $arguments = ($decoderArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $decoderRun = Start-UopDecoderProcess -FilePath $Decoder -Arguments $arguments -WorkingDirectory $workspace `
            -OutputPath $paths.o -ErrorPath $paths.e
        $decoderStopped = $false
        try { $decoderExitCode = Complete-UopDecoderProcess -Run $decoderRun -TimeoutSeconds $TimeoutSeconds }
        finally { $decoderStopped = Stop-UopDecoderProcess -Run $decoderRun }
        if ($decoderExitCode -ne 0 -or -not [IO.File]::Exists($paths.x)) {
            $decoderMessage = "tracerpt exit code $decoderExitCode. See '$($outputs.o)'."
            # Carry the native exit status so the collection can report it for this ETL.
            if ($decoderExitCode -ne 0) {
                throw [Runtime.InteropServices.ExternalException]::new($decoderMessage, $decoderExitCode)
            }
            throw $decoderMessage
        }
    }
    catch { $failure = $_ }
    finally {
        try {
            if ($null -ne $workspace) {
                try {
                    if ($null -eq $workspacePin) { throw 'Private decoder workspace could not be pinned; its files must not be accessed.' }
                    if (-not $decoderStopped) { throw 'Owned decoder exit could not be confirmed; its files must not be moved or removed.' }
                    foreach ($name in $outputs.Keys) {
                        if ([IO.File]::Exists($paths[$name])) {
                            try {
                                [IO.File]::Move($paths[$name], $outputs[$name])
                            }
                            catch { throw "Cannot preserve '$($paths[$name])' as '$($outputs[$name])': $($_.Exception.Message)" }
                        }
                    }
                    # Delete the owned input while the pin still prevents workspace replacement.
                    [IO.File]::Delete($paths.i)
                }
                catch { $preservationFailure = $_ }
                finally {
                    if ($null -ne $workspacePin) { $workspacePin.Dispose() }
                }
                if ($null -eq $preservationFailure) {
                    try { [IO.Directory]::Delete($workspace, $false) }
                    catch { $preservationFailure = $_ }
                }
            }
        }
        finally {
            if ($null -ne $rootPin) { $rootPin.Dispose() }
        }
    }
    if ($null -ne $preservationFailure) {
        $decoderFailure = if ($null -ne $failure) { "$($failure.Exception.Message) " } else { '' }
        throw "${decoderFailure}Decoder evidence transfer or cleanup failed: $($preservationFailure.Exception.Message) Private workspace retained at '$workspace'."
    }
    if ($null -ne $failure) { throw $failure }
    $outputs.x
}

function Format-UopLogCollectionReport {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    $lines = @(
        "UOP provider logs: $($Result.Status) ($($Result.EventCount) events)"
        if ($Result.PSObject.Properties['SourceCounts'] -and $null -ne $Result.SourceCounts -and
            $Result.SourceCounts.Discovered -gt 0) {
            "Sources: $(Format-UopSourceCounts $Result.SourceCounts)"
        }
        if ($Result.LogPath) { "Log: $($Result.LogPath)" }
        if ($Result.CspLogPath) { "CSP log: $($Result.CspLogPath)" }
        if ($Result.ReportingLogPath) { "Reporting log: $($Result.ReportingLogPath)" }
        foreach ($path in $Result.CspTextLogPaths) {
            if ($path) { "CSP text: $path" }
        }
        if ($Result.BundlePath) { "Diagnostics: $($Result.BundlePath)" }
    )
    $lines -join [Environment]::NewLine
}

function Get-UOPProviderLogs {
    <#
    .SYNOPSIS
    Snapshots and decodes registered native UOP provider diagnostics.
    .DESCRIPTION
    Enumerates ProviderId values beneath the 64-bit HKLM registry key
    SOFTWARE\Microsoft\WindowsUpdate\UOPProviders\System. Only built-in adapters
    select files: registry paths, commands and executables are never used.
    Unrecognized registered providers have explicit Unsupported status.
    The Microsoft.Windows.Update.AutomaticAppUpdater adapter reads
    AutomaticAppUpdater.*.etl, AppUpdateCSP.*.etl and AppUpdateCSP.[0-7].log from the diagnostics
    directory, plus AAUReportingEvents.log and its numbered archives from
    the reporting directory, without recursion. Writes readable event lines in the
    decoding device's local time zone, applying daylight-saving rules at each event.
    The header identifies that time zone; event ordering and JSON timestamps remain UTC.
    Offline captures use the decoding device's zone, not the source device's zone.
    Historical Microsoft.Windows.AutomaticAppUpdater[.Diagnostics] component names
    still display as AAU; structured decoded records retain their original names.
    Writes
    to UOPProviderLogs\<yyyyMMdd-HHmmss-fff>.<GUID>\<ProviderId>.log and a separate
    <ProviderId>.CSP.log under the caller's Windows LocalApplicationData folder. When present,
    AAUReportingEvents.log and numbered archives are copied byte-for-byte into the same output folder
    and retained even without KeepDiagnostics. The eight rotating CSP text log slots
    are also copied byte-for-byte and retained without KeepDiagnostics; they are
    not decoded ETW events and do not contribute to EventCount.
    Collection requires -IncludeAllLogs or -ProviderId; without either, no discovery
    or output occurs. Successful
    collection removes its temporary diagnostic workspace unless -KeepDiagnostics
    or -RawOnly is specified. Retained bundles contain raw snapshots, decoder XML,
    schemas, interpreted metadata and summaries at the root of a unique directory
    under the chosen output directory, safe to delete when no longer needed.
    Each ETL is decoded in a private UOPDecode.<random> folder in your temporary folder
    (the per-user folder Windows designates, normally %TEMP%); outputs are moved back into
    the bundle and the folder is removed. The temporary folder is not used when it is
    missing or not local, when a reparse point is on its path, when it is inside a OneDrive
    root (the OneDrive, OneDriveCommercial or OneDriveConsumer environment folders), when it
    carries Windows cloud-file attributes, or when a decoder path there would reach 260
    characters. Decoding then uses a short private folder inside the bundle. Other sync
    clients cannot be detected. If moving outputs back fails, the folder is kept and its
    path reported.
    Every source is snapshotted before any ETL is decoded, so a long decode cannot
    let retention remove a source that is still waiting to be copied. ETLs are then
    decoded newest first, so a reached -MaxEvents budget keeps the most recent history;
    reports and DecodedEvents.jsonl stay in chronological order.
    Every path the collector creates or passes to tracerpt stays below 260
    characters (directories below 248), whether or not Windows long paths are
    enabled. When an original name would exceed that, the snapshot and its decoder
    outputs are retained as Source<NNNN> plus the original extension; Collection.json
    maps each snapshot to its original source. When the output location itself is
    too deep for the reports, the bundle or the longest per-source names
    (Source9999.etl.decoder-errors.txt, <name>.AppUpdateCSP.7.log and
    <reporting name>.9999.log staged with .<GUID>.tmp), the command fails before
    creating anything, including with -WhatIf, and names the path; choose a shorter -LogPath.
    The private type that pins directories is compiled once per session. Windows
    PowerShell compiles it in TMP/TEMP when that path is ASCII, at most 200
    characters and contains no '~', otherwise in a new private folder under the
    Windows temporary folder; 8.3 aliases are not used. While the compiler runs,
    TMP and TEMP name that folder, because the compiler cannot use a TEMP outside
    the ANSI code page; both are restored afterwards. If no folder is usable, the
    command fails immediately and explains how to set TEMP and TMP.
    Requires 64-bit Windows PowerShell on 64-bit Windows; a 32-bit (WOW64) process
    fails before discovery and names the 64-bit powershell.exe to use.
    tracerpt is started with its own process handle, so its real exit code is always
    reported; a code that cannot be read is an explicit failure.
    Requires a non-service user account with an existing Windows profile.
    SYSTEM, service identities and impersonated contexts are rejected before discovery
    or file creation, including with explicit paths, RawOnly and WhatIf.
    Noninteractive user sessions with a Windows profile are supported.
    Defaults to the Windows-resolved LocalApplicationData\UOPProviderLogs root,
    not TEMP. There is no fallback; specify a non-protected LogPath when needed.
    New collection roots, timestamp directories and diagnostic workspaces grant
    access only to the collecting user, with inheritance disabled.
    Existing directory ACLs are not changed. Explicit LogPath files use the
    existing destination directory's permissions; choose that directory deliberately.
    Default collection pins the UOPProviderLogs root without write/delete sharing,
    rejecting reparses and incompatible existing write handles rather than repairing it.
    Its opened handle must identify a directory owned by the collecting user, with
    no write/control grants to identities other than that user, SYSTEM or Administrators.
    Existing administrative permissions are accepted, never added or repaired.
    Exports are diagnostic data, not authoritative system state.
    AAUReportingEvents logs and archives are copied separately,
    byte-for-byte; they are not treated as ETW records. Numbered archives are
    retained beside the active copy even without KeepDiagnostics or RawOnly.
    Discovered archives are pinned while active and archived reporting files are
    snapshotted, delaying AAU archive replacement until copying completes. CSP text
    slots are not pinned, so CSP hosts can still claim or recycle inactive slots.
    WU-style local timestamp/sequence ETLs are collected.
    Filename dates do not determine event chronology.
    Discovery uses filenames, not the live session name/GUID. Only the selected
    InputPath and StatePath are scanned; supply explicit paths for offline history.

    The built-in Windows tracerpt.exe decodes self-describing TraceLogging
    payloads. Message formatting is not used. Named field values, XML attributes,
    nested field XML, emitting PID/TID, complete System metadata and all payload
    correlation fields are retained in DecodedEvents.jsonl. Values are XML representations, not
    guessed CLR types; exported decoder schemas retain available type metadata.
    Historical stack/address fields remain only in the raw/structured bundle, not
    the readable log. No stacks are reconstructed or symbolized.
    SimpleTrace includes local code-flow messages, compiler call-site file/line,
    numeric facts and explicit availability/truncation flags. WorkflowEvent and
    CspOperationResult remain separate structured Reporting records, not trace
    messages. All decoded fields are preserved, including unknown schema versions,
    full-width counts and native results; collection never routes them to telemetry.

    Access is limited by the caller's existing ACL permissions. Collection does
    not elevate, stop/flush traces, delete history, install metadata, change
    policy, or upload data. Only local non-reparse filesystem paths are accepted.
    Live snapshots are best-effort: unflushed buffers cannot be recovered, and a
    circular ETL may change during copy. Each copy is compared with a second read of
    its source; a source written meanwhile is copied once more, and if it changed
    again the copy is kept with ChangedDuringCopy, a reason and a warning that events
    or rows may be missing. Such a copy is never presented as complete: its bundle is
    retained and Status is Partial. Collect closed ETLs with -InputPath for a consistent
    historical capture.

    Missing AAU source categories produce explicit warnings. CSP capture is optional:
    existing CSP text and current/legacy ETLs are collected, but absence does not imply a
    failed AAU capture. When no AAU/CSP diagnostics exist yet, Status is NoSources with
    a warning that names the searched folders; this is not an error.
    Each discovered source has its own outcome in Sources: Collected, Decoded,
    PartiallyDecoded, Skipped or Failed, with a reason and any native HRESULT or
    tracerpt exit code. A live source removed by retention before its snapshot is
    Skipped. With -InputPath a missing source is Failed. A source folder that exists
    but cannot be read is a discovery failure with its HRESULT, not an absent folder.
    A source that cannot be copied or decoded is Failed; events already parsed from an
    ETL that stops decoding are kept (the newest of them when -MaxEvents is reached) and
    the ETL is PartiallyDecoded. Each skipped or failed source produces a warning and an
    entry in the report; collection continues and Status is Partial. Failures, sources
    that were not fully decoded and sources that changed during their copy retain the bundle.
    Only when failures leave no
    evidence at all does the command write an Incomplete manifest/report and then
    raise a terminating error. Text-only collections have Status TextOnly; a collection
    of ETLs with no decoded events has Status NoEvents and explicit warnings,
    not proof that an operation had no events. -RawOnly skips all decoding.
    .PARAMETER IncludeAllLogs
    Selects all registered native System providers. Cannot be combined with ProviderId.
    Only supported adapters collect files; other providers receive Unsupported reports.
    .PARAMETER ProviderId
    Registered native provider identities to collect. Cannot be combined with IncludeAllLogs.
    An explicit InputPath requires exactly one supported ProviderId and
    bypasses registry discovery, allowing offline collection without registration.
    .PARAMETER InputPath
    Directory containing ETLs. Defaults to
    %SystemRoot%\Logs\UOPProviders\Microsoft.Windows.Update.AutomaticAppUpdater.
    ETLPath is an alias; it also denotes a directory, not an ETL filename.
    For an explicit InputPath, reporting text defaults to that directory for offline use.
    .PARAMETER StatePath
    Optional separate directory containing AAUReportingEvents logs and
    reporting archives for offline collections. Normally defaults to
    %SystemRoot%\Logs\UOPProviders\Microsoft.Windows.Update.AutomaticAppUpdater.
    Active reporting files permit ACL-authorized shared reads and copies, not writes
    or deletion. Copying requires read access; there is no copy-only permission.
    Generic copy tools that deny write sharing may fail on the active file; this
    collector explicitly shares read/write/delete access. The pin begins at lazy
    UOP diagnostics initialization, not necessarily at service startup.
    When AAU stops, only ACL-authorized writers can modify the originals.
    Only the current provider directories are used by default; no history is migrated.
    State.json is not collected.
    .PARAMETER LogPath
    Optional destination file for AAU events and selected-provider status. CSP events
    are written separately to <filename-without-extension>.CSP.log in the same directory.
    The current reporting log is copied to <filename-without-extension>.AAUReportingEvents.log,
    or AAUReportingEvents.log when using the default provider filename.
    Its parent must already exist. When omitted, creates a timestamped directory under
    UOPProviderLogs in the caller's Windows LocalApplicationData folder.
    There is no ProgramData or TEMP fallback. The private diagnostic workspace
    is created in the output parent directory, including with explicit LogPath.
    All destinations honor Force and WhatIf.
    Every directory name includes a fresh random GUID, not only after a collision.
    Existing candidate directories are never reused.
    Unsupported providers receive a status-only report, not guessed source paths.
    Output cannot reside
    in the protected diagnostics directory, even when InputPath is overridden,
    or in or above the input directory. Source files are never overwritten.
    .PARAMETER Force
    Intentionally replaces an existing output file, subject to ShouldProcess.
    Previously retained raw diagnostic bundles are never replaced or deleted.
    .PARAMETER KeepDiagnostics
    Retains the new raw diagnostic bundle after successful collection. Without it,
    only the readable logs and reporting-log copies (including archives) remain.
    Collection failures, ETLs left undecoded or partially decoded (for example by
    -MaxEvents) and sources that changed during their copy retain their evidence bundle.
    A failure before the first snapshot removes its still-empty bundle instead of
    reporting it as evidence.
    Each GUID-named UOPProviderLogs.*.diagnostics bundle contains only collector-owned copies and
    can be deleted in its entirety when that evidence is no longer needed.
    .PARAMETER RawOnly
    Collects and retains raw ETL/text snapshots and a manifest without claiming to decode.
    .PARAMETER MaxInputBytes
    Total raw snapshot budget, default 1 GiB. Files exceeding the remaining budget are not copied.
    Each such file is Failed with a warning; Status is Partial when other evidence was collected,
    or Incomplete with a terminating error when nothing was. Sources are unchanged.
    .PARAMETER MaxEvents
    Maximum events retained for the ordered report, default 100000. Raw snapshots are still collected.
    ETLs are decoded newest first: each writer's ETLs (AutomaticAppUpdater, AppUpdateCSP) by the
    sequence number in <prefix>.YYYYMMDD.HHMMSS.mmm.<sequence>.etl, because the timestamp of a file
    still being written can lag; ETLs of different writers and other names by the last-write time
    read when each was copied, a writer's later file counting as at least as new as its earlier ones.
    An ETL with more events than the remaining limit keeps only its newest events and is
    PartiallyDecoded; tracerpt is not run for the remaining ETLs (Skipped, reason
    EventBudgetReached, raw snapshots retained). One warning states how many ETLs were decoded
    completely, partially or not at all, and Status is Partial. This is a configured bound, not an
    error, and never silent truncation; increase -MaxEvents to decode more.
    .PARAMETER MaxDecodedXmlBytes
    Maximum XML file size accepted by the parser, default 512 MiB per ETL. Decoder output remains raw
    evidence when this budget is exceeded. This is a parsing budget, not a decoder disk quota.
    .PARAMETER DecoderTimeoutSeconds
    Maximum runtime per tracerpt invocation, default 120 seconds. A timed-out decoder is terminated;
    its raw ETL and partial output remain in the bundle. Increase explicit limits for larger captures.
    .PARAMETER PassThru
    Returns the structured collection result instead of the default string report.
    Script callers that read result properties must specify -PassThru.
    .OUTPUTS
    System.String by default: one report per provider, or one report with -LogPath.
    Each report contains the actual status, event count and available output paths.
    Paths occupy complete logical lines without formatter-inserted hard breaks;
    a terminal can still visually wrap a long line.
    With -PassThru, returns one structured collection result per provider, or one
    result with -LogPath. This preserves the previous structured output contract.
    Each result has LogPath, CspLogPath, CspTextLogPaths, ReportingLogPath, BundlePath, Status,
    Providers, EventCount, Warnings and ReportingArchivePaths. ReportingLogPath is null if no current
    reporting log was copied; a missing source produces an explicit warning.
    Errors lists genuine per-source failures of a collection that continued (each was also
    written as a warning). SourceCounts gives the Discovered, Snapshotted, Decoded,
    PartiallyDecoded, Skipped, Failed and ChangedDuringCopy source counts, and Sources gives
    each source's Name, Source, Scenario, Status, SnapshotPath, EventCount, Reason, HResult
    and ChangedDuringCopy. SnapshotPath is null when the source was not copied or when the
    diagnostic workspace was removed after a normal collection.
    The default report adds a Sources line with those counts when sources were found.
    CspTextLogPaths lists the copied CSP text logs, or is empty when none were copied.
    EventCount includes both text streams; the retained JSON contains their UTC-ordered events.
    BundlePath is null when the temporary diagnostic workspace was removed.
    The -PassThru display is a concise completion summary; Format-List * shows every
    property. Its object formatter can wrap paths on a narrow console.
    Progress reports discovery, copying, decoding and report publication.
    Use -Verbose for input filenames, or $ProgressPreference = 'SilentlyContinue'
    to suppress progress without changing the selected output mode.
    Default reports require no Out-String width override or global console changes.
    With -PassThru, structured path properties always retain their complete values.
    Warnings and errors remain on their original streams in either output mode.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs
    Writes UOPProviderLogs\<timestamp>.<GUID>\<ProviderId>.log for every registered provider,
    plus <ProviderId>.CSP.log and the current AAUReportingEvents.log for AAU,
    and removes each successful collection's temporary workspace.
    .EXAMPLE
    Get-UOPProviderLogs -ProviderId Microsoft.Windows.Update.AutomaticAppUpdater -KeepDiagnostics
    Collects the root AAU diagnostic family, including CSP text and current/legacy CSP ETLs.
    Retains full decoded fields and raw evidence for troubleshooting; no second CSP ID is needed.
    .EXAMPLE
    $result = Get-UOPProviderLogs -ProviderId Microsoft.Windows.Update.AutomaticAppUpdater -PassThru
    $result.LogPath
    Returns the structured result for scripts and reads its complete log path directly.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs -LogPath C:\Diagnostics\UOPProviders.log
    Collects using existing permissions, normally from an elevated shell.
    .EXAMPLE
    Get-UOPProviderLogs -ProviderId Microsoft.Windows.Update.AutomaticAppUpdater -InputPath C:\SavedAAU -LogPath C:\Diagnostics\aau.log -RawOnly
    Preserves raw files for offline decoding on a compatible Windows host.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs -LogPath C:\Diagnostics\UOPProviders.log -Force -WhatIf
    Shows the write operation without creating files or running a decoder.
    .NOTES
    This script module is installed under the inbox Windows PowerShell module
    path. PowerShell module auto-loading makes the exported command available
    without requiring callers to locate or import a private payload path.
    Diagnostic payloads can contain app identifiers and native addresses.
    Protect the chosen output directory and share collected files deliberately.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'All')][switch]$IncludeAllLogs,
        [Parameter(Mandatory = $true, ParameterSetName = 'Selected')]
        [ValidateNotNullOrEmpty()][string[]]$ProviderId,
        [Parameter()][Alias('ETLPath')][ValidateNotNullOrEmpty()]
        [string]$InputPath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$StatePath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$LogPath,
        [switch]$Force,
        [switch]$KeepDiagnostics,
        [switch]$RawOnly,
        [switch]$PassThru,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxInputBytes = 1073741824,
        [ValidateRange(1, [int]::MaxValue)][int]$MaxEvents = 100000,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxDecodedXmlBytes = 536870912,
        [ValidateRange(1, 3600)][int]$DecoderTimeoutSeconds = 120
    )

    $ErrorActionPreference = 'Stop'
    Assert-UopNativeProcess
    $context = Get-UopCollectorContext
    if ([string]::IsNullOrWhiteSpace($context.UserSid) -or
        $context.UserSid -in @('S-1-5-7', 'S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or
        $context.UserSid -match '^S-1-5-(80|82)-' -or
        $context.IsService -or
        $context.ImpersonationLevel -ne [Security.Principal.TokenImpersonationLevel]::None -or
        [string]::IsNullOrWhiteSpace($context.ProfilePath) -or
        -not [IO.Directory]::Exists($context.ProfilePath)) {
        throw 'Get-UOPProviderLogs requires a non-service user account with an existing Windows profile. SYSTEM, service identities and impersonation are not supported; run from a user PowerShell session.'
    }
    if (-not $IncludeAllLogs -and -not $PSBoundParameters.ContainsKey('ProviderId')) {
        Write-Warning 'No logs collected. Specify -IncludeAllLogs or -ProviderId to select providers.'
        return
    }
    $offline = $PSBoundParameters.ContainsKey('InputPath')
    if ($offline) {
        if ($null -eq $ProviderId -or @($ProviderId).Count -ne 1 -or $ProviderId[0] -ine $script:AauProviderId) {
            throw 'InputPath requires exactly one supported ProviderId: Microsoft.Windows.Update.AutomaticAppUpdater.'
        }
        $selected = @($script:AauProviderId)
    }
    else {
        $registered = @(Get-UopRegisteredProviderId | Sort-Object -Unique)
        if ($ProviderId) {
            foreach ($id in $ProviderId) {
                if ($id -notin $registered) {
                    throw "ProviderId is not registered: $(ConvertTo-AauLogText $id). Use InputPath for a supported offline provider."
                }
            }
            $selected = @($registered | Where-Object { $_ -in $ProviderId })
        }
        else { $selected = $registered }
    }
    $collectAau = $script:AauProviderId -in $selected
    if ($PSBoundParameters.ContainsKey('StatePath') -and -not $collectAau) {
        throw 'StatePath requires the AutomaticAppUpdater provider to be selected.'
    }
    $inputDirectory = $null
    $stateDirectory = $null
    $sourceSets = @()
    if ($collectAau) {
        $defaults = Get-AauDefaultDirectories
        if (-not $InputPath) { $InputPath = $defaults.InputPath }
        if (-not $StatePath) {
            $StatePath = if ($offline) { $InputPath } else { $defaults.StatePath }
        }
        $inputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
        $stateDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
        Assert-AauLocalPath -Path $inputDirectory
        Assert-AauLocalPath -Path $stateDirectory
        $inputDirectory = [IO.Path]::GetFullPath($inputDirectory)
        if ($inputDirectory.Length -gt 3) { $inputDirectory = $inputDirectory.TrimEnd('\') }
        $stateDirectory = [IO.Path]::GetFullPath($stateDirectory)
        if ($stateDirectory.Length -gt 3) { $stateDirectory = $stateDirectory.TrimEnd('\') }
        Assert-AauLocalPath -Path $inputDirectory
        Assert-AauLocalPath -Path $stateDirectory
        if ($offline -and -not [IO.Directory]::Exists($inputDirectory)) {
            throw "Input directory does not exist or is inaccessible: $inputDirectory"
        }
        if ($PSBoundParameters.ContainsKey('StatePath') -and -not [IO.Directory]::Exists($stateDirectory)) {
            throw "State directory does not exist or is inaccessible: $stateDirectory"
        }
        $reportingPattern = '^AAUReportingEvents(\.\d+)?\.log$'
        $sourceSets = @(
            @{ Directory = $inputDirectory; Pattern = '^(AutomaticAppUpdater|AppUpdateCSP)\..+\.etl$' },
            @{ Directory = $inputDirectory; Pattern = '^AppUpdateCSP\.[0-7]\.log$' },
            @{ Directory = $stateDirectory; Pattern = $reportingPattern })
        foreach ($sourceSet in $sourceSets) { Assert-AauLocalPath -Path $sourceSet.Directory }
    }
    if (-not $PSBoundParameters.ContainsKey('LogPath')) {
        if ($selected.Count -eq 0) {
            Write-Warning 'No native UOP providers are registered in the 64-bit System registry key.'
            return
        }
        $outputRoot = Get-UopCollectionRoot
        Assert-AauLocalPath -Path $outputRoot
        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
        $outputDirectory = Join-Path $outputRoot "$timestamp.$([Guid]::NewGuid().ToString('N'))"
        $rootPin = $null
        $directoryPin = $null
        try {
        while ($true) {
            if ([IO.Directory]::Exists($outputDirectory) -or [IO.File]::Exists($outputDirectory)) {
                $outputDirectory = Join-Path $outputRoot "$timestamp.$([Guid]::NewGuid().ToString('N'))"
            }
            Assert-AauLocalPath -Path $outputDirectory
            $reservedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $requests = @(
                foreach ($id in $selected) {
                    $path = Join-Path $outputDirectory (Get-UopProviderLogName -ProviderId $id)
                    $paths = @($path; if ($id -ieq $script:AauProviderId) {
                        Get-UopCspLogPath -LogPath $path
                        Get-UopReportingLogPath -LogPath $path
                    })
                    foreach ($destination in $paths) {
                        if (-not $reservedPaths.Add($destination)) {
                            throw "Selected provider log filenames collide: $destination"
                        }
                        Assert-UopOutputPath -OutputPath $destination -SourceSets $sourceSets -Force:$Force -AllowMissingParent
                    }
                    # Collection IDs have a fixed length, so a fresh one checks this provider's
                    # collection paths before the timestamp directory is created.
                    Assert-UopCollectionPathLength -OutputPath $path -ReportPaths $paths `
                        -CollectionId ([Guid]::NewGuid().ToString('N')) -IncludeSourceNames:($id -ieq $script:AauProviderId)
                    [pscustomobject]@{ ProviderId = $id; LogPath = $path }
                }
            )
            # Create with the private descriptor, not an ACL adjustment after creation.
            if (-not $PSCmdlet.ShouldProcess($outputDirectory, 'Create provider log output directory')) { return }
            if ($null -eq $rootPin) {
                $rootPin = Open-UopOutputDirectory -Path $outputRoot -CreateMissing -DenyLeafWrite
            }
            try { [UopProviderDiagnostics.OutputDirectoryPin]::CreatePrivate($outputDirectory) }
            catch {
                $creationError = $_.Exception.GetBaseException()
                if ($creationError -isnot [ComponentModel.Win32Exception] -or
                    $creationError.NativeErrorCode -ne 183) { throw }
                $outputDirectory = Join-Path $outputRoot "$timestamp.$([Guid]::NewGuid().ToString('N'))"
                continue
            }
            $directoryPin = Open-UopOutputDirectory -Path $outputDirectory
            break
        }
        $collectionErrors = [Collections.Generic.List[string]]::new()
        foreach ($request in $requests) {
            $parameters = @{}
            foreach ($key in $PSBoundParameters.Keys) { $parameters[$key] = $PSBoundParameters[$key] }
            $parameters.Remove('IncludeAllLogs')
            $parameters.ProviderId = @($request.ProviderId)
            $parameters.LogPath = $request.LogPath
            if ($request.ProviderId -ine $script:AauProviderId) { $parameters.Remove('StatePath') }
            try { Get-UOPProviderLogs @parameters }
            catch { $collectionErrors.Add("$($request.ProviderId): $($_.Exception.Message)") }
        }
        if ($collectionErrors.Count -gt 0) {
            throw "$($collectionErrors -join ' ') One or more provider collections failed."
        }
        return
        }
        finally {
            if ($null -ne $directoryPin) { $directoryPin.Dispose() }
            if ($null -ne $rootPin) { $rootPin.Dispose() }
        }
    }
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    Assert-AauLocalPath -Path $outputPath
    $outputPath = [IO.Path]::GetFullPath($outputPath)
    Assert-UopOutputPath -OutputPath $outputPath -SourceSets $sourceSets -Force:$Force
    $cspOutputPath = $null
    $reportingOutputPath = $null
    if ($collectAau) {
        $cspOutputPath = Get-UopCspLogPath -LogPath $outputPath
        Assert-UopOutputPath -OutputPath $cspOutputPath -SourceSets $sourceSets -Force:$Force
        $reportingOutputPath = Get-UopReportingLogPath -LogPath $outputPath
        Assert-UopOutputPath -OutputPath $reportingOutputPath -SourceSets $sourceSets -Force:$Force
    }
    $decoder = Join-Path ([Environment]::GetFolderPath('System')) 'tracerpt.exe'
    $destinations = @($outputPath; if ($cspOutputPath) { $cspOutputPath }; if ($reportingOutputPath) { $reportingOutputPath })
    $collectionId = [Guid]::NewGuid().ToString('N')
    Assert-UopCollectionPathLength -OutputPath $outputPath -ReportPaths $destinations -CollectionId $collectionId `
        -IncludeSourceNames:$collectAau
    if (-not $PSCmdlet.ShouldProcess(($destinations -join ', '), 'Collect diagnostics, write event logs and copy reporting generations')) {
        return
    }

    $outputPin = Open-UopOutputDirectory -Path ([IO.Path]::GetDirectoryName($outputPath))
    $progressActivity = 'Collecting UOP provider logs'
    try {
    Write-Progress -Activity $progressActivity -Status 'Finding diagnostic files' -PercentComplete -1
    $displayTimeZone = [TimeZoneInfo]::Local
    $bundlePath = Get-UopBundlePath -OutputPath $outputPath -CollectionId $collectionId
    Assert-UopOutputPath -OutputPath $bundlePath -SourceSets $sourceSets -AllowMissingParent
    if ([IO.Directory]::Exists($bundlePath) -or [IO.File]::Exists($bundlePath)) {
        throw "Diagnostic workspace already exists; it will not be reused: $bundlePath"
    }
    [UopProviderDiagnostics.OutputDirectoryPin]::CreatePrivate($bundlePath)
    $warnings = [Collections.Generic.List[string]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $snapshots = [Collections.Generic.List[object]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $providers = [Collections.Generic.List[object]]::new()
    $retainDiagnostics = $KeepDiagnostics -or $RawOnly
    $collectionFailed = $false
    $bundleInUse = $false
    $manifest = $null
    $reportsPublished = $false
    $reportingLogPath = $null
    $reportingArchivePaths = [Collections.Generic.List[string]]::new()
    $cspTextLogPaths = [Collections.Generic.List[string]]::new()
    $reportingPins = [Collections.Generic.List[IO.FileStream]]::new()
    $sourceRecords = [Collections.Generic.List[object]]::new()
    $sourceCounts = $null
    $reports = @(
        [pscustomobject]@{
            Path = $outputPath; Scenario = 'UOP'; StagedPath = "$outputPath.$collectionId.tmp"; Created = $false
            SnapshotPath = $null
        }
        if ($cspOutputPath) {
            [pscustomobject]@{
                Path = $cspOutputPath; Scenario = 'CSP'; StagedPath = "$cspOutputPath.$collectionId.tmp"; Created = $false
                SnapshotPath = $null
            }
        }
    )
    try {
        $copiedBytes = 0L
        foreach ($id in $selected) {
            if ($id -ieq $script:AauProviderId) { continue }
            $providers.Add([pscustomobject]@{
                ProviderId = $id; Status = 'Unsupported'; EventCount = 0; BundlePath = $null
            })
            $warnings.Add("Unsupported registered ProviderId: $(ConvertTo-AauLogText $id). No files collected for this provider.")
        }
        if ($selected.Count -eq 0) { $warnings.Add('No native UOP providers are registered in the 64-bit System registry key.') }
        $sources = @()
        $plans = @()
        $providerBundle = $null
        if ($collectAau) {
            $providerBundle = $bundlePath
            foreach ($sourceSet in $sourceSets) {
                try { $sources += @(Get-UopSourceFiles @sourceSet) }
                catch {
                    # Access denial or an I/O failure is a genuine discovery failure, unlike absence.
                    $code = Get-UopFailureCode -Exception $_.Exception
                    $failures.Add("Source discovery failed for '$($sourceSet.Directory)'$(if ($code) { " ($code)" }): $($_.Exception.Message)")
                }
            }
            $sources = @($sources | Sort-Object FullName -Unique | Sort-Object @{
                Expression = {
                    if ($_.Name -ieq 'AAUReportingEvents.log') { 0 }
                    elseif ($_.Name -match '^AAUReportingEvents\.\d+\.log$') { 1 }
                    elseif ($_.Name -match '^AppUpdateCSP\.[0-7]\.log$') { 2 }
                    else { 3 }
                }
            }, FullName)
            # Plan every destination before copying: an unusable output location fails before
            # any evidence is copied, and no retained path can reach the Windows path limit.
            $duplicateNames = @($sources | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
            $sourceIndex = 0
            $plans = @(foreach ($source in $sources) {
                $sourceIndex++
                $plan = New-UopSourcePlan -Source $source -Index $sourceIndex `
                    -IsDuplicateName ($source.Name -in $duplicateNames) -BundlePath $providerBundle `
                    -OutputPath $outputPath -ReportingOutputPath $reportingOutputPath -CollectionId $collectionId `
                    -SourceSets $sourceSets -Decode (-not $RawOnly) -Force:$Force
                if ($plan.Shortened) {
                    Write-Verbose "Retaining '$($source.FullName)' as '$($plan.SnapshotPath)' to stay within the Windows path limit."
                }
                $sourceRecords.Add($plan.Record)
                $plan
            })
            # Pin discovered archives before copying the active file. AAU publishes
            # before truncating active, so its rollover cannot erase either generation
            # during this snapshot. Reads still permit the lifetime active writer.
            # CSP text slots are not pinned: a CSP host must stay able to claim or recycle an
            # inactive slot while it is copied, so a torn copy is detected after the fact instead.
            foreach ($source in $sources) {
                if ($source.Name -notmatch '^AAUReportingEvents\.\d+\.log$') { continue }
                try {
                    Assert-AauLocalPath -Path $source.FullName
                    $reportingPins.Add([IO.File]::Open($source.FullName, [IO.FileMode]::Open,
                        [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
                }
                catch {
                    if ($offline -or -not (Test-UopSourceRemoved -Path $source.FullName -Exception $_.Exception)) {
                        $failures.Add("Reporting archive pin failed for '$($source.FullName)': $($_.Exception.Message)")
                    }
                }
            }
            if ($sources.Count -eq 0 -and $failures.Count -eq 0) {
                # A provider that has not written diagnostics yet is a normal state, not a failure.
                $warnings.Add("No AAU/CSP diagnostics found. Searched '$inputDirectory' for AutomaticAppUpdater.*.etl, AppUpdateCSP.*.etl and AppUpdateCSP.[0-7].log; '$stateDirectory' for AAUReportingEvents.log and AAUReportingEvents.<number>.log. None have been written there yet; this is not a collection failure.")
            }
            foreach ($category in @('AutomaticAppUpdater.*.etl', 'AAUReportingEvents.log')) {
                if (@($sources | Where-Object Name -like $category).Count -eq 0) {
                    $warnings.Add("Source category missing: $category")
                }
            }
            $warnings.Add('Live files are copied without flushing or stopping ETW. Unflushed buffers and changes during circular-file copying may not be recoverable.')
        }

        # Phase 1: snapshot every source before decoding any ETL. Decoding takes minutes, during
        # which retention could otherwise delete sources that are still waiting to be copied.
        # From here on the bundle can hold evidence; before this point it is still empty.
        $bundleInUse = $true
        $sourceIndex = 0
        foreach ($plan in $plans) {
            $source = $plan.Source
            $record = $plan.Record
            if ($source.Extension -ieq '.etl' -and $reportingPins.Count -gt 0) {
                foreach ($pin in $reportingPins) { $pin.Dispose() }
                $reportingPins.Clear()
            }
            $sourceIndex++
            Write-Progress -Activity $progressActivity -Status "Copying file $sourceIndex of $($plans.Count)" `
                -CurrentOperation $source.Name -PercentComplete ([int](100.0 * ($sourceIndex - 1) / $plans.Count))
            Write-Verbose "Input: $($source.FullName)"
            $budgetAccounted = $false
            try {
                if ($plan.SnapshotDirectory -ne $providerBundle) {
                    # Preserve distinct source files with the same basename; never overwrite one.
                    [void][IO.Directory]::CreateDirectory($plan.SnapshotDirectory)
                }
                $snapshot = Copy-AauSnapshot -Source $source -Destination $plan.SnapshotPath `
                    -MaximumBytes ($MaxInputBytes - $copiedBytes)
                $copiedBytes += $snapshot.Length
                $budgetAccounted = $true
                $plan.SnapshotTimeUtc = [DateTimeOffset]::Parse($snapshot.LastWriteTimeUtc,
                    [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                $snapshot | Add-Member -NotePropertyName ProviderId -NotePropertyValue $script:AauProviderId
                $snapshot | Add-Member -NotePropertyName Scenario -NotePropertyValue $plan.Scenario
                $snapshots.Add($snapshot)
                $record.Status = 'Collected'
                $record.SnapshotPath = $plan.SnapshotPath
                if ($null -ne $plan.ReportKind) {
                    if ($plan.ReportKind -eq 'ReportingLog') { $reportingLogPath = $plan.ReportPath }
                    elseif ($plan.ReportKind -eq 'CspText') { $cspTextLogPaths.Add($plan.ReportPath) }
                    else { $reportingArchivePaths.Add($plan.ReportPath) }
                    $reports += [pscustomobject]@{
                        Path = $plan.ReportPath; Scenario = 'Reporting'
                        StagedPath = "$($plan.ReportPath).$collectionId.tmp"; Created = $false
                        SnapshotPath = $plan.SnapshotPath
                    }
                }
                if (-not $snapshot.UnchangedDuringCopy) {
                    # Kept, never presented as complete: the bytes may mix two states of the file.
                    $record.ChangedDuringCopy = $true
                    $record.Reason = 'ChangedDuringCopy: the source was written while it was copied; events or rows may be missing.'
                    $warnings.Add("Source changed during snapshot; it was copied while being written and events or rows may be missing: $($source.Name)")
                }
                if ($plan.ReportKind -eq 'CspText' -and -not (Test-UopTextEndsWithNewline -Path $plan.SnapshotPath)) {
                    $warnings.Add("CSP text ends with an incomplete final row: $($source.Name)")
                }
            }
            catch {
                if (-not $budgetAccounted -and [IO.File]::Exists($plan.SnapshotPath)) {
                    $copiedBytes += [IO.FileInfo]::new($plan.SnapshotPath).Length
                }
                if (-not $offline -and (Test-UopSourceRemoved -Path $source.FullName -Exception $_.Exception)) {
                    # Normal retention, not a failure. Explicit -InputPath sources stay strict.
                    $record.Status = 'Skipped'
                    Add-UopSourceReason $record 'Removed by retention before its snapshot.'
                    $warnings.Add("Skipped '$($source.FullName)': removed by retention before its snapshot.")
                }
                else {
                    $record.Status = 'Failed'
                    Add-UopSourceReason $record $_.Exception.Message
                    $record.HResult = Get-UopFailureCode -Exception $_.Exception
                    $failures.Add("Snapshot failed for '$($source.FullName)': $($_.Exception.Message)")
                }
            }
        }
        foreach ($pin in $reportingPins) { $pin.Dispose() }
        $reportingPins.Clear()

        # Phase 2: decode the retained ETL snapshots newest first (Get-UopEtlDecodeOrder), so a reached event
        # budget keeps the most recent history: an ETL with more events than the remaining budget keeps its
        # newest events. A failure is recorded for its ETL and the remaining ETLs are still decoded; events
        # parsed before the failure are kept, the newest of them when the budget is reached.
        $decodePlans = @(if (-not $RawOnly) {
            Get-UopEtlDecodeOrder -Plans @($plans | Where-Object { $_.Scenario -ne 'Reporting' -and $_.Record.Status -eq 'Collected' })
        })
        $decodedEventCount = 0
        $budgetReached = $false
        $decodeIndex = 0
        foreach ($plan in $decodePlans) {
            $record = $plan.Record
            $decodeIndex++
            if ($decodedEventCount -ge $MaxEvents) {
                # A configured limit, not a failure: tracerpt is not run and the raw snapshot is kept.
                $budgetReached = $true
                $record.Status = 'Skipped'
                Add-UopSourceReason $record "EventBudgetReached: not decoded because -MaxEvents $MaxEvents was reached."
                continue
            }
            Write-Progress -Activity $progressActivity -Status "Decoding file $decodeIndex of $($decodePlans.Count)" `
                -CurrentOperation $plan.Source.Name -PercentComplete ([int](100.0 * ($decodeIndex - 1) / $decodePlans.Count))
            # Events of one ETL arrive oldest first. Only the newest that fit the remaining budget are kept:
            # an older event leaves the window when a newer one arrives, so the budget raises no error.
            $window = [Collections.Generic.Queue[object]]::new()
            $budget = @{ Capacity = $MaxEvents - $decodedEventCount; Dropped = [long]0 }
            $decodeError = $null
            try {
                $xmlPath = Invoke-UopEtlDecoder -Decoder $decoder -SnapshotPath $plan.SnapshotPath `
                    -TimeoutSeconds $DecoderTimeoutSeconds
                Read-AauDecodedEvents -Path $xmlPath -SourceFile $plan.Label `
                    -MaximumBytes $MaxDecodedXmlBytes | ForEach-Object {
                    if ($window.Count -ge $budget.Capacity) {
                        [void]$window.Dequeue()
                        $budget.Dropped++
                    }
                    $window.Enqueue($_)
                }
            }
            catch { $decodeError = $_ }
            foreach ($eventRecord in $window) {
                $eventRecord | Add-Member -NotePropertyName UopProviderId -NotePropertyValue $script:AauProviderId
                $eventRecord | Add-Member -NotePropertyName Scenario -NotePropertyValue $plan.Scenario
                $plan.Events.Add($eventRecord)
            }
            $keptEvents = $plan.Events.Count
            $record.EventCount = $keptEvents
            $decodedEventCount += $keptEvents
            if ($budget.Dropped -gt 0) { $budgetReached = $true }
            if ($null -ne $decodeError) {
                $record.Status = if ($keptEvents -gt 0) { 'PartiallyDecoded' } else { 'Failed' }
                Add-UopSourceReason $record $decodeError.Exception.Message
                $record.HResult = Get-UopFailureCode -Exception $decodeError.Exception
                $decodeFailure = "Decode failed for '$($plan.Source.Name)': $($decodeError.Exception.Message)"
                if ($budget.Dropped -gt 0) {
                    $budgetNote = " The newest $keptEvents events decoded before the failure are kept; " +
                        "$($budget.Dropped) older events were not kept because -MaxEvents $MaxEvents was reached."
                    $record.Reason += $budgetNote
                    $decodeFailure += $budgetNote
                }
                elseif ($keptEvents -gt 0) { $decodeFailure += " Events decoded before the failure are kept: $keptEvents." }
                $failures.Add($decodeFailure)
            }
            elseif ($budget.Dropped -gt 0) {
                # A configured limit, not a failure: the oldest events of this ETL gave way to newer ones.
                $record.Status = 'PartiallyDecoded'
                Add-UopSourceReason $record ("EventBudgetReached: kept the newest $keptEvents of " +
                    "$($keptEvents + $budget.Dropped) events because -MaxEvents $MaxEvents was reached.")
            }
            else {
                $record.Status = 'Decoded'
                if ($keptEvents -eq 0) {
                    $warnings.Add("No decodable component events in '$($plan.Source.Name)'; see raw ETL and decoder summary.")
                }
            }
        }
        if ($budgetReached) {
            # Counted by final status, as the Sources line counts them.
            $statusCounts = @{ Decoded = 0; PartiallyDecoded = 0; Skipped = 0; Failed = 0 }
            foreach ($plan in $decodePlans) { $statusCounts[$plan.Record.Status]++ }
            $budgetWarning = "Decoded event budget reached (-MaxEvents $MaxEvents): $($statusCounts.Decoded) of " +
                "$($decodePlans.Count) ETLs decoded completely, newest first; $($statusCounts.PartiallyDecoded) partially " +
                "decoded (newest events kept, or those decoded before a failure); $($statusCounts.Skipped) not decoded"
            if ($statusCounts.Failed -gt 0) { $budgetWarning += "; $($statusCounts.Failed) failed to decode (see their errors)" }
            $warnings.Add("$budgetWarning. ETLs that were not fully decoded keep their raw snapshots. Rerun with a larger -MaxEvents to decode them.")
        }
        # Merge in source order, as before newest-first decoding, so equal timestamps keep their order.
        foreach ($plan in $plans) {
            foreach ($eventRecord in $plan.Events) { $events.Add($eventRecord) }
        }
        $sourceCounts = Get-UopSourceCounts -Sources $sourceRecords.ToArray()

        Set-UopPolicyCoverage -Events $events
        $incompletePolicyRecords = @($events | Where-Object {
            $_.PSObject.Properties['PolicyCoverage'] -and $_.PolicyCoverage.PartCoverage -ne 'Complete'
        }).Count
        if ($incompletePolicyRecords -gt 0) {
            $warnings.Add("Policy capture coverage is missing, duplicated or invalid for $incompletePolicyRecords records. Producer truncation is reported separately; retain raw events.")
        }
        # Evidence from other sources keeps a collection usable. Only failures that leave
        # nothing collected make it incomplete and terminating. A copy that changed while it was
        # taken may mix two states of its file, so it never lets the collection read as complete.
        $collectionUnusable = $failures.Count -gt 0 -and $snapshots.Count -eq 0
        $aauStatus = if ($collectionUnusable) { 'Incomplete' }
            elseif ($failures.Count -gt 0 -or $sourceCounts.Skipped -gt 0 -or $sourceCounts.PartiallyDecoded -gt 0 -or
                $sourceCounts.ChangedDuringCopy -gt 0) {
                if ($snapshots.Count -gt 0) { 'Partial' } else { 'NoSources' }
            }
            elseif ($sources.Count -eq 0) { 'NoSources' }
            elseif ($RawOnly) { 'RawOnly' }
            elseif (@($sources | Where-Object Extension -eq '.etl').Count -eq 0) { 'TextOnly' }
            elseif ($events.Count -eq 0) { 'NoEvents' }
            else { 'Decoded' }
        if ($collectAau -and $aauStatus -eq 'Partial') {
            $warnings.Add("Diagnostic collection is partial. Sources: $(Format-UopSourceCounts $sourceCounts). Skipped, failed, partially decoded and changed sources are explained in warnings and in each source record.")
        }
        if ($collectAau) {
            $providers.Add([pscustomobject]@{
                ProviderId = $script:AauProviderId; Status = $aauStatus; EventCount = $events.Count
                BundlePath = $providerBundle; InputPath = $inputDirectory; StatePath = $stateDirectory
                SourceDirectories = @($sourceSets | ForEach-Object { $_.Directory } | Sort-Object -Unique)
            })
        }
        $status = if ($collectionUnusable) { 'Incomplete' }
            elseif ($selected.Count -eq 0) { 'NoProviders' }
            elseif (-not $collectAau) { 'Unsupported' }
            elseif ($providers.Count -gt 1) { 'Partial' }
            else { $aauStatus }
        # Keep the raw bundle whenever its evidence was not fully decoded, may be torn because the
        # source changed while it was copied, or a failure needs it.
        $retainDiagnostics = $KeepDiagnostics -or $RawOnly -or $failures.Count -gt 0 -or
            @($sourceRecords | Where-Object {
                ($_.Status -in @('Skipped', 'PartiallyDecoded') -or $_.ChangedDuringCopy) -and
                    $null -ne $_.SnapshotPath }).Count -gt 0
        Write-Progress -Activity $progressActivity -Status "Writing report ($($events.Count) events)" `
            -CurrentOperation $outputPath -PercentComplete -1
        $manifest = [ordered]@{
            SchemaVersion = 1
            CollectedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            DisplayTimeZone = $displayTimeZone.Id
            Discovery = $(if ($offline) { 'Offline' } else { 'Registry64' })
            Providers = @($providers.ToArray())
            LogPath = $outputPath
            CspLogPath = $cspOutputPath
            ReportingLogPath = $reportingLogPath
            ReportingArchivePaths = @($reportingArchivePaths.ToArray())
            CspTextLogPaths = @($cspTextLogPaths.ToArray())
            BundlePath = $bundlePath
            Status = $status
            Decoder = $(if ($RawOnly -or -not $collectAau) { $null } else { $decoder })
            EventCount = $events.Count
            CopiedBytes = $copiedBytes
            Limits = [ordered]@{
                MaxInputBytes = $MaxInputBytes
                MaxEvents = $MaxEvents
                MaxDecodedXmlBytes = $MaxDecodedXmlBytes
                DecoderTimeoutSeconds = $DecoderTimeoutSeconds
            }
            Snapshots = @($snapshots.ToArray())
            SourceCounts = $sourceCounts
            Sources = @($sourceRecords.ToArray())
            Warnings = @($warnings.ToArray())
            Errors = @($failures.ToArray())
        }
        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $bundlePath 'Collection.json'),
            ($manifest | ConvertTo-Json -Depth 8), $encoding)
        $orderedEvents = @(Sort-AauDecodedEvents -Events $events.ToArray())
        $jsonWriter = [IO.StreamWriter]::new((Join-Path $bundlePath 'DecodedEvents.jsonl'), $false, $encoding)
        try {
            foreach ($eventRecord in $orderedEvents) {
                $jsonWriter.WriteLine(($eventRecord | ConvertTo-Json -Depth 12 -Compress))
            }
        }
        finally { $jsonWriter.Dispose() }
        foreach ($report in $reports) {
            $reportStream = [IO.File]::Open($report.StagedPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            $report.Created = $true
            if ($report.Scenario -eq 'Reporting') {
                $snapshotStream = $null
                try {
                    $snapshotStream = [IO.File]::OpenRead($report.SnapshotPath)
                    $snapshotStream.CopyTo($reportStream)
                }
                finally {
                    if ($null -ne $snapshotStream) { $snapshotStream.Dispose() }
                    $reportStream.Dispose()
                }
                continue
            }
            $reportEvents = @($orderedEvents | Where-Object Scenario -eq $report.Scenario)
            $writer = $null
            try {
                $writer = [IO.StreamWriter]::new($reportStream, $encoding)
                $writer.WriteLine("# UOP Providers | Scenario=$($report.Scenario) | Status=$status | Events=$($reportEvents.Count) | Local time | TimeZone=$(ConvertTo-AauLogText $displayTimeZone.Id)")
                if ($retainDiagnostics) { $writer.WriteLine("# Bundle=$bundlePath") }
                else { $writer.WriteLine('# Diagnostics retention not requested; use -KeepDiagnostics for raw evidence.') }
                foreach ($provider in $providers) {
                    $writer.WriteLine("# Provider=$(ConvertTo-AauLogText $provider.ProviderId) | Status=$($provider.Status)")
                }
                if ($collectAau) { $writer.WriteLine("# Sources: $(Format-UopSourceCounts $sourceCounts)") }
                if ($collectAau) { $writer.WriteLine("# AAU/$($report.Scenario) = $script:AauProviderId; reporting text is separate raw evidence.") }
                if ($reportingLogPath) { $writer.WriteLine("# ReportingLog=$(ConvertTo-AauLogText $reportingLogPath)") }
                foreach ($cspTextPath in $cspTextLogPaths) {
                    $writer.WriteLine("# CSPTextLog=$(ConvertTo-AauLogText $cspTextPath)")
                }
                foreach ($warning in $warnings) { $writer.WriteLine("# Warning: $(ConvertTo-AauLogText $warning)") }
                foreach ($failure in $failures) { $writer.WriteLine("# Error: $(ConvertTo-AauLogText $failure)") }
                foreach ($eventRecord in $reportEvents) {
                    $writer.WriteLine((Format-AauEvent $eventRecord -TimeZone $displayTimeZone))
                }
            }
            finally {
                if ($null -ne $writer) { $writer.Dispose() }
                else { $reportStream.Dispose() }
            }
        }
        # Atomic publication never opens an existing output for truncation, including
        # an existing hardlink. Each report is published independently; failures retain evidence.
        foreach ($report in $reports) {
            Assert-AauLocalPath -Path $report.Path
            if ([IO.File]::Exists($report.Path)) {
                if (-not $Force) {
                    throw "Output was created during collection; raw diagnostics remain at '$bundlePath'. Use -Force to replace it."
                }
                [IO.File]::Replace($report.StagedPath, $report.Path, [Management.Automation.Language.NullString]::Value)
            }
            else {
                [IO.File]::Move($report.StagedPath, $report.Path)
            }
        }
        $reportsPublished = $true
        foreach ($warning in $warnings) {
            Write-Warning $warning
        }
        if ($collectionUnusable) {
            throw "$($failures -join ' ') Diagnostic collection is incomplete. Report: '$outputPath'; raw bundle: '$bundlePath'."
        }
        # The collection continued past these per-source failures; surface each one.
        foreach ($failure in $failures) {
            Write-Warning $failure
        }
    }
    catch {
        $collectionFailed = $true
        # A failure before the first snapshot leaves an empty bundle: remove it rather than announce it as evidence.
        $retainDiagnostics = $bundleInUse -and ($retainDiagnostics -or $null -ne $manifest -or $failures.Count -gt 0 -or
            $snapshots.Count -gt 0 -or $events.Count -gt 0)
        if ($null -ne $manifest) {
            $manifest.Status = 'Incomplete'
            if (-not $reportsPublished -or $failures.Count -eq 0) {
                $manifest.Errors = @($manifest.Errors) + $_.Exception.Message
            }
            try {
                [IO.File]::WriteAllText((Join-Path $bundlePath 'Collection.json'),
                    ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            }
            catch {
                Write-Warning "Could not mark the retained manifest incomplete: $($_.Exception.Message)" -WarningAction Continue
            }
        }
        if ($retainDiagnostics) {
            Write-Warning "Collector-owned evidence remains at '$bundlePath'; this bundle can be deleted when no longer needed." -WarningAction Continue
        }
        throw
    }
    finally {
        foreach ($pin in $reportingPins) { $pin.Dispose() }
        foreach ($report in $reports) {
            if ($report.Created -and [IO.File]::Exists($report.StagedPath)) {
                try {
                    if ($retainDiagnostics) {
                        [IO.File]::Move($report.StagedPath, (Get-UopRetainedReportPath -BundlePath $bundlePath `
                            -Scenario $report.Scenario -SnapshotPath $report.SnapshotPath))
                    }
                    else { [IO.File]::Delete($report.StagedPath) }
                }
                catch {
                    $cleanupError = "Temporary report cleanup failed at '$($report.StagedPath)': $($_.Exception.Message)"
                    if ($collectionFailed) { Write-Warning $cleanupError -WarningAction Continue }
                    else { throw $cleanupError }
                }
            }
        }
        if (-not $retainDiagnostics) {
            # Only this invocation's new GUID-named workspace, after atomic publication.
            # Never enumerate or remove earlier retained bundles or any source directory.
            try { [IO.Directory]::Delete($bundlePath, $true) }
            catch {
                $cleanupError = "Diagnostic workspace cleanup failed at '$bundlePath': $($_.Exception.Message)"
                if ($collectionFailed) { Write-Warning $cleanupError -WarningAction Continue }
                else { throw $cleanupError }
            }
            if (-not [IO.Directory]::Exists($bundlePath)) {
                $bundlePath = $null
                foreach ($provider in $providers) { $provider.BundlePath = $null }
                # The removed workspace held the snapshots; outcomes and counts remain.
                foreach ($record in $sourceRecords) { $record.SnapshotPath = $null }
            }
        }
    }
    $collectionResult = [pscustomobject]@{
        PSTypeName = 'Microsoft.Windows.Update.UopLogCollectionResult'
        LogPath = $outputPath
        CspLogPath = $cspOutputPath
        ReportingLogPath = $reportingLogPath
        ReportingArchivePaths = @($reportingArchivePaths.ToArray())
        CspTextLogPaths = @($cspTextLogPaths.ToArray())
        BundlePath = $bundlePath
        Status = $status
        EventCount = $events.Count
        Providers = @($providers.ToArray())
        Warnings = @($warnings.ToArray())
        Errors = @($failures.ToArray())
        SourceCounts = $sourceCounts
        Sources = @($sourceRecords.ToArray())
    }
    if ($PassThru) { $collectionResult }
    else { Format-UopLogCollectionReport -Result $collectionResult }
    }
    finally {
        $outputPin.Dispose()
        Write-Progress -Activity $progressActivity -Completed
    }
}

Export-ModuleMember -Function Get-UOPProviderLogs
