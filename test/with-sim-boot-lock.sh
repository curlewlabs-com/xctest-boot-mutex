#!/bin/sh
# Tests for bin/with-sim-boot-lock.sh.
#
# These run the real wrapper against a real kernel lock - no fake `xcrun`,
# no fake lock primitive - because what is worth guarding here is the
# mutual-exclusion behavior itself, and a test that stubbed the lock would
# assert only that the stub was called. The wrapped commands are plain shell
# so the test needs no simulator.
#
# Each primitive branch is covered across the CI matrix rather than in one
# run: macOS uses `lockf`, Linux uses `flock`. A run exercises its host's
# primitive.
# The assertions below are written against the wrapper's
# contract, which is identical either way - unlike the CPU assertion in
# sim-boot-lock-acquire.sh, which that same split does reach.
#
# The properties, and the failure each one guards:
#   1. Concurrent invocations do not overlap. This is the whole point; a
#      regression here is a returning `(ipc/mig) server died` storm that
#      presents as an unrelated flaky iOS job.
#   2. The wrapped command's exit status is the wrapper's. A swallowed
#      non-zero turns a failed simulator boot into a green step that fails
#      later, somewhere else.
#   3. Failure to acquire is fail-closed AND distinguishable: non-zero, the
#      wrapped command never ran, and the operator guidance is named. The
#      alternative - booting anyway - reintroduces the storm precisely when
#      the host is already contended.
#   4. The lock file survives a completed run. `lockf` removes it by default;
#      with it removed, a holder on the old inode and an acquirer on a fresh
#      one each "hold" the lock, which splits the mutex silently.
#   5. The wrapped command receives the resolved acquire budget, so a longer
#      operation can remain bounded below its peer waiters.
#   6. The wrapped command runs under the caller's umask, while the lock file
#      it shares with other accounts is still created world-writable. The
#      wrapper clears the umask to create that file; leaking the cleared mask
#      into the command would make everything it writes world-writable.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/with-sim-boot-lock.sh"

if [ ! -x "$SCRIPT" ]; then
    echo "ERROR: $SCRIPT not found or not executable" >&2
    exit 1
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/with-sim-boot-lock-test.XXXXXX")
SUITE_COMPLETE=0
trap 'rm -rf "$TEST_TMPDIR" || echo "WARN: cleanup failed (test result unaffected): $TEST_TMPDIR" >&2; [ "$SUITE_COMPLETE" = 1 ] || exit 1' EXIT

# A lock file of our own, so the test never contends with a real simulator
# boot on the same host - this suite can run on a Mac that is also a runner.
SIM_BOOT_LOCK_FILE="$TEST_TMPDIR/test.lock"
export SIM_BOOT_LOCK_FILE

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

check_eq() {
    label="$1"
    expected="$2"
    actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass
    else
        fail "$label: expected '$expected', got '$actual'"
    fi
}

check_contains() {
    label="$1"
    needle="$2"
    haystack="$3"
    case "$haystack" in
    *"$needle"*) pass ;;
    *) fail "$label: expected to contain '$needle', got '$haystack'" ;;
    esac
}

# 1. Serialization. Each worker brackets a sleep with its own start/end
# marker; if the windows overlapped, some start would be followed by a
# different worker's line. Asserting on the interleaving rather than on
# wall-clock time keeps this from flaking on a loaded CI host.
ORDER_FILE="$TEST_TMPDIR/order.txt"
: >"$ORDER_FILE"
for worker in 1 2 3; do
    "$SCRIPT" sh -c "echo start-$worker >>'$ORDER_FILE'; sleep 1; echo end-$worker >>'$ORDER_FILE'" \
        >/dev/null 2>&1 &
done
wait

