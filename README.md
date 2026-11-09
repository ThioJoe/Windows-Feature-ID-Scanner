# Windows-Feature-ID-Scanner
A modern take on mach2's feature scanning: GitHub Actions scans Windows 11 for feature IDs and their names (ARM64 on a GitHub runner, x64 in a virtual machine built from Microsoft's servers), stores the results per build, and tracks what changes between builds.

**Browse the data:** the GitHub Pages site (published from `site/`) compares any two scanned builds (added / removed / renamed features, feature store changes, default state changes, and the shell folders, settings pages, Settings search entries, URL protocols and other links Super God Mode found in each) and lists every feature ID in a build with the build it first appeared in. Click a feature to see what its code reveals: the functions that check it, the strings they use, the features it requires and its default state. It also lists the builds Microsoft has released for every Windows 11 version and Insider channel, and which of them have been scanned.

## How it works

The `Windows Feature Scanner` workflow (`.github/workflows/windows-scanner.yml`) runs on the `windows-11-arm` runner, because the Windows Server images don't carry the consumer feature set.

1. **`scan-symbols.py`** finds feature names and IDs in Microsoft's public symbols. For every binary under the Windows directories it downloads the matching PDB from the Microsoft symbol server and reads the symbols that WIL feature staging emits (`Feature_<Name>__descriptor`, `Feature_<Name>__private_descriptor`, `__WilFeatureTraits_Feature_<Name>::id`), then reads each feature's ID from the binary. C++ features in binaries built with older WIL have no descriptor; their ID comes from the code of their `GetCurrentFeatureEnabledState`, which passes it to Windows. This replaces mach2, which is retired and fails on current PDBs. For binaries that contain features, it also analyzes their code (see below).
2. **`scan-features.ps1`** runs ViVeTool to dump the feature store (the IDs actually configured on the machine) and fills in names from step 1.
3. **`run-super-god-mode.ps1`** runs the latest release of [Super God Mode](https://github.com/ThioJoe/Windows-Super-God-Mode) and keeps its statistics: CSV files listing the build's CLSID shell folders, named special folders, task links, `ms-settings:` pages, deep links, URL protocols and hidden app links, and the XML data the task links and deep links come from. The shortcuts it creates aren't kept. If it fails, the scan carries on without its statistics.
4. **`update-data.py`** puts all of it in the build's folder, `data/builds/<build>-<arch>/`, and regenerates the index, first-seen table and diffs. The workflow commits the result and republishes the site.

The workflow runs daily: a small check job reads the runner's Windows build and only starts a full scan when that build isn't in `data/` yet. It can also be started manually from the Actions tab, which always scans.

Scanning downloads several GB of PDBs (each is deleted after reading). What was found in each PDB is stored in `data/symbol-cache.json` (`data/symbol-cache-AMD64.json` for the x64 scans), keyed by the PDB's name and GUID, so later scans only download PDBs for binaries that changed. PDBs the symbol server doesn't have (404) are remembered too and re-checked after 14 days. If a changed binary's PDB still can't be downloaded after retries, the scan uses what the most recent earlier version of that binary contained and marks those features `"unverified"`, rather than dropping them.

## x64 builds in a virtual machine

The `Windows VM Feature Scanner` workflow (`.github/workflows/windows-vm-scanner.yml`) scans x64 builds of Windows 11 regardless of what runner images exist. GitHub's x64 runners run Windows Server, but they can run Hyper-V virtual machines, so `scan-in-vm.ps1` builds a Windows 11 Enterprise VM on one, entirely from Microsoft's servers:

1. The base image comes from the Media Creation Tool's catalogs of Windows images, which list each image file on Microsoft's servers with its hash. The tool's download link still points to a 24H2 catalog from June 2025; the tool then asks Windows Update's metadata service for the current catalog (26H2 at the time of writing), and so does the script. It takes the newest image that can become the target version: a 26H2 image can't become 25H2, so 25H2 and 24H2 start from the 24H2 one. The image is applied to a virtual disk that boots without the setup screens.
2. The target cumulative update, from the Microsoft Update Catalog, is installed inside the running VM with DISM. 24H2, 25H2 and 26H2 share their code and their cumulative updates.
3. Unless the image is that version already, the target version's enablement package is installed, which is what makes the build a 25H2 or 26H2 one. Microsoft only distributes it through Windows Update (not the Update Catalog), where it comes together with the newest cumulative update; so the VM takes only the package's own file from Windows Update's offer (chosen with its target release version policy) and installs it with DISM, which keeps the build at the target update. That's what lets any past build be scanned, not only the newest.
4. Windows Update then installs whatever else it offers, as it would on any PC at that build (Defender and Windows Security platform updates, .NET and so on), leaving out updates that would change the build. The Microsoft Store updates the apps that come with Windows, which cumulative updates don't touch, so they're at the versions a PC gets today rather than the ones the image was made with. An app update that fails because the app is running is retried after closing what Windows' deployment log names, and whatever still fails is retried after a restart. Apps and these other updates don't decide the build, so one that still can't be installed doesn't stop the scan; the build's data gets a `notes` entry saying so.
5. After a last restart, the VM is checked against what the build is supposed to be:
   - Windows' servicing lists the build's cumulative update as installed, with no update half installed or waiting for a restart.
   - `DISM /ScanHealth` and `sfc /verifyonly` find no file that differs from the component manifests Microsoft signs.
   - `verify-windows-files.py` checks the installed files against Microsoft's own lists. Each update's KB article (read through the Microsoft Learn API, see below) links a file list with the name, version and SHA-256 of every file the update carries. Every file installed from Windows' component store has to be either a file one of the installed updates lists (by SHA-256) or exactly the file in Microsoft's image the VM started from, listed right after the image is applied. Which of an update's components apply to a system is decided by Windows' servicing, which the first check covers.

   If a check fails, nothing is recorded. The reports (`verification.json` and the others, plus a list of every file with its SHA-256) are kept with the run's artifacts either way.
6. The same scan as on the ARM64 runner runs inside the VM, with Super God Mode run as the VM's own user, as it would be by someone using that PC. If the VM didn't end up at the expected build, nothing is recorded.

Starting from an older image and updating it gives the same Windows as Microsoft's own image of that build: built both ways (from Microsoft's 26300.9711 image as it is, and from the June 2025 24H2 image plus the October update and the 26H2 enablement package), every file installed from the component store was byte-identical between the two VMs, and neither had one the other lacked, apart from three of .NET's precompiled native images. The differences were in apps (the Store apps and Edge an image comes with), the update history, and files Windows generates on each PC.

