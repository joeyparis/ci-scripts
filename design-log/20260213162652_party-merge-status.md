# Background
We use party branches (e.g., `party/<base>`) rebuilt from open Bitbucket PRs so deployments can validate a combined set of changes.

# Problem
It was hard to quickly determine, from the deployed party branch, which PR branches were actually included and which were skipped (typically due to merge conflicts). The previous workflow relied on CI logs and/or automated PR comments.

# Questions and Answers
Q: Where should the “merged vs not merged” status live so it’s visible during deployment?
A: Commit a single markdown file directly on the party branch so anyone looking at the deployed branch can see the list without digging through CI logs.

Q: Should we keep leaving Bitbucket PR comments when conflicts occur?
A: No. Remove the PR-comment behavior and direct people to the markdown status file.

Q: Do we still want conflict details somewhere?
A: Keep the existing per-PR conflict report artifact (where available) since it can help debugging, but do not post PR comments.

# Design
- Add a single status markdown file written during party-branch rebuild and committed only to the party branch.
  - Default path: `party_merge_status.md`.
  - Configurable via `REBUILD_PARTY_BRANCH_STATUS_MD_PATH`.
- The file contains:
  - Base branch + party branch.
  - A “Merged” list (PR number + branch name when available).
  - A “Not merged” list (PR number + branch name + a reason like `merge conflict`).
- Ordering is stable (sorted) to reduce churn between runs.
- Remove all behavior that creates/updates/resolves Bitbucket PR comments for merge conflicts.

# Implementation Plan
1) Track merges during the merge passes:
   - Collect merged branches.
   - Collect last failure reason for branches that remain pending.
2) After merge attempts finish for a base branch:
   - Write the status markdown file.
   - `git add` + `git commit` only if the file changed.
3) Continue force-pushing the party branch.
4) Delete/disable the PR-comment paths for conflicts.
5) Validate with `bash -n rebuild_party_branch.sh`.

# Examples
✅ Example (merged)
- PR #123 — `feature/foo`

❌ Example (not merged)
- PR #456 — `bugfix/bar` (merge conflict)

# Trade-offs
- Pros:
  - Status is discoverable from the party branch itself.
  - No dependency on reading CI logs or PR comment threads.
  - Stable ordering minimizes diffs.
- Cons:
  - The status file is generated per rebuild; if someone looks at an older party branch commit, it reflects that run’s state.

## Implementation Results
- Implemented status markdown generation/commit on the party branch in `rebuild_party_branch.sh`.
- Removed Bitbucket PR-comment behavior for conflicts.
- Verified script syntax with `bash -n`.
