#!/usr/bin/env bash
# site_test.sh — public site sync: complete tree replacement, reserved names,
# and git-backed folders cloned then fast-forwarded.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

site_source="$sandbox/site"
published_root="$sandbox/site-published"
repository_list="$sandbox/repositories.tsv"
mkdir -p "$site_source/hello" "$site_source/scripts" "$published_root"
: > "$repository_list"

printf '<!doctype html>\n<p>home</p>\n' > "$site_source/index.html"
printf '#!/bin/sh\necho hello\n' > "$site_source/hello/DEFAULT.sh"
printf '#!/bin/sh\n' > "$site_source/scripts/DEFAULT.sh"
printf 'body { color: red; }\n' > "$site_source/style.css"
printf 'node_modules\n' > "$site_source/.gitignore"

run_sync() {
  PUBLISHED_ROOT="$published_root" LOG_LEVEL=error \
    bash "$PROJECT_ROOT/site/deploy/files/sync_site.sh" "${1:-$site_source}" "$repository_list"
}

# --- plain entries ----------------------------------------------------------
run_sync
assert_file_exists "$published_root/index.html" "site home is deployed"
assert_file_exists "$published_root/hello/DEFAULT.sh" "site directory is deployed"
assert_file_exists "$published_root/scripts/DEFAULT.sh" "builtins are part of the site"
assert_file_exists "$published_root/style.css" "site file is deployed"
assert_equal "body { color: red; }" "$(cat "$published_root/style.css")" "site file content"
assert_file_missing "$published_root/.gitignore" "dot-prefixed entries stay private"

# --- the whole tree is replaced, so nothing stale survives -------------------
printf 'stale\n' > "$published_root/stale.txt"
rm -f "$site_source/style.css"
run_sync
assert_file_missing "$published_root/style.css" "removed site file is pruned"
assert_file_missing "$published_root/stale.txt" "unmanaged file is pruned"
assert_file_exists "$published_root/hello/DEFAULT.sh" "other entries survive"

# --- reserved and invalid names ---------------------------------------------
mkdir -p "$sandbox/bad-site/node"
printf '#!/bin/sh\n' > "$sandbox/bad-site/node/DEFAULT.sh"
assert_failure "generated node name is rejected" run_sync "$sandbox/bad-site"

mkdir -p "$sandbox/invalid-site/bad name"
assert_failure "invalid site name is rejected" run_sync "$sandbox/invalid-site"

# --- git-backed folder ------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  work_repository="$sandbox/work"
  bare_repository="$sandbox/origin.git"

  git init -q "$work_repository"
  git -C "$work_repository" config user.email tester@example.com
  git -C "$work_repository" config user.name Tester
  printf 'version one\n' > "$work_repository/page.html"
  git -C "$work_repository" add page.html
  git -C "$work_repository" commit -qm 'version one'
  git clone -q --bare "$work_repository" "$bare_repository"

  printf 'project\t%s\n' "$bare_repository" > "$repository_list"
  run_sync
  assert_file_exists "$published_root/project/.git" "repository is a git checkout"
  assert_equal 'version one' "$(cat "$published_root/project/page.html")" "cloned content"
  assert_equal 'version one' "$(git -C "$published_root/project" log -1 --format=%s)" "cloned commit"

  printf 'version two\n' > "$work_repository/page.html"
  git -C "$work_repository" add page.html
  git -C "$work_repository" commit -qm 'version two'
  git -C "$work_repository" push -q "$bare_repository" HEAD

  run_sync
  assert_equal 'version two' "$(cat "$published_root/project/page.html")" "pulled content"
  assert_equal 'version two' "$(git -C "$published_root/project" log -1 --format=%s)" "pulled commit"
else
  printf 'git not found: repository sync test skipped\n'
fi