interleaved=""
current=""
while read -r line; do
    marker=${line%%-*}
    who=${line#*-}
    if [ "$marker" = "start" ]; then
        [ -z "$current" ] || interleaved="start-$who inside $current"
        current="$who"
    else
        [ "$who" = "$current" ] || interleaved="end-$who closed $current"
        current=""
    fi
done <"$ORDER_FILE"

check_eq "three concurrent runs emit six lines" "6" "$(wc -l <"$ORDER_FILE" | tr -d ' ')"
check_eq "concurrent runs do not overlap" "" "$interleaved"

# 2. Exit status propagation. 42 is arbitrary but distinct from the
# wrapper's own failure statuses (1 for acquire failure, 2 for usage).
set +e
"$SCRIPT" sh -c 'exit 42' >/dev/null 2>&1
rc=$?
set -e
check_eq "wrapped command's exit status propagates" "42" "$rc"

# 3. Fail-closed acquire. Hold the lock with the wrapper itself - portable
# across either primitive branch, unlike hand-rolling a holder - then race a
# second invocation against a 1s budget it cannot win.
RAN_MARKER="$TEST_TMPDIR/should-not-run"
HELD="$TEST_TMPDIR/held"
RELEASE="$TEST_TMPDIR/release"
# The holder says when it has the lock and keeps it until told to let go, so
# the contender below races a lock that is held, however slow the runner is.
# shellcheck disable=SC2016 # The holder's shell, not this one, expands these.
"$SCRIPT" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' sh "$HELD" "$RELEASE" \
    >/dev/null 2>&1 &
HOLDER_PID=$!
held_deadline=$(($(date +%s) + 60))
while [ ! -e "$HELD" ]; do
    if [ "$(date +%s)" -ge "$held_deadline" ]; then
        echo "ERROR: the holder never took the lock - suite cannot run" >&2
        exit 1
    fi
    sleep 0.1
done

set +e
contend_output=$(SIM_BOOT_ACQUIRE_TIMEOUT=1 "$SCRIPT" touch "$RAN_MARKER" 2>&1)
contend_rc=$?
set -e

check_eq "losing the acquire race exits non-zero" "1" "$contend_rc"
check_contains "acquire failure names the operator guidance" "When acquisition fails" "$contend_output"
if [ -e "$RAN_MARKER" ]; then
    fail "fail-closed: wrapped command ran without the lock"
else
    pass
fi

touch "$RELEASE"
wait "$HOLDER_PID" 2>/dev/null || true

# 4. The lock file outlives a completed run.
"$SCRIPT" true >/dev/null 2>&1
if [ -e "$SIM_BOOT_LOCK_FILE" ]; then
    pass
else
    fail "lock file was removed after a run - the mutex would split across acquisitions"
fi

# The child sees the resolved value even when the caller supplies an override.
BUDGET_FILE="$TEST_TMPDIR/acquire-budget"
# shellcheck disable=SC2016 # The child shell, not this test, reads the exported value.
SIM_BOOT_ACQUIRE_TIMEOUT=37 "$SCRIPT" sh -c 'printf "%s\n" "$SIM_BOOT_ACQUIRE_TIMEOUT" >"$1"' sh "$BUDGET_FILE" >/dev/null 2>&1
check_eq "wrapped command receives resolved acquire budget" "37" "$(cat "$BUDGET_FILE")"

# 6. The caller's umask reaches the command; the lock file keeps its shared
# mode. A fresh lock path, so this run is the one that creates it.
MASK_FILE="$TEST_TMPDIR/command-umask"
FRESH_LOCK="$TEST_TMPDIR/fresh.lock"
# shellcheck disable=SC2016 # The child shell, not this test, runs umask.
(umask 077 && SIM_BOOT_LOCK_FILE="$FRESH_LOCK" "$SCRIPT" sh -c 'umask >"$1"' sh "$MASK_FILE") >/dev/null 2>&1
check_eq "wrapped command keeps the caller's umask" "0077" "$(cat "$MASK_FILE")"
if command -v lockf >/dev/null 2>&1; then
    lock_mode=$(stat -c '%A' "$FRESH_LOCK" 2>/dev/null || stat -f '%Sp' "$FRESH_LOCK")
    check_eq "lockf creates the shared lock file world-writable" "-rw-rw-rw-" "$lock_mode"
fi

# 7. Usage error is distinct from each outcome above, so a caller that forgot its command
# does not read as a lock problem.
set +e
"$SCRIPT" >/dev/null 2>&1
usage_rc=$?
set -e
check_eq "no command is a usage error, not a lock failure" "2" "$usage_rc"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "FAIL - $FAIL assertions failed, $PASS passed" >&2
    exit 1
fi
echo "OK - $PASS assertions passed"
SUITE_COMPLETE=1
