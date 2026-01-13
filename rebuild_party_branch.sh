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

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

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

bitbucket_api_get_allow_fail() {
  # Usage: bitbucket_api_get_allow_fail <url> <username> <app_password>
  # Like bitbucket_api_get, but returns non-zero instead of exiting.
  local url="$1"
  local username="$2"
  local app_password="$3"

  local response http_code body
  response=$(curl -sS -u "${username}:${app_password}" -w '\n%{http_code}' "$url") || {
    printf 'Failed to call Bitbucket API at %s\n' "$url" >&2
    return 1
  }

  http_code=${response##*$'\n'}
  body=${response%$'\n'$http_code}

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    printf 'Bitbucket API error %s: %s\n' "$http_code" "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
}

bitbucket_api_request() {
  # Usage: bitbucket_api_request <method> <url> <username> <app_password> [json_body]
  local method="$1"
  local url="$2"
  local username="$3"
  local app_password="$4"
  local json_body="${5:-}"

  local -a curl_args=(
    -sS
    -u "${username}:${app_password}"
    -w $'\n%{http_code}'
    --fail-with-body
    -X "$method"
  )

  if [[ -n "$json_body" ]]; then
    curl_args+=(
      -H 'Content-Type: application/json'
      --data "$json_body"
    )
  fi

  local response http_code body
  response=$(curl "${curl_args[@]}" "$url") || {
    printf 'Failed to call Bitbucket API (%s) at %s\n' "$method" "$url" >&2
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

bitbucket_api_request_allow_fail() {
  # Usage: bitbucket_api_request_allow_fail <method> <url> <username> <app_password> [json_body]
  # Like bitbucket_api_request, but returns non-zero instead of exiting.
  local method="$1"
  local url="$2"
  local username="$3"
  local app_password="$4"
  local json_body="${5:-}"

  local -a curl_args=(
    -sS
    -u "${username}:${app_password}"
    -w $'\n%{http_code}'
    -X "$method"
  )

  if [[ -n "$json_body" ]]; then
    curl_args+=(
      -H 'Content-Type: application/json'
      --data "$json_body"
    )
  fi

  local response http_code body
  response=$(curl "${curl_args[@]}" "$url") || {
    printf 'Failed to call Bitbucket API (%s) at %s\n' "$method" "$url" >&2
    return 1
  }

  http_code=${response##*$'\n'}
  body=${response%$'\n'$http_code}

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    printf 'Bitbucket API error %s: %s\n' "$http_code" "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
}

fetch_pr_comments() {
  # Usage: fetch_pr_comments <workspace> <repo_slug> <pr_id> <username> <app_password>
  local workspace="$1"
  local repo_slug="$2"
  local pr_id="$3"
  local username="$4"
  local app_password="$5"

  local url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments"
  local all_comments='[]'

  while [[ -n "$url" ]]; do
    local page_json values_json
    page_json=$(bitbucket_api_get "$url" "$username" "$app_password")

    values_json=$(jq -c '.values // []' <<<"$page_json")
    all_comments=$(
      jq -sc 'add' \
        <(printf '%s\n' "$all_comments") \
        <(printf '%s\n' "$values_json")
    )

    url=$(jq -r '.next // empty' <<<"$page_json")
  done

  printf '%s\n' "$all_comments"
}

fetch_pr_comments_allow_fail() {
  # Usage: fetch_pr_comments_allow_fail <workspace> <repo_slug> <pr_id> <username> <app_password>
  # Like fetch_pr_comments, but returns non-zero instead of exiting.
  local workspace="$1"
  local repo_slug="$2"
  local pr_id="$3"
  local username="$4"
  local app_password="$5"

  local url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments"
  local all_comments='[]'

  while [[ -n "$url" ]]; do
    local page_json values_json
    page_json=$(bitbucket_api_get_allow_fail "$url" "$username" "$app_password") || return 1

    values_json=$(jq -c '.values // []' <<<"$page_json")
    all_comments=$(
      jq -sc 'add' \
        <(printf '%s\n' "$all_comments") \
        <(printf '%s\n' "$values_json")
    )

    url=$(jq -r '.next // empty' <<<"$page_json")
  done

  printf '%s\n' "$all_comments"
}

party_conflict_comment_marker() {
  printf '%s\n' '<!-- rebuild_party_branch:conflict -->'
}

party_conflict_resolved_marker() {
  printf '%s\n' '<!-- rebuild_party_branch:conflict-resolved -->'
}

find_party_active_conflict_comment_ids() {
  # Usage: find_party_active_conflict_comment_ids <comments_json>
  # Returns IDs for conflict comments that have NOT been marked resolved.
  local comments_json="$1"
  local marker resolved_marker
  marker=$(party_conflict_comment_marker)
  resolved_marker=$(party_conflict_resolved_marker)

  jq -r --arg marker "$marker" --arg resolved "$resolved_marker" \
    '.[] | select(.content.raw and (.content.raw | contains($marker)) and ((.content.raw | contains($resolved)) | not)) | .id' \
    <<<"$comments_json"
}

find_party_active_conflict_comment_id() {
  # Usage: find_party_active_conflict_comment_id <comments_json>
  local comments_json="$1"

  find_party_active_conflict_comment_ids "$comments_json" | head -n 1
}

strikeout_markdown_lines() {
  # Usage: strikeout_markdown_lines <raw_text>
  local raw_text="$1"

  local out='' line
  while IFS= read -r line; do
    # Do not strike out hidden marker lines.
    if [[ "$line" == '<!-- rebuild_party_branch:'* ]]; then
      continue
    fi

    if [[ -z "$line" ]]; then
      out+=$'\n'
      continue
    fi

    out+="~~${line}~~"$'\n'
  done <<<"$raw_text"

  printf '%s' "$out"
}

first_merge_conflict_snippet_for_file() {
  # Usage: first_merge_conflict_snippet_for_file <file_path> <max_lines>
  # Extracts the first conflict-marker block (<<<<<<< ... >>>>>>>) from the working tree file,
  # including a few context lines around it and prefixing lines with their line numbers.
  #
  # Tunables:
  #   REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_BEFORE (default: 3)
  #   REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_AFTER  (default: 3)
  local file_path="$1"
  local max_lines="$2"

  [[ -f "$file_path" ]] || return 0

  local before after
  before=${REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_BEFORE:-3}
  after=${REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_AFTER:-3}

  awk -v max="$max_lines" -v before="$before" -v after="$after" '
    function push(num, line) {
      # Keep only the last "before" lines.
      if (before <= 0) return
      if (q_size >= before) {
        for (i = 1; i < q_size; i++) { q_num[i] = q_num[i+1]; q_line[i] = q_line[i+1] }
        q_size--
      }
      q_size++
      q_num[q_size] = num
      q_line[q_size] = line
    }

    function print_line(num, line) {
      if (printed >= max) return
      printf "%6d|%s\n", num, line
      printed++
    }

    BEGIN {
      found = 0
      printed = 0
      q_size = 0
      after_left = -1
    }

    {
      if (found == 0) {
        if (index($0, "<<<<<<<") == 1) {
          found = 1
          # Print buffered context-before lines.
          for (i = 1; i <= q_size; i++) {
            print_line(q_num[i], q_line[i])
          }
          # Print the conflict start line.
          print_line(NR, $0)
          next
        }
        push(NR, $0)
        next
      }

      # We are in the conflict block (or immediately after it for context-after).
      print_line(NR, $0)

      if (after_left == -1 && index($0, ">>>>>>>") == 1) {
        after_left = after
        next
      }

      if (after_left >= 0) {
        after_left--
        if (after_left < 0) {
          exit
        }
      }

      if (printed >= max) {
        exit
      }
    }
  ' "$file_path"
}

auto_resolve_empty_side_conflict_markers() {
  # Usage: auto_resolve_empty_side_conflict_markers <file_path>
  # If ALL conflict blocks in the file are trivial (one side is blank/whitespace-only),
  # rewrite the file choosing the non-empty side for each block.
  # Returns 0 if it resolved; 1 if not applicable/unsafe.
  local file_path="$1"

  [[ -f "$file_path" ]] || return 1
  grep -q '^<<<<<<<' "$file_path" 2>/dev/null || return 1

  local tmp
  tmp="${file_path}.rebuild_party_branch_resolved.$$"

  if ! awk '
    function is_blank(s) {
      gsub(/[ \t\r\n]/, "", s)
      return length(s) == 0
    }

    BEGIN {
      in_conflict = 0
      side = 0
      ours = ""
      theirs = ""
    }

    /^<<<<<<</ {
      if (in_conflict) {
        exit 2
      }
      in_conflict = 1
      side = 2
      ours = ""
      theirs = ""
      next
    }

    in_conflict && /^=======$/ {
      side = 3
      next
    }

    in_conflict && /^>>>>>>>/ {
      if (is_blank(ours) && !is_blank(theirs)) {
        printf "%s", theirs
      } else if (!is_blank(ours) && is_blank(theirs)) {
        printf "%s", ours
      } else {
        exit 3
      }
      in_conflict = 0
      side = 0
      next
    }

    {
      if (!in_conflict) {
        print
        next
      }

      if (side == 2) {
        ours = ours $0 ORS
        next
      }

      if (side == 3) {
        theirs = theirs $0 ORS
        next
      }

      exit 4
    }

    END {
      if (in_conflict) {
        exit 5
      }
    }
  ' "$file_path" >"$tmp"; then
    rm -f "$tmp" || true
    return 1
  fi

  mv "$tmp" "$file_path"
  return 0
}

try_auto_resolve_trivial_merge_conflicts() {
  # Usage: try_auto_resolve_trivial_merge_conflicts
  # Attempts to resolve trivial conflict types without human input:
  # - Text conflicts where one side of EACH conflict block is blank/whitespace-only
  # - Delete/modify-ish cases where only one side (ours/theirs) exists in the index
  # Returns 0 if it resolved ALL current conflicts and completed the merge commit.
  local conflict_files
  conflict_files=$(git --no-pager diff --name-only --diff-filter=U 2>/dev/null || true)
  [[ -n "$conflict_files" ]] || return 1

  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    # 1) Inline conflict markers: choose the non-empty side, but only if every block is trivial.
    if auto_resolve_empty_side_conflict_markers "$f"; then
      git add "$f" || return 1
      continue
    fi

    # 2) If only one stage exists (ours XOR theirs), pick it.
    local stages has_ours has_theirs
    stages=$(git ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | sort -u || true)
    has_ours=0
    has_theirs=0
    grep -qx '2' <<<"$stages" && has_ours=1 || true
    grep -qx '3' <<<"$stages" && has_theirs=1 || true

    if ((has_ours == 1 && has_theirs == 0)); then
      git checkout --ours -- "$f" || return 1
      git add "$f" || return 1
      continue
    fi

    if ((has_ours == 0 && has_theirs == 1)); then
      git checkout --theirs -- "$f" || return 1
      git add "$f" || return 1
      continue
    fi

    # Not trivial/safe.
    return 1
  done <<<"$conflict_files"

  # If anything is still unmerged, bail.
  if [[ -n "$(git ls-files -u 2>/dev/null || true)" ]]; then
    return 1
  fi

  # Complete the merge commit using the default merge message.
  if ! git commit --no-edit >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

upsert_party_conflict_comment() {
  # Usage: upsert_party_conflict_comment <workspace> <repo_slug> <username> <app_password> <pr_id> <base_branch> <party_branch> <source_branch> <merge_ref> <conflict_files>
  # conflict_files should be a newline-separated list of file paths (typically from: git diff --name-only --diff-filter=U)
  local workspace="$1"
  local repo_slug="$2"
  local username="$3"
  local app_password="$4"
  local pr_id="$5"
  local base_branch="$6"
  local party_branch="$7"
  local source_branch="$8"
  local merge_ref="$9"
  local conflict_files="${10:-}"

  local marker now
  marker=$(party_conflict_comment_marker)
  now=$(now_utc)

  # Render up to 25 conflicting files to keep comments readable.
  local conflicts_md=''
  local -a conflicts=()
  if [[ -n "$conflict_files" ]]; then
    local -i count=0
    local f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      conflicts+=("$f")
    done <<<"$conflict_files"

    for f in "${conflicts[@]}"; do
      count=$((count + 1))
      if ((count > 25)); then
        break
      fi
      conflicts_md+="- \`$f\`"$'\n'
    done

    if ((${#conflicts[@]} > 25)); then
      conflicts_md+="- _(and $(( ${#conflicts[@]} - 25 )) more...)_"$'\n'
    fi
  fi

  # Include a small snippet of conflict context (first conflict per file), capped by lines.
  # Tune via env vars to avoid giant PR comments.
  local max_total_lines max_lines_per_file
  max_total_lines=${REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_MAX_LINES:-120}
  max_lines_per_file=${REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_MAX_LINES_PER_FILE:-40}

  local conflict_context_md=''
  if ((${#conflicts[@]} > 0)); then
    local -i total_lines=0
    local file block remaining per_file_lines block_lines conflict_start

    for file in "${conflicts[@]}"; do
      remaining=$((max_total_lines - total_lines))
      if ((remaining <= 0)); then
        break
      fi

      per_file_lines=$max_lines_per_file
      if ((per_file_lines > remaining)); then
        per_file_lines=$remaining
      fi

      conflict_start=$(awk 'index($0, "<<<<<<<") == 1 { print NR; exit }' "$file" 2>/dev/null || true)
      block=$(first_merge_conflict_snippet_for_file "$file" "$per_file_lines" || true)

      if [[ -n "$block" ]]; then
        conflict_context_md+=$'\n'"**\`$file\`**"
        if [[ -n "$conflict_start" ]]; then
          conflict_context_md+=" (around line $conflict_start)"
        fi
        conflict_context_md+=$'\n\n'

        # Use indented code blocks (classic Markdown) for maximum compatibility.
        local indented='' line
        while IFS= read -r line; do
          indented+="    ${line}"$'\n'
        done <<<"$block"
        conflict_context_md+="$indented"$'\n'
      else
        conflict_context_md+=$'\n'"**\`$file\`**"$'\n\n'"_(Unable to extract conflict markers from this file (some conflict types don\x27t include inline markers); see CI logs.)_"$'\n'
      fi

      block_lines=$(printf '%s' "$block" | awk 'END{print NR}')
      total_lines=$((total_lines + block_lines))
    done

    if ((total_lines >= max_total_lines)); then
      conflict_context_md+=$'\n'"_(Conflict context truncated at ${max_total_lines} line(s). Set REBUILD_PARTY_BRANCH_CONFLICT_CONTEXT_MAX_LINES / _MAX_LINES_PER_FILE to adjust.)_"$'\n'
    fi
  fi

  local comment_body
  comment_body=$(
    printf '%s\n' \
      '**Party branch rebuild skipped this PR due to merge conflicts**' \
      '' \
      "- Base branch: \`$base_branch\`" \
      "- Party branch: \`$party_branch\`" \
      "- Source branch: \`$source_branch\`" \
      "- Merge ref: \`$merge_ref\`" \
      "- Time (UTC): \`$now\`" \
      '' \
      'Conflicting files:' \
      '' \
      "${conflicts_md:-_Unable to determine conflicting files; see CI logs for details._}" \
      '' \
      'Conflict context (first conflict per file):' \
      '' \
      "${conflict_context_md:-_Unable to extract conflict context; see CI logs for details._}" \
      '' \
      'Please resolve conflicts by updating the PR branch so it can be included in the party branch.' \
      '' \
      '_(Automated comment created by an AI agent; not written by Joey.)_' \
      "$marker"
  )

  local payload
  payload=$(jq -nc --arg raw "$comment_body" '{content:{raw:$raw}}')

  # If there is an existing conflict comment still in conflict, delete it and recreate a new
  # comment so it floats to the top of the thread.
  local comments_json
  comments_json=$(fetch_pr_comments_allow_fail "$workspace" "$repo_slug" "$pr_id" "$username" "$app_password") || comments_json='[]'

  local -a existing_ids=()
  mapfile -t existing_ids < <(find_party_active_conflict_comment_ids "$comments_json" || true)

  if ((${#existing_ids[@]} > 0)); then
    local -i deleted=0
    local id url

    for id in "${existing_ids[@]}"; do
      [[ -z "$id" ]] && continue
      url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments/${id}"
      if bitbucket_api_request_allow_fail DELETE "$url" "$username" "$app_password" >/dev/null; then
        deleted=$((deleted + 1))
      fi
    done

    if ((deleted == ${#existing_ids[@]})); then
      local create_url create_resp created_id
      create_url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments"
      create_resp=$(bitbucket_api_request_allow_fail POST "$create_url" "$username" "$app_password" "$payload") || return 1
      created_id=$(jq -r '.id // empty' <<<"$create_resp")

      if [[ -n "$created_id" ]]; then
        printf 'Recreated PR #%s conflict comment (comment id %s).\n' "$pr_id" "$created_id"
      else
        printf 'Recreated PR #%s conflict comment.\n' "$pr_id"
      fi
      return 0
    fi

    # Could not delete all of them; fall back to updating the first one in place.
    local fallback_id
    fallback_id="${existing_ids[0]}"
    if [[ -n "$fallback_id" ]]; then
      url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments/${fallback_id}"
      bitbucket_api_request_allow_fail PUT "$url" "$username" "$app_password" "$payload" >/dev/null || return 1
      printf 'Updated PR #%s conflict comment (comment id %s).\n' "$pr_id" "$fallback_id"
      return 0
    fi
  fi

  local create_url create_resp created_id
  create_url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments"
  create_resp=$(bitbucket_api_request_allow_fail POST "$create_url" "$username" "$app_password" "$payload") || return 1
  created_id=$(jq -r '.id // empty' <<<"$create_resp")

  if [[ -n "$created_id" ]]; then
    printf 'Created PR #%s conflict comment (comment id %s).\n' "$pr_id" "$created_id"
  else
    printf 'Created PR #%s conflict comment.\n' "$pr_id"
  fi
}

strip_party_conflict_details_for_resolved_comment() {
  # Usage: strip_party_conflict_details_for_resolved_comment <raw_text>
  # Removes the merge-conflict snippet section and footer markers so the resolved comment
  # stays readable (and avoids weird strike-through formatting).
  local raw_text="$1"

  local out='' line
  local -i skipping_context=0

  while IFS= read -r line; do
    # Drop markers and the AI footer; we'll add them back.
    if [[ "$line" == '<!-- rebuild_party_branch:'* ]]; then
      continue
    fi

    if [[ "$line" == '_(Automated comment created by an AI agent; not written by Joey.)_' ]]; then
      continue
    fi

    # Drop the old header and timestamp to reduce noise.
    if [[ "$line" == '**Party branch rebuild skipped this PR due to merge conflicts**' ]]; then
      continue
    fi

    if [[ "$line" == "- Time (UTC):"* ]]; then
      continue
    fi

    # Remove the conflict context section entirely (it contains the inline conflict markers).
    if ((skipping_context == 1)); then
      if [[ "$line" == 'Please resolve conflicts by updating the PR branch so it can be included in the party branch.' ]]; then
        skipping_context=0
      fi
      continue
    fi

    if [[ "$line" == 'Conflict context (first conflict per file):' ]]; then
      skipping_context=1
      out+=$'Conflict context: _(removed after resolution to keep formatting clean)_\n'
      continue
    fi

    # This instruction doesn't apply after resolution.
    if [[ "$line" == 'Please resolve conflicts by updating the PR branch so it can be included in the party branch.' ]]; then
      continue
    fi

    out+="$line"$'\n'
  done <<<"$raw_text"

  printf '%s' "$out"
}

resolve_party_conflict_comment_if_present() {
  # Usage: resolve_party_conflict_comment_if_present <workspace> <repo_slug> <username> <app_password> <pr_id> <party_branch>
  local workspace="$1"
  local repo_slug="$2"
  local username="$3"
  local app_password="$4"
  local pr_id="$5"
  local party_branch="$6"

  local marker resolved_marker
  marker=$(party_conflict_comment_marker)
  resolved_marker=$(party_conflict_resolved_marker)

  local comments_json existing_comment_id existing_raw
  comments_json=$(fetch_pr_comments_allow_fail "$workspace" "$repo_slug" "$pr_id" "$username" "$app_password") || return 1
  existing_comment_id=$(find_party_active_conflict_comment_id "$comments_json")

  [[ -z "$existing_comment_id" ]] && return 0

  existing_raw=$(jq -r --arg id "$existing_comment_id" '.[] | select((.id|tostring)==$id) | .content.raw // empty' <<<"$comments_json")

  # If it's already marked resolved, don't touch it.
  if [[ "$existing_raw" == *"$resolved_marker"* ]]; then
    return 0
  fi

  local now previous_clean
  now=$(now_utc)
  previous_clean=$(strip_party_conflict_details_for_resolved_comment "$existing_raw")

  local new_body
  new_body=$(
    printf '%s\n' \
      "Resolved: this PR now merges cleanly into \`$party_branch\` as of \`$now\`." \
      '' \
      "$previous_clean" \
      '' \
      '_(Automated comment created by an AI agent; not written by Joey.)_' \
      "$marker" \
      "$resolved_marker"
  )

  local payload url
  payload=$(jq -nc --arg raw "$new_body" '{content:{raw:$raw}}')
  url="https://api.bitbucket.org/2.0/repositories/${workspace}/${repo_slug}/pullrequests/${pr_id}/comments/${existing_comment_id}"
  bitbucket_api_request_allow_fail PUT "$url" "$username" "$app_password" "$payload" >/dev/null || return 1

  printf 'Marked PR #%s conflict comment as resolved (comment id %s).\n' "$pr_id" "$existing_comment_id"
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

    # Merge each head branch into the party branch.
    #
    # To maximize inclusion, do multiple passes:
    # - Attempt to merge all PR branches.
    # - If some conflict, skip them for the moment.
    # - After other branches land, retry the conflicters (sometimes the conflicts disappear).
    #
    # Tunable:
    #   REBUILD_PARTY_BRANCH_MAX_MERGE_PASSES (default: 5)
    local -i max_merge_passes
    max_merge_passes=${REBUILD_PARTY_BRANCH_MAX_MERGE_PASSES:-5}
    if ((max_merge_passes < 1)); then
      max_merge_passes=1
    fi

    local -a pending_head_branches=()
    if [[ -n "$head_branches" ]]; then
      # shellcheck disable=SC2206
      pending_head_branches=($head_branches)
    fi

    local -i pass_num=0
    local head_branch merge_ref pr_id_for_branch label

    while ((${#pending_head_branches[@]} > 0)); do
      pass_num=$((pass_num + 1))
      if ((pass_num > max_merge_passes)); then
        printf 'Reached max merge passes (%d); leaving %d branch(es) unmerged for %s.\n' \
          "$max_merge_passes" "${#pending_head_branches[@]}" "$party_branch_name" >&2
        break
      fi

      printf 'Merge pass %d/%d (%d branch(es) pending) for %s\n' \
        "$pass_num" "$max_merge_passes" "${#pending_head_branches[@]}" "$party_branch_name"

      local -i merged_this_pass=0
      local -a next_pending=()

      for head_branch in "${pending_head_branches[@]}"; do
        merge_ref="origin/${head_branch}"
        pr_id_for_branch=${branch_to_pr_id["$head_branch"]:-}

        if [[ -n "$pr_id_for_branch" ]]; then
          label="PR #${pr_id_for_branch} (${merge_ref})"
        else
          label="$merge_ref"
        fi

        printf 'Merging %s into %s...\n' "$label" "$party_branch_name"

        if ! shell_allow_fail "git merge --no-ff --no-edit '$merge_ref'"; then
          # Optional: auto-resolve trivial conflicts to maximize inclusion.
          #
          # Tunable:
          #   REBUILD_PARTY_BRANCH_AUTO_RESOLVE_TRIVIAL_CONFLICTS (default: 1)
          if [[ "${REBUILD_PARTY_BRANCH_AUTO_RESOLVE_TRIVIAL_CONFLICTS:-1}" == "1" ]]; then
            if try_auto_resolve_trivial_merge_conflicts; then
              printf 'Auto-resolved trivial conflicts for %s; merge completed.\n' "$label"
              merged_this_pass=$((merged_this_pass + 1))
              if [[ -n "$pr_id_for_branch" ]]; then
                resolve_party_conflict_comment_if_present \
                  "$workspace" \
                  "$repo_slug" \
                  "$username" \
                  "$app_password" \
                  "$pr_id_for_branch" \
                  "$party_branch_name" || true
              fi
              continue
            fi
          fi

          printf 'Merge conflict when merging %s: see git output above.\n' "$label" >&2
          printf 'Deferring %s for retry due to conflict.\n' "$label" >&2

          # Only comment when Git indicates actual file-level merge conflicts.
          local conflict_files
          conflict_files=$(git --no-pager diff --name-only --diff-filter=U 2>/dev/null || true)

          if [[ -n "$pr_id_for_branch" ]] && [[ -n "$(git ls-files -u 2>/dev/null || true)" ]]; then
            upsert_party_conflict_comment \
              "$workspace" \
              "$repo_slug" \
              "$username" \
              "$app_password" \
              "$pr_id_for_branch" \
              "$base_branch_name" \
              "$party_branch_name" \
              "$head_branch" \
              "$merge_ref" \
              "$conflict_files" || true
          fi

          # Abort the merge and try the next branch.
          git merge --abort || true
          next_pending+=("$head_branch")
        else
          merged_this_pass=$((merged_this_pass + 1))
          if [[ -n "$pr_id_for_branch" ]]; then
            resolve_party_conflict_comment_if_present \
              "$workspace" \
              "$repo_slug" \
              "$username" \
              "$app_password" \
              "$pr_id_for_branch" \
              "$party_branch_name" || true
          fi
        fi
      done

      pending_head_branches=("${next_pending[@]}")

      if ((merged_this_pass == 0)); then
        # No progress means the remaining branches conflict against the current party branch state.
        break
      fi
    done

    if ((${#pending_head_branches[@]} > 0)); then
      printf '%s\n' '=================================================='
      printf 'WARNING: The following PR branches were SKIPPED\n'
      printf '         from %s due to merge conflicts:\n' "$party_branch_name"
      for head_branch in "${pending_head_branches[@]}"; do
        merge_ref="origin/${head_branch}"
        pr_id_for_branch=${branch_to_pr_id["$head_branch"]:-}
        if [[ -n "$pr_id_for_branch" ]]; then
          label="PR #${pr_id_for_branch} (${merge_ref})"
        else
          label="$merge_ref"
        fi
        printf '  - %s\n' "$label"
      done
      printf '%s\n' '=================================================='
    fi

    # Force push party branch for this base.
    shell "git push origin '$party_branch_name' --force"
  done
}

main "$@"
