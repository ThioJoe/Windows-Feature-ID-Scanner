# Copyright (c) Microsoft Corporation. All rights reserved.
# Shared preflight only: checks do not pin handles or eliminate check/open races.
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
