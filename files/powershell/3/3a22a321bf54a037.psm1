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

function Open-UopOutputDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$CreateMissing,
        [switch]$DenyLeafWrite
    )

    Assert-UopLocalPath -Path $Path -RejectControlCharacters
    if (-not ('UopProviderDiagnostics.OutputDirectoryPin' -as [type])) {
        Add-Type -TypeDefinition @'
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
}
'@ -ErrorAction Stop
    }
    [UopProviderDiagnostics.OutputDirectoryPin]::Open($Path, $CreateMissing.IsPresent, $DenyLeafWrite.IsPresent)
}

function Assert-AauLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-UopLocalPath -Path $Path
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

function Copy-AauSnapshot {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [long]$MaximumBytes = [long]::MaxValue
    )

    Assert-AauLocalPath -Path $Source.FullName
    $before = [IO.File]::GetLastWriteTimeUtc($Source.FullName)
    $inputStream = [IO.File]::Open($Source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $length = $inputStream.Length
        if ($length -gt $MaximumBytes) {
            throw "Input byte budget exceeded for '$($Source.FullName)' ($length bytes; $MaximumBytes remaining)."
        }
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $remaining = $length
            $buffer = [byte[]]::new(65536)
            while ($remaining -gt 0) {
                $read = $inputStream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                if ($read -eq 0) {
                    throw "Source was truncated during collection: $($Source.FullName)"
                }
                $outputStream.Write($buffer, 0, $read)
                $remaining -= $read
            }
        }
        finally {
            $outputStream.Dispose()
        }
        $stable = $inputStream.Length -eq $length -and
            [IO.File]::GetLastWriteTimeUtc($Source.FullName) -eq $before
    }
    finally {
        $inputStream.Dispose()
    }
    [pscustomobject]@{
        Source = $Source.FullName
        Snapshot = $Destination
        Length = $length
        LastWriteTimeUtc = $before.ToString('o')
        UnchangedDuringCopy = $stable
        SHA256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
    }
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

    # Missing default roots are normal before the first provider run. Access denial is not.
    try { $item = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return }
    if (-not $item.PSIsContainer) { throw "Expected a diagnostics directory: $Directory" }
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

    # Keep one physical line per event; never interpret payload text as log structure.
    return [regex]::Replace($Value, '[\p{Cc}\p{Cf}]', ' ').Trim()
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
        $operation += " | $failureKind"
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
        (ConvertTo-AauLogText $operation)
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

