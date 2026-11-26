# Copyright (c) Microsoft Corporation. All rights reserved.
# Private fragment, dot-sourced into its owning module; not an independent entrypoint.
function Assert-AauLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-UopLocalPath -Path $Path
}

function Get-UopProviderLogName {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    # Registry identities are labels, not trusted filesystem paths. Never sanitize
    # two different identities into the same filename or accept Windows device names.
    if ($ProviderId.Length -gt 200 -or $ProviderId -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or
        $ProviderId -match '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw "ProviderId cannot be used as a log filename: $(ConvertTo-AauLogText $ProviderId). Use an explicit -LogPath for a combined report."
    }
    if ($ProviderId -ieq $script:AauProviderId) { $ProviderId = $script:AauProviderId }
    return "$ProviderId.log"
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
        $protectedCanonical.InputPath
        $protectedCanonical.StatePath
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Logs\AutomaticAppUpdater')
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\UOPProvider\AutomaticAppUpdater')
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\UOPProviders\AutomaticAppUpdater')
        (Join-Path ([Environment]::GetFolderPath('Windows')) "Logs\UOPProvider\$script:AauProviderId")
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "Microsoft\UOPProvider\$script:AauProviderId")
    )
    foreach ($privateDirectory in $protectedDirectories) {
        if ($OutputPath.StartsWith("$privateDirectory\", [StringComparison]::OrdinalIgnoreCase) -or
            $OutputPath.Equals($privateDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Output must be outside the protected AutomaticAppUpdater diagnostics and state directories.'
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
        StatePath = $canonical.StatePath
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