A daily check (`check-windows-builds.py`) finds the builds Microsoft has released for every Windows 11 version and every Windows Insider channel. It starts a scan for each build of 26H2, 25H2 and 24H2 (the versions the VM can be built for) that is newer than the newest build of that version in `data/`, so no build is missed when two come out between checks (the newest three, if more are missing). A version with no build in `data/` yet starts at its newest. Monthly security updates, optional previews and out-of-band releases all count, since each is a different build. The sources are Microsoft's, read on every check and compared with each other:

- **Versions and their updates:** support.microsoft.com's index of its Windows 11 update history (JSON), checked against the [Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information) page, which also stands in for the index when that can't be read.
- **Insider builds:** the index of the [Windows Insider release notes](https://learn.microsoft.com/en-us/windows-insider/) (JSON), with each build's release date from [Flight Hub](https://learn.microsoft.com/en-us/windows-insider/flight-hub/), which also stands in for the index.
- **Pages:** KB articles, the release information page and Flight Hub are read through the [Microsoft Learn API](https://learn.microsoft.com/api/mcp) (`microsoft_learn.py`), which gives a page as Markdown. A page's HTML is only read when that fails.

A source that fails, or two that disagree, show up as warnings on the run. The run's summary lists the newest builds of every version and channel; the list is kept in `data/releases.json` and shown on the site. 26H1 isn't scanned: it's a separate branch for new devices, and the Media Creation Tool's catalogs have no image of it.

Insider builds aren't scanned yet because the VM-side setup for receiving Insider updates hasn't been implemented. The rest of the path is in place: for an Insider build, `scan-in-vm.ps1 -InsiderChannel <channel>` starts from the newest image and uses Windows Update to install the channel's build once the VM is configured to receive it. The checks then run without the file check, since Insider builds have no file lists. The setup function (`Register-InsiderDevice`) is currently a placeholder. Possible approaches include automating normal Insider enrollment, configuring Windows' Insider flighting settings directly, or obtaining the build through Windows Update's APIs. It's not yet established which approach will work reliably. The `WINDOWS_INSIDER_DEVICE` secret is also a placeholder and is currently empty. While it's empty, the daily check lists Insider builds but doesn't schedule them. Once the setup is implemented and Insider scans are enabled, the check can scan each Insider channel's new builds except Release Preview's, which are scanned as the updates they become.

A scan of one build takes about an hour to an hour and a half on GitHub's runner. Since 25H2 and 26H2 start from different images, a comparison between them can also show differences in the apps the images come with: the Store doesn't bring every app on an older image to the version a newer image has. Manual runs can pick the versions, scan specific builds (older ones, for example) and rescan builds that are already in `data/`. (Microsoft's ISO download page turns away requests from GitHub's runners, so the base image comes from the Media Creation Tool's catalog instead.)

## What the code reveals

Every feature a binary uses comes with WIL plumbing compiled into it: a descriptor, state variables and small functions specific to that feature. `scan-symbols.py` decodes each such binary's ARM64 or x64 code and finds every call to those functions and every use of those variables, and the PDB's public symbols name the functions they're in. From that:

- **Callers:** the functions that check the feature (e.g. `CLogonTaskFramework::s_ShellHandwritingMethod`), which often say what it does even when the feature has no name.
- **Hints:** the strings, source file paths, imported functions, named data (registry values, WNF state names, ...) and other functions used by the first few of those callers.
- **Dependencies:** features that only work when other features are also on. C-style descriptors list them; C++ features check them inside their own plumbing. Some of the most-required features are named like monthly release gates (`Standalone_26_09_NonSec`), which hints at the update a feature belongs to.
- **Default state and change time:** whether a feature is on when nothing configures it, and when a change takes effect (on read, on reload, at sign-in or after a reboot). C-style descriptors store both; for C++ features they're read from the code of the feature's `GetCurrentFeatureEnabledState`. In testing on ARM64, the result agreed with the feature store's ImageDefault entries for all 1,301 features that had one. x64 code arranges that decision in more ways, so the x64 analysis follows the function's code with each possible configured state and sees which one sets the feature's 'enabled' bit. Features a binary only uses, while another binary defines them, get no default from it.
- **Lookup tables:** a function that references many features (such as KernelBase's `GetFeatureDescriptor`, which lists about 1,300) is a table, not a check, and is reported separately.

ARM64 and x64 code is decoded (ARM64X and ARM64EC binaries contain both); 32-bit binaries get no usage details. Callers and hints are found automatically and can include unrelated code from the same function. A function with no public symbol shows up as `(unnamed function after <nearest named function>)`.

## Data

```
data/
├── index.json                  Every scanned build with summary counts
├── symbol-cache.json           What each scanned PDB contained (by PDB name and GUID), reused by later scans
├── symbol-cache-AMD64.json     The same for the x64 scans
├── first-seen.json             First tracked build each feature ID appeared in, per architecture
├── releases.json               The newest builds Microsoft has released for each Windows 11 version and Insider channel
├── builds/<build>-<arch>/      A folder per scanned build:
│   ├── features.json           All feature IDs of the build, one per line: id, name (null if unknown), modules, default state, requirements, feature store state
│   ├── details.json            What each binary's code reveals about each feature, one per line (callers, strings, ...)
│   └── super-god-mode/         Super God Mode's statistics for the build: its CSV and XML files as it writes them, and run.json
└── diffs/<old>_to_<new>.json   Changes between consecutive builds (.md versions for reading on GitHub)
```

Every feature ID found is listed, named or not. Many features only have a number for a name in the symbols (the ID itself, or an obfuscated hash); those have `"name": null` and keep the raw symbol names in `symbolNames`. A feature whose code has been removed from every binary can still be configured in the feature store; it keeps the name an earlier build found for it (`"nameSource": "earlierBuild"`). A feature that ViVeTool's dictionary names differently from the symbols also has that name, as `viveToolName`. "First seen" for the first tracked build only means the feature existed at least that early. A build scanned in the VM can have `notes`, such as Store apps the VM couldn't update, and an Insider build has its `insiderChannel`.

`modules` lists the binaries that contain a feature's code. Some binaries ship full PDBs whose type information declares the IDs of hundreds of features they never use (the PDB of Windows.UI.Xaml.dll declares 1,878 feature IDs; the binary uses 55); those are listed separately in `declaredIn`. Where known, a feature also has `default` (`enabled`, `disabled`, `alwaysEnabled` or `alwaysDisabled`), `changeTime` (`read`, `moduleReload`, `session` or `reboot`) and `requires` (feature IDs). The bulkier details are in each build's `details.json`.

The site doesn't load the `details.json` files or the `super-god-mode/` folders themselves. When it's published, `build-site-data.py` derives the files it loads: each feature's details from the newest build that has them, split into 64 files by feature ID so that a feature's panel downloads one small file instead of a build's whole details, and each build's Super God Mode CSV files in one JSON file, so that comparing two builds loads two files. That file also has the entries of the Settings app's search index (`Settings_XML_Resolved.xml`): each entry's description, page, deep link and keywords, and the feature that shows or hides it. Those derived files only exist on the published site, not in the repository.

## Running locally

`python scan-symbols.py` works on any Windows machine with Python 3 (no packages needed). It writes `extracted-names.txt` (`ID Name`) and `symbol-features.json`. See `--help` for options such as `--root`, `--symbol-cache` and `--keep-pdbs`.

To view the site locally, put the contents of `site/` and a copy of `data/` in a folder, run `python build-site-data.py --out <folder>/derived`, and serve the folder with any web server (`python -m http.server`).
