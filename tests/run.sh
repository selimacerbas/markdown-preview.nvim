#!/bin/sh
# The one test loop CI and `make test` share: every suite runs even after one
# fails, so a red run names them all; the help tags are checked when a doc/
# directory exists.
#
# Neovim builds its runtimepath from XDG_CONFIG_HOME and XDG_DATA_HOME, and
# opens its startup log and shada under XDG_STATE_HOME, before any script
# runs, where the helper cannot move them: the developer's ~/.config/nvim and
# start packages stayed searchable after H.isolate (measured), and a start
# package must not shadow the checkout under test. So the runner points all
# four at a private directory of its own and removes it: mktemp's name is
# unpredictable and its mode 700, where a fixed name in a shared /tmp let
# another account claim or repoint it first (measured). A caller who exports
# one of them keeps the responsibility for that path.
#
# Neovim's exit code alone passed a suite that never loaded the helper,
# whatever it printed (measured), so a suite whose output carries no Results
# line fails the run too.
#
# Each suite is passed by its absolute logical name: $PWD keeps the name of a
# link the checkout was reached through, where Neovim would make a relative
# name absolute against the physical directory, and the helper puts the
# checkout on the runtimepath by the name it was loaded through (a plain link
# to a directory whose real name carries a comma loads only by the link).
set -u
cd "$(dirname "$0")/.." || exit 1
run=$(mktemp -d) || exit 1
trap 'rm -rf "$run"' EXIT
: "${XDG_CONFIG_HOME:=$run/config}"
: "${XDG_DATA_HOME:=$run/data}"
: "${XDG_STATE_HOME:=$run/state}"
: "${XDG_CACHE_HOME:=$run/cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
fail=0
for t in tests/*_test.lua; do
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::group::%s\n' "$t"
    # tee shows the output as it comes; a POSIX pipeline reports only its
    # last command's status, so Neovim's travels through a file, and tee's
    # own status counts too: a capture that failed must not pass the gate.
    { nvim --headless -u NONE -l "$PWD/$t" 2>&1; echo "$?" >"$run/rc"; } | tee "$run/out" || fail=1
    [ "$(cat "$run/rc")" = 0 ] || fail=1
    if ! grep -q '^Results: ' "$run/out"; then
        printf '%s printed no Results line: a suite that never calls H.finish() rules nothing\n' "$t"
        fail=1
    fi
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::endgroup::\n'
done
if [ -d doc ]; then
    nvim --headless -u NONE -c 'try | helptags doc | catch | echomsg v:exception | cquit 1 | endtry' -c 'qa!' || fail=1
fi
exit "$fail"
