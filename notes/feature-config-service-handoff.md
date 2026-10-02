# Handoff: where "Service" feature configurations come from

## Goal

The feature store dump (ViVeTool `/query`) has entries at several priorities. Most of them ship in the Windows image or in update packages, so they could in principle be read from an ISO or other static files. The `Service` (priority 4) entries don't: Microsoft's servers push them to each device at runtime.

This investigation set out to find:

1. Which Windows component downloads them, from which endpoint, and what it sends.
2. Whether that request can be made directly, without booting Windows.

All testing was done on the `ai-sandbox-windows.yml` VM using the `windows-11-arm` image, build 26200.9457.

## What's been found

### The pipeline

1. **Scheduled task:** `\Microsoft\Windows\Flighting\OneSettings\RefreshCache` runs at boot and logon, then about every 3.5 hours. Its COM handler is `C:\Windows\System32\wosc.dll`, the Windows OneSettings client, hosted in `taskhostw.exe`.
2. **Request:** it sends a GET to Microsoft's OneSettings service:
   `https://settings-win.data.microsoft.com/settings/v3.0/WaaS/FeatureManagement?<device attributes>`
   The client's user agent is `MSDW`.
3. **Saved response:** the response goes to `C:\ProgramData\Microsoft\Windows\OneSettings\FeatureConfig.json`, with the previous copy kept as `FeatureConfig.bak.json`.
4. **Notification:** a WNF notification goes to the feature configuration component, `C:\Windows\System32\fcon.dll`. Its tasks live under `\Microsoft\Windows\Flighting\FeatureConfig\`.
5. **Registry:** `fcon.dll` writes each feature to `HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\<feature ID>`. The values are `EnabledState`, `Variant`, `FlightId` (e.g. `FX:1365D6E0`), `RolloutState`, `RolloutType` and `TelemetryFlags`. From there they go into the live feature store.

### Evidence

- `FeatureConfig.json` lists exactly the same 276 feature IDs as `Overrides\4` (276 subkeys). Both were written in the same second (00:42:43Z, about 90 s after boot).
- Every other priority (0, 1, 5, 9, 15) has registry timestamps from the image build, 2026-09-13. `Overrides\4` entries were written at runtime: 2026-09-24, when the runner image was created, and then at each boot.
- After deleting `FeatureConfig.json` and triggering `RefreshCache`, the file was downloaded again. A WinHTTP ETW trace (providers `Microsoft-Windows-WinHttp` and `Microsoft-Windows-WebIO`) captured the exact URL.

### Endpoint definition

OneSettings' own client config, `C:\ProgramData\Microsoft\Windows\OneSettings\config.json`, defines the endpoint as `ENDPOINT.FCON`:

- `Partner: WaaS`, `Feature: FeatureManagement`, `CtacAppId: CDM`
- `DeviceTicketOption: 2`. Most likely this means a device authentication ticket is attached to the request.
- The response is saved via `PayloadHandler: FILE`, and other components are notified through WNF.

### Request attributes

The list of attributes the `CDM` app may send is in `C:\ProgramData\Microsoft\Windows\OneSettings\CTAC.json`, under `CTACTARGETINGATTRIBUTES` → `PartB` → `CDM` (about 90 names). The same data is also in the registry at `HKLM\SOFTWARE\Microsoft\WindowsSelfHost\OneSettings\TargetingAttributes`.

The actual captured request:

```
https://settings-win.data.microsoft.com/settings/v3.0/WaaS/FeatureManagement?FlightRing=Retail&TelemetryLevel=0&AppVer=&ProcessorIdentifier=ARMv8%20%2864-bit%29%20Family%208%20Model%20D49%20Revision%20%20%200&OEMModel=Virtual%20Machine&InstallDate=1790300745&DurableDeviceRegionGeo=244&ChassisTypeId=3&IsCloudDomainJoined=0&FX_FlightIds=FX%3A1392F879&DL_OSVersion=10.0.26200.9457&IsDeviceRetailDemo=0&EdgeStableVersion=154.0.4258.37&FlightingBranchName=&OSUILocale=en-US&DeviceFamily=Windows.Desktop&OSSkuId=4&WebExperience=1&TotalPhysicalRAM=16384&App=CDM&WidgetsAppVer=526.21100.40.0&ProcessorCores=4&CurrentBranch=ge_release&IsVirtualDevice=1&HostingSystemEditionId=199&InstallLanguage=en-US&IsWindows365Device=0&AttrDataVer=501&MX_FlightIds=MD%3A283BAEF%2CME%3A3841A79%2CME%3A3A53D55%2CMD%3A3A53F1C%2CME%3A3536BD9%2CMD%3A2FE0A31%2CMD%3A2FE0A40%2CMD%3A2FE0A4F%2CMD%3A37B239D%2CMD%3A36AF640%2CMD%3A9999&IsA9CapablePC=0&SocketCount=1&OSVersion=10.0.26200.9457&CloudService=Azure&FconWexpVersion=3&ActivationChannel=Volume%3AGVLK&UUSVersion=1509.2608.11022.0&ClientHash2=822&IsMicrosoftAAD=0&OSArchitecture=arm64&AccountFirstChar=&DefaultUserRegion=244&DeviceForm=0
```

There's no device ID in the URL. `ClientHash2` looks like a rollout bucket, but that hasn't been verified.

### Response format

`FeatureConfig.json` looks like this:

```
{"queryUrl": "/settings/v3.0/WaaS/FeatureManagement",
 "settings": {
   "PAYLOAD_<n>_1": {
     "ad": {"entityId": "FX:<flight>",
            "items": [{"featureId": 47557358, "featureOptions": 4, "variant": 0, ...}]},
     "prm": {...},
     "history": ...}}}
