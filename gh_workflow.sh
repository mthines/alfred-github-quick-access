#!/bin/bash

# GitHub Alfred Workflow
# Commands are loaded from commands.json - add new commands there
# Repositories are fetched from GitHub API and cached

WORKFLOW_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${alfred_workflow_cache:-${HOME}/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.github.quick-access}"
CACHE_FILE="$CACHE_DIR/repos.json"
COMMANDS_FILE="$WORKFLOW_DIR/commands.json"
CACHE_TTL=604800  # 1 week
USERNAME_FILE="$CACHE_DIR/username"
DEBUG_LOG="$CACHE_DIR/debug.log"

mkdir -p "$CACHE_DIR"

# Find gh and jq binaries — try PATH, then common install locations
find_bin() {
    local name="$1"
    local found
    found=$(command -v "$name" 2>/dev/null) && [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    for p in /opt/homebrew/bin /usr/local/bin /usr/bin /opt/local/bin "$HOME/.local/bin"; do
        if [ -x "$p/$name" ]; then
            printf '%s' "$p/$name"; return 0
        fi
    done
    printf '%s' "$name"  # last resort, will fail with clear error
    return 1
}

GH_BIN=$(find_bin gh)
JQ_BIN=$(find_bin jq)

# Logging helper for background fetch — captures errors so users can debug
log_debug() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DEBUG_LOG"
}

# Resolve GitHub username: user config > cached > gh api query
if [ -n "${github_username:-}" ]; then
    GH_USERNAME="$github_username"
    printf '%s' "$GH_USERNAME" > "$USERNAME_FILE"
elif [ -f "$USERNAME_FILE" ]; then
    GH_USERNAME=$(cat "$USERNAME_FILE")
else
    GH_USERNAME=$("$GH_BIN" api user --jq '.login' 2>/dev/null || echo "")
    if [ -n "$GH_USERNAME" ]; then
        printf '%s' "$GH_USERNAME" > "$USERNAME_FILE"
    fi
fi

query="$1"
WORKFLOWS_DIR="$CACHE_DIR/workflows"
mkdir -p "$WORKFLOWS_DIR"
export CACHE_FILE COMMANDS_FILE WORKFLOW_DIR WORKFLOWS_DIR CACHE_TTL query GH_BIN JQ_BIN GH_USERNAME

# Fetch repos if cache is missing or stale
needs_refresh=false
if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
    needs_refresh=true
else
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
    if [ "$cache_age" -gt "$CACHE_TTL" ]; then
        needs_refresh=true
    fi
fi

if [ "$needs_refresh" = true ]; then
    # Fetch in background so Alfred stays responsive
    (
        log_debug "Fetch started. GH_BIN=$GH_BIN JQ_BIN=$JQ_BIN PATH=$PATH"

        # Verify binaries exist before attempting fetches
        if [ ! -x "$GH_BIN" ] && ! command -v "$GH_BIN" >/dev/null 2>&1; then
            log_debug "ERROR: gh binary not found or not executable at: $GH_BIN"
            exit 1
        fi
        if [ ! -x "$JQ_BIN" ] && ! command -v "$JQ_BIN" >/dev/null 2>&1; then
            log_debug "ERROR: jq binary not found or not executable at: $JQ_BIN"
            exit 1
        fi

        # Verify gh is authenticated
        if ! "$GH_BIN" auth status >/dev/null 2>>"$DEBUG_LOG"; then
            log_debug "ERROR: gh is not authenticated. Run 'gh auth login' in a terminal."
            exit 1
        fi

        # Fetch all accessible repos using gh repo list (covers personal + all orgs)
        "$GH_BIN" repo list --limit 500 --json nameWithOwner,name,description,url,isPrivate,owner,updatedAt 2>>"$DEBUG_LOG" > "$CACHE_FILE.tmp.personal"
        personal_count=$("$JQ_BIN" 'length' "$CACHE_FILE.tmp.personal" 2>/dev/null || echo "?")
        log_debug "Personal repos fetched: $personal_count"

        # Fetch org repos (gh repo list with viewer affiliations misses many org repos)
        orgs=$("$GH_BIN" api user/orgs --jq '.[].login' 2>>"$DEBUG_LOG")
        log_debug "Orgs found: $(printf '%s' "$orgs" | tr '\n' ' ')"
        for org in $orgs; do
            "$GH_BIN" repo list "$org" --limit 500 --json nameWithOwner,name,description,url,isPrivate,owner,updatedAt 2>>"$DEBUG_LOG"
        done > "$CACHE_FILE.tmp.orgs"

        # Merge and deduplicate by nameWithOwner
        if "$JQ_BIN" -s 'add | unique_by(.nameWithOwner) | sort_by(.updatedAt) | reverse' "$CACHE_FILE.tmp.personal" "$CACHE_FILE.tmp.orgs" > "$CACHE_FILE.tmp" 2>>"$DEBUG_LOG"; then
            mv "$CACHE_FILE.tmp" "$CACHE_FILE"
            total_count=$("$JQ_BIN" 'length' "$CACHE_FILE" 2>/dev/null || echo "?")
            log_debug "Cache written: $total_count repos"
        else
            log_debug "ERROR: jq failed to merge results"
        fi
        rm -f "$CACHE_FILE.tmp.personal" "$CACHE_FILE.tmp.orgs"
    ) &
