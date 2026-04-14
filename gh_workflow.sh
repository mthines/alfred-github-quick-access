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

# Find gh and jq binaries
GH_BIN=$(command -v gh 2>/dev/null || echo "/opt/homebrew/bin/gh")
JQ_BIN=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")

mkdir -p "$CACHE_DIR"

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
        # Fetch all accessible repos using gh repo list (covers personal + all orgs)
        "$GH_BIN" repo list --limit 500 --json nameWithOwner,name,description,url,isPrivate,owner,updatedAt 2>/dev/null > "$CACHE_FILE.tmp.personal"

        # Fetch org repos (gh repo list with viewer affiliations misses many org repos)
        orgs=$("$GH_BIN" api user/orgs --jq '.[].login' 2>/dev/null)
        for org in $orgs; do
            "$GH_BIN" repo list "$org" --limit 500 --json nameWithOwner,name,description,url,isPrivate,owner,updatedAt 2>/dev/null
        done > "$CACHE_FILE.tmp.orgs"

        # Merge and deduplicate by nameWithOwner
        "$JQ_BIN" -s 'add | unique_by(.nameWithOwner) | sort_by(.updatedAt) | reverse' "$CACHE_FILE.tmp.personal" "$CACHE_FILE.tmp.orgs" > "$CACHE_FILE.tmp" 2>/dev/null && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        rm -f "$CACHE_FILE.tmp.personal" "$CACHE_FILE.tmp.orgs"
    ) &
fi

# Build Alfred JSON output
python3 << 'PYTHON'
import json
import os
import subprocess
import time

cache_file = os.environ["CACHE_FILE"]
commands_file = os.environ["COMMANDS_FILE"]
workflow_dir = os.environ["WORKFLOW_DIR"]
workflows_dir = os.environ["WORKFLOWS_DIR"]
cache_ttl = int(os.environ.get("CACHE_TTL", "604800"))
raw_query = os.environ.get("query", "").strip()
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

        wf_matches = filter_workflows(workflows, wf_filter_words)

        if wf_matches:
            for wf in wf_matches:
                items.append(make_wf_item(wf, full_name, url))
        else:
            candidate_filter = wf_filter_words[:-1]
            branch_ref = after_actions[-1] if after_actions else None

            wf_matches2 = filter_workflows(workflows, candidate_filter) if candidate_filter else []

            if len(wf_matches2) == 1 and branch_ref:
                wf = wf_matches2[0]
                wf_name = wf.get("name", "")
                wf_path = wf.get("path", "")
                wf_file = os.path.basename(wf_path)
                items.append({
                    "uid": f"gh-dispatch-{full_name}-{wf['id']}-{branch_ref}",
                    "title": f"Run {wf_name} on {branch_ref}",
                    "subtitle": f"Dispatch {full_name} → {wf_file} (branch: {branch_ref})",
                    "arg": json.dumps({"repo": full_name, "workflow": wf_file, "ref": branch_ref}),
                    "icon": icon,
                    "variables": {"action": "dispatch"},
                })
                items.append(make_wf_item(wf, full_name, url))
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
        if i > 0 and p in PR_KEYWORDS:
            # Check there's a search query after "pr"
            # Skip if it looks like the user is typing "me" (compound subcommand)
            remaining = parts_lower[i + 1:]
            if remaining and len(remaining) == 1 and "me".startswith(remaining[0]):
                break  # partial "me" typing — let compound subcommand handle it
            if remaining:
                pr_idx = i
                pr_mode = True
            break

if pr_mode:
    repo_filter = parts_lower[:pr_idx]
    pr_query_words = [w.lower() for w in parts[pr_idx + 1:]]
    filter_key = " ".join(repo_filter)

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
    items.append({"title": "No results found", "subtitle": f"No matches for '{raw_query}'", "valid": False, "icon": icon})

output = {"items": items}
if not repos:
    output["rerun"] = 1.5

print(json.dumps(output))
PYTHON
