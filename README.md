# Feature ID Scanner for Windows Updates

Automated scanning for Windows Feature ID details in each newly released Windows build, with the ability to compare them between builds.

<div align="center">
  <h1><a href="https://thiojoe.github.io/Windows-Feature-ID-Scanner/">🔗 Open the Interactive Data Viewer</a></h1>
  <sub>https://thiojoe.github.io/Windows-Feature-ID-Scanner/</sub>
</div>

## Data collected about each build:
- Feature ID numbers
- **Callers**: Which binaries and functions call a feature ID
- **Dependencies**: Which other features must be enabled for a feature to work
- **Default States**: Whether a feature ID is enabled/disabled by default
- **"Super God Mode" analysis**: Including settings pages, deep links, URL protocols, and more
- **Runtime analysis**: Uses Windows event tracing to spot if windows components check a feature ID

## Build Comparison Tool Features
- Compare any two scanned builds
- Feature IDs that have been added, removed, or renamed
- Default state changes for a feature ID
- Renamed or newly named feature IDs
