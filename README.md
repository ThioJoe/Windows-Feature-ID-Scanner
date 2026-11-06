# Windows-Feature-ID-Scanner
A modern take on mach2's feature scanning: GitHub Actions scans a Windows 11 ARM64 runner for feature IDs and their names, stores the results per build, and tracks what changes between builds.

**Browse the data:** the GitHub Pages site (published from `site/`) compares any two scanned builds (added / removed / renamed features, feature store changes, default state changes) and lists every feature ID in a build with the build it first appeared in. Click a feature to see what its code reveals: the functions that check it, the strings they use, the features it requires and its default state.

## How it works

The `Windows Feature Scanner` workflow (`.github/workflows/windows-scanner.yml`) runs on the `windows-11-arm` runner, because the Windows Server images don't carry the consumer feature set.

1. **`scan-symbols.py`** finds feature names and IDs in Microsoft's public symbols. For every binary under the Windows directories it downloads the matching PDB from the Microsoft symbol server and reads the symbols that WIL feature staging emits (`Feature_<Name>__descriptor`, `Feature_<Name>__private_descriptor`, `__WilFeatureTraits_Feature_<Name>::id`), then reads each feature's ID from the binary. This replaces mach2, which is retired and fails on current PDBs. For binaries that contain features, it also analyzes their code (see below).
2. **`scan-features.ps1`** runs ViVeTool to dump the feature store (the IDs actually configured on the machine) and fills in names from step 1.
3. **`update-data.py`** merges both into `data/builds/<build>-<arch>.json` and regenerates the index, first-seen table and diffs. The workflow commits the result and republishes the site.

The workflow runs daily: a small check job reads the runner's Windows build and only starts a full scan when that build isn't in `data/` yet. It can also be started manually from the Actions tab, which always scans.

Scanning downloads several GB of PDBs (each is deleted after reading). What was found in each PDB is stored in `data/symbol-cache.json`, keyed by the PDB's name and GUID, so later scans only download PDBs for binaries that changed. PDBs the symbol server doesn't have (404) are remembered too and re-checked after 14 days. If a changed binary's PDB still can't be downloaded after retries, the scan uses what the most recent earlier version of that binary contained and marks those features `"unverified"`, rather than dropping them.

## What the code reveals

Every feature a binary uses comes with WIL plumbing compiled into it: a descriptor, state variables and small functions specific to that feature. `scan-symbols.py` decodes each such binary's ARM64 code and finds every call to those functions and every use of those variables, and the PDB's public symbols name the functions they're in. From that:

- **Callers:** the functions that check the feature (e.g. `CLogonTaskFramework::s_ShellHandwritingMethod`), which often say what it does even when the feature has no name.
- **Hints:** the strings, source file paths, imported functions, named data (registry values, WNF state names, ...) and other functions used by the first few of those callers.
- **Dependencies:** features that only work when other features are also on. C-style descriptors list them; C++ features check them inside their own plumbing. Some of the most-required features are named like monthly release gates (`Standalone_26_09_NonSec`), which hints at the update a feature belongs to.
- **Default state and change time:** whether a feature is on when nothing configures it, and when a change takes effect (on read, on reload, at sign-in or after a reboot). C-style descriptors store both; for C++ features they're read from the code of the feature's `GetCurrentFeatureEnabledState`. In testing, the result agreed with the feature store's ImageDefault entries for all 1,301 features that had one. Features a binary only uses, while another binary defines them, get no default from it.
- **Lookup tables:** a function that references many features (such as KernelBase's `GetFeatureDescriptor`, which lists about 1,300) is a table, not a check, and is reported separately.

Only ARM64 code is decoded, including the ARM64 and ARM64EC parts of ARM64X binaries; binaries for other architectures get no usage details. Callers and hints are found automatically and can include unrelated code from the same function. A function with no public symbol shows up as `(unnamed function after <nearest named function>)`.

## Data

```
data/
├── index.json                  Every scanned build with summary counts
├── symbol-cache.json           What each scanned PDB contained (by PDB name and GUID), reused by later scans
├── first-seen.json             First tracked build each feature ID appeared in, per architecture
├── builds/<build>-<arch>.json  All feature IDs of a build, one per line: id, name (null if unknown), modules, default state, requirements, feature store state
├── details/<arch>/<nn>.json    What each binary's code reveals about each feature (callers, strings, ...), split by ID (ID % 64)
└── diffs/<old>_to_<new>.json   Changes between consecutive builds (.md versions for reading on GitHub)
```

Every feature ID found is listed, named or not. Many features only have a number for a name in the symbols (the ID itself, or an obfuscated hash); those have `"name": null` and keep the raw symbol names in `symbolNames`. A feature whose code has been removed from every binary can still be configured in the feature store; it keeps the name an earlier build found for it (`"nameSource": "earlierBuild"`). "First seen" for the first tracked build only means the feature existed at least that early.

`modules` lists the binaries that contain a feature's code. Some binaries ship full PDBs whose type information declares the IDs of hundreds of features they never use (the PDB of Windows.UI.Xaml.dll declares 1,878 feature IDs; the binary uses 55); those are listed separately in `declaredIn`. Where known, a feature also has `default` (`enabled`, `disabled`, `alwaysEnabled` or `alwaysDisabled`), `changeTime` (`read`, `moduleReload`, `session` or `reboot`) and `requires` (feature IDs). The bulkier details are in `data/details/`, keyed by feature ID, from the newest build that had them.

## Running locally

`python scan-symbols.py` works on any Windows machine with Python 3 (no packages needed). It writes `extracted-names.txt` (`ID Name`) and `symbol-features.json`. See `--help` for options such as `--root`, `--symbol-cache` and `--keep-pdbs`. The code analysis only covers ARM64 binaries, so on an x64 machine the output has names, IDs and modules but no usage details.
