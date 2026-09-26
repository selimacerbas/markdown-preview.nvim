#!/bin/sh
# The files live-server.nvim and markdown-preview.nvim share, compared with
# the sibling checkout's copy. live-server's copy is the source: a change
# lands there first and is copied. The list below is the one statement of
# what is shared. A Lua file is compared by diff -w, since StyLua indents
# with tabs in one repository and spaces in the other, after the lines
# from a "-- parity: own lines begin" line to its "-- parity: own lines end"
# line are dropped (helpers.lua's H.rtp and markdown-preview's floor tag,
# markdown-preview's lazy.lua section of parse_test.lua); every other file
# byte for byte.
#
# Usage: sh tests/parity.sh <sibling checkout>. Exit 0 is in parity, 1
# names every drifted file, 2 is could not compare (no sibling, a marker
# without its pair); make parity exits 2 for either failure, as make does.
set -u
cd "$(dirname "$0")/.." || exit 2
sib=${1:-}
if [ -z "$sib" ] || [ ! -d "$sib" ]; then
    echo "parity: the sibling checkout '$sib' is not a directory (make parity SIBLING=<path>)" >&2
    exit 2
fi
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
# dash ends on a signal without the EXIT trap (measured), so each signal
# cleans up and is raised again, so the caller stops at once too.
trap 'rm -rf "$tmp"; trap - HUP; kill -HUP $$' HUP
trap 'rm -rf "$tmp"; trap - INT; kill -INT $$' INT
trap 'rm -rf "$tmp"; trap - TERM; kill -TERM $$' TERM

# own FILE OUT: FILE without its own lines; exit 2 on an unpaired marker.
own() {
    awk '
        /^-- parity: own lines begin/ { if (skip) bad = 1; skip = 1; next }
        /^-- parity: own lines end/ { if (!skip) bad = 1; skip = 0; next }
        !skip { print }
        END { if (skip || bad) exit 2 }
    ' "$1" >"$2"
}

n=0
drifted=0
while read -r how path; do
    n=$((n + 1))
    if [ ! -f "$path" ] || [ ! -f "$sib/$path" ]; then
        echo "parity: $path is missing here or in $sib" >&2
        drifted=$((drifted + 1))
        continue
    fi
    case $how in
        cmp)
            cmp -s "$path" "$sib/$path"
            rc=$?
            ;;
        lua)
            own "$path" "$tmp/here" || { echo "parity: $path has an own-lines marker without its pair" >&2; exit 2; }
            own "$sib/$path" "$tmp/there" || { echo "parity: $sib/$path has an own-lines marker without its pair" >&2; exit 2; }
            diff -w "$tmp/here" "$tmp/there" >"$tmp/diff"
            rc=$?
            ;;
        *)
            echo "parity: the list names an unknown comparison: $how" >&2
            exit 2
            ;;
    esac
    case $rc in
        0) ;;
        1)
            echo "parity: $path differs from $sib/$path ($how)" >&2
            drifted=$((drifted + 1))
            ;;
        *)
            echo "parity: $path could not be compared ($how exit $rc)" >&2
            exit 2
            ;;
    esac
done <<'LIST'
lua tests/helpers.lua
lua tests/helpers_test.lua
lua tests/parse_test.lua
cmp tests/floor_smoke.sh
cmp tests/run.sh
cmp tests/message_policy_test.sh
cmp tests/parity.sh
cmp Makefile
cmp .gitattributes
cmp .luarc.json
cmp .githooks/commit-msg
cmp .githooks/message-policy
cmp .github/PULL_REQUEST_TEMPLATE.md
LIST
if [ "$drifted" -gt 0 ]; then
    echo "parity: $drifted of $n shared files drifted from $sib" >&2
    exit 1
fi
echo "parity: $n shared files in parity with $sib"
