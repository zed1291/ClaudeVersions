#!/bin/bash

# --- Config ---
REPO_DIR="$HOME/github/ClaudeVersions"
GITHUB_URL="https://github.com/zed1291/ClaudeVersions.git"
GITHUB_USER="zed1291"
GITHUB_REPO="ClaudeVersions"
SSH_KEY="$HOME/.claude/github_claude_ed25519"
LOG_FILE="$(dirname "$0")/claude_update.log"

# Use SSH key from local directory
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -F /dev/null -o StrictHostKeyChecking=no"

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

# --- Local JSON (Source of Truth) ---
LOCAL_JSON="$(dirname "$0")/claude_versions.json"

# Initialize local JSON if it does not exist
if [ ! -f "$LOCAL_JSON" ]; then
    echo '{"latest": {"version": "", "url": "", "date": ""}}' > "$LOCAL_JSON"
    log_message "Initialized local JSON: $LOCAL_JSON"
fi

# --- Function to update JSON ---
update_json() {
    local file=$1
    local version=$2
    local url=$3
    local date=$4

    # Use python3 for reliable JSON manipulation
    python3 -c "
import json
with open('$file', 'r') as f:
    data = json.load(f)

# Update latest
data['latest'] = {'version': '$version', 'url': '$url', 'date': '$date'}

# Add/update version entry directly at root level
data['$version'] = {'url': '$url', 'date': '$date'}

# Remove 'versions' key if it exists
if 'versions' in data:
    del data['versions']

with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
}

update_json "$LOCAL_JSON" "$latest_version" "$download_url" "$current_date"
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
    log_message "WARNING: Git pull failed"
fi

# Get absolute path to script directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Check if source files exist
if [ ! -f "$LOCAL_JSON" ]; then
    log_message "ERROR: Local JSON file not found: $LOCAL_JSON"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/getClaudeVersion.sh" ]; then
    log_message "ERROR: Local script file not found"
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
git commit -m "Automated: Update Claude versions and script ($current_date)"
git push origin main

log_message "SUCCESS: Pushed to GitHub"
log_message "Update complete."
echo "Update complete."
