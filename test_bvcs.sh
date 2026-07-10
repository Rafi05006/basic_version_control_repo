#!/usr/bin/bash
# ============================================================================
# test_bvcs.sh — Automated spec-compliance test suite for BVCS assignment
#
# Usage:
#   ./test_bvcs.sh /path/to/2205XYZ.sh
#
# For every test: builds a throwaway repo in $WORKROOT/caseN, runs the
# subcommand(s), and compares actual stdout / exit code / on-disk state
# against the exact spec. Timestamps are normalized before comparison.
# Prints PASS/FAIL per test, a unified diff on failure, and a summary.
# ============================================================================

set -u

if [ $# -ne 1 ]; then
    echo "Usage: $0 /path/to/2205006.sh"
    exit 1
fi

SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -f "$SCRIPT" ]; then
    echo "Script not found: $SCRIPT"
    exit 1
fi
chmod +x "$SCRIPT" 2>/dev/null

WORKROOT="$(mktemp -d /tmp/bvcs_test.XXXXXX)"
CASE_N=0
PASS=0
FAIL=0
FAILED_NAMES=()

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

newcase(){
    CASE_N=$((CASE_N+1))
    DIR="$WORKROOT/case$CASE_N"
    mkdir -p "$DIR"
    cd "$DIR" || exit 1
}

bvcs(){
    "$SCRIPT" "$@"
}

# Strip timestamps like "2026-07-10 10:17:32" -> "<TS>" so dynamic times
# don't break exact-match comparisons.
norm(){
    sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<TS>/g'
}

# assert_eq NAME EXPECTED ACTUAL
assert_eq(){
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        echo "${GREEN}PASS${RESET}  $name"
    else
        FAIL=$((FAIL+1))
        FAILED_NAMES+=("$name")
        echo "${RED}FAIL${RESET}  $name"
        echo "  --- expected ---"
        echo "$expected" | sed 's/^/  | /'
        echo "  --- actual ---"
        echo "$actual" | sed 's/^/  | /'
        echo "  --- diff (expected vs actual) ---"
        diff <(echo "$expected") <(echo "$actual") | sed 's/^/  /'
    fi
}

# assert_true NAME CONDITION_DESCRIPTION [test -x ... ]
assert_true(){
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS+1))
        echo "${GREEN}PASS${RESET}  $name"
    else
        FAIL=$((FAIL+1))
        FAILED_NAMES+=("$name")
        echo "${RED}FAIL${RESET}  $name (condition failed: $*)"
    fi
}

section(){
    echo
    echo "${YELLOW}==== $1 ====${RESET}"
}

# ============================================================================
# TASK 1: init, check_repo, dispatcher
# ============================================================================
section "Task 1: init / check_repo / dispatcher"

newcase
out="$(bvcs init)"
assert_eq "init: success message" "Initialized empty BVCS repository." "$out"
assert_true "init: .bvcs/objects dir exists" test -d .bvcs/objects
assert_true "init: .bvcs/staging exists and empty" bash -c '[ -e .bvcs/staging ] && [ ! -s .bvcs/staging ]'
assert_true "init: .bvcs/log exists and empty" bash -c '[ -e .bvcs/log ] && [ ! -s .bvcs/log ]'
assert_true "init: .bvcs/HEAD exists and empty" bash -c '[ -e .bvcs/HEAD ] && [ ! -s .bvcs/HEAD ]'

out="$(bvcs init)"; code=$?
assert_eq "init: repeat init error message" "Error: BVCS repository already exists." "$out"
assert_true "init: repeat init exits nonzero" bash -c "[ $code -ne 0 ]"

newcase
out="$(bvcs status)"; code=$?
assert_eq "check_repo: error message outside repo" "Error: Not a BVCS repository. Run 'init' first." "$out"
assert_true "check_repo: exits nonzero" bash -c "[ $code -ne 0 ]"

out="$(bvcs help)"; code=$?
assert_true "help: works without a repo (no crash)" bash -c "[ $code -eq 0 ] || [ -n \"$out\" ]"

newcase
bvcs init >/dev/null
out="$(bvcs banana)"; code=$?
assert_eq "dispatcher: unknown subcommand message" "Error: Unknown subcommand 'banana'." "$out"
assert_true "dispatcher: unknown subcommand exits 1" bash -c "[ $code -eq 1 ]"

# ============================================================================
# TASK 2: add
# ============================================================================
section "Task 2: add"

newcase
bvcs init >/dev/null
out="$(bvcs add)"
assert_eq "add: no args error" "Error: No files specified." "$out"

echo hello > greet.txt
echo world > world.txt
out="$(bvcs add greet.txt world.txt)"
assert_eq "add: stage two files" "$(printf 'Staged: greet.txt\nStaged: world.txt')" "$out"
assert_eq "add: staging file contents/order" "$(printf 'greet.txt\nworld.txt')" "$(cat .bvcs/staging)"

out="$(bvcs add greet.txt)"
assert_eq "add: already-staged message" "Already staged: greet.txt" "$out"

out="$(bvcs add ghost.txt)"
assert_eq "add: file-not-found message" "Error: 'ghost.txt' not found." "$out"

