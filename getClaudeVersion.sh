#!/bin/bash

# --- Config ---
REPO_DIR="/home/zed/github/ClaudeVersions-repo"
GITHUB_URL="https://github.com/zed1291/ClaudeVersions.git"
GITHUB_USER="zed1291"
GITHUB_REPO="ClaudeVersions"
SSH_KEY="/home/zed/.claude/github_claude_ed25519"
LOG_FILE="$(dirname "$0")/claude_update.log"

# Use SSH key from local directory
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -F /dev/null -o StrictHostKeyChecking=no"

# Calculate script directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- Logging ---
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --- Fetch latest Claude version and download URL ---
RELEASES_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
releases_data=$(curl -fs "$RELEASES_URL")
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to fetch RELEASES.json"
    exit 1
fi

download_url=$(echo "$releases_data" | grep -o '"url":"[^"]*"' | cut -d'"' -f4 | sed 's/\.zip$/.pkg/')
latest_version=$(echo "$releases_data" | grep -o '"url":"[^"]*"' | cut -d'"' -f4 | grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | head -n1 | tr -d '/')
current_date=$(date +'%Y-%m-%d')

# --- Validate system date ---
# Check if today's date is older than any existing date in the JSON
validate_date() {
    local today="$1"
    local json_file="$2"
    
    # If JSON doesn't exist yet, skip validation
    if [ ! -f "$json_file" ]; then
        return 0
    fi
    
    # Get all dates from the JSON file
    local existing_dates
    existing_dates=$(python3 -c "
import json, sys
try:
    data = json.load(open('$json_file'))
    dates = []
    for key, value in data.items():
        if isinstance(value, dict) and 'date' in value:
            dates.append(value['date'])
    print('\n'.join(dates))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
    
    if [ -z "$existing_dates" ]; then
        return 0
    fi
    
    # Compare today with each existing date
    # Convert dates to comparable integers (YYYYMMDD format)
    today_int=$(echo "$today" | tr -d '-')
    
    while IFS= read -r existing_date; do
        if [ -n "$existing_date" ]; then
            existing_int=$(echo "$existing_date" | tr -d '-')
            if [ "$today_int" -lt "$existing_int" ]; then
                log_message "ERROR: System date ($today) is older than existing date ($existing_date) in JSON. Check system clock!"
                return 1
            fi
        fi
    done <<< "$existing_dates"
    
    return 0
}

validate_date "$current_date" "$LOCAL_JSON"
if [ $? -ne 0 ]; then
    log_message "ERROR: Invalid system date detected. Aborting update."
    exit 1
fi

# --- Local JSON (Source of Truth) ---
LOCAL_JSON="$SCRIPT_DIR/claude_versions.json"

# Initialize local JSON if it does not exist
if [ ! -f "$LOCAL_JSON" ]; then
    echo '{"latest": {"version": "", "url": "", "date": ""}}' > "$LOCAL_JSON"
    log_message "Initialized local JSON: $LOCAL_JSON"
fi

# --- Check if version has changed ---
current_latest_version=$(python3 -c "import json; print(json.load(open('$LOCAL_JSON'))['latest']['version'])" 2>/dev/null)

# Only update if version is different or JSON doesn't exist
if [ "$current_latest_version" != "$latest_version" ]; then
    log_message "New version detected: $latest_version (was: $current_latest_version)"
    use_date="$current_date"
else
    # Keep existing date - version hasn't changed
    use_date=$(python3 -c "import json; print(json.load(open('$LOCAL_JSON'))['latest']['date'])" 2>/dev/null)
    log_message "Version unchanged: $latest_version, preserving date: $use_date"
fi

# --- Function to update JSON ---
update_json() {
    local file=$1
    local version=$2
    local url=$3
    local date=$4

    export UPDATE_JSON_FILE="$file"
    export UPDATE_JSON_VERSION="$version"
    export UPDATE_JSON_URL="$url"
    export UPDATE_JSON_DATE="$date"

    python3 << 'PYEOF'
import json
import os

with open(os.environ['UPDATE_JSON_FILE'], 'r') as f:
    data = json.load(f)

data['latest'] = {
    'version': os.environ['UPDATE_JSON_VERSION'],
    'url': os.environ['UPDATE_JSON_URL'],
    'date': os.environ['UPDATE_JSON_DATE']
}

data[os.environ['UPDATE_JSON_VERSION']] = {
    'url': os.environ['UPDATE_JSON_URL'],
    'date': os.environ['UPDATE_JSON_DATE']
}

if 'versions' in data:
    del data['versions']

with open(os.environ['UPDATE_JSON_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

    unset UPDATE_JSON_FILE UPDATE_JSON_VERSION UPDATE_JSON_URL UPDATE_JSON_DATE
}

update_json "$LOCAL_JSON" "$latest_version" "$download_url" "$use_date"
log_message "Updated local JSON with version $latest_version"

# --- GitHub Sync ---
log_message "Starting GitHub sync"

# Set up the repo directory
if [ ! -d "$REPO_DIR/.git" ]; then
    log_message "Cloning repository for the first time..."
    git clone git@github.com:$GITHUB_USER/$GITHUB_REPO.git "$REPO_DIR"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to clone repository"
        exit 1
    fi
    log_message "Repository cloned successfully"
fi

cd "$REPO_DIR" || exit 1

# Pull latest changes
if ! git pull origin main; then
    log_message "ERROR: Git pull failed"
    exit 1
fi



# Copy files to repo
cp "$LOCAL_JSON" ./claude_versions.json
cp "$SCRIPT_DIR/getClaudeVersion.sh" ./getClaudeVersion.sh

# Check if anything changed
if git diff --quiet claude_versions.json getClaudeVersion.sh; then
    log_message "No changes in JSON or script. Skipping commit."
    exit 0
fi

log_message "Changes detected. Committing to GitHub..."

# Commit and push
git add claude_versions.json getClaudeVersion.sh
if ! git commit -m "Automated: Update Claude versions and script ($current_date)"; then
    log_message "ERROR: Git commit failed"
    exit 1
fi
git push origin main

log_message "SUCCESS: Pushed to GitHub"
log_message "Update complete."
echo "Update complete."
