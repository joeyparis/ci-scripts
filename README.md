# CI Scripts

This repository contains a collection of CI scripts used for various automation tasks.

## Scripts

- `rebuild_party_branch.sh`: Shell script for rebuilding party branches.
  - Writes a single status markdown file to the party branch (default: `party_merge_status.md`) listing which PR branches merged and which did not.
  - Set `REBUILD_PARTY_BRANCH_STATUS_MD_PATH` to change the output path.

## Legacy Scripts

Legacy scripts are located in the `legacy/` directory.

- `legacy/rebuild_party_branch.rb`: Old Ruby version of the rebuild party branch script.
