#!/bin/bash

# Handles special actions before opening URLs
# Routes based on the "action" variable set by the script filter

action="${action:-}"
query="$1"

GH_BIN=$(command -v gh 2>/dev/null || echo "/opt/homebrew/bin/gh")
JQ_BIN=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")
CACHE_DIR="${alfred_workflow_cache:-${HOME}/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.github.quick-access}"

case "$action" in
    refresh)
        rm -f "$CACHE_DIR/repos.json"
        rm -f "$CACHE_DIR/username"
        rm -rf "$CACHE_DIR/workflows"
        ;;
    copy)
        printf '%s' "$query" | pbcopy
        ;;
    dispatch)
        # Parse JSON payload: {"repo": "owner/name", "workflow": "file.yaml", "ref": "branch"}
        repo=$(printf '%s' "$query" | "$JQ_BIN" -r '.repo')
        workflow=$(printf '%s' "$query" | "$JQ_BIN" -r '.workflow')
        ref=$(printf '%s' "$query" | "$JQ_BIN" -r '.ref')
        "$GH_BIN" workflow run "$workflow" --repo "$repo" --ref "$ref" >/dev/null 2>&1
        ;;
    open_log)
        # Open the debug log in the default text viewer
        open -t "$query" 2>/dev/null || open "$query" 2>/dev/null
        ;;
    select_repo)
        # Save repo preference for this filter key, then pass URL through
        PREFS_FILE="$CACHE_DIR/repo_preferences.json"
        fk="${filter_key:-}"
        sr="${selected_repo:-}"
        if [ -n "$fk" ] && [ -n "$sr" ]; then
            if [ -f "$PREFS_FILE" ]; then
                "$JQ_BIN" --arg k "$fk" --arg v "$sr" '.[$k] = $v' "$PREFS_FILE" > "$PREFS_FILE.tmp" && mv "$PREFS_FILE.tmp" "$PREFS_FILE"
            else
                printf '{}' | "$JQ_BIN" --arg k "$fk" --arg v "$sr" '.[$k] = $v' > "$PREFS_FILE"
            fi
        fi
        # Pass URL through to Open URL
        printf '%s' "$query"
        ;;
    *)
        # Default: pass through to Open URL
        printf '%s' "$query"
        ;;
esac
