#!/usr/bin/env bash
# handler_test.sh — work/done/get, static tree, 404, traversal.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

published_root="$sandbox/shared"
state_directory="$sandbox/state"
mkdir -p "$published_root/docs" "$published_root/data" "$published_root/assets" \
  "$published_root/legacy" "$published_root/repo/.git" "$published_root/tree/sub"
printf '<!doctype html>\n<p>fixture-home</p>\n' > "$published_root/index.html"
printf '<!doctype html>\n<p>fixture-index</p>\n' > "$published_root/docs/index.html"
printf '#!/bin/sh\necho fixture-default\n' > "$published_root/docs/DEFAULT.sh"
printf 'body { color: red; }\n' > "$published_root/assets/site.css"
printf '# notes\n' > "$published_root/assets/note.md"
printf 'host={{SERVER_HOST}} port={{HTTP_PORT}}\n' > "$published_root/assets/info.html"
printf 'raw {{SERVER_HOST}}\n' > "$published_root/assets/raw.txt"
printf '#!/bin/sh\necho fixture-legacy\n' > "$published_root/legacy/DEFAULT.sh"
printf 'secret-token\n' > "$published_root/repo/.git/config"
printf 'id\tvalue\n1\tone\n' > "$published_root/data/table.tsv"
printf 'alpha\n' > "$published_root/tree/alpha.txt"
printf 'private\n' > "$published_root/tree/.secret"

# Command can come from SVR_ROOT/command
svr_root="$sandbox/svr"
mkdir -p "$svr_root"
printf 'echo from-svr-command\n' > "$svr_root/command"
export SVR_ROOT="$svr_root"
export SERVER_HOST='fixture.example'
export HTTP_PORT='9090'
server_start "$published_root" "$state_directory"

# --- work / done (fictif id) -----------------------------------------------
http_get /work
assert_status 200 "$HTTP_STATUS" "GET /work returns an id"
token="$HTTP_BODY"
assert_not_equal '' "$token" "id is not empty"

http_get "/work/$token"
assert_status 200 "$HTTP_STATUS" "GET /work/<id> returns the command"
assert_equal 'echo from-svr-command' "$HTTP_BODY" "command from SVR_ROOT/command"

http_post "/done/$token" 'output=hello-world'
assert_status 200 "$HTTP_STATUS" "POST /done/<id> confirms"
assert_contains "$HTTP_BODY" "confirmed: $token" "confirmation body"

# --- /get -------------------------------------------------------------------
http_post /get "dataset=sample"
assert_status 200 "$HTTP_STATUS" "dataset request granted"
assert_contains "$HTTP_BODY" 'dataset sample granted' "dataset body"

http_post /get ""
assert_status 400 "$HTTP_STATUS" "missing dataset should be rejected"

# --- static tree ------------------------------------------------------------
http_get /
assert_status 200 "$HTTP_STATUS" "root should resolve to index.html"
assert_equal 'text/html; charset=utf-8' "$HTTP_CONTENT_TYPE" "root content type"
assert_contains "$HTTP_BODY" 'fixture-home' "root index content"

http_get /docs
assert_status 200 "$HTTP_STATUS" "directory should prefer index.html"
assert_equal 'text/html; charset=utf-8' "$HTTP_CONTENT_TYPE" "index content type"
assert_contains "$HTTP_BODY" 'fixture-index' "index content wins over DEFAULT"

http_get /docs/
assert_status 200 "$HTTP_STATUS" "trailing slash directory"
assert_contains "$HTTP_BODY" 'fixture-index' "trailing slash index content"

http_get /docs/DEFAULT.sh
assert_status 200 "$HTTP_STATUS" "explicit DEFAULT file is still served"
assert_equal 'text/plain; charset=utf-8' "$HTTP_CONTENT_TYPE" "script content type"
assert_contains "$HTTP_BODY" 'fixture-default' "DEFAULT content"

http_get /legacy
assert_status 200 "$HTTP_STATUS" "directory should fall back to DEFAULT"
assert_equal 'text/plain; charset=utf-8' "$HTTP_CONTENT_TYPE" "DEFAULT content type"
assert_contains "$HTTP_BODY" 'fixture-legacy' "legacy DEFAULT content"

http_get /assets/site.css
assert_status 200 "$HTTP_STATUS" "stylesheet should be served"
assert_equal 'text/css; charset=utf-8' "$HTTP_CONTENT_TYPE" "stylesheet content type"

http_get /assets/note.md
assert_status 200 "$HTTP_STATUS" "markdown should be served"
assert_equal 'text/markdown; charset=utf-8' "$HTTP_CONTENT_TYPE" "markdown content type"

http_get /assets/info.html
assert_status 200 "$HTTP_STATUS" "template page should be served"
assert_contains "$HTTP_BODY" 'host=fixture.example port=9090' "configuration variables are rendered"
assert_not_contains "$HTTP_BODY" '{{' "placeholders are replaced"

http_get /assets/raw.txt
assert_status 200 "$HTTP_STATUS" "plain text should be served"
assert_equal 'raw {{SERVER_HOST}}' "$HTTP_BODY" "plain text stays byte-exact"

http_get /tree
assert_status 200 "$HTTP_STATUS" "directory without index or DEFAULT should list"
assert_equal 'text/html; charset=utf-8' "$HTTP_CONTENT_TYPE" "listing content type"
assert_contains "$HTTP_BODY" 'alpha.txt' "listing shows files"
assert_contains "$HTTP_BODY" 'sub/' "listing marks subdirectories"
assert_contains "$HTTP_BODY" '../' "listing links to the parent"
assert_not_contains "$HTTP_BODY" '.secret' "listing hides dotfiles"

http_get /repo/.git/config
assert_status 404 "$HTTP_STATUS" "dot-prefixed segment should be private"
assert_not_contains "$HTTP_BODY" 'secret-token' "git config must not leak"

http_get /.git/config
assert_status 404 "$HTTP_STATUS" "root dot-prefixed segment should be private"

http_get /data/table.tsv
assert_status 200 "$HTTP_STATUS" "nested file should be served"
assert_contains "$HTTP_BODY" $'1\tone' "nested file content"

http_get /missing
assert_status 404 "$HTTP_STATUS" "missing path should be 404"

http_get_path_as_is /../etc/passwd
assert_status 404 "$HTTP_STATUS" "path traversal should be 404"

http_get_path_as_is '/data/../../etc/passwd'
assert_status 404 "$HTTP_STATUS" "nested traversal should be 404"
