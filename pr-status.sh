#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

section() {
  printf "\n${BOLD}━━━ %s ━━━${RESET}\n" "$1"
}

# ── Detect PR ──
pr_arg="${1:-}"

if [[ -n "$pr_arg" ]]; then
  # Check if it's a URL
  if [[ "$pr_arg" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    pr_number="${BASH_REMATCH[3]}"
  else
    pr_number="$pr_arg"
    owner=$(gh repo view --json owner -q '.owner.login')
    repo=$(gh repo view --json name -q '.name')
  fi
else
  pr_number=$(gh pr view --json number -q '.number')
  owner=$(gh repo view --json owner -q '.owner.login')
  repo=$(gh repo view --json name -q '.name')
fi

# ── Fetch all data via GraphQL ──
query='query {
  repository(owner: "'"$owner"'", name: "'"$repo"'") {
    pullRequest(number: '"$pr_number"') {
      title
      url
      state
      mergeable
      mergeStateStatus
      reviewDecision
      baseRefName
      headRefName
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(last: 100) {
                nodes {
                  ... on CheckRun {
                    __typename
                    name
                    conclusion
                    status
                    detailsUrl
                  }
                  ... on StatusContext {
                    __typename
                    context
                    state
                    targetUrl
                  }
                }
              }
            }
          }
        }
      }
      reviewRequests(last: 20) {
        nodes {
          requestedReviewer {
            ... on Team { name slug }
            ... on User { login }
          }
        }
      }
      latestReviews(last: 50) {
        nodes {
          state
          author { login }
        }
      }
      comments(last: 30) {
        nodes {
          author { login __typename }
          body
          url
          createdAt
        }
      }
      reviewThreads(last: 50) {
        nodes {
          isResolved
          comments(first: 100) {
            nodes {
              author { login __typename }
              body
              url
              createdAt
              path
              line
            }
          }
        }
      }
    }
  }
}'

data=$(gh api graphql -f query="$query")

# Helper to extract fields from the JSON
jq_pr() {
  echo "$data" | jq -r ".data.repository.pullRequest$1"
}

# ── Header ──
title=$(jq_pr '.title')
url=$(jq_pr '.url')
head_ref=$(jq_pr '.headRefName')
base_ref=$(jq_pr '.baseRefName')
mergeable=$(jq_pr '.mergeable')
merge_state=$(jq_pr '.mergeStateStatus')
review_decision=$(jq_pr '.reviewDecision')

printf "\n${DIM}%s${RESET}\n" "$title"
printf "${DIM}%s → %s${RESET}\n" "$head_ref" "$base_ref"
printf "Github: ${DIM}%s${RESET}\n" "$url"

# Jira link from branch name
if [[ "$head_ref" =~ ^([A-Z]+-[0-9]+) ]]; then
  printf "Jira: ${DIM}https://miro.atlassian.net/browse/%s${RESET}\n" "${BASH_REMATCH[1]}"
fi

# ── CI/CD ──
section "CI/CD"

checks_json=$(echo "$data" | jq '[.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | .[] ]')

failed_json=$(echo "$checks_json" | jq '[.[] | select(
  (.__typename == "CheckRun" and (.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED")) or
  (.__typename == "StatusContext" and (.state == "FAILURE" or .state == "ERROR"))
)]')

pending_count=$(echo "$checks_json" | jq '[.[] | select(
  (.__typename == "CheckRun" and (.status == "IN_PROGRESS" or .status == "QUEUED")) or
  (.__typename == "StatusContext" and .state == "PENDING")
)] | length')

failed_count=$(echo "$failed_json" | jq 'length')

if [[ "$failed_count" -eq 0 ]]; then
  if [[ "$pending_count" -gt 0 ]]; then
    printf "✅ No failures ${DIM}(%s still running)${RESET}\n" "$pending_count"
  else
    printf "✅ CI/CD is fine\n"
  fi
else
  printf "${RED}%s failed:${RESET}\n" "$failed_count"
  echo "$failed_json" | jq -r '.[] | select(.name != "Test E2E / E2E results") | "\(.name // .context)\t\(.detailsUrl // .targetUrl)"' | while IFS=$'\t' read -r name url; do
    printf "  ${RED}✗${RESET} %s\n" "$name"
    printf "    ${DIM}%s${RESET}\n" "$url"
  done
  if [[ "$pending_count" -gt 0 ]]; then
    printf "${YELLOW}  + %s still running${RESET}\n" "$pending_count"
  fi
