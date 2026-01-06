#!/bin/bash
# windows-runner.sh: Continuously clones, starts, and cleans up a fresh Windows VM for GitHub Actions using UTM CLI.
# Requirements: UTM.app installed, utmctl available in PATH, a base VM named "Windows-runner" exists.

# Configuration
BASE_VM="Windows-runner"
CLONE_PREFIX="Windows-runner-clone-"
# Where to place the startup script
START_SCRIPT_NAME="./start-action-runner.ps1"

SHARED_DIRECTORY="$HOME/.utm/shared"
TOKEN=""
ORGANIZATION=""
REPO_NAME=""

# Get organization, repo, token, and shared directory from .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    SHARED_DIRECTORY="${UTM_SHARED_DIRECTORY:-$SHARED_DIRECTORY}"
    # Expand $HOME in SHARED_DIRECTORY if present
    SHARED_DIRECTORY=$(eval echo "$SHARED_DIRECTORY")
    TOKEN="${GITHUB_TOKEN:-$TOKEN}"
    ORGANIZATION="${GITHUB_ORGANIZATION:-$ORGANIZATION}"
    REPO_NAME="${GITHUB_REPOSITORY_NAME:-$REPO_NAME}"
fi

echo "Using ORGANIZATION=$ORGANIZATION, REPO_NAME=$REPO_NAME, SHARED_DIRECTORY=$SHARED_DIRECTORY"

# Copy the startup script to the shared directory
mkdir -p "$SHARED_DIRECTORY"
cp "$START_SCRIPT_NAME" "$SHARED_DIRECTORY"
# Replace placeholders in the startup script
sed -i '' "s/REPO_NAME/$REPO_NAME/g" "$SHARED_DIRECTORY/$START_SCRIPT_NAME"
sed -i '' "s/ORGANIZATION/$ORGANIZATION/g" "$SHARED_DIRECTORY/$START_SCRIPT_NAME"
sed -i '' "s/TOKEN/$TOKEN/g" "$SHARED_DIRECTORY/$START_SCRIPT_NAME"
UNIQUE_ID=$(date '+%Y-%m-%d-%H-%M-%S')
sed -i '' "s/UUID/$UNIQUE_ID/g" "$SHARED_DIRECTORY/$START_SCRIPT_NAME"


log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

get_vm_status() {
    # Returns the status string for a given VM, or 'unknown' if not found
    local vm_name="$1"
    local status_line
    status_line=$(utmctl status "$vm_name" 2>/dev/null | head -n1 | tr -d '\r\n' | awk '{print tolower($1)}')
    if [[ -z "$status_line" ]]; then
        echo "unknown"
    else
        echo "$status_line"
    fi
}

# Wait for a VM to be fully stopped
wait_for_vm_stopped() {
    local vm_name="$1"
    log "Waiting for $vm_name to stop..."
    while true; do
        STATUS=$(get_vm_status "$vm_name")
        if [ "$STATUS" != "started" ]; then
            log "$vm_name is stopped (status: $STATUS)"
            break
        fi
        sleep 3
    done
}

# Try to delete a VM, retrying if necessary until successful
delete_vm_with_retry() {
    local vm_name="$1"
    if utmctl delete "$vm_name"; then
        log "Deleted $vm_name."
        return 0
    else
        log "Delete failed for $vm_name."
        sleep 5
    fi
}

# List all VMs, filter for clones, and delete them (after ensuring stopped)
delete_old_clones() {
    utmctl list \
    | tail -n +2 \
    | awk '{for (i=3; i<=NF; i++) printf $i (i<NF?" ":"\n")}' \
    | grep "^$CLONE_PREFIX" \
    | while read -r vm; do
        log "Checking if old clone $vm is stopped before deletion..."
        wait_for_vm_stopped "$vm"
        delete_vm_with_retry "$vm"
    done
}

# Main loop
while true; do
    delete_old_clones
    
    # Generate a unique clone name
    CLONE_NAME="${CLONE_PREFIX}$(date '+%Y-%m-%d-%H:%M:%S')"
    log "Cloning $BASE_VM to $CLONE_NAME"
    if ! utmctl clone "$BASE_VM" --name "$CLONE_NAME"; then
        log "Clone failed. Retrying in 5 seconds..."
        sleep 5
        continue
    fi
    
    log "Starting $CLONE_NAME ..."
    if ! utmctl start "$CLONE_NAME"; then
        log "Start failed. Deleting $CLONE_NAME and retrying in 5 seconds..."
        delete_vm_with_retry "$CLONE_NAME"
        sleep 5
        continue
    fi
    
    # Wait for the VM to enter 'started' state (timeout after 60s)
    log "Waiting for $CLONE_NAME to enter 'started' state..."
    running_wait=0
    running_timeout=60
    while (( running_wait < running_timeout )); do
        STATUS=$(get_vm_status "$CLONE_NAME")
        if [[ "$STATUS" == "started" ]]; then
            log "$CLONE_NAME is started."
            break
        fi
        sleep 2
        ((running_wait+=2))
    done
    if [[ "$STATUS" != "started" ]]; then
        log "$CLONE_NAME never entered 'started' state (status: $STATUS). Deleting and retrying..."
        delete_vm_with_retry "$CLONE_NAME"
        sleep 5
        continue
    fi
    
    # Wait for the VM to stop robustly
    wait_for_vm_stopped "$CLONE_NAME"
    
    # Delete the stopped clone before next iteration, with retries
    log "Deleting stopped clone $CLONE_NAME ..."
    delete_vm_with_retry "$CLONE_NAME"
    sleep 2
done
