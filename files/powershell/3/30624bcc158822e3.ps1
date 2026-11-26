# Copyright (c) Microsoft Corporation. All rights reserved.
# Private fragment, dot-sourced into its owning module; not an independent entrypoint.
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
        ($eventName -eq 'Failure' -and $provider.GetAttribute('Name') -match 'AppUpdateCSP')) {
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
                $captured = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($field.Value, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$captured)) {
                    $timestamp = $captured.ToUniversalTime()
                }
            }
        }
    }
    [pscustomobject]@{
        TimestampUtc = $timestamp.ToString('o')
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
