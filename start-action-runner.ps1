# This should be run at startup of the Windows VM to configure and start the GitHub Actions runner
# It is automatically modified and copied to the shared directory in ./windows-runner.sh 

# Wait for network and GitHub connectivity
while ($true) {
    try {
        $response = Test-NetConnection github.com -Port 443 -WarningAction SilentlyContinue
        if ($response.TcpTestSucceeded) {
            Write-Host "GitHub is reachable. Proceeding..."
            break
        } else {
            Write-Host "Waiting for network/GitHub connectivity..."
        }
    } catch {
        Write-Host "Waiting for network/GitHub connectivity..."
    }
    Start-Sleep -Seconds 5
}

Start-Process -Wait -NoNewWindow C:\actions-runner\config.cmd -ArgumentList @(
    '--url', 'https://github.com/ORGANIZATION/REPO_NAME',
    '--unattended',
    '--ephemeral',
    '--replace',
    '--name', 'runner-windows-11',
    '--runnergroup', 'Default',
    '--work', '_work',
    '--token', 'TOKEN'
)

# Start the runner
Start-Process -Wait -NoNewWindow C:\actions-runner\run.cmd

# Stop the VM after the runner exits
Stop-Computer -Force