out="$(bvcs add ghost.txt world.txt)"
assert_eq "add: skips missing file, continues with rest" "$(printf "Error: 'ghost.txt' not found.\nAlready staged: world.txt")" "$out"

# ============================================================================
# TASK 3: status
# ============================================================================
section "Task 3: status"

newcase
bvcs init >/dev/null
out="$(bvcs status)"
assert_eq "status: clean repo, nothing at all" "Nothing to commit, working tree clean." "$out"

newcase
bvcs init >/dev/null
echo x > only_untracked.txt
out="$(bvcs status)"
assert_eq "status: single untracked file, no staging/HEAD (regression case)" \
    "$(printf 'Untracked files:\nonly_untracked.txt\n')" "$out"

newcase
bvcs init >/dev/null
echo a > a.txt
echo b > b.txt
bvcs add a.txt b.txt >/dev/null
out="$(bvcs status)"
assert_eq "status: staged only, followed by trailing blank line" \
    "$(printf 'Staged for commit:\na.txt\nb.txt\n')" "$out"

newcase
bvcs init >/dev/null
echo a > a.txt
bvcs add a.txt >/dev/null
bvcs commit -m "c1" >/dev/null
echo "change" >> a.txt
echo z > z_untracked.txt
echo m > m_untracked.txt
out="$(bvcs status)"
expected="$(printf 'Modified (not staged):\na.txt\n\nUntracked files:\nm_untracked.txt\nz_untracked.txt\n')"
assert_eq "status: modified tracked file is detected (core status bug)" "$expected" "$out"

newcase
bvcs init >/dev/null
echo a > a.txt
echo b > b.txt
bvcs add a.txt b.txt >/dev/null
bvcs commit -m "c1" >/dev/null
echo "change" >> a.txt
bvcs add a.txt >/dev/null
echo z > z_untracked.txt
out="$(bvcs status)"
expected="$(printf 'Staged for commit:\na.txt\n\nUntracked files:\nz_untracked.txt\n')"
assert_eq "status: staged file excluded from modified list, full 3-part example" "$expected" "$out"

newcase
bvcs init >/dev/null
echo a > a.txt
bvcs add a.txt >/dev/null
bvcs commit -m "c1" >/dev/null
out="$(bvcs status)"
assert_eq "status: fully clean after commit" "Nothing to commit, working tree clean." "$out"

# ============================================================================
# TASK 4: commit
# ============================================================================
section "Task 4: commit"

newcase
bvcs init >/dev/null
out="$(bvcs commit)"
assert_eq "commit: missing -m flag" 'Error: Commit message required. Use -m "message".' "$out"

out="$(bvcs commit -m)"
assert_eq "commit: -m with no message text" 'Error: Commit message required. Use -m "message".' "$out"

out="$(bvcs commit -m "hi")"
assert_eq "commit: nothing staged" "Error: Nothing to commit." "$out"

echo a > a.txt
echo b > b.txt
bvcs add a.txt b.txt >/dev/null
out="$(bvcs commit -m "Initial commit" | norm)"
assert_eq "commit: success message format" \
    "$(printf '[0001] Initial commit\n2 file(s) committed.')" "$out"
assert_eq "commit: HEAD updated to 0001" "0001" "$(cat .bvcs/HEAD)"
assert_true "commit: staging truncated" bash -c '[ ! -s .bvcs/staging ]'
assert_true "commit: snapshot files exist" bash -c '[ -f .bvcs/objects/0001/files/a.txt ] && [ -f .bvcs/objects/0001/files/b.txt ]'
assert_eq "commit: log line format" "0001|<TS>|Initial commit" "$(cat .bvcs/log | norm)"

echo c > c.txt
bvcs add c.txt >/dev/null
out="$(bvcs commit -m "Second commit" | norm)"
assert_eq "commit: second commit id increments, correct file count" \
    "$(printf '[0002] Second commit\n1 file(s) committed.')" "$out"
assert_true "commit: carries forward previous snapshot files" \
    bash -c '[ -f .bvcs/objects/0002/files/a.txt ] && [ -f .bvcs/objects/0002/files/b.txt ] && [ -f .bvcs/objects/0002/files/c.txt ]'

# ============================================================================
# TASK 5: log
# ============================================================================
section "Task 5: log"

newcase
bvcs init >/dev/null
out="$(bvcs log)"
assert_eq "log: no commits" "No commits yet." "$out"

echo a > a.txt
bvcs add a.txt >/dev/null
bvcs commit -m "Initial commit" >/dev/null
sleep 1
echo b > b.txt
bvcs add b.txt >/dev/null
bvcs commit -m "Second commit" >/dev/null

out="$(bvcs log | norm)"
expected="$(printf 'commit 0002\nDate: <TS>\nMessage: Second commit\n\ncommit 0001\nDate: <TS>\nMessage: Initial commit\n')"
assert_eq "log: most-recent-first, exact format, blank line after each entry" "$expected" "$out"

# ============================================================================
# TASK 6: diff
# ============================================================================
section "Task 6: diff"

