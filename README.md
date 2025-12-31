# UTM Actions Runner

Like Tartlet for UTM- Continuously clones, starts, and cleans up a fresh Windows VM for GitHub Actions using UTM CLI.

Tartlet is a powerful tool, but only supports MacOS and Linux VMs using Tart. I created this repo to provide the same local runner experience for Windows VMs using UTM.

If you want to run a Windows github action runner on your Mac hardware, this is a good place to start.

## Resources

UTM - Windows and Linux on Mac

https://mac.getutm.app/

https://docs.getutm.app/scripting/scripting/

### UTM Installation

Install UTM and expose the CLI

```bash
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl

# Test it works
utmctl --version
```

### Windows "Base" VM Setup

We need a Windows Virtual Machine to serve as the source, or "base" for runner clones. The base VM should not be modified after setup, and any testing should be done on clones, to ensure a stable runner environment.

Create the base using this guide:

[💻 Running Windows on your M1 Mac with UTM and CrystalFetch](https://gist.github.com/paulfermoreyes/daf4c89327707a333c0b05e5855eee64)

Name the VM "Windows-runner"
Create a shared directory on the host machine eg. `~/.utm/shared`, and update the VM settings to grant access.

Start the VM and modify it as follows:

Install UTM guest tools
Install the latest Windows updates
Install the autologin package from https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
Enable script execution using the command:

```bash
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Install git bash from https://git-scm.com/install/windows
Install jq using the command:

```bash
winget install jqlang.jq
```

Optional performance and organization changes:

- Uninstall Copilot: Settings > apps > installed apps > Copilot
- Stop windows search indexing: run the command `services.msc` > disable Windows Search on startup
- (TODO: add more)

### Github Action Runner Setup

In your Repo navigate to Settings > Actions > Runners > New self-hosted Runner.

Complete the step "Download" for your base VM. Do not perform the "Configure" step.

The startup script `start-action-runner.ps1` configures our runner on startup. It will be placed automatically in the shared directory on startup, typically in the Z:\ drive. Create a new task in Task Scheduler to run this startup script.

- start on: log-in
- command: powershell.exe
- arguments: -File "Z:\start-action-runner.ps1"

### Start windows-runner-on-mac

Now we are ready to start our runner manager.

Create a `.env` with the following values:

```bash
SHARED_DIRECTORY="$HOME/.utm/shared"
TOKEN="your_token_from_runner_setup"
ORGANIZATION="your_username"
REPO_NAME="your_repo"
```

Then start the runner with:

```bash
./utm-actions-runner.sh
```

This will copy the startup script to the shared directory, update the runner config values, and start your new cloned runner.

The script will repeatedly create a new clones after the previous one shuts down.

## Troubleshooting

- Check the startup script in the shared directory. It should have the correct values.
- Change the runner script if your named your base something besides "Windows-runner"
- You must restart the script if your configuration changes

## Tips:

- Use the shared directory to enable a persistent local cache, eg:

```yaml
name: Build Python Package

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: [self-hosted, windows]
    env:
      # Use the Z: Drive shared directory
      SELF_CACHED_DIR: /z

    steps:
      - name: Cache pip downloads
        uses: iby/self-cached@**v1**
        with:
          path: ${{ steps.pip-cache.outputs.dir }}
          key: ${{ runner.os }}-pip-${{ hashFiles('requirements.*.txt') }}
```

## Improvements:

- TODO: what else is needed?
