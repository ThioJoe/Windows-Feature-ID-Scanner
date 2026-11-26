# Copyright (c) Microsoft Corporation. All rights reserved.
# Private fragment, dot-sourced into its owning module; not an independent entrypoint.
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