function Invoke-UopEtlDecoder {
    param([string]$Decoder, [string]$SnapshotPath, [int]$TimeoutSeconds = 120)

    $xmlPath = "$SnapshotPath.xml"
    $decoderArguments = @($SnapshotPath, '-o', $xmlPath, '-of', 'XML', '-y',
        '-export', "$SnapshotPath.schema.man", '-int', "$SnapshotPath.metadata.xml",
        '-summary', "$SnapshotPath.summary.txt")
    # Every argument is a fixed switch or a Windows filename (which cannot contain a quote).
    $arguments = ($decoderArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath $Decoder -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput "$SnapshotPath.decoder.txt" -RedirectStandardError "$SnapshotPath.decoder-errors.txt"
    try {
        # Retain the handle so Windows PowerShell can read ExitCode after a short-lived process exits.
        $processHandle = $process.Handle
        Wait-UopDecoderExit -Process $process -TimeoutSeconds $TimeoutSeconds
        $decoderExitCode = $process.ExitCode
    }
    finally {
        try {
            if (-not $process.HasExited) {
                try { $process.Kill() }
                catch [InvalidOperationException] {
                    if (-not $process.HasExited) { throw }
                }
                $process.WaitForExit()
            }
        }
        finally { $process.Dispose() }
    }
    if ($decoderExitCode -ne 0 -or -not [IO.File]::Exists($xmlPath)) {
        throw "tracerpt exit code $decoderExitCode. See '$SnapshotPath.decoder.txt'."
    }
    $xmlPath
}

function Format-UopLogCollectionReport {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    $lines = @(
        "UOP provider logs: $($Result.Status) ($($Result.EventCount) events)"
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
    schemas, interpreted metadata and summaries in a unique directory under
    the chosen output directory, safe to delete when no longer needed.
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
    snapshotted, delaying AAU archive replacement until copying completes.
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
    circular ETL may change during copy. Changing files are explicitly reported;
    collect closed ETLs with -InputPath for a consistent historical capture.

    Missing AAU source categories produce explicit warnings. CSP capture is optional:
    existing CSP text and current/legacy ETLs are collected, but absence does not imply a
    failed AAU capture. Copy/decode failures
    preserve the bundle, write an Incomplete manifest/report, and then raise a
    terminating error. Text-only collections have Status TextOnly; a collection
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
    Collection failures retain their evidence bundle.
    Each GUID-named UOPProviderLogs.*.diagnostics bundle contains only collector-owned copies and
    can be deleted in its entirety when that evidence is no longer needed.
    .PARAMETER RawOnly
    Collects and retains raw ETL/text snapshots and a manifest without claiming to decode.
    .PARAMETER MaxInputBytes
    Total raw snapshot budget, default 1 GiB. Files exceeding the remaining budget are not copied.
    Budget exhaustion publishes Incomplete with the evidence already collected; sources are unchanged.
    .PARAMETER MaxEvents
    Maximum events retained for the ordered report, default 100000. Raw snapshots are still collected.
    Reaching the limit before another event produces Incomplete, never silent truncation.
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
    if (-not $PSCmdlet.ShouldProcess(($destinations -join ', '), 'Collect diagnostics, write event logs and copy reporting generations')) {
        return
    }

    $outputPin = Open-UopOutputDirectory -Path ([IO.Path]::GetDirectoryName($outputPath))
    $progressActivity = 'Collecting UOP provider logs'
    try {
    Write-Progress -Activity $progressActivity -Status 'Finding diagnostic files' -PercentComplete -1
    $displayTimeZone = [TimeZoneInfo]::Local
    $collectionId = [Guid]::NewGuid().ToString('N')
    $workspaceRoot = [IO.Path]::GetDirectoryName($outputPath)
    $bundlePath = Join-Path $workspaceRoot "UOPProviderLogs.$collectionId.diagnostics"
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
    $manifest = $null
    $reportsPublished = $false
    $reportingLogPath = $null
    $reportingArchivePaths = [Collections.Generic.List[string]]::new()
    $cspTextLogPaths = [Collections.Generic.List[string]]::new()
    $reportingPins = [Collections.Generic.List[IO.FileStream]]::new()
    $reports = @(
        [pscustomobject]@{ Path = $outputPath; Scenario = 'UOP'; StagedPath = "$outputPath.$collectionId.tmp"; Created = $false }
        if ($cspOutputPath) {
            [pscustomobject]@{ Path = $cspOutputPath; Scenario = 'CSP'; StagedPath = "$cspOutputPath.$collectionId.tmp"; Created = $false }
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
        $providerBundle = $null
        if ($collectAau) {
            $providerBundle = Join-Path $bundlePath $script:AauProviderId
            [void][IO.Directory]::CreateDirectory($providerBundle)
            foreach ($sourceSet in $sourceSets) {
                try { $sources += @(Get-UopSourceFiles @sourceSet) }
                catch { $failures.Add("Source discovery failed for '$($sourceSet.Directory)': $($_.Exception.Message)") }
            }
            $sources = @($sources | Sort-Object FullName -Unique | Sort-Object @{
                Expression = {
                    if ($_.Name -ieq 'AAUReportingEvents.log') { 0 }
                    elseif ($_.Name -match '^AAUReportingEvents\.\d+\.log$') { 1 }
                    elseif ($_.Name -match '^AppUpdateCSP\.[0-7]\.log$') { 2 }
                    else { 3 }
                }
            }, FullName)
            # Pin discovered archives before copying the active file. AAU publishes
            # before truncating active, so its rollover cannot erase either generation
            # during this snapshot. Reads still permit the lifetime active writer.
            foreach ($source in $sources) {
                if ($source.Name -match '^AppUpdateCSP\.[0-7]\.log$') {
                    try {
                        Assert-AauLocalPath -Path $source.FullName
                        try {
                            # Inactive slots cannot be claimed/recycled until this read pin closes.
                            $pin = [IO.File]::Open($source.FullName, [IO.FileMode]::Open,
                                [IO.FileAccess]::Read, [IO.FileShare]::Read)
                        }
                        catch [IO.IOException] {
                            if (($_.Exception.HResult -band 0xffff) -ne 32) { throw }
                            $pin = [IO.File]::Open($source.FullName, [IO.FileMode]::Open,
                                [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                            $warnings.Add("Live CSP text may change or contain an incomplete final row: $($source.Name)")
                        }
                        $reportingPins.Add($pin)
                    }
                    catch {
                        $failures.Add("CSP text pin failed for '$($source.FullName)': $($_.Exception.Message)")
                    }
                    continue
                }
                if ($source.Name -notmatch '^AAUReportingEvents\.\d+\.log$') { continue }
                try {
                    Assert-AauLocalPath -Path $source.FullName
                    $reportingPins.Add([IO.File]::Open($source.FullName, [IO.FileMode]::Open,
                        [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
                }
                catch {
                    $failures.Add("Reporting archive pin failed for '$($source.FullName)': $($_.Exception.Message)")
                }
            }
            if ($sources.Count -eq 0 -and $failures.Count -eq 0) {
                $missingSources = "No AAU/CSP diagnostics found. Searched '$inputDirectory' for AutomaticAppUpdater.*.etl, AppUpdateCSP.*.etl and AppUpdateCSP.[0-7].log; '$stateDirectory' for AAUReportingEvents.log and AAUReportingEvents.<number>.log."
                $warnings.Add($missingSources)
                $failures.Add($missingSources)
            }
            foreach ($category in @('AutomaticAppUpdater.*.etl', 'AAUReportingEvents.log')) {
                if (@($sources | Where-Object Name -like $category).Count -eq 0) {
                    $warnings.Add("Source category missing: $category")
                }
            }
            $warnings.Add('Live files are copied without flushing or stopping ETW. Unflushed buffers and changes during circular-file copying may not be recoverable.')
        }

        $sourceIndex = 0
        $duplicateNames = @($sources | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
        foreach ($source in $sources) {
            if ($source.Extension -ieq '.etl' -and $reportingPins.Count -gt 0) {
                foreach ($pin in $reportingPins) { $pin.Dispose() }
                $reportingPins.Clear()
            }
            $sourceIndex++
            $percentComplete = [int](100.0 * ($sourceIndex - 1) / $sources.Count)
            Write-Progress -Activity $progressActivity -Status "Copying file $sourceIndex of $($sources.Count)" `
                -CurrentOperation $source.Name -PercentComplete $percentComplete
            Write-Verbose "Input: $($source.FullName)"
            $snapshotDirectory = $providerBundle
            $sourceLabel = $source.Name
            if ($source.Name -in $duplicateNames) {
                # Preserve distinct source files with the same basename; never overwrite one.
                $sourceFolder = 'Source{0:D4}' -f $sourceIndex
                $snapshotDirectory = Join-Path $providerBundle $sourceFolder
                $sourceLabel = "$sourceFolder\$($source.Name)"
            }
            $snapshotPath = Join-Path $snapshotDirectory $source.Name
            $budgetAccounted = $false
            $scenario = if ($source.Extension -ine '.etl') { 'Reporting' }
                elseif ($source.Name -like 'AppUpdateCSP.*') { 'CSP' } else { 'UOP' }
            try {
                if ($snapshotDirectory -ne $providerBundle) {
                    [void][IO.Directory]::CreateDirectory($snapshotDirectory)
                }
                $snapshot = Copy-AauSnapshot -Source $source -Destination $snapshotPath `
                    -MaximumBytes ($MaxInputBytes - $copiedBytes)
                $copiedBytes += $snapshot.Length
                $budgetAccounted = $true
                $snapshot | Add-Member -NotePropertyName ProviderId -NotePropertyValue $script:AauProviderId
                $snapshot | Add-Member -NotePropertyName Scenario -NotePropertyValue $scenario
                $snapshots.Add($snapshot)
                if ($scenario -eq 'Reporting' -and $source.Name -ieq 'AAUReportingEvents.log') {
                    $reportingLogPath = $reportingOutputPath
                    $reports += [pscustomobject]@{
                        Path = $reportingLogPath; Scenario = 'Reporting'
                        StagedPath = "$reportingLogPath.$collectionId.tmp"; Created = $false
                        SnapshotPath = $snapshotPath
                    }
                }
                elseif ($scenario -eq 'Reporting' -and $source.Name -match '^AppUpdateCSP\.[0-7]\.log$') {
                    $cspTextName = "$([IO.Path]::GetFileNameWithoutExtension($outputPath)).$($source.Name)"
                    if ($source.Name -in $duplicateNames) { $cspTextName = "$sourceFolder.$cspTextName" }
                    $cspTextPath = Join-Path ([IO.Path]::GetDirectoryName($outputPath)) $cspTextName
                    Assert-UopOutputPath -OutputPath $cspTextPath -SourceSets $sourceSets -Force:$Force
                    $cspTextLogPaths.Add($cspTextPath)
                    $reports += [pscustomobject]@{
                        Path = $cspTextPath; Scenario = 'Reporting'
                        StagedPath = "$cspTextPath.$collectionId.tmp"; Created = $false
                        SnapshotPath = $snapshotPath
                    }
                }
                elseif ($scenario -eq 'Reporting') {
                    $suffix = $source.Name.Substring('AAUReportingEvents'.Length)
                    $stem = [IO.Path]::GetFileNameWithoutExtension($reportingOutputPath)
                    if ($source.Name -in $duplicateNames) { $stem += ".$sourceFolder" }
                    $archiveOutputPath = Join-Path ([IO.Path]::GetDirectoryName($reportingOutputPath)) "$stem$suffix"
                    Assert-UopOutputPath -OutputPath $archiveOutputPath -SourceSets $sourceSets -Force:$Force
                    $reportingArchivePaths.Add($archiveOutputPath)
                    $reports += [pscustomobject]@{
                        Path = $archiveOutputPath; Scenario = 'Reporting'
                        StagedPath = "$archiveOutputPath.$collectionId.tmp"; Created = $false
                        SnapshotPath = $snapshotPath
                    }
                }
                if (-not $snapshot.UnchangedDuringCopy) {
                    $warnings.Add("Source changed during snapshot; consistency is not guaranteed: $($source.Name)")
                }
            }
            catch {
                if (-not $budgetAccounted -and [IO.File]::Exists($snapshotPath)) {
                    $copiedBytes += [IO.FileInfo]::new($snapshotPath).Length
                }
                $failures.Add("Snapshot failed for '$($source.FullName)': $($_.Exception.Message)")
                continue
            }
            if ($RawOnly -or $source.Extension -ine '.etl') {
                continue
            }
            try {
                Write-Progress -Activity $progressActivity -Status "Decoding file $sourceIndex of $($sources.Count)" `
                    -CurrentOperation $source.Name -PercentComplete $percentComplete
                $xmlPath = Invoke-UopEtlDecoder -Decoder $decoder -SnapshotPath $snapshotPath `
                    -TimeoutSeconds $DecoderTimeoutSeconds
                $previousCount = $events.Count
                Read-AauDecodedEvents -Path $xmlPath -SourceFile $sourceLabel `
                    -MaximumBytes $MaxDecodedXmlBytes | ForEach-Object {
                    if ($events.Count -ge $MaxEvents) {
                        throw "Decoded event budget exceeded ($MaxEvents). Earlier events and raw evidence are preserved."
                    }
                    $_ | Add-Member -NotePropertyName UopProviderId -NotePropertyValue $script:AauProviderId
                    $_ | Add-Member -NotePropertyName Scenario -NotePropertyValue $scenario
                    $events.Add($_)
                }
                if ($events.Count -eq $previousCount) {
                    $warnings.Add("No decodable component events in '$($source.Name)'; see raw ETL and decoder summary.")
                }
            }
            catch {
                $failures.Add("Decode failed for '$($source.Name)': $($_.Exception.Message)")
            }
        }
        foreach ($pin in $reportingPins) { $pin.Dispose() }
        $reportingPins.Clear()

        Set-UopPolicyCoverage -Events $events
        $incompletePolicyRecords = @($events | Where-Object {
            $_.PSObject.Properties['PolicyCoverage'] -and $_.PolicyCoverage.PartCoverage -ne 'Complete'
        }).Count
        if ($incompletePolicyRecords -gt 0) {
            $warnings.Add("Policy capture coverage is missing, duplicated or invalid for $incompletePolicyRecords records. Producer truncation is reported separately; retain raw events.")
        }
        $aauStatus = if ($failures.Count -gt 0) { 'Incomplete' }
            elseif ($RawOnly) { 'RawOnly' }
            elseif (@($sources | Where-Object Extension -eq '.etl').Count -eq 0) { 'TextOnly' }
            elseif ($events.Count -eq 0) { 'NoEvents' }
            else { 'Decoded' }
        if ($collectAau) {
            $providers.Add([pscustomobject]@{
                ProviderId = $script:AauProviderId; Status = $aauStatus; EventCount = $events.Count
                BundlePath = $providerBundle; InputPath = $inputDirectory; StatePath = $stateDirectory
                SourceDirectories = @($sourceSets | ForEach-Object { $_.Directory } | Sort-Object -Unique)
            })
        }
        $status = if ($failures.Count -gt 0) { 'Incomplete' }
            elseif ($selected.Count -eq 0) { 'NoProviders' }
            elseif (-not $collectAau) { 'Unsupported' }
            elseif ($providers.Count -gt 1) { 'Partial' }
            else { $aauStatus }
        $retainDiagnostics = $KeepDiagnostics -or $RawOnly -or $failures.Count -gt 0
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
        if ($failures.Count -gt 0) {
            throw "$($failures -join ' ') Diagnostic collection is incomplete. Report: '$outputPath'; raw bundle: '$bundlePath'."
        }
    }
    catch {
        $collectionFailed = $true
        $retainDiagnostics = $retainDiagnostics -or $null -ne $manifest -or $failures.Count -gt 0 -or
            $snapshots.Count -gt 0 -or $events.Count -gt 0
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
                        $retainedName = if ($report.Scenario -eq 'Reporting') {
                            "Collected.$([IO.Path]::GetFileName($report.Path))"
                        } else { "Collected.$($report.Scenario).log" }
                        [IO.File]::Move($report.StagedPath, (Join-Path $bundlePath $retainedName))
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
