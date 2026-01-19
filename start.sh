#!/bin/bash
# windows-runner.sh: Continuously clones, starts, and cleans up a fresh Windows VM for GitHub Actions using UTM CLI.
# Requirements: UTM.app installed, utmctl available in PATH, a base VM named "Windows-runner" exists.

# Configuration
BASE_VM="Windows-runner"
CLONE_PREFIX="Windows-runner-clone-"
# Where to place the startup script
START_SCRIPT_NAME="./start-action-runner.ps1"

SHARED_DIRECTORY="$HOME/.utm/shared"

# GitHub App auth / runner configuration (via .env)
GITHUB_APP_ID=""
GITHUB_APP_INSTALLATION_ID=""
GITHUB_RUNNER_SCOPE="repository" # repository | organization
GITHUB_ORGANIZATION=""
GITHUB_REPOSITORY_NAME=""

# macOS Keychain location for the GitHub App private key PEM
KEYCHAIN_ACCOUNT="utm-actions-runner"
KEYCHAIN_SERVICE="utm-actions-runner-github-app"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

# Get organization, repo, token, and shared directory from .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    # Back-compat: some configs used UTM_SHARED_DIRECTORY; README uses SHARED_DIRECTORY
    SHARED_DIRECTORY="${SHARED_DIRECTORY:-${UTM_SHARED_DIRECTORY:-$SHARED_DIRECTORY}}"
    # Expand $HOME in SHARED_DIRECTORY if present
    SHARED_DIRECTORY=$(eval echo "$SHARED_DIRECTORY")

    GITHUB_APP_ID="${GITHUB_APP_ID:-$GITHUB_APP_ID}"
    GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-$GITHUB_APP_INSTALLATION_ID}"
    GITHUB_RUNNER_SCOPE="${GITHUB_RUNNER_SCOPE:-$GITHUB_RUNNER_SCOPE}"
    GITHUB_ORGANIZATION="${GITHUB_ORGANIZATION:-$GITHUB_ORGANIZATION}"
    GITHUB_REPOSITORY_NAME="${GITHUB_REPOSITORY_NAME:-$GITHUB_REPOSITORY_NAME}"

    KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-$KEYCHAIN_ACCOUNT}"
    KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-$KEYCHAIN_SERVICE}"
fi

echo "Using GITHUB_ORGANIZATION=$GITHUB_ORGANIZATION, GITHUB_REPOSITORY_NAME=$GITHUB_REPOSITORY_NAME, GITHUB_RUNNER_SCOPE=$GITHUB_RUNNER_SCOPE, SHARED_DIRECTORY=$SHARED_DIRECTORY"


log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Missing required command: $1"
        exit 127
    }
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log "Missing required env var: $name"
        exit 2
    fi
}

base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

normalize_pem() {
    # Best-effort: restore PEM formatting if Keychain stripped newlines.
    # Reads PEM content from stdin, writes normalized PEM to stdout.
    local pem raw header footer body
    raw="$(cat)"
    # Normalize line endings
    raw="${raw//$'\r'/}"

    if [[ "$raw" != *"-----BEGIN "* || "$raw" != *"-----END "* ]]; then
        printf '%s' "$raw"
        return
    fi

    # Already looks like multi-line PEM.
    if [[ "$raw" == *$'\n'* ]]; then
        printf '%s' "$raw"
        return
    fi

    header="$(printf '%s' "$raw" | sed -n 's/^\(-----BEGIN [^-]*-----\).*/\1/p')"
    footer="$(printf '%s' "$raw" | sed -n 's/.*\(-----END [^-]*-----\)$/\1/p')"
    body="$(printf '%s' "$raw" \
        | sed "s|$header||" \
        | sed "s|$footer||" \
        | tr -d ' \n\r\t')"

    if [[ -z "$header" || -z "$footer" || -z "$body" ]]; then
        printf '%s' "$raw"
        return
    fi

    printf '%s\n' "$header"
    printf '%s' "$body" | fold -w 64
    printf '%s\n' "$footer"
}

