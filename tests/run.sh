#!/bin/sh
# The one test loop CI and `make test` share: every suite runs even after one
# fails, so a red run names them all; the help tags are checked when a doc/
# directory exists. Neovim opens its startup log and shada under
# XDG_STATE_HOME before any script runs, the one path the helper cannot move,
# so the runner gives each run a private directory of its own and removes it:
# mktemp's name is unpredictable and its mode 700, where a fixed name in a
# shared /tmp let another account claim or repoint it first (measured). A
# caller who exports XDG_STATE_HOME keeps the responsibility for that path.
set -u
cd "$(dirname "$0")/.." || exit 1
if [ -z "${XDG_STATE_HOME:-}" ]; then
    state=$(mktemp -d) || exit 1
    trap 'rm -rf "$state"' EXIT
    XDG_STATE_HOME=$state
fi
export XDG_STATE_HOME
fail=0
for t in tests/*_test.lua; do
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::group::%s\n' "$t"
    nvim --headless -u NONE -l "$t" || fail=1
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::endgroup::\n'
done
if [ -d doc ]; then
    nvim --headless -u NONE -c 'try | helptags doc | catch | echomsg v:exception | cquit 1 | endtry' -c 'qa!' || fail=1
fi
exit "$fail"
