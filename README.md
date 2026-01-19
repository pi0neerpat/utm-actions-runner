# UTM Actions Runner

Like [Tartlet](https://github.com/shapehq/tartelet) but for Windows on Mac. 

Spins up a fresh Github action runner for Windows, using the UTM CLI.



If you want Windows github runners on Mac, this may be a good place to start.

## Resources

UTM - Windows and Linux on Mac

https://mac.getutm.app/

https://docs.getutm.app/scripting/scripting/

## Overview

1. Install UTM
2. Create the windows VM
3. Install Github Actions
4. Install the Github App for generating runner keys

### 1. Install UTM

Install UTM and expose the CLI

```bash
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl

# Test it works
utmctl --version
```

Note: UTM CLI doesn't behave properly in VSCode- recommend using Terminal for all commands.

### 2. Setup Windows "Base" VM

We need a Windows Virtual Machine to serve as the source, or "base" for runner clones. The base VM should not be modified after setup, and any testing should be done on clones, to ensure a stable runner environment.

Create the base using this guide:

[💻 Running Windows on your M1 Mac with UTM and CrystalFetch](https://gist.github.com/paulfermoreyes/daf4c89327707a333c0b05e5855eee64)

Name the VM "Windows-runner"

Create a shared directory on the host machine eg. `~/.utm/shared`, and update the VM settings to grant access.

Start the VM and modify it as follows:

- Install UTM guest tools
- Install the latest Windows updates
- Install the autologin package from https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
- Enable script execution using the command:

```bash
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

- Install git bash from https://git-scm.com/install/windows. Use the Recommended Settings, else your PATH may not be correct for bash in Github Actions.
- Modify PATH to point to the correct bash.exe. Search for "Edit System Variable" > select "Environment Variables" > edit “Path” and add/move `C:\Program Files\Git\bin` at the top.

- Install jq using the command:

```bash
winget install jqlang.jq
```

Optional performance and ease-of-use changes:
- Install windows-nvm: https://github.com/coreybutler/nvm-windows
- Install yarn: https://yarnpkg.com/getting-started/install
- Stop windows search indexing: run the command `services.msc` > disable Windows Search on startup
- Disable startup apps: Settungs > search "Startup Apps"
- Disable the "Windows" key: https://github.com/nous-/disable-windows-key
- Update File Explorer to show hidden files: Settings > System > Advanced > File Explorer, and enable the relevant settings

### 3. Setup Github Actions

In your Repo navigate to Settings > Actions > Runners > New self-hosted Runner.

Complete the step "Download" for your base VM. Do not perform the "Configure" step.

The startup script `start-action-runner.ps1` configures our runner on startup. It will be placed automatically in the shared directory on startup, typically in the Z:\ drive. Create a new task in Task Scheduler to run this startup script.

- start on: log-in
- command: powershell.exe
- arguments: -File "Z:\start-action-runner.ps1"

### 4. Setup GitHub App

To automatically generate runner registration tokens (no manual token retrieval needed), set up a GitHub App:

1. **Create a GitHub App**:
   - For organization runners: Go to your organization settings → Developer settings → GitHub Apps → New GitHub App
   - For repository runners: Go to your account settings → Developer settings → GitHub Apps → New GitHub App
   - Set the app name (e.g., "UTM Actions Runner")
   - Set permissions based on scope:
     - **Organization scope**: Enable "Organization: Self-hosted runners (Read & Write)"
     - **Repository scope**: Enable "Repository: Administration (Read & Write)" and "Repository: Metadata (Read-only)"
   - Generate a private key and download it (`.pem` file)
   - Note the **App ID** (shown on the app settings page)

2. **Install the GitHub App**:
   - For organization: Install on your organization
   - For repository: Install on your account
   - **Find the Installation ID** :
     
     - Go to: https://github.com/settings/apps (for personal account) or https://github.com/organizations/{ORG}/settings/apps (for organization)
     - Click on your app
     - Click "Install App" or view existing installations
     - Click on the installation (repository or organization name)
     - The Installation ID is in the URL: `.../installations/{INSTALLATION_ID}`

3. **Store the Private Key**:
   
   Store the private key in Keychain:

   ```bash
   KEY_FILE="/path/to/your-private-key.pem"
   KEY_CONTENT=$(cat "$KEY_FILE")

   security add-generic-password \
     -a "utm-actions-runner" \
     -s "utm-actions-runner-github-app" \
     -w "$KEY_CONTENT" \
     -U
   ```
   
   **Important**: If you get "Operation not permitted" when reading the file:
   - Move the file away from ~/Downloads

### 5. Start Runner

Now we are ready to start our runner manager.

Create a `.env` with the following values:

```bash
SHARED_DIRECTORY="$HOME/.utm/shared"
GITHUB_APP_ID="123456"
GITHUB_APP_INSTALLATION_ID="78901234"
GITHUB_RUNNER_SCOPE="repository"  # or "organization"
GITHUB_ORGANIZATION="your_username_or_org"
GITHUB_REPOSITORY_NAME="your_repo"  # Only needed for repository scope
```


Then start the runner with:

```bash
./start.sh
```

This will:
- Generate a fresh registration token automatically using the GitHub App
- Copy the startup script to the shared directory with the token
- Start your new cloned runner

The script will repeatedly create new clones after the previous one shuts down, generating a fresh token for each instance.

## Troubleshooting

- Check the startup script in the shared directory. It should have the correct values.
- Check the your base VM naming if you chose something besides "Windows-runner"
- You must restart the script if your configuration changes
- Make sure you are running the script in Terminal, not VSCode
- Make sure the repo organization and name are correct

## Tips

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