```

On this VM it held 277 payloads covering 276 distinct feature IDs. Most items have no `priority` field; 6 have `"priority": 4`. `featureOptions` values seen were 2, 4 and 18.

It only contains the flights assigned to this device. It's not a full feature list and doesn't include defaults.

## What's not solved: replaying the request

- **Same request, same VM:** sending the identical URL from the same VM, byte-for-byte via raw `http.client`, with and without UA `MSDW`, returns `400 Bad Request`. The body is just `CorrelationId: <guid>`. PowerShell's `Invoke-WebRequest` gets the same result.
- **What's probably missing:** a request header the real client adds, most likely the device ticket (`DeviceTicketOption: 2`).
- **Why the trace doesn't show it:** the WinHTTP ETW trace logs that headers were sent, but not their contents; `tracerpt` renders them as garbage.
- **Interception attempt:** `pip install mitmproxy` failed on the ARM64 sandbox, with the install error not looked into.

### Open questions and possible next steps

1. **Header names:** search `wosc.dll` strings for header names (e.g. `Authorization`, `X-*`, "ticket") to see what it attaches. This is static and quick.
2. **Interception:** see the real headers by intercepting TLS on the sandbox. Options: x64 Python under emulation plus mitmproxy, with `netsh winhttp set proxy` and the mitmproxy CA trusted machine-wide. Or decode the WebIO ETW header events properly.
3. **Is the ticket required?** If it is, replaying with modified attributes would mean getting tickets from Microsoft's device authentication for devices that don't exist. That needs a decision before going further.
4. **Unrelated:** `C:\Windows\System32\WinCsFlags.exe` belongs to a separate, newer flag system, the Windows Configuration System (WinCS). On this VM, `WinCsFlags /query` shows one flag (`F33E0C8E`, a Secure Boot certificate update, CVE-2026-21265). It's not part of the feature store.

## Other related findings (from earlier in the investigation)

- **Feature store entries on the runner:** 3,269, by priority:
  - `Security` (9): 1,371
  - `ImageDefault` (0): 1,133
  - `ImageOverride` (15): 473
  - `Service` (4): 274 in the ViVeTool dump; 276 in the registry on the sandbox VM
  - `EKB` (1): 14
  - `5` (unnamed in ViVe's enum): 3
  - `User` (8): 1
- **Where the non-Service priorities live:** all of them are stored in the registry under `FeatureManagement\Overrides\<priority>\`. So the offline `SYSTEM` hive from an ISO should contain everything except Service entries. That still needs checking against an actual ISO.
- **Other `FeatureManagement` subkeys:** `Definitions`, `EnterpriseTempControls`, `FConMetadata`, `FeatureInventory`, `LastKnownGood`, `Policies`, `UsageSubscriptions`.
- **Files saved during the session:** `recon*.ps1`, `trace*.ps1` and copies of the OneSettings JSON files are in the session scratchpad, which won't persist. The sandbox VM was stopped after this write-up.
