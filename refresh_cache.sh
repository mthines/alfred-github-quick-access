#!/bin/bash

# Force refresh the repository cache
CACHE_DIR="${alfred_workflow_cache:-${HOME}/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.mthines.github}"
CACHE_FILE="$CACHE_DIR/repos.json"

mkdir -p "$CACHE_DIR"

/opt/homebrew/bin/gh api graphql --paginate -f query='
query($endCursor: String) {
    viewer {
        repositories(first: 100, after: $endCursor, ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR], orderBy: {field: UPDATED_AT, direction: DESC}) {
            pageInfo { hasNextPage endCursor }
            nodes {
                nameWithOwner
                name
                description
                url
                isPrivate
                owner { login }
                updatedAt
            }
        }
    }
}' --jq '.data.viewer.repositories.nodes[]' 2>/dev/null | /opt/homebrew/bin/jq -s '.' > "$CACHE_FILE" 2>/dev/null

echo "Cache refreshed"
