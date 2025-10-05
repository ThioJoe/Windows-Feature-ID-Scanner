# Windows-Feature-ID-Scanner
Work in Progress. Attempting to use GitHub actions to run a Windows Feature ID scanner like Vive Tool in an automated manner for new versions.

## GitHub Actions Workflow

This repository includes a GitHub Actions workflow that:
- Runs on the latest Windows x64 runner (GitHub-hosted runners currently only support x64 architecture)
- Executes `scanner-script.ps1` to perform system scanning
- Automatically collects output files
- Organizes output files into folders based on the Windows build version and architecture
- Uploads results as workflow artifacts

### Running the Workflow

The workflow triggers on:
- Manual dispatch (via the Actions tab)
- Pushes to the `main` branch
- Pull requests

### Output Structure

Output files are organized in the following structure:
```
output/
└── Windows-Build-{BuildNumber}-{Architecture}/
    ├── system-info.txt
    ├── feature-list.txt
    └── summary.json
```

### Scanner Script

The `scanner-script.ps1` is a placeholder that demonstrates the workflow functionality. It:
- Collects Windows system information
- Generates sample output files (system-info.txt, feature-list.txt, summary.json)
- Can be replaced with actual feature scanning logic
