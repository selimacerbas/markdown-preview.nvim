#!/bin/sh
# The one test loop CI and `make test` share: every suite runs even after one
# fails, so a red run names them all; the help tags are checked when a doc/
# directory exists.
#
# Neovim builds its runtimepath from XDG_CONFIG_HOME and XDG_DATA_HOME, and
# opens its log under XDG_STATE_HOME, before any script runs, where the
# helper cannot move them: the developer's ~/.config/nvim and start packages
# stayed searchable after H.isolate (measured), and a start package must not
# shadow the checkout under test. A suite under -l writes no shada; the
# help-tags call below does (measured). So the runner points all four at a
# private directory of its own and removes it: mktemp's name is
# unpredictable and its mode 700, where a fixed name in a shared /tmp let
# another account claim or repoint it first (measured). It sets them
# whatever the caller exported: the hosted ubuntu image exports
# XDG_CONFIG_HOME=$HOME/.config, which kept that config on the runtimepath
# of every ubuntu leg, and a test run has no case for a caller's config.
#
# Neovim's exit code alone passed a suite that never loaded the helper,
# whatever it printed (measured), so a suite whose output carries no Results
# line fails the run too. Under GitHub Actions a red suite's FAIL rows and
# its cause are annotations too, so a red run names them without its log.
#
# Each suite is passed by its absolute logical name: $PWD keeps the name of a
# link the shell cd'ed into (make -C <link> and a recipe's $PWD read the
# physical name, so run from inside the link), where Neovim would make a
# relative name absolute against the physical directory, and the helper puts
# the checkout on the runtimepath by the name it was loaded through (a plain
# link to a directory whose real name carries a comma loads only by the link).
set -u
cd "$(dirname "$0")/.." || exit 1
run=$(mktemp -d) || exit 1
trap 'rm -rf "$run"' EXIT
# dash ends on HUP, INT or TERM without the EXIT trap, which left the run
# directory behind (measured), so each signal cleans up and is raised again:
# an exit status instead let a bash recipe shell run make test's next lane.
trap 'rm -rf "$run"; trap - HUP; kill -HUP $$' HUP
trap 'rm -rf "$run"; trap - INT; kill -INT $$' INT
trap 'rm -rf "$run"; trap - TERM; kill -TERM $$' TERM
XDG_CONFIG_HOME=$run/config
XDG_DATA_HOME=$run/data
XDG_STATE_HOME=$run/state
XDG_CACHE_HOME=$run/cache
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
gha=${GITHUB_ACTIONS:-}
fail=0
for t in tests/*_test.lua; do
    [ -n "$gha" ] && printf '::group::%s\n' "$t"
    # tee shows the output as it comes; a POSIX pipeline reports only its
    # last command's status, so Neovim's travels through a file, and tee's
    # own status counts too: a capture that failed must not pass the gate.
    why=
    { nvim --headless -u NONE -l "$PWD/$t" 2>&1; echo "$?" >"$run/rc"; } | tee "$run/out" || why='its output could not be captured'
    rc=$(cat "$run/rc")
    [ "$rc" = 0 ] || why="${why:+$why; }it exited $rc"
    if ! grep -q '^Results: ' "$run/out"; then
        printf '%s printed no Results line: a suite that never calls H.finish() rules nothing\n' "$t"
        why="${why:+$why; }it printed no Results line"
    fi
    [ -n "$gha" ] && printf '::endgroup::\n'
    if [ -n "$why" ]; then
        fail=1
        # A % would open an escape in a workflow command's message.
        if [ -n "$gha" ]; then
            grep '^ *FAIL: ' "$run/out" | sed -e 's/%/%25/g' -e "s|^ *FAIL: *|::error::$t: |"
            printf '::error::%s failed: %s\n' "$t" "$why" | sed 's/%/%25/g'
        fi
    fi
done
if [ -d doc ]; then
    if ! nvim --headless -u NONE -c 'try | helptags doc | catch | echomsg v:exception | cquit 1 | endtry' -c 'qa!'; then
        fail=1
        [ -n "$gha" ] && printf '::error::the help tags of doc/ failed\n'
    fi
fi
exit "$fail"
