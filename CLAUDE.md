# GitHub Quick Access - Alfred Workflow

## Overview
An Alfred workflow triggered by keyword `gh` that provides quick access to GitHub repositories, pull requests, issues, actions workflows, and more. Uses the `gh` CLI for authentication and API access.

## Architecture

```
gh_workflow.sh     - Main script filter entry point (Bash + embedded Python)
commands.json      - Static command definitions (PRs, issues, etc.) — extensible
action.sh          - Action router (refresh, copy, dispatch, select_repo, open_log)
info.plist         - Alfred workflow configuration
icon.png           - Workflow icon
refresh_cache.sh   - Standalone cache refresh helper
```

### Data Flow
1. Alfred triggers `gh_workflow.sh` with the user query.
2. Script resolves binary paths (`gh`, `jq`) via `find_bin` helper which checks `command -v` then a list of common install paths (`/opt/homebrew/bin`, `/usr/local/bin`, etc.).
3. If the repos cache is missing or stale, a **background fetch** runs (uses `gh repo list` for personal + each org from `gh api user/orgs`). Errors and progress are logged to `$CACHE_DIR/debug.log`.
4. The embedded Python builds the Alfred JSON response from cached repos and `commands.json`.
5. Selected item is routed through `action.sh`, which either passes the URL through to the Open URL node or handles a special action (refresh, copy, dispatch, select_repo, open_log).

### Caches & Files
All under `~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.github.quick-access/`:
- `repos.json` — main repo list (7-day TTL)
- `username` — cached GitHub username
- `repo_preferences.json` — preferred repo per filter key (e.g., `"da": "dash0hq/dash0"`)
- `workflows/<owner>/<repo>.json` — workflow definitions (7-day TTL)
- `workflows/<owner>/<repo>.prs.json` — open PRs (5-min TTL)
- `debug.log` — diagnostic log from background fetches

## Query Modes

The Python parser detects modes in this order:

1. **Actions mode** — `<repo-filter> a|ac|act|actions [workflow-filter] [branch]`
2. **PR search mode** — `<repo-filter> pr|prs|pulls <query>` (skipped if remaining is just partial "me" to keep `pr me` compound fast)
3. **Standard mode** — falls through; supports compound subcommands (`pr me`, `issues me`) and single subcommands (`pr`, `issues`, `wiki`, etc.)

## Debug Logging

`gh_workflow.sh` writes to `$CACHE_DIR/debug.log` from the background fetch process. The `log_debug()` helper timestamps each line. Stderr from `gh` and `jq` is redirected to the same log via `2>>"$DEBUG_LOG"`.

When the repos cache is empty, the Python output includes diagnostic items:
- "Setup needed: no repositories cached" — runs a quick health check (`gh` exists, `gh auth status`) and surfaces the specific issue.
- "View debug log" — uses the `open_log` action to open the log in the user's text editor.
- "Refresh Repository Cache" — fallback option.

## How to Extend

### Adding a New Static Command
Edit `commands.json` (entries support `mods`, `variables`, `icon`, and `{username}` placeholders).

### Adding a New Action Type
1. Add a `case` in `action.sh`.
2. Set `variables.action` in the relevant Alfred item.

### Adding a Subcommand
Add to `REPO_SUBCOMMANDS` (single word → URL path) or `REPO_COMPOUND_SUBCOMMANDS` (two-word tuple → URL path) in the Python section.

### Modifier Keys on Repos
- Enter: Open repo
- Cmd+Enter: Open issues
- Alt+Enter: Open pull requests
- Ctrl+Enter: Copy SSH clone URL

## Dependencies
- `gh` CLI (auto-detected via `command -v` or common install paths)
- `jq` (auto-detected the same way)
- `python3` (system)
- Alfred 5 + Powerpack

## Troubleshooting

If no repos appear:
1. Check `$CACHE_DIR/debug.log` — the background fetch logs all errors there.
2. Common causes: `gh` not in PATH that Alfred sees; `gh` not authenticated; `jq` not installed.
3. Run `gh refresh` in Alfred (or delete `repos.json`) to retry.
4. Test from a terminal: `cd <workflow-dir> && ./gh_workflow.sh ""` — should output JSON with items.
