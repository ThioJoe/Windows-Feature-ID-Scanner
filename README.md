# Windows-Feature-ID-Scanner
A modern take on mach2's feature scanning: GitHub Actions scans a Windows 11 ARM64 runner for feature IDs and their names, stores the results per build, and tracks what changes between builds.

**Browse the data:** the GitHub Pages site (published from `site/`) compares any two scanned builds (added / removed / renamed features, feature store changes) and lists every feature ID in a build with the build it first appeared in.

## How it works

The `Windows Feature Scanner` workflow (`.github/workflows/windows-scanner.yml`) runs on the `windows-11-arm` runner, because the Windows Server images don't carry the consumer feature set.

1. **`scan-symbols.py`** finds feature names and IDs in Microsoft's public symbols. For every binary under the Windows directories it downloads the matching PDB from the Microsoft symbol server and reads the symbols that WIL feature staging emits (`Feature_<Name>__descriptor`, `Feature_<Name>__private_descriptor`, `__WilFeatureTraits_Feature_<Name>::id`), then reads each feature's ID from the binary. This replaces mach2, which is retired and fails on current PDBs.
2. **`scan-features.ps1`** runs ViVeTool to dump the feature store (the IDs actually configured on the machine) and fills in names from step 1.
3. **`update-data.py`** merges both into `data/builds/<build>-<arch>.json` and regenerates the index, first-seen table and diffs. The workflow commits the result and republishes the site.

The workflow runs daily: a small check job reads the runner's Windows build and only starts a full scan when that build isn't in `data/` yet. It can also be started manually from the Actions tab, which always scans.

Scanning downloads several GB of PDBs (each is deleted after reading). What was found in each PDB is stored in `data/symbol-cache.json`, keyed by the PDB's name and GUID, so later scans only download PDBs for binaries that changed. PDBs the symbol server doesn't have (404) are remembered too and re-checked after 14 days. If a changed binary's PDB still can't be downloaded after retries, the scan uses what the most recent earlier version of that binary contained and marks those features `"unverified"`, rather than dropping them.

## Data

```
data/
├── index.json                  Every scanned build with summary counts
├── symbol-cache.json           What each scanned PDB contained (by PDB name and GUID), reused by later scans
├── first-seen.json             First tracked build each feature ID appeared in, per architecture
├── builds/<build>-<arch>.json  All feature IDs of a build, one per line: id, name (null if unknown), modules, feature store state
└── diffs/<old>_to_<new>.json   Changes between consecutive builds (.md versions for reading on GitHub)
```

Every feature ID found is listed, named or not. Many features only have a number for a name in the symbols (the ID itself, or an obfuscated hash); those have `"name": null` and keep the raw symbol names in `symbolNames`. "First seen" for the first tracked build only means the feature existed at least that early.

## Running locally

`python scan-symbols.py` works on any Windows machine with Python 3 (no packages needed). It writes `extracted-names.txt` (`ID Name`) and `symbol-features.json`. See `--help` for options such as `--root`, `--symbol-cache` and `--keep-pdbs`.
