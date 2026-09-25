#!/bin/sh
# The commit-message policy and the commit-msg hook, measured end to end:
# the policy script alone, then real git commits in a scratch repository
# whose hook make hooks installed, under git's own comment handling (the
# configured strings, auto, -v, -m, -F, an editor session). GIT_EDITOR=true
# leaves git's template in the file untouched, as a user who saves at once.
# The CI arms of the commits job are the workflow's own steps and are not
# run by this suite.
#
# Run: sh tests/message_policy_test.sh
set -u
cd "$(dirname "$0")/.." || exit 1
src=$PWD
policy=$src/.githooks/message-policy
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
# The developer's own git configuration must not reach the scratch commits.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_EDITOR
dash=$(printf '\342\200\224')
passed=0
failed=0

ok() { passed=$((passed + 1)); printf '  PASS: %s\n' "$1"; }
bad() {
    failed=$((failed + 1))
    printf '  FAIL: %s (exit %s, want %s)\n' "$1" "$2" "$3"
    sed 's/^/    | /' "$tmp/err"
}
# judge NAME GOT WANT [TEXT]: the exit is WANT, and TEXT is in the output
# (for a pass, the output is empty: a sed error on stderr is a failure too).
judge() {
    if [ "$2" != "$3" ]; then bad "$1" "$2" "$3"; return; fi
    if [ -n "${4:-}" ]; then
        grep -qF -e "$4" "$tmp/err" || { bad "$1" "$2" "$3 and the line $4"; return; }
    elif [ "$3" = 0 ] && [ -s "$tmp/err" ]; then
        bad "$1" "$2" "$3 and no output"
        return
    fi
    ok "$1"
}
# pol NAME WANT TEXT MESSAGE: the policy script on a file holding MESSAGE.
pol() {
    printf '%s\n' "$4" >"$tmp/msg"
    "$policy" "$tmp/msg" 2>"$tmp/err"
    judge "policy: $1" "$?" "$2" "$3"
}

echo 'Section 1: the policy script'
pol 'a clean message' 0 '' "$(printf 'Fix the reload race\n\nThe watcher fired twice.')"
pol 'the em dash in the subject' 1 'em dash character (U+2014) on line 1' "Fix it ${dash} now"
pol 'the em dash in the body' 1 'em dash character (U+2014) on line 3' "$(printf 'Fix it\n\nwhy %s here' "$dash")"
for t in Co-authored-by Signed-off-by Co-developed-by Assisted-by Generated-by \
    Reviewed-by Acked-by Tested-by Suggested-by Reported-by; do
    pol "the trailer $t" 1 "attribution trailer on line 3 ($t)" "$(printf 'Fix it\n\n%s: A <a@example.invalid>' "$t")"
done
pol 'a trailer in upper case' 1 'attribution trailer on line 3 (CO-AUTHORED-BY)' "$(printf 'Fix it\n\nCO-AUTHORED-BY: A')"
pol 'a trailer with a tab before the colon' 1 'attribution trailer on line 3 (Signed-off-by)' "$(printf 'Fix it\n\nSigned-off-by\t: A')"
pol 'a trailer with blanks before the colon' 1 'attribution trailer on line 3 (Co-Authored-By)' "$(printf 'Fix it\n\n  Co-Authored-By  : A')"
for s in '[skip ci]' '[ci skip]' '[no ci]' '[skip actions]' '[actions skip]'; do
    pol "the skip instruction $s" 1 "skip instruction ($s on line 1)" "Fix it $s"