hex_to_text() {
    # Decode a hex string from stdin to bytes/text.
    # Prefers xxd if available, otherwise python3 if available.
    local hex
    hex="$(cat)"
    hex="${hex#0x}"
    hex="${hex//[[:space:]]/}"

    if command -v xxd >/dev/null 2>&1; then
        printf '%s' "$hex" | xxd -r -p
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY' "$hex"
import sys
hx = sys.argv[1].strip()
try:
    sys.stdout.write(bytes.fromhex(hx).decode("utf-8", errors="strict"))
except Exception:
    # If it's not UTF-8, still write raw bytes as latin-1 to preserve 1:1 mapping
    sys.stdout.write(bytes.fromhex(hx).decode("latin-1"))
PY
        return
    fi

    log "Keychain secret looks hex-encoded, but neither xxd nor python3 is available to decode it."
    exit 2
}

decode_keychain_secret() {
    # Reads stdin, decodes common Keychain encodings, writes decoded text to stdout.
    local raw trimmed
    raw="$(cat)"
    raw="${raw//$'\r'/}"

    # If the key was stored with literal \n sequences, interpret escapes.
    # (PEM files never legitimately contain backslash-escape sequences.)
    raw="$(printf '%b' "$raw")"

    # Trim surrounding quotes (can happen if the secret was stored with quotes).
    if [[ "$raw" == \"*\" ]]; then
        trimmed="${raw#\"}"
        trimmed="${trimmed%\"}"
        raw="$trimmed"
    fi

    # Some Keychain flows store PEM as hex bytes (e.g. "2d2d2d2d2d...").
    if [[ "$raw" =~ ^0x[0-9A-Fa-f]+$ ]] || [[ "$raw" =~ ^[0-9A-Fa-f]{200,}$ ]]; then
        printf '%s' "$raw" | hex_to_text
        return
    fi

    printf '%s' "$raw"
}

get_private_key_pem_file() {
    # Reads PEM from Keychain and writes it to a temp file. Prints temp file path.
    # The caller is responsible for deleting the file.
    local key_content tmp
    key_content="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
    if [[ -z "$key_content" ]]; then
        log "Failed to read GitHub App private key from Keychain (account=$KEYCHAIN_ACCOUNT service=$KEYCHAIN_SERVICE)."
        log "Store it with: security add-generic-password -a \"$KEYCHAIN_ACCOUNT\" -s \"$KEYCHAIN_SERVICE\" -w \"<PEM_CONTENT>\" -U"
        exit 2
    fi

    # macOS mktemp -t treats its argument as a prefix (not a template), so avoid XXXXXX here.
    tmp="$(mktemp -t utm-actions-runner-key)"
    chmod 600 "$tmp"
    printf '%s' "$key_content" | decode_keychain_secret | normalize_pem >"$tmp"

    # Validate the key before using it, so we can give a clear error message.
    if ! openssl pkey -in "$tmp" -noout >/dev/null 2>&1; then
        log "Private key from Keychain could not be parsed as a PEM private key."
        log "account=$KEYCHAIN_ACCOUNT service=$KEYCHAIN_SERVICE"
        log "Tip: re-store the key with the exact PEM contents (including BEGIN/END lines)."
        rm -f "$tmp"
        exit 2
    fi
    printf '%s\n' "$tmp"
}

generate_jwt() {
    # Generates a GitHub App JWT (RS256) using the PEM file path provided.
    local pem_file="$1"
    local now iat exp header payload unsigned sig

    now="$(date +%s)"
    iat="$((now - 60))"
    exp="$((now + 540))" # 9 minutes

    header='{"alg":"RS256","typ":"JWT"}'
    payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID")"

    unsigned="$(
        printf '%s' "$header" | base64url
        printf '.'
        printf '%s' "$payload" | base64url
    )"

    sig="$(
        printf '%s' "$unsigned" \
            | openssl dgst -sha256 -sign "$pem_file" \
            | base64url
    )"

    printf '%s.%s\n' "$unsigned" "$sig"
}

