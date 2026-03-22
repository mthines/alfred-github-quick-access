# GitHub Quick Access for Alfred

A powerful Alfred workflow for navigating GitHub at the speed of thought. Fuzzy-search your repos, open pull requests, browse actions, dispatch workflows — all from your keyboard.

## Features

- **Fuzzy repo search** — Type `gh my` to find repos matching "my" (e.g., `my-app`, `my-api`, `my-docs`)
- **Quick navigation** — Jump to any repo's PRs, issues, actions, wiki, branches, tags, releases, or settings
- **Actions deep-dive** — Browse a repo's GitHub Actions workflows and filter them
- **Workflow dispatch** — Trigger `workflow_dispatch` workflows on any branch directly from Alfred
- **Smart commands** — Quick access to your PRs, issues, notifications, gists, profile, and stars
- **Caching** — Repos and workflows are cached for 7 days for instant results
- **Tab completion** — When multiple repos match, Tab drills into the selected repo
- **Repo preferences** — Alfred remembers which repo you prefer for ambiguous filters

## Requirements

- [Alfred 5](https://www.alfredapp.com/) with Powerpack
- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- [`jq`](https://jqlang.github.io/jq/) installed (`brew install jq`)

## Installation

1. Download the latest `.alfredworkflow` file from [Releases](https://github.com/mthines/alfred-github-quick-access/releases)
2. Double-click to install in Alfred
3. Optionally set your GitHub username in the workflow configuration (auto-detected from `gh` if left empty)

## Usage

### Basic Commands

| Command | Action |
|---|---|
| `gh` | Show all commands and repos |
| `gh pr` | Open your GitHub pull requests |
| `gh pr me` | Open PRs created by you |
| `gh pr review` | Open PRs requesting your review |
| `gh issues` | Open your GitHub issues |
| `gh notif` | Open notifications |
| `gh gists` | Open your gists |
| `gh profile` | Open your GitHub profile |
| `gh stars` | Open your starred repos |
| `gh refresh` | Clear all caches and re-fetch |

### Repo Navigation

| Command | Action |
|---|---|
| `gh <filter>` | Fuzzy search repos, Enter opens in browser |
| `gh <filter> pr` | Open the repo's Pull Requests tab |
| `gh <filter> pr me` | Open the repo's PRs filtered by you |
| `gh <filter> issues` | Open the repo's Issues tab |
| `gh <filter> a` | Browse the repo's GitHub Actions workflows |

**Supported subcommands:** `pr`, `issues`, `a`/`act`/`actions`, `wiki`, `settings`, `b`/`branches`, `t`/`tags`, `releases`, `projects`, `security`, `insights`

### Modifier Keys on Repos

| Modifier | Action |
|---|---|
| **Enter** | Open repo in browser |
| **Cmd+Enter** | Open repo's issues |
| **Alt+Enter** | Open repo's pull requests |
| **Ctrl+Enter** | Copy SSH clone URL to clipboard |

### Actions Mode

Actions mode lets you browse and dispatch GitHub Actions workflows:

| Command | Action |
|---|---|
| `gh my-app act` | List repos matching "my-app" — **Tab** to drill into workflows |
| `gh my-app act dep` | Filter workflows by "dep" (e.g., "Deploy") |
| `gh my-app act dep feat/login` | Dispatch the Deploy workflow on branch `feat/login` |

**How it works:**

1. `gh <repo-filter> act` — Shows matching repos. Press **Tab** on the one you want to browse its workflows. Press **Enter** to set it as your preferred repo for this filter and open its `/actions` page.
2. `gh <repo-filter> act <workflow-filter>` — Uses your preferred repo (or top match) and filters its workflows.
3. `gh <repo-filter> act <workflow-filter> <branch>` — If the workflow filter matches exactly one workflow and the last word doesn't match any workflow, it becomes a branch name for dispatch.

### How Filtering Works

The workflow uses substring matching — all words in your query must appear somewhere in the repo name, owner, or description. Examples:

- `gh my` → matches "my-app", "my-api", "my-docs", etc.
- `gh my ap` → matches "my-app" and "my-api" (both "my" and "ap" match)
- `gh react nat` → matches "react-native-app" (both words are substrings)

## Caching

- **Repos** are cached for 7 days, refreshed in the background
- **Workflows** are cached per-repo for 7 days, fetched on demand when you enter actions mode
- **Username** is auto-detected from `gh` CLI and cached
- Use `gh refresh` to clear everything and re-fetch

## Extending

Add new quick commands by editing `commands.json` in the workflow directory. Each entry needs:

```json
{
  "uid": "gh-your-command",
  "title": "Command Title",
  "subtitle": "Description shown in Alfred",
  "arg": "https://github.com/your-url",
  "match": "keywords for fuzzy matching"
}
```

Use `{username}` in `arg` to reference the configured GitHub username.

## How It Works

```
Alfred → gh_workflow.sh (Script Filter) → action.sh (Router) → Open URL / Dispatch / Copy
```

- `gh_workflow.sh` — Main script filter. Parses the query, loads cached data, and outputs Alfred JSON.
- `action.sh` — Handles special actions: refresh cache, copy to clipboard, dispatch workflow, save repo preferences.
- `commands.json` — Extensible quick commands (PRs, issues, notifications, etc.).
- Caches live in `~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.github.quick-access/`.

## License

MIT