done
pol 'a skip instruction in mixed case' 1 'skip instruction ([skip ci] on line 3)' "$(printf 'Fix it\n\nsee [Skip CI]')"
pol 'the trailer skip-checks: true' 1 'skip-checks trailer on line 3' "$(printf 'Fix it\n\nskip-checks: true')"
pol 'the trailer skip-checks:true' 1 'skip-checks trailer on line 3' "$(printf 'Fix it\n\nskip-checks:true')"
pol 'the trailer in mixed case' 1 'skip-checks trailer on line 3' "$(printf 'Fix it\n\n  Skip-Checks : TRUE ')"
pol 'a skip-checks trailer ending in CRLF' 1 'skip-checks trailer on line 3' "$(printf 'Fix it\r\n\r\nskip-checks: true\r')"
pol 'an attribution trailer ending in CRLF' 1 'attribution trailer on line 3 (Co-authored-by)' "$(printf 'Fix it\r\n\r\nCo-authored-by: A\r')"
pol 'skip-checks: false skips nothing' 0 '' "$(printf 'Fix it\n\nskip-checks: false')"
pol 'a message that is only a subject' 0 '' 'Fix the reload race'
printf 'Fix it %s\n' "$dash" | "$policy" - 2>"$tmp/err"
judge 'policy: - reads stdin' "$?" 1 'em dash character'
printf 'Fix it\n' | "$policy" - 2>"$tmp/err"
judge 'policy: - reads a clean stdin' "$?" 0
"$policy" "$tmp/no-such-file" 2>"$tmp/err"
judge 'policy: a missing file cannot be judged' "$?" 2 'is not a readable file'
# A PATH that finds grep and cat but no awk breaks the line numbering, which
# must read as could-not-judge, never as a refusal with a wrong line.
mkdir "$tmp/bin" && ln -s "$(command -v grep)" "$(command -v cat)" "$tmp/bin/" || exit 1
printf 'Fix it %s\n' "$dash" >"$tmp/msg"
PATH=$tmp/bin "$policy" "$tmp/msg" 2>"$tmp/err"
judge 'policy: a failed tool in the numbering cannot be judged' "$?" 2 'awk failed'
pol 'Latin-1 bytes and no violation' 0 '' "$(printf 'Fix caf\351 na\357ve\n\nR\351sum\351 \344\366\374')"
# A pull request that keeps the template carries it as its body, which the
# commits job judges.
"$policy" "$src/.github/PULL_REQUEST_TEMPLATE.md" 2>"$tmp/err"
judge 'policy: the pull request template passes' "$?" 0