fi

# Build Alfred JSON output
python3 << 'PYTHON'
import json
import os
import re
import subprocess
import time

PR_URL_RE = re.compile(r'^https?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)')

cache_file = os.environ["CACHE_FILE"]
commands_file = os.environ["COMMANDS_FILE"]
workflow_dir = os.environ["WORKFLOW_DIR"]
workflows_dir = os.environ["WORKFLOWS_DIR"]
cache_ttl = int(os.environ.get("CACHE_TTL", "604800"))
_raw_query_env = os.environ.get("query", "")
trailing_space = _raw_query_env != _raw_query_env.rstrip()
raw_query = _raw_query_env.strip()
gh_bin = os.environ.get("GH_BIN", "gh")
gh_username = os.environ.get("GH_USERNAME", "")
icon = {"path": "icon.png"}

# --- Subcommand definitions ---

REPO_COMPOUND_SUBCOMMANDS = {}
if gh_username:
    REPO_COMPOUND_SUBCOMMANDS = {
        ("pr", "me"): f"/pulls/{gh_username}",
        ("prs", "me"): f"/pulls/{gh_username}",
        ("issues", "me"): f"/issues/created_by/{gh_username}",
    }

REPO_SUBCOMMANDS = {
    "pr": "/pulls",
    "prs": "/pulls",
    "pulls": "/pulls",
    "issues": "/issues",
    "a": "/actions",
    "ac": "/actions",
    "act": "/actions",
    "actions": "/actions",
    "wiki": "/wiki",
    "settings": "/settings",
    "b": "/branches",
    "branches": "/branches",
    "t": "/tags",
    "tags": "/tags",
    "releases": "/releases",
    "projects": "/projects",
    "security": "/security",
    "insights": "/pulse",
}

ACTIONS_KEYWORDS = {"a", "ac", "act", "actions"}
PR_KEYWORDS = {"pr", "prs", "pulls"}
PR_FILTER_KEYS = {"author", "label", "state"}
PR_STATE_VALUES = ["open", "closed", "merged", "all"]

# Human-readable display names for URL paths
PATH_DISPLAY = {
    "/pulls": "pull requests",
    "/issues": "issues",
    "/actions": "actions",
    "/wiki": "wiki",
    "/settings": "settings",
    "/branches": "branches",
    "/tags": "tags",
    "/releases": "releases",
    "/projects": "projects",
    "/security": "security",
    "/pulse": "insights",
}

# --- Helpers ---

def display_name(path):
    """Convert a URL path to a human-readable label."""
    # Exact match first
    if path in PATH_DISPLAY:
        return PATH_DISPLAY[path]
    # Compound paths with username → "X by me"
    for base_path, label in PATH_DISPLAY.items():
        if path.startswith(base_path + "/"):
            return f"{label} by me"
    return path.strip("/")

def fuzzy_match(query_words, text):
    text_lower = text.lower()
    return all(w in text_lower for w in query_words)

def load_json(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return [] if path.endswith(".json") else {}

def load_json_dict(path):
    try:
        with open(path, "r") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)

def repo_search_text(repo):
    name = repo.get("name", "")
    full_name = repo.get("nameWithOwner", "")
    owner = repo.get("owner", {}).get("login", "")
    description = repo.get("description", "") or ""
    return " ".join([name, full_name, owner, name.replace("-", " "), name.replace("_", " "), description])

def repo_match_score(repo, filter_words, prefs, filter_key):
    """Score a repo match. Lower = better. Preferred repo always wins."""
    full_name = repo.get("nameWithOwner", "").lower()
    name = repo.get("name", "").lower()
    query = " ".join(filter_words)

    if prefs.get(filter_key) == repo.get("nameWithOwner"):
        return -1
    if query == name or query == full_name:
        return 0
    if name.startswith(query) or full_name.endswith("/" + query):
        return 1
    return 2

def get_matching_repos(repos, filter_words, prefs=None, filter_key=""):
    if not filter_words:
        return repos
    query = " ".join(filter_words)
    exact = [r for r in repos if r.get("nameWithOwner", "").lower() == query]
    if exact:
        return exact
    matched = [r for r in repos if fuzzy_match(filter_words, repo_search_text(r))]
    if prefs:
        matched.sort(key=lambda r: repo_match_score(r, filter_words, prefs, filter_key))
    else:
        matched.sort(key=lambda r: repo_match_score(r, filter_words, {}, ""))
    return matched

def workflows_cache_path(owner, repo_name):
    d = os.path.join(workflows_dir, owner)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"{repo_name}.json")