fi

# ── Comments ──
section "Comments"

issue_comments=$(echo "$data" | jq '[.data.repository.pullRequest.comments.nodes // [] | .[] | select(.author.__typename != "Bot" and ((.author.login // "") | test("\\[bot\\]$") | not)) | {
  author: (.author.login // "unknown"),
  body: .body,
  url: .url,
  createdAt: .createdAt,
  type: "comment"
}]')

review_threads=$(echo "$data" | jq '[.data.repository.pullRequest.reviewThreads.nodes // [] | .[] | select(.comments.nodes | length > 0) | select([.comments.nodes[] | select(.author.__typename != "Bot" and ((.author.login // "") | test("\\[bot\\]$") | not))] | length > 0) | {
  comments: [.comments.nodes[] | select(.author.__typename != "Bot" and ((.author.login // "") | test("\\[bot\\]$") | not)) | {
    author: (.author.login // "unknown"),
    body: .body,
    url: .url,
    createdAt: .createdAt
  }],
  path: .comments.nodes[0].path,
  line: .comments.nodes[0].line,
  resolved: .isResolved
}] | sort_by(.comments[0].createdAt)')

issue_count=$(echo "$issue_comments" | jq 'length')
thread_comment_count=$(echo "$review_threads" | jq '[.[].comments | length] | add // 0')
total_comments=$((issue_count + thread_comment_count))

if [[ "$issue_count" -eq 0 ]] && [[ $(echo "$review_threads" | jq 'length') -eq 0 ]]; then
  printf "${DIM}No comments${RESET}\n"
else
  printf "%s total comment(s):\n" "$total_comments"

  # Issue comments
  echo "$issue_comments" | jq -r '.[] | "\(.author)\t\(.createdAt)\t\(.body)\t\(.url)"' | while IFS=$'\t' read -r author created body comment_url; do
    date_fmt=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%b %d, %I:%M %p" 2>/dev/null || echo "$created")
    preview=$(echo "$body" | head -1 | cut -c1-100)
    suffix=""
    [[ ${#body} -gt 100 ]] && suffix="…"
    printf "  ${CYAN}@%s${RESET} ${DIM}%s${RESET}\n" "$author" "$date_fmt"
    printf "    %s%s\n" "$preview" "$suffix"
    printf "    ${DIM}%s${RESET}\n" "$comment_url"
  done

  # Review threads
  thread_count=$(echo "$review_threads" | jq 'length')
  for i in $(seq 0 $((thread_count - 1))); do
    thread=$(echo "$review_threads" | jq ".[$i]")
    resolved=$(echo "$thread" | jq -r '.resolved')
    path=$(echo "$thread" | jq -r '.path // empty')
    line=$(echo "$thread" | jq -r '.line // empty')
    comment_count=$(echo "$thread" | jq '.comments | length')
    reply_count=$((comment_count - 1))

    if [[ "$reply_count" -eq 1 ]]; then
      reply_word="reply"
    else
      reply_word="replies"
    fi

    location=""
    if [[ -n "$path" ]]; then
      location="${DIM}${path}"
      [[ -n "$line" ]] && location="${location}:${line}"
      location="${location}${RESET} "
    fi

    first=$(echo "$thread" | jq '.comments[0]')
    first_author=$(echo "$first" | jq -r '.author')
    first_created=$(echo "$first" | jq -r '.createdAt')
    first_body=$(echo "$first" | jq -r '.body')
    first_url=$(echo "$first" | jq -r '.url')
    first_date=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_created" "+%b %d, %I:%M %p" 2>/dev/null || echo "$first_created")
    first_preview=$(echo "$first_body" | head -1 | cut -c1-100)
    first_suffix=""
    [[ ${#first_body} -gt 100 ]] && first_suffix="…"

    if [[ "$resolved" == "true" ]]; then
      printf " ✅ ${CYAN}@%s${RESET} ${DIM}%s${RESET} ${DIM} %s %s${RESET}\n" "$first_author" "$first_date" "$reply_count" "$reply_word"
      printf "    %b%s%s\n" "$location" "$first_preview" "$first_suffix"
      printf "    ${DIM}%s${RESET}\n" "$first_url"
    else
      printf "  ${YELLOW}●${RESET} ${CYAN}@%s${RESET} ${DIM}%s${RESET} ${DIM}☐ %s %s${RESET}\n" "$first_author" "$first_date" "$reply_count" "$reply_word"
      printf "    %b%s%s\n" "$location" "$first_preview" "$first_suffix"

      # Show replies for unresolved threads
      for j in $(seq 1 $((comment_count - 1))); do
        c=$(echo "$thread" | jq ".comments[$j]")
        c_author=$(echo "$c" | jq -r '.author')
        c_created=$(echo "$c" | jq -r '.createdAt')
        c_body=$(echo "$c" | jq -r '.body')
        c_date=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$c_created" "+%b %d, %I:%M %p" 2>/dev/null || echo "$c_created")
        c_preview=$(echo "$c_body" | head -1 | cut -c1-100)
        c_suffix=""
        [[ ${#c_body} -gt 100 ]] && c_suffix="…"
        printf "    ↳ ${CYAN}@%s${RESET} ${DIM}%s${RESET}\n" "$c_author" "$c_date"
        printf "      %s%s\n" "$c_preview" "$c_suffix"
      done
      printf "  ${DIM}%s${RESET}\n" "$first_url"
    fi
  done
fi

# ── Merge Status ──
section "Merge Status"

reasons=()

# Conflicts
if [[ "$mergeable" == "CONFLICTING" ]]; then
  reasons+=("$(printf "${RED}✗ Has merge conflicts with %s${RESET}" "$base_ref")")
elif [[ "$mergeable" == "UNKNOWN" ]]; then
  reasons+=("$(printf "${YELLOW}? Merge conflict status unknown (still calculating)${RESET}")")
fi

# Reviews
if [[ "$review_decision" == "REVIEW_REQUIRED" ]]; then
  pending_reviewers=$(echo "$data" | jq -r '[.data.repository.pullRequest.reviewRequests.nodes[] | .requestedReviewer | if .slug then "team/\(.slug)" elif .login then .login else empty end] | join(", ")')
  msg=$(printf "${RED}✗ Review required${RESET}")
  if [[ -n "$pending_reviewers" ]]; then
    msg=$(printf "%s\n    Waiting on: ${YELLOW}%s${RESET}" "$msg" "$pending_reviewers")
  fi
  reasons+=("$msg")
elif [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
  changes_from=$(echo "$data" | jq -r '[.data.repository.pullRequest.latestReviews.nodes[] | select(.state == "CHANGES_REQUESTED") | .author.login // "unknown"] | join(", ")')
  reasons+=("$(printf "${RED}✗ Changes requested by: %s${RESET}" "$changes_from")")
fi

# CI failures
if [[ "$failed_count" -gt 0 ]]; then
  reasons+=("$(printf "${RED}✗ %s CI check(s) failed${RESET}" "$failed_count")")
fi

# Behind
if [[ "$merge_state" == "BEHIND" ]]; then
  reasons+=("$(printf "${YELLOW}⚠ Branch is behind %s — needs rebase/merge${RESET}" "$base_ref")")
fi

# Overall
if [[ ${#reasons[@]} -eq 0 ]] && [[ "$merge_state" == "CLEAN" ]]; then
  printf "${GREEN}✅ Ready to merge${RESET}\n"
elif [[ ${#reasons[@]} -eq 0 ]] && [[ "$merge_state" == "UNSTABLE" ]]; then
  printf "${YELLOW}⚠ Unstable — some non-required checks failed but can merge${RESET}\n"
elif [[ ${#reasons[@]} -eq 0 ]]; then
  printf "${YELLOW}Status: %s${RESET}\n" "$merge_state"
else
  printf "${RED}Cannot merge:${RESET}\n"
  for r in "${reasons[@]}"; do
    printf "  %b\n" "$r"
  done
fi

# ── Conflicts detail ──
if [[ "$mergeable" == "CONFLICTING" ]]; then
  section "Conflicts"
  printf "${RED}This PR has conflicts with %s.${RESET}\n" "$base_ref"
  printf "${DIM}Rebase or merge %s into your branch to resolve.${RESET}\n" "$base_ref"
fi