newcase
bvcs init >/dev/null
out="$(bvcs diff)"
assert_eq "diff: no commits yet" "Error: No commits yet." "$out"

echo hello > greet.txt
echo world > world.txt
bvcs add greet.txt world.txt >/dev/null
bvcs commit -m "Initial commit" >/dev/null

out="$(bvcs diff ghost.txt)"
assert_eq "diff: untracked-file error message" "Error: 'ghost.txt' is not tracked." "$out"

out="$(bvcs diff world.txt)"
assert_eq "diff: no-changes message (single file)" "world.txt: no changes." "$out"

echo goodbye >> greet.txt
out="$(bvcs diff greet.txt)"
expected="$(printf -- '--- .bvcs/objects/0001/files/greet.txt\n+++ greet.txt\n@@ -1 +1,2 @@\n hello\n+goodbye')"
assert_eq "diff: unified diff with correct --label headers" "$expected" "$out"

out="$(bvcs diff)"
expected="$(printf -- '--- .bvcs/objects/0001/files/greet.txt\n+++ greet.txt\n@@ -1 +1,2 @@\n hello\n+goodbye\nworld.txt: no changes.')"
assert_eq "diff: no-arg form shows ALL tracked files, none omitted" "$expected" "$out"

# ============================================================================
# TASK 7: restore
# ============================================================================
section "Task 7: restore"

newcase
bvcs init >/dev/null
out="$(bvcs restore)"
assert_eq "restore: no file arg checked BEFORE 'no commits' (order matters)" "Error: No file specified." "$out"

out="$(bvcs restore greet.txt)"
assert_eq "restore: no commits yet (with file given)" "Error: No commits yet." "$out"

echo hello > greet.txt
echo world > world.txt
bvcs add greet.txt world.txt >/dev/null
bvcs commit -m "Initial commit" >/dev/null

out="$(bvcs restore ghost.txt <<< "y")"
assert_eq "restore: file not in snapshot" "Error: 'ghost.txt' not found in commit 0001." "$out"

echo goodbye >> greet.txt
out="$(bvcs restore greet.txt <<< "y")"
expected="$(printf "Restore 'greet.txt' from commit 0001? [y/N]: Restored: greet.txt")"
assert_eq "restore: confirm 'y' -- prompt + success message format" "$expected" "$out"
assert_eq "restore: file content actually reverted" "hello" "$(cat greet.txt)"

echo goodbye >> greet.txt
out="$(bvcs restore greet.txt <<< "n")"; code=$?
expected="$(printf "Restore 'greet.txt' from commit 0001? [y/N]: Aborted.")"
assert_eq "restore: decline with 'n' -- message" "$expected" "$out"
assert_true "restore: decline exits 0" bash -c "[ $code -eq 0 ]"
assert_eq "restore: file untouched after abort" "$(printf 'hello\ngoodbye')" "$(cat greet.txt)"

out="$(bvcs restore greet.txt <<< "Y")"
expected="$(printf "Restore 'greet.txt' from commit 0001? [y/N]: Restored: greet.txt")"
assert_eq "restore: confirm capital 'Y' also accepted" "$expected" "$out"

# ============================================================================
# End-to-end scenario (from the tutorial's worked example)
# ============================================================================
section "End-to-end scenario"

newcase
bvcs init >/dev/null
echo '#include <stdio.h>' > main.c
echo 'int helper() {}' > util.c
echo '# Notes' > notes.md
bvcs add main.c util.c >/dev/null
out="$(bvcs status)"
expected="$(printf 'Staged for commit:\nmain.c\nutil.c\n\nUntracked files:\nnotes.md\n')"
assert_eq "e2e: status before first commit" "$expected" "$out"

out="$(bvcs commit -m "Initial commit" | norm)"
assert_eq "e2e: first commit summary" "$(printf '[0001] Initial commit\n2 file(s) committed.')" "$out"

echo 'int main() {}' >> main.c
out="$(bvcs status)"
expected="$(printf 'Modified (not staged):\nmain.c\n\nUntracked files:\nnotes.md\n')"
assert_eq "e2e: status shows modified main.c" "$expected" "$out"

out="$(bvcs diff main.c)"
expected="$(printf -- '--- .bvcs/objects/0001/files/main.c\n+++ main.c\n@@ -1 +1,2 @@\n #include <stdio.h>\n+int main() {}')"
assert_eq "e2e: diff main.c" "$expected" "$out"

out="$(bvcs restore main.c <<< "y")"
expected="$(printf "Restore 'main.c' from commit 0001? [y/N]: Restored: main.c")"
assert_eq "e2e: restore main.c" "$expected" "$out"

# ============================================================================
# SUMMARY
# ============================================================================
echo
echo "${YELLOW}============================================${RESET}"
echo "TOTAL: $((PASS+FAIL))   ${GREEN}PASS: $PASS${RESET}   ${RED}FAIL: $FAIL${RESET}"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Failed tests:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
    done
fi
echo "${YELLOW}============================================${RESET}"

rm -rf "$WORKROOT"
[ "$FAIL" -eq 0 ]