def load_workflows(owner, repo_name):
    """Load cached workflows, fetch on-demand if missing/stale."""
    path = workflows_cache_path(owner, repo_name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        age = time.time() - os.path.getmtime(path)
        if age < cache_ttl:
            return load_json(path), False

    try:
        result = subprocess.run(
            [gh_bin, "api",
             f"repos/{owner}/{repo_name}/actions/workflows",
             "--jq", ".workflows"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            workflows = json.loads(result.stdout)
            save_json(path, workflows)
            return workflows, False
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass

    return load_json(path), True

def prs_cache_path(owner, repo_name):
    d = os.path.join(workflows_dir, owner)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"{repo_name}.prs.json")

def load_prs(owner, repo_name):
    """Load cached open PRs, fetch on-demand if missing/stale."""
    path = prs_cache_path(owner, repo_name)
    cache_ttl_prs = 300  # 5 min for PRs (change frequently)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        age = time.time() - os.path.getmtime(path)
        if age < cache_ttl_prs:
            return load_json(path), False

    try:
        result = subprocess.run(
            [gh_bin, "pr", "list", "--repo", f"{owner}/{repo_name}",
             "--state", "open", "--limit", "100",
             "--json", "number,title,author,headRefName,url,createdAt,isDraft"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            prs = json.loads(result.stdout)
            save_json(path, prs)
            return prs, False
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass

    return load_json(path), True

def labels_cache_path(owner, repo_name):
    d = os.path.join(workflows_dir, owner)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"{repo_name}.labels.json")

def load_labels(owner, repo_name):
    """Load cached labels, fetch on-demand if missing/stale."""
    path = labels_cache_path(owner, repo_name)
    cache_ttl_labels = 86400  # 1 day — labels change rarely
    if os.path.exists(path) and os.path.getsize(path) > 0:
        age = time.time() - os.path.getmtime(path)
        if age < cache_ttl_labels:
            return load_json(path), False

    try:
        result = subprocess.run(
            [gh_bin, "label", "list", "--repo", f"{owner}/{repo_name}",
             "--limit", "200", "--json", "name,color,description"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            labels = json.loads(result.stdout)
            save_json(path, labels)
            return labels, False
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass

    return load_json(path), True

def build_pr_filter_suggestions(key, partial, prefix_words, owner, repo_name, full_name, url):
    """Tab-completion items for PR filter values (author/label/state)."""
    items = []
    partial_lower = partial.lower()
    prefix_str = (" ".join(prefix_words) + " ") if prefix_words else ""

    if key == "author":
        prs, _ = load_prs(owner, repo_name)
        author_counts = {}
        for pr in prs:
            a = pr.get("author", {}).get("login", "")
            if a:
                author_counts[a] = author_counts.get(a, 0) + 1

        if gh_username and (not partial_lower or "me".startswith(partial_lower)):
            items.append({
                "uid": f"gh-pr-author-{full_name}-me",
                "title": "author:me",
                "subtitle": f"Your open PRs in {full_name} — Tab to apply, Enter to view",
                "autocomplete": f"{full_name} pr {prefix_str}author:me ",
                "arg": f"{url}/pulls?q=is%3Aopen+author%3A{gh_username}",
                "icon": icon,
            })

        for name, count in sorted(author_counts.items(), key=lambda x: (-x[1], x[0])):
            if partial_lower and partial_lower not in name.lower():
                continue
            plural = "s" if count != 1 else ""
            items.append({
                "uid": f"gh-pr-author-{full_name}-{name}",
                "title": f"author:{name}",
                "subtitle": f"{count} open PR{plural} in {full_name} — Tab to apply, Enter to view",
                "autocomplete": f"{full_name} pr {prefix_str}author:{name} ",
                "arg": f"{url}/pulls?q=is%3Aopen+author%3A{name}",
                "icon": icon,
            })

    elif key == "state":
        for state in PR_STATE_VALUES:
            if partial_lower and not state.startswith(partial_lower):
                continue
            search_q = "is%3Apr" if state == "all" else f"is%3Apr+is%3A{state}"
            items.append({
                "uid": f"gh-pr-state-{full_name}-{state}",
                "title": f"state:{state}",
                "subtitle": f"Filter PRs by state — Tab to apply, Enter to view",
                "autocomplete": f"{full_name} pr {prefix_str}state:{state} ",
                "arg": f"{url}/pulls?q={search_q}",
                "icon": icon,
            })

    elif key == "label":
        labels, _ = load_labels(owner, repo_name)
        for lab in sorted(labels, key=lambda x: x.get("name", "").lower()):
            name = lab.get("name", "")
            if not name or " " in name:
                # Skip labels with spaces — they break space-separated query parsing.
                continue
            if partial_lower and partial_lower not in name.lower():
                continue
            desc = (lab.get("description") or "").strip()
            subtitle = desc if desc else "Filter PRs by label"
            items.append({
                "uid": f"gh-pr-label-{full_name}-{name}",
                "title": f"label:{name}",
                "subtitle": f"{subtitle[:100]} — Tab to apply, Enter to view",
                "autocomplete": f"{full_name} pr {prefix_str}label:{name} ",
                "arg": f"{url}/pulls?q=is%3Aopen+label%3A{name}",
                "icon": icon,
            })

    if not items:
        literal = f"{key}:{partial}" if partial else f"{key}:"
        items.append({
            "title": f"No {key}s matching '{partial}'" if partial else f"No {key}s available",
            "subtitle": f"in {full_name} — Enter to search GitHub directly",
            "autocomplete": f"{full_name} pr {prefix_str}{literal}",
            "arg": f"{url}/pulls?q=is%3Aopen+{key}%3A{partial}",
            "icon": icon,
        })

    return items

def filter_workflows(workflows, filter_words):
    matches = []
    for wf in workflows:
        if wf.get("state") != "active":
            continue
        wf_name = wf.get("name", "")
        wf_path = wf.get("path", "")
        wf_search = f"{wf_name} {wf_path} {wf_name.replace('-', ' ').replace('_', ' ')}"
        if fuzzy_match(filter_words, wf_search):
            matches.append(wf)
    return matches

def make_wf_item(wf, full_name, url):
    """Build a workflow Alfred item with Tab autocomplete for dispatch."""
    wf_name = wf.get("name", "")
    wf_path = wf.get("path", "")
    wf_file = os.path.basename(wf_path)
    return {
        "uid": f"gh-wf-{full_name}-{wf['id']}",
        "title": wf_name,
        "subtitle": f"{full_name} → {wf_path} (Tab + branch to dispatch)",
        "arg": f"{url}/actions/workflows/{wf_file}",
        "autocomplete": f"{full_name} act {wf_name} ",
        "icon": icon,
    }

def make_dispatch_item(wf, full_name, branch_ref):
    """Build an Alfred item that dispatches a workflow on the given branch/PR."""
    wf_name = wf.get("name", "")
    wf_path = wf.get("path", "")
    wf_file = os.path.basename(wf_path)

    pr_match = PR_URL_RE.match(branch_ref)
    if pr_match:
        pr_owner, pr_repo, pr_num = pr_match.groups()
        title = f"Run {wf_name} on PR #{pr_num} ({pr_owner}/{pr_repo})"
        subtitle = f"Dispatch {full_name} → {wf_file} (PR head branch resolved at run time)"
    else:
        title = f"Run {wf_name} on {branch_ref}"
        subtitle = f"Dispatch {full_name} → {wf_file} (branch: {branch_ref})"

    return {
        # Stable uid (no branch_ref) so Alfred can learn dispatch frequency
        # across branches and rank it above the plain wf browse item.
        "uid": f"gh-dispatch-{full_name}-{wf['id']}",
        "title": title,
        "subtitle": subtitle,
        "arg": json.dumps({"repo": full_name, "workflow": wf_file, "ref": branch_ref}),
        "icon": icon,
        "variables": {"action": "dispatch"},
    }

def wf_item_no_uid(wf, full_name, url):
    """Variant of make_wf_item without a uid — used when emitted alongside a
    dispatch item so Alfred's knowledge-based sorting does not reorder it
    above the dispatch (the dispatch is the primary intent when a branch is
    passed)."""
    item = make_wf_item(wf, full_name, url)
    item.pop("uid", None)
    return item

# --- Dynamic commands ---

def build_commands():
    """Load commands.json and resolve {username} placeholders."""
    try:
        with open(commands_file, "r") as f:
            commands = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    for cmd in commands:
        if gh_username:
            for key in ("arg", "subtitle"):
                if key in cmd and "{username}" in cmd[key]:
                    cmd[key] = cmd[key].replace("{username}", gh_username)
        cmd.setdefault("icon", icon)
    return commands

# --- Preferences ---

prefs_file = os.path.join(os.path.dirname(cache_file), "repo_preferences.json")
prefs = load_json_dict(prefs_file)

# --- Parse query ---

parts = raw_query.split()
parts_lower = [p.lower() for p in parts]

# Detect actions mode: find an actions keyword in the parts
# Pattern: <repo-filter...> <actions-keyword> [workflow-filter...] [branch]
actions_mode = False
actions_idx = -1

for i, p in enumerate(parts_lower):
    if i > 0 and p in ACTIONS_KEYWORDS:
        actions_idx = i
        actions_mode = True
        break

if actions_mode:
    repo_filter = parts_lower[:actions_idx]
    after_actions = parts[actions_idx + 1:]  # preserve original case for branch
    wf_filter_words = [w.lower() for w in after_actions]
    filter_key = " ".join(repo_filter)

    repos = load_json(cache_file)
    matching = get_matching_repos(repos, repo_filter, prefs, filter_key)
    items = []

    if not matching:
        items.append({"title": "No repos found", "subtitle": f"No match for '{filter_key}'", "valid": False, "icon": icon})
    elif not wf_filter_words and len(matching) > 1:
        for repo in matching:
            name = repo.get("name", "")
            full_name = repo.get("nameWithOwner", "")
            url = repo.get("url", "")
            is_private = repo.get("isPrivate", False)
            lock = " [private]" if is_private else ""
            is_preferred = prefs.get(filter_key) == full_name

            items.append({
                "uid": f"gh-act-repo-{full_name}",
                "title": f"{'* ' if is_preferred else ''}{name}",
                "subtitle": f"{full_name}{lock} → Tab to browse workflows, Enter to select",
                "arg": f"{url}/actions",
                "autocomplete": f"{full_name} act ",
                "icon": icon,
                "variables": {
                    "action": "select_repo",
                    "filter_key": filter_key,
                    "selected_repo": full_name,
                },
            })
    elif not wf_filter_words:
        repo = matching[0]
        owner = repo["owner"]["login"]
        repo_name = repo["name"]
        full_name = repo["nameWithOwner"]
        url = repo["url"]

        workflows, fetch_failed = load_workflows(owner, repo_name)
        active_wfs = [wf for wf in workflows if wf.get("state") == "active"]

        if not active_wfs:
            items.append({
                "title": f"No workflows found in {full_name}",
                "subtitle": "This repo has no active GitHub Actions workflows",
                "arg": f"{url}/actions",
                "icon": icon,
            })
        else:
            for wf in active_wfs:
                items.append(make_wf_item(wf, full_name, url))

        if fetch_failed:
            items.append({"title": "Using stale workflow cache", "subtitle": "Failed to refresh — showing cached data", "valid": False, "icon": icon})
    else:
        preferred = prefs.get(filter_key)
        repo = None
        if preferred:
            repo = next((r for r in matching if r["nameWithOwner"] == preferred), None)
        if not repo:
            repo = matching[0]

        owner = repo["owner"]["login"]
        repo_name = repo["name"]
        full_name = repo["nameWithOwner"]
        url = repo["url"]

        workflows, fetch_failed = load_workflows(owner, repo_name)

        # Detect an explicit branch-looking last argument (contains '/' or is a
        # PR URL). When present, ALWAYS strip it out and treat it as a branch
        # ref — never let it leak into the workflow filter. This guarantees the
        # dispatch action is the first item even when the workflow filter is
        # ambiguous (e.g. matches multiple workflows).
        last_arg = after_actions[-1] if after_actions else ""
        explicit_branch = (
            last_arg if last_arg and ("/" in last_arg or PR_URL_RE.match(last_arg))
            else None
        )

        if explicit_branch:
            branch_ref = explicit_branch
            wf_filter_remaining = wf_filter_words[:-1]
            wf_matches = (
                filter_workflows(workflows, wf_filter_remaining) if wf_filter_remaining
                else [w for w in workflows if w.get("state") == "active"]
            )

            if wf_matches:
                # Dispatch items first (one per matching workflow), then the
                # plain workflow open-in-browser items below — emitted without
                # uids so Alfred's knowledge-based sort can't bump them above
                # the dispatch items.
                for wf in wf_matches:
                    items.append(make_dispatch_item(wf, full_name, branch_ref))
                for wf in wf_matches:
                    items.append(wf_item_no_uid(wf, full_name, url))
            else:
                items.append({"title": "No workflows found", "subtitle": f"No match for '{' '.join(wf_filter_remaining)}' in {full_name}", "valid": False, "icon": icon})
        else:
            wf_matches = filter_workflows(workflows, wf_filter_words)

            if wf_matches:
                for wf in wf_matches:
                    items.append(make_wf_item(wf, full_name, url))
            else:
                # Fallback: treat last arg as a branch when the full filter
                # yields nothing (covers branch names without '/' like "main").
                candidate_filter = wf_filter_words[:-1]
                branch_ref = after_actions[-1] if after_actions else None

                wf_matches2 = filter_workflows(workflows, candidate_filter) if candidate_filter else []

                if len(wf_matches2) == 1 and branch_ref:
                    wf = wf_matches2[0]
                    items.append(make_dispatch_item(wf, full_name, branch_ref))
                    items.append(wf_item_no_uid(wf, full_name, url))
                elif wf_matches2:
                    for wf in wf_matches2:
                        items.append(make_wf_item(wf, full_name, url))
                else:
                    items.append({"title": "No workflows found", "subtitle": f"No match for '{' '.join(wf_filter_words)}' in {full_name}", "valid": False, "icon": icon})

        if fetch_failed:
            items.append({"title": "Using stale workflow cache", "subtitle": "Failed to refresh — showing cached data", "valid": False, "icon": icon})

    output = {"items": items}
    print(json.dumps(output))
    raise SystemExit(0)

# --- PR search mode ---
# Pattern: <repo-filter...> <pr-keyword> <search-query...>
# Only enters this mode if there are words AFTER the pr keyword
# (otherwise falls through to standard subcommand mode)

pr_mode = False
pr_idx = -1

if not actions_mode:
    for i, p in enumerate(parts_lower):
        if p in PR_KEYWORDS:
            remaining = parts_lower[i + 1:]
            # With a repo prefix, "pr me" is the compound subcommand → bail so
            # standard mode can resolve /pulls/<username>. Without a repo there
            # is no compound path, so let cross-repo search handle "pr me".
            if i > 0 and remaining and len(remaining) == 1 and "me".startswith(remaining[0]):
                break
            if remaining:
                pr_idx = i
                pr_mode = True
            break

if pr_mode:
    repo_filter = parts_lower[:pr_idx]
    pr_query_words = [w.lower() for w in parts[pr_idx + 1:]]
    # Normalize "#1234" → "1234" so PR-number lookup works with or without the prefix.
    pr_query_words = [
        w[1:] if w.startswith("#") and len(w) > 1 and w[1:].isdigit() else w
        for w in pr_query_words
    ]
    filter_key = " ".join(repo_filter)

    # Cross-repo PR search (no repo prefix) — use GitHub search API to find
    # PRs across every accessible repo. The repo-scoped path below relies on
    # the cached open-PR list, which we can't use without a specific repo.
    if not repo_filter:
        items = []

        cross_filters = {}
        text_words = []
        for w in pr_query_words:
            if ":" in w:
                key, _, val = w.partition(":")
                if key in ("author", "label", "state") and val:
                    cross_filters[key] = val
                    continue
            text_words.append(w)

        query_str = " ".join(text_words)
        is_branch_path = len(text_words) == 1 and "/" in text_words[0]
        is_me_shortcut = text_words == ["me"] and bool(gh_username)
        has_substantive_query = (
            bool(cross_filters)
            or is_branch_path
            or is_me_shortcut
            or len(query_str) >= 3
        )

        if not has_substantive_query:
            items.append({
                "title": "Keep typing to search PRs across all repos",
                "subtitle": "e.g. gh pr fix/my-branch · gh pr #1234 · gh pr <title-words>",
                "valid": False,
                "icon": icon,
            })
        else:
            # "me" as the sole text token → my open PRs across all repos
            if not cross_filters and text_words == ["me"] and gh_username:
                cmd = [gh_bin, "search", "prs",
                       "--author", gh_username, "--state", "open", "--limit", "30",
                       "--json", "number,title,author,repository,url,state,isDraft,createdAt"]
            else:
                cmd = [gh_bin, "search", "prs",
                       "--limit", "30",
                       "--json", "number,title,author,repository,url,state,isDraft,createdAt"]
                if is_branch_path:
                    cmd.extend(["--head", text_words[0]])
                elif text_words:
                    cmd.append(query_str)

                author = cross_filters.get("author")
                if author == "me" and gh_username:
                    author = gh_username
                if author:
                    cmd.extend(["--author", author])
                if cross_filters.get("label"):
                    cmd.extend(["--label", cross_filters["label"]])
                state = cross_filters.get("state")
                if state and state != "all":
                    cmd.extend(["--state", state])

            cross_failed = False
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                cross_prs = json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else []
            except (subprocess.TimeoutExpired, json.JSONDecodeError):
                cross_prs = []
                cross_failed = True

            if cross_prs:
                for pr in cross_prs:
                    pr_num = pr.get("number", 0)
                    pr_title = pr.get("title", "")
                    pr_author = pr.get("author", {}).get("login", "")
                    repo_full = pr.get("repository", {}).get("nameWithOwner", "")
                    pr_url = pr.get("url", "")
                    is_draft = pr.get("isDraft", False)
                    pr_state = pr.get("state", "open")
                    draft_label = " [draft]" if is_draft else ""
                    state_label = f" [{pr_state}]" if pr_state != "open" else ""
                    items.append({
                        "uid": f"gh-pr-{repo_full}-{pr_num}",
                        "title": f"{repo_full}#{pr_num}{draft_label}{state_label} — {pr_title}",
                        "subtitle": f"by {pr_author}",
                        "arg": pr_url,
                        "icon": icon,
                        "text": {"copy": pr_url, "largetype": f"{repo_full}#{pr_num} {pr_title}"},
                    })
            else:
                encoded = "+".join(pr_query_words) if pr_query_words else ""
                items.append({
                    "title": f"No PRs matching '{' '.join(pr_query_words)}'",
                    "subtitle": "Enter to search on GitHub directly",
                    "arg": f"https://github.com/search?type=pullrequests&q={encoded}",
                    "icon": icon,
                })

            if cross_failed:
                items.append({"title": "Search failed", "subtitle": "Check network or gh auth", "valid": False, "icon": icon})

        output = {"items": items}
        print(json.dumps(output))
        raise SystemExit(0)

    repos = load_json(cache_file)
    matching = get_matching_repos(repos, repo_filter, prefs, filter_key)
    items = []

    if not matching:
        items.append({"title": "No repos found", "subtitle": f"No match for '{filter_key}'", "valid": False, "icon": icon})
    else:
        # Use preferred repo or top match
        preferred = prefs.get(filter_key)
        repo = None
        if preferred:
            repo = next((r for r in matching if r["nameWithOwner"] == preferred), None)
        if not repo:
            repo = matching[0]

        owner = repo["owner"]["login"]
        repo_name = repo["name"]
        full_name = repo["nameWithOwner"]
        url = repo["url"]

        # Filter value autocomplete: when the last query word is "<key>:<partial>"
        # without a trailing space in the raw query, suggest matching values for
        # that filter so the user can Tab to complete. Trailing space → user has
        # moved past the filter, run the search.
        last_word = pr_query_words[-1] if pr_query_words else ""
        if pr_query_words and not trailing_space and ":" in last_word:
            fkey, _, partial = last_word.partition(":")
            if fkey in PR_FILTER_KEYS:
                prefix_words = pr_query_words[:-1]
                items = build_pr_filter_suggestions(
                    fkey, partial, prefix_words, owner, repo_name, full_name, url
                )
                output = {"items": items}
                print(json.dumps(output))
                raise SystemExit(0)

        # Parse key:value filters (author:, label:, state:) from query
        pr_filters = {}
        text_query = []
        for w in pr_query_words:
            if ":" in w:
                key, _, val = w.partition(":")
                if key in ("author", "label", "state") and val:
                    pr_filters[key] = val
                    continue
            text_query.append(w)

        # If filters are present, fetch PRs with those filters directly
        fetch_failed = False
        if pr_filters:
            cmd = [gh_bin, "pr", "list", "--repo", full_name,
                   "--limit", "100",
                   "--json", "number,title,author,headRefName,url,createdAt,isDraft,state,labels"]
            author_filter = pr_filters.get("author", "")
            if author_filter == "me" and gh_username:
                author_filter = gh_username
            if author_filter:
                cmd.extend(["--author", author_filter])
            if "label" in pr_filters:
                cmd.extend(["--label", pr_filters["label"]])
            state = pr_filters.get("state", "open")
            cmd.extend(["--state", state])

            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                prs = json.loads(result.stdout) if result.returncode == 0 else []
            except (subprocess.TimeoutExpired, json.JSONDecodeError):
                prs = []
                fetch_failed = True
        else:
            prs, fetch_failed = load_prs(owner, repo_name)

        # Filter PRs by text query words
        filtered_prs = []
        for pr in prs:
            pr_title = pr.get("title", "")
            pr_branch = pr.get("headRefName", "")
            pr_author = pr.get("author", {}).get("login", "")
            pr_num = str(pr.get("number", ""))
            search_text = f"{pr_title} {pr_branch} {pr_author} {pr_num} {pr_title.replace('-', ' ').replace('_', ' ')}"
            if not text_query or fuzzy_match(text_query, search_text):
                filtered_prs.append(pr)

        # If query is a PR number and not in cache, fetch it directly
        query_str = " ".join(pr_query_words)
        if not filtered_prs and query_str.isdigit():
            try:
                result = subprocess.run(
                    [gh_bin, "pr", "view", query_str, "--repo", full_name,
                     "--json", "number,title,author,headRefName,url,state,isDraft"],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode == 0 and result.stdout.strip():
                    filtered_prs = [json.loads(result.stdout)]
            except (subprocess.TimeoutExpired, json.JSONDecodeError):
                pass

        # If still no matches and the query is a single non-digit word with no
        # key:value filters, try resolving it as a branch name via --head.
        # Catches closed/merged PRs and PRs outside the open-PR cache (limit 100).
        if (not filtered_prs and not pr_filters
                and len(pr_query_words) == 1 and not pr_query_words[0].isdigit()):
            branch = pr_query_words[0]
            try:
                result = subprocess.run(
                    [gh_bin, "pr", "list", "--repo", full_name,
                     "--head", branch, "--state", "all", "--limit", "10",
                     "--json", "number,title,author,headRefName,url,createdAt,isDraft,state"],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode == 0 and result.stdout.strip():
                    branch_prs = json.loads(result.stdout)
                    branch_prs.sort(key=lambda p: p.get("createdAt", ""), reverse=True)
                    filtered_prs = branch_prs
            except (subprocess.TimeoutExpired, json.JSONDecodeError):
                pass

        if filtered_prs:
            for pr in filtered_prs:
                pr_title = pr.get("title", "")
                pr_num = pr.get("number", 0)
                pr_branch = pr.get("headRefName", "")
                pr_author = pr.get("author", {}).get("login", "")
                pr_url = pr.get("url", "")
                is_draft = pr.get("isDraft", False)
                pr_state = pr.get("state", "OPEN")
                draft_label = " [draft]" if is_draft else ""
                state_label = f" [{pr_state.lower()}]" if pr_state != "OPEN" else ""

                items.append({
                    "uid": f"gh-pr-{full_name}-{pr_num}",
                    "title": f"#{pr_num}{draft_label}{state_label} {pr_title}",
                    "subtitle": f"{full_name} ← {pr_branch} by {pr_author}",
                    "arg": pr_url,
                    "icon": icon,
                    "text": {"copy": pr_url, "largetype": f"#{pr_num} {pr_title}"},
                })
        else:
            items.append({
                "title": f"No PRs matching '{' '.join(pr_query_words)}'",
                "subtitle": f"in {full_name}",
                "arg": f"{url}/pulls?q=is%3Aopen+{'+'.join(pr_query_words)}",
                "icon": icon,
            })

        if fetch_failed:
            items.append({"title": "Using stale PR cache", "subtitle": "Failed to refresh — showing cached data", "valid": False, "icon": icon})

    output = {"items": items}
    print(json.dumps(output))
    raise SystemExit(0)

# --- Standard mode (non-actions) ---

parts_lower_std = parts_lower
subcommand = None
subcommand_path = ""
filter_words = parts_lower_std

# Check compound subcommands first
if len(parts_lower_std) >= 3 and tuple(parts_lower_std[-2:]) in REPO_COMPOUND_SUBCOMMANDS:
    subcommand = " ".join(parts_lower_std[-2:])
    subcommand_path = REPO_COMPOUND_SUBCOMMANDS[tuple(parts_lower_std[-2:])]
    filter_words = parts_lower_std[:-2]
elif len(parts_lower_std) >= 2 and parts_lower_std[-1] in REPO_SUBCOMMANDS:
    subcommand = parts_lower_std[-1]
    subcommand_path = REPO_SUBCOMMANDS[subcommand]
    filter_words = parts_lower_std[:-1]

items = []

# Commands from commands.json (only when no subcommand)
if not subcommand:
    commands = build_commands()
    for cmd in commands:
        match_text = cmd.get("match", "") + " " + cmd.get("title", "")
        if not filter_words or fuzzy_match(filter_words, match_text):
            items.append(cmd)

# Repos
repos = load_json(cache_file)

for repo in repos:
    name = repo.get("name", "")
    full_name = repo.get("nameWithOwner", "")
    description = repo.get("description", "") or ""
    url = repo.get("url", "")
    is_private = repo.get("isPrivate", False)
    owner = repo.get("owner", {}).get("login", "")

    search_text = repo_search_text(repo)
    if filter_words and not fuzzy_match(filter_words, search_text):
        continue

    lock = " [private]" if is_private else ""
    target_url = url + subcommand_path

    if subcommand:
        label = display_name(subcommand_path)
        title = f"{name} - {label}"
        subtitle = f"{full_name}{lock} → {label}"
    else:
        title = name
        subtitle = f"{full_name}{lock}"
        if description:
            subtitle += f" - {description}"

    # Tab autocomplete: use nameWithOwner for uniqueness, preserve subcommand
    if subcommand:
        ac = f"{full_name} {subcommand} "
    else:
        ac = f"{full_name} "

    items.append({
        "uid": f"gh-repo-{full_name}-{subcommand or 'home'}",
        "title": title,
        "subtitle": subtitle,
        "arg": target_url,
        "autocomplete": ac,
        "icon": icon,
        "text": {"copy": target_url, "largetype": full_name},
        "mods": {
            "cmd": {"subtitle": f"Open {full_name} issues", "arg": f"{url}/issues"},
            "alt": {"subtitle": f"Open {full_name} pull requests", "arg": f"{url}/pulls"},
            "ctrl": {"subtitle": f"Copy clone URL: git@github.com:{full_name}.git", "arg": f"git@github.com:{full_name}.git", "variables": {"action": "copy"}},
        },
    })

if not items:
    # Differentiate between "cache empty" (likely setup issue) and "real no match"
    if not repos:
        debug_log = os.path.join(os.path.dirname(cache_file), "debug.log")
        gh_bin_path = os.environ.get("GH_BIN", "gh")

        # Quick health check: does gh exist and is it authenticated?
        gh_exists = os.path.exists(gh_bin_path) or subprocess.run(
            ["which", gh_bin_path], capture_output=True
        ).returncode == 0

        diag_subtitle = "Repository cache is empty — fetch may still be running or failed"

        if not gh_exists:
            diag_subtitle = f"gh CLI not found at: {gh_bin_path}. Install: brew install gh"
        else:
            try:
                auth = subprocess.run([gh_bin_path, "auth", "status"],
                                      capture_output=True, text=True, timeout=5)
                if auth.returncode != 0:
                    diag_subtitle = "gh CLI is not authenticated. Run 'gh auth login' in a terminal."
            except Exception:
                pass

        items.append({
            "title": "Setup needed: no repositories cached",
            "subtitle": diag_subtitle,
            "arg": "https://github.com/mthines/alfred-github-quick-access#troubleshooting",
            "icon": icon,
        })

        if os.path.exists(debug_log):
            items.append({
                "title": "View debug log",
                "subtitle": f"Press Enter to open: {debug_log}",
                "arg": debug_log,
                "icon": icon,
                "variables": {"action": "open_log"},
            })

        items.append({
            "title": "Refresh Repository Cache",
            "subtitle": "Re-fetch repositories from GitHub",
            "arg": "REFRESH_CACHE",
            "icon": icon,
            "variables": {"action": "refresh"},
        })
    else:
        items.append({"title": "No results found", "subtitle": f"No matches for '{raw_query}'", "valid": False, "icon": icon})

output = {"items": items}
if not repos:
    output["rerun"] = 1.5

print(json.dumps(output))
PYTHON
