#!/usr/bin/env bash
set -euo pipefail

# Rebuild party branches from open Bitbucket PRs using Bash + jq.
# Mirrors the behavior of rebuild_party_branch.rb but avoids the Ruby runtime.
#
# Requirements:
#   - bash
#   - git
#   - curl
#   - jq
#
# Environment variables (same as Ruby script):
#   BITBUCKET_WORKSPACE
#   BITBUCKET_REPO_SLUG
#   BB_USERNAME
#   BB_APP_PASSWORD

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'Error: required command "%s" not found on PATH\n' "$name" >&2
    exit 1
  fi
}

shell() {
  # Fail-fast shell wrapper for commands that should abort the pipeline on error.
  local cmd="$*"
  printf '+ %s\n' "$cmd"
  if ! bash -o pipefail -c "$cmd"; then
    printf 'Command failed: %s\n' "$cmd" >&2
    exit 1
  fi
}

shell_allow_fail() {
  # Like shell(), but returns non-zero instead of exiting; caller handles failure.
  local cmd="$*"
  printf '+ %s\n' "$cmd"
  if ! bash -o pipefail -c "$cmd"; then
    return 1
  fi
}

bitbucket_api_get() {
  # Usage: bitbucket_api_get <url> <username> <app_password>
  local url="$1"
  local username="$2"
  local app_password="$3"

  # Capture body and HTTP status separately.
  local response http_code body
  response=$(curl -sS -u "${username}:${app_password}" -w '\n%{http_code}' --fail-with-body "$url") || {
    printf 'Failed to call Bitbucket API at %s\n' "$url" >&2
    exit 1
  }

  http_code=${response##*$'\n'}
  body=${response%$'\n'$http_code}

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    printf 'Bitbucket API error %s: %s\n' "$http_code" "$body" >&2
    exit 1
  fi

  printf '%s\n' "$body"
}

fetch_open_prs() {
  # Usage: fetch_open_prs <workspace> <repo_slug> <username> <app_password>
  local workspace="$1"
  local repo_slug="$2"
  local username="$3"
  local app_password="$4"

  # The Ruby script uses URI.encode_www_form_component on 'state="OPEN"', which yields:
  #   state%3D%22OPEN%22
  local encoded_q='state%3D%22OPEN%22'
  local url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests?q=${encoded_q}"

  local all_prs='[]'

  while [[ -n "$url" ]]; do
    local page_json values_json
    page_json=$(bitbucket_api_get "$url" "$username" "$app_password")

    # Extract this page's values as an array.
    values_json=$(jq -c '.values // []' <<<"$page_json")

    # Accumulate arrays without passing large JSON blobs as single arguments.
    all_prs=$(
      jq -sc 'add' \
        <(printf '%s\n' "$all_prs") \
        <(printf '%s\n' "$values_json")
    )

    # Follow pagination.
    url=$(jq -r '.next // empty' <<<"$page_json")
  done

  printf '%s\n' "$all_prs"
}

unique_words() {
  # Deduplicate a whitespace-separated list of words, preserving first-seen order.
  local -A seen=()
  local out=()
  local word
  for word in "$@"; do
    [[ -z "$word" ]] && continue
    if [[ -z "${seen[$word]+x}" ]]; then
      seen[$word]=1
      out+=("$word")
    fi
  done
  printf '%s\n' "${out[*]}"
}

party_branch_name_for_base() {
  local base_branch="$1"
  printf 'party/%s\n' "$base_branch"
}

main() {
  require_cmd git
  require_cmd curl
  require_cmd jq

  local workspace repo_slug username app_password
  workspace=${BITBUCKET_WORKSPACE:?"BITBUCKET_WORKSPACE is required"}
  repo_slug=${BITBUCKET_REPO_SLUG:?"BITBUCKET_REPO_SLUG is required"}
  username=${BB_USERNAME:?"BB_USERNAME is required"}
  app_password=${BB_APP_PASSWORD:?"BB_APP_PASSWORD is required"}

  printf 'Workspace:    %s\n' "$workspace"
  printf 'Repo slug:    %s\n' "$repo_slug"

  # Prevent infinite loops: Do not run this script if we are already on a party branch.
  # This script pushes to party branches, which would trigger the pipeline again.
  if [[ "${BITBUCKET_BRANCH:-}" == party/* ]]; then
    printf 'Skipping rebuild because we are already on a party branch: %s\n' "$BITBUCKET_BRANCH"
    exit 0
  fi

  local prs_json
  prs_json=$(fetch_open_prs "$workspace" "$repo_slug" "$username" "$app_password")

  # No open PRs at all.
  if [[ "$prs_json" == '[]' ]]; then
    printf 'No open PRs; nothing to do.\n'
    exit 0
  fi

  # All PR IDs (unfiltered), for logging.
  local -a all_pr_ids=()
  mapfile -t all_pr_ids < <(jq -r '.[].id' <<<"$prs_json")

  if ((${#all_pr_ids[@]} == 0)); then
    printf 'No open PRs; nothing to do.\n'
    exit 0
  fi

  printf 'Found %d open PR(s): %s\n' "${#all_pr_ids[@]}" "${all_pr_ids[*]}"

  # Filter to PRs with valid source and destination branches.
  local -a pr_records=()
  mapfile -t pr_records < <(
    jq -r '.[] | select(.destination.branch.name and .source.branch.name) | "\(.id)\t\(.destination.branch.name)\t\(.source.branch.name)"' <<<"$prs_json"
  )

  if ((${#pr_records[@]} == 0)); then
    printf 'No PRs with valid source/destination branches; nothing to do.\n'
    exit 0
  fi

  # Group by base branch and track mapping from source branch -> PR id.
  declare -A base_to_srcs=()
  declare -A base_to_pr_ids=()
  declare -A branch_to_pr_id=()

  local record pr_id dest_branch src_branch
  for record in "${pr_records[@]}"; do
    IFS=$'\t' read -r pr_id dest_branch src_branch <<<"$record"

    base_to_srcs["$dest_branch"]+=" $src_branch"
    base_to_pr_ids["$dest_branch"]+=" $pr_id"
    branch_to_pr_id["$src_branch"]="$pr_id"
  done

  if ((${#base_to_srcs[@]} == 0)); then
    printf 'No PRs with valid source/destination branches; nothing to do.\n'
    exit 0
  fi

  # Keys of base_to_srcs are the target base branches.
  local base_branch_name
  local -a target_bases=("${!base_to_srcs[@]}")
  printf 'Target base branches for party rebuild: %s\n' "${target_bases[*]}"

  # Fetch all branches once, same as Ruby script.
  shell "git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune"

  for base_branch_name in "${target_bases[@]}"; do
    if [[ "$base_branch_name" == party/* ]]; then
      printf 'Skipping base branch %s because it is already a party branch.\n' "$base_branch_name"
      continue
    fi
    local party_branch_name
    party_branch_name=$(party_branch_name_for_base "$base_branch_name")

    # Unique head branches and PR IDs for this base.
    local head_branches_raw pr_ids_raw
    local head_branches pr_ids_for_base

    head_branches_raw=${base_to_srcs["$base_branch_name"]}
    pr_ids_raw=${base_to_pr_ids["$base_branch_name"]}

    head_branches=$(unique_words $head_branches_raw)
    pr_ids_for_base=$(unique_words $pr_ids_raw)

    printf '%s\n' '--------------------------------------------------'
    printf 'Rebuilding party branch for base: %s\n' "$base_branch_name"
    printf '  Party branch: %s\n' "$party_branch_name"
    printf '  PRs: %s\n' "$pr_ids_for_base"
    printf '%s\n' '--------------------------------------------------'

    # Minimal debug: show working tree status before we wipe it.
    shell "git status --short || true"

    # Ensure a clean working tree for this base branch.
    shell 'git reset --hard'
    shell 'git clean -fd'

    # checkout/reset party branch from origin/<base>
    shell "git checkout -B '$party_branch_name' 'origin/$base_branch_name'"

    # Merge each head branch into the party branch, skipping conflicts.
    local -a conflicting_branches=()
    local head_branch merge_ref pr_id_for_branch label

    for head_branch in $head_branches; do
      merge_ref="origin/${head_branch}"
      pr_id_for_branch=${branch_to_pr_id["$head_branch"]:-}

      if [[ -n "$pr_id_for_branch" ]]; then
        label="PR #${pr_id_for_branch} (${merge_ref})"
      else
        label="$merge_ref"
      fi

      printf 'Merging %s into %s...\n' "$label" "$party_branch_name"

      if ! shell_allow_fail "git merge --no-ff --no-edit '$merge_ref'"; then
        printf 'Merge conflict when merging %s: see git output above.\n' "$label" >&2
        printf 'Skipping %s for this run due to conflict.\n' "$label" >&2
        # Do not blow up the whole pipeline; abort the merge and continue.
        git merge --abort || true
        conflicting_branches+=("$label")
      fi
    done

    if ((${#conflicting_branches[@]} > 0)); then
      printf '%s\n' '=================================================='
      printf 'WARNING: The following PR branches were SKIPPED\n'
      printf '         from %s due to merge conflicts:\n' "$party_branch_name"
      for label in "${conflicting_branches[@]}"; do
        printf '  - %s\n' "$label"
      done
      printf '%s\n' '=================================================='
    fi

    # Force push party branch for this base.
    shell "git push origin '$party_branch_name' --force"
  done
}

main "$@"
