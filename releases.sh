#!/usr/bin/env bash
set -euo pipefail

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: not in a GitHub repository or 'gh' not available" >&2
    exit 1
}
REPO_NAME="${REPO#*/}"
CACHE_FILE="$HOME/.releases_cache_${REPO_NAME}.txt"

run() {
    "$@" 2>/dev/null || true
}

load_cache() {
    # Populates associative arrays CACHE_BUILD and CACHE_MSG keyed by hash
    declare -gA CACHE_BUILD CACHE_MSG
    [[ -f "$CACHE_FILE" ]] || return 0
    while IFS='|' read -r hash build msg; do
        [[ -n "$hash" ]] || continue
        CACHE_BUILD["$hash"]="$build"
        CACHE_MSG["$hash"]="$msg"
    done < "$CACHE_FILE"
}

releases() {
    local new_entries
    new_entries=$(mktemp /tmp/releases_new_XXXXXX.txt)

    run git fetch --tags --quiet

    load_cache

    local releases_json
    releases_json=$(run gh release list --repo "$REPO" --limit 10 --json tagName,publishedAt)
    [[ -n "$releases_json" ]] || releases_json="[]"

    local -a tags=()
    declare -A tag_dates

    while IFS=$'\t' read -r tag_name published_at; do
        [[ -n "$tag_name" ]] || continue
        tags+=("$tag_name")
        # Format date: "12 Mar 2026, 14:30"
        if date --version &>/dev/null; then
            # GNU date
            tag_dates["$tag_name"]=$(date -d "$published_at" '+%d %b %Y, %H:%M' 2>/dev/null || echo "$published_at")
        else
            # macOS date
            tag_dates["$tag_name"]=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$published_at" '+%d %b %Y, %H:%M' 2>/dev/null || \
                                     date -jf '%Y-%m-%dT%T%z' "$published_at" '+%d %b %Y, %H:%M' 2>/dev/null || \
                                     echo "$published_at")
        fi
    done < <(echo "$releases_json" | jq -r '.[] | [.tagName, .publishedAt] | @tsv')

    local prev=""
    for tag in "${tags[@]}"; do
        if [[ -n "$prev" ]]; then
            echo "$prev  ${tag_dates[$prev]:-}"

            local log_output
            log_output=$(run git log --format="%h %s" "${tag}..${prev}")
            if [[ -n "$log_output" ]]; then
                while IFS= read -r line; do
                    local hash="${line%% *}"
                    local rest="${line#* }"
                    # Strip trailing PR references like " (#1234)"
                    rest=$(echo "$rest" | sed 's/ (#[0-9]*)$//')

                    if [[ -n "${CACHE_MSG[$hash]+x}" ]]; then
                        local build_prefix=""
                        [[ -n "${CACHE_BUILD[$hash]}" ]] && build_prefix="${CACHE_BUILD[$hash]} "
                        echo "  $hash ${build_prefix}${CACHE_MSG[$hash]}"
                    else
                        local build
                        build=$(run git tag --points-at "$hash" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

                        local build_prefix=""
                        [[ -n "$build" ]] && build_prefix="$build "
                        echo "  $hash ${build_prefix}${rest}"
                        echo "${hash}|${build}|${rest}" >> "$new_entries"
                    fi
                done <<< "$log_output"
            fi
            echo ""
        fi
        prev="$tag"
    done

    if [[ -n "$prev" ]]; then
        echo "$prev  ${tag_dates[$prev]:-}"
        echo "  (oldest in range — no prior release to diff)"
    fi

    # Append new entries to cache
    if [[ -s "$new_entries" ]]; then
        cat "$new_entries" >> "$CACHE_FILE"
    fi
    rm -f "$new_entries"
}

releases