echo 'Section 2: the hook in a scratch repository'
repo=$tmp/repo
git init -q "$repo" || exit 1
mkdir -p "$repo/.githooks"
cp "$src/Makefile" "$repo/" && cp "$src/.githooks/commit-msg" "$src/.githooks/message-policy" "$repo/.githooks/" || exit 1
git -C "$repo" config core.hooksPath .githooks
make -s -C "$repo" hooks >"$tmp/err" 2>&1
judge 'make hooks refuses while core.hooksPath is set' "$?" 2 'core.hooksPath is .githooks'
git -C "$repo" config --unset core.hooksPath
make -s -C "$repo" hooks >"$tmp/err" 2>&1
judge 'make hooks installs the hook' "$?" 0 'hooks: installed'
# git skips a hook that is not executable with only a hint line, which the
# rows below filter out, so every row that wants a commit would pass unjudged.
(cd "$repo" && test -x "$(git rev-parse --git-path hooks/commit-msg)") >"$tmp/err" 2>&1
judge 'the installed hook is executable' "$?" 0
# The branch name and a staged file's name and content carry the em dash,
# so an editor session refuses a clean message unless its comment lines are
# dropped and the diff is cut away.
git -C "$repo" checkout -q -b "topic${dash}x" || exit 1
n=0
stage() {
    n=$((n + 1))
    printf 'line %s %s\n' "$n" "$dash" >>"$repo/file${dash}x"
    git -C "$repo" add -A
}
# com NAME WANT TEXT [CONFIG=VALUE ...] -- GIT COMMIT ARGS: WANT is 0 for a
# commit and 1 for a refusal, whose output names TEXT.
com() {
    name=$1 want=$2 text=$3
    shift 3
    git -C "$repo" config --unset-all core.commentChar
    git -C "$repo" config --unset-all core.commentString
    git -C "$repo" config --unset-all commit.cleanup
    while [ "$1" != -- ]; do
        git -C "$repo" config --add "${1%%=*}" "${1#*=}"
        shift
    done
    shift
    stage
    (cd "$repo" && GIT_EDITOR=true git commit -q "$@") >"$tmp/err.git" 2>&1
    got=$?
    [ "$got" = 0 ] || got=1
    # Git's own warning and hint lines (git 2.52 deprecates commentChar=auto
    # and says so on every commit) are not the hook's output; a failed row
    # shows them too, so a line the filter hid is not lost.
    grep -v -e '^warning: ' -e '^hint:' "$tmp/err.git" >"$tmp/err"
    before=$failed
    judge "hook: $name" "$got" "$want" "$text"
    [ "$failed" = "$before" ] || sed 's/^/    git| /' "$tmp/err.git"
}
# rec NAME HOOK RECORDED CONFIG... -- ARGS: com with HOOK as its want, then
# the policy over the message git recorded (committed with --no-verify when
# the hook refused) must rule RECORDED.
rec() {
    rname=$1 hwant=$2 rwant=$3
    shift 3
    com "$rname" "$hwant" '' "$@"
    if [ "$got" != 0 ]; then
        while [ "$1" != -- ]; do shift; done
        shift
        stage
        (cd "$repo" && GIT_EDITOR=true git commit -q --no-verify "$@") >"$tmp/err" 2>&1 || { bad "recorded: $rname" commit 0; return; }
    fi
    git -C "$repo" log -1 --format=%B | "$policy" - 2>"$tmp/err"
    got=$?
    judge "recorded: $rname" "$got" "$rwant"
}
com 'the # default under an editor commits' 0 '' -- -e -m 'Clean subject'
com 'the # default under -v -e commits' 0 '' -- -v -e -m 'Clean subject'
com 'a configured ; under -v -e commits' 0 '' core.commentChar=';' -- -v -e -m 'Clean subject'
com 'a configured // under -v -e commits' 0 '' core.commentString=// -- -v -e -m 'Clean subject'
com 'a sed-special [.*^$/ under -v -e commits' 0 '' 'core.commentString=[.*^$/' -- -v -e -m 'Clean subject'
com 'commentChar then commentString: the last read wins' 0 '' core.commentChar=';' core.commentString=@ -- -v -e -m 'Clean subject'
com 'commentString then commentChar: the last read wins' 0 '' core.commentString=@ core.commentChar=';' -- -v -e -m 'Clean subject'
com 'auto with #12 first under -v: cut at the ; scissors' 0 '' core.commentChar=auto -- -v -e -m '#12 Clean subject'
com 'auto with #12 first, no -v: the ; lines dropped' 0 '' core.commentChar=auto -- -e -m '#12 Clean subject'
com 'auto with -m: nothing stripped' 1 'em dash character' core.commentChar=auto -- -m 'Clean subject' -m "; note ${dash}"
com 'a -m comment-character line is judged' 1 'em dash character (U+2014) on line 3' -- -m 'Clean subject' -m "# note ${dash}"
printf 'Clean subject\n\n# ------------------------ >8 ------------------------\nCo-authored-by: A\n' >"$tmp/F"
com 'a -F trailer below a literal scissors line' 1 'attribution trailer on line 4' -- -F "$tmp/F"
com 'a scissors line then a non-comment line in an editor session' 1 'attribution trailer' -- -e -F "$tmp/F"
com '-m with Co-Authored-By : is refused' 1 'attribution trailer on line 3 (Co-Authored-By)' -- -m 'Clean subject' -m 'Co-Authored-By : A'
com 'an em dash subject under an editor is refused' 1 'em dash character (U+2014) on line 1' -- -e -m "Subject ${dash} x"
# commit.cleanup, each mode under an editor with -v and with a -m comment
# line, against what git recorded.
rec 'cleanup=whitespace under -v -e on the em dash branch' 1 1 commit.cleanup=whitespace -- -v -e -m 'Clean subject'
# The rest run on a plain branch: git records the branch name in the
# comment lines it keeps, and an em dash there would hide a hook that
# judges the diff below the scissors line.
git -C "$repo" checkout -q -b plain || exit 1
for m in default strip scissors whitespace verbatim; do
    rec "cleanup=$m under -v -e" 0 0 commit.cleanup=$m -- -v -e -m 'Clean subject'
    case $m in strip) w=0 ;; *) w=1 ;; esac
    rec "cleanup=$m with a -m comment line" "$w" "$w" commit.cleanup=$m -- -m 'Clean subject' -m "# note ${dash}"
done
# A -F file with a line that is the comment string alone reads as an editor
# session; git records its comment lines, which the CI job then refuses.
printf 'Clean subject\n\n#\n# note %s\n' "$dash" >"$tmp/F2"
rec 'a -F file shaped like an editor session passes the hook' 0 1 -- -F "$tmp/F2"
mv "$repo/.githooks/message-policy" "$tmp/policy.moved"
com 'a missing policy script cannot be judged' 1 'git commit --no-verify' -- -m 'Clean subject'
mv "$tmp/policy.moved" "$repo/.githooks/message-policy"

echo
echo '========================================'
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
echo '========================================'
[ "$failed" = 0 ]