github_api() {
    local method="$1"
    local path="$2"
    local token="${3:-}"

    local url="${GITHUB_API_URL}${path}"
    local -a headers
    headers+=(-H "Accept: application/vnd.github+json")
    headers+=(-H "X-GitHub-Api-Version: 2022-11-28")

    if [[ -n "$token" ]]; then
        headers+=(-H "Authorization: Bearer ${token}")
    fi

    if [[ "$method" == "GET" ]]; then
        curl -fsSL -X "$method" "${headers[@]}" "$url"
        return
    fi

    curl -fsSL -X "$method" "${headers[@]}" "$url"
}

get_installation_token() {
    local pem_file jwt token_json
    pem_file="$(get_private_key_pem_file)"

    # Always delete the temp PEM file, even if JWT generation or API calls fail.
    # Note: This script does not use any other traps, so clearing RETURN is safe here.
    trap 'rm -f "${pem_file:-}"' RETURN

    jwt="$(generate_jwt "$pem_file")"

    token_json="$(
        github_api POST "/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" "$jwt"
    )"

    printf '%s' "$token_json" | jq -r '.token'
}

get_runner_registration_token() {
    local installation_token token_json
    installation_token="$(get_installation_token)"

    if [[ "$GITHUB_RUNNER_SCOPE" == "organization" ]]; then
        require_env GITHUB_ORGANIZATION
        token_json="$(
            github_api POST "/orgs/${GITHUB_ORGANIZATION}/actions/runners/registration-token" "$installation_token"
        )"
        printf '%s' "$token_json" | jq -r '.token'
        return
    fi

    # Default: repository scope
    require_env GITHUB_ORGANIZATION
    require_env GITHUB_REPOSITORY_NAME
    token_json="$(
        github_api POST "/repos/${GITHUB_ORGANIZATION}/${GITHUB_REPOSITORY_NAME}/actions/runners/registration-token" "$installation_token"
    )"
    printf '%s' "$token_json" | jq -r '.token'
}

get_runner_url() {
    if [[ "$GITHUB_RUNNER_SCOPE" == "organization" ]]; then
        require_env GITHUB_ORGANIZATION
        printf 'https://github.com/%s\n' "$GITHUB_ORGANIZATION"
        return
    fi

    require_env GITHUB_ORGANIZATION
    require_env GITHUB_REPOSITORY_NAME
    printf 'https://github.com/%s/%s\n' "$GITHUB_ORGANIZATION" "$GITHUB_REPOSITORY_NAME"
}

write_startup_script() {
    local token="$1"
    local runner_url="$2"
    local unique_id="$3"

    mkdir -p "$SHARED_DIRECTORY"
    cp "$START_SCRIPT_NAME" "$SHARED_DIRECTORY"

    local target="$SHARED_DIRECTORY/$START_SCRIPT_NAME"
    sed -i '' "s|GITHUB_URL|$runner_url|g" "$target"
    sed -i '' "s/TOKEN/$token/g" "$target"
    sed -i '' "s/UUID/$unique_id/g" "$target"
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
    require_cmd utmctl
    require_cmd curl
    require_cmd openssl
    require_cmd jq
    require_cmd security

    require_env GITHUB_APP_ID
    require_env GITHUB_APP_INSTALLATION_ID

    # Generate a fresh runner registration token and embed it in the startup script for this VM.
    log "Generating fresh runner registration token..."
    TOKEN="$(get_runner_registration_token)"
    if [[ -z "${TOKEN:-}" || "$TOKEN" == "null" ]]; then
        log "Failed to generate runner registration token. Retrying in 10 seconds..."
        sleep 10
        continue
    fi
    RUNNER_URL="$(get_runner_url)"
    if [[ -z "${RUNNER_URL:-}" ]]; then
        log "Failed to determine runner URL. Retrying in 10 seconds..."
        sleep 10
        continue
    fi
    UNIQUE_ID=$(date '+%Y-%m-%d-%H-%M-%S')
    write_startup_script "$TOKEN" "$RUNNER_URL" "$UNIQUE_ID"
    log "Startup script written with fresh token for $RUNNER_URL (runner id: $UNIQUE_ID)"

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
