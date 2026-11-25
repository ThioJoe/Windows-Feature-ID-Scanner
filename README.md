# Feature ID Scanner for Windows Updates

Automated scanning for Windows Feature ID details in each newly released Windows build, with the ability to compare them between builds.

<div align="center">
  <h1><a href="https://thiojoe.github.io/Windows-Feature-ID-Scanner/">🔗 Open the Interactive Data Viewer</a></h1>
  <sub>https://thiojoe.github.io/Windows-Feature-ID-Scanner/</sub>
</div>

## Screenshot
<p align="center">
<img src="https://github.com/user-attachments/assets/de3d3667-c525-4408-bd0c-01c3c8919d55" />
</p>

-------

# Data collected about each build:
- Feature ID numbers
- **Names**: From Microsoft's public symbols, or ViVeTool's dictionary when the symbols have none
- **Callers**: Which binaries and functions call a feature ID
- **Code details**: Strings, source file paths, imported functions and registry values used in the functions that check a feature
- **Dependencies**: Which other features must be enabled for a feature to work
- **Default States**: Whether a feature ID is enabled/disabled by default
- **Change timing**: Whether a change to a feature takes effect the next time it's checked, when its binary reloads, at sign-in, or after a reboot
- **Feature store**: The feature configurations actually present on the scanned system (read with ViVeTool)
- **First seen**: The earliest scanned build each feature ID appeared in
- **Release info**: Which update the build came from (e.g. 2026-11 B), its release date and KB number
- **"Super God Mode" analysis**: Including settings pages, deep links, URL protocols, and more
- **Runtime analysis**: Uses Windows event tracing to spot if windows components check a feature ID
- **Runtime triggers**: Which processes checked a feature, and which Settings pages, folders or apps were open when they did

## Build Comparison Tool Features
- Compare any two scanned builds
- Feature IDs that have been added, removed, or renamed
- Default state changes for a feature ID
- Renamed or newly named feature IDs
- Feature IDs that lost their name
- Feature store changes
- Added, removed or changed Super God Mode items: shell folders, Control Panel tasks, Settings pages, Settings search entries, deep links, URL protocols and hidden app links
- The build each removed or newly named feature first appeared in
- Filter by ID, name or module, or show named features only

## Other Viewer Features
- Browse every feature ID in a build, with filters for named, in the feature store, new in that build, or seen in a runtime trace
- Search features by their code details (function names, strings, etc.)
- Click a feature to see its dependency tree, the features that require it, and whether it's actually on by default once its dependencies are accounted for
- Copy a feature's ID together with all of its dependencies' IDs for use with ViVeTool
- List of recent builds for each Windows 11 version and Insider channel, with KB links and which ones have been scanned
