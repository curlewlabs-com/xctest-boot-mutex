#!/bin/sh
# Tests for bin/xctest-with-boot-mutex.sh, driving the real wrapper against a
# real kernel lock. The wrapped command stands in for xcodebuild: it prints
# xcodebuild's suite-started line when the test tells it to, which is the only
# part of xcodebuild's behavior the wrapper reads.
#
# The properties, and the failure each one guards:
#   1. The lock is held from acquisition until the first suite-started line,
#      and released while the wrapped command is still running. Held too
#      short, boots overlap and the CoreSimulatorService storm returns; held
#      too long, every test run on the host is serialized end to end.
#   2. The hook sees acquired -> releasing -> exited, the first two with the
#      lock held and the last without it, every call naming the wrapper's own
#      PID, and exited carrying the wrapped command's status. A hook recording
#      what a run created is sound only inside the window no other run can
#      enter, and a hook keyed on its parent PID instead of the wrapper's
#      records a process that is already gone.
#   3. A failing acquired-call stops the run before the wrapped command
#      starts. Its job is to make the run safe to start; a run started anyway
#      is the unsafe run.
#   4. A run that never prints the line still releases at exit, through the
#      same releasing-call. A lock that outlived its run would wedge the host.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/bin/xctest-with-boot-mutex.sh"
PROBE="$REPO_ROOT/bin/with-sim-boot-lock.sh"

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/xctest-with-boot-mutex-test.XXXXXX")
SUITE_COMPLETE=0
trap 'rm -rf "$TEST_TMPDIR" || echo "WARN: cleanup failed (test result unaffected): $TEST_TMPDIR" >&2; [ "$SUITE_COMPLETE" = 1 ] || exit 1' EXIT

# A lock of the suite's own, so it never contends with a real simulator boot on
# a Mac that is also a runner.
SIM_BOOT_LOCK_FILE="$TEST_TMPDIR/boot.lock"
RUNNER_TEMP="$TEST_TMPDIR"
export SIM_BOOT_LOCK_FILE RUNNER_TEMP

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

check_eq() {
    if [ "$2" = "$3" ]; then
        pass
    else
        fail "$1: expected '$2', got '$3'"
    fi
}

# "held" or "free": whether a peer could take the boot lock right now. A zero
# budget makes this a single attempt, so it never waits on the holder.
lock_state() {
    if SIM_BOOT_ACQUIRE_TIMEOUT=0 "$PROBE" true >/dev/null 2>&1; then
        echo free
    else
        echo held
    fi
}

# Wait for a file the wrapped command or the hook writes. Observed rather than
# slept for, so a loaded runner slows the suite down instead of failing it.
wait_for() {
    _wf_end=$(($(date +%s) + 60))
    while [ ! -e "$1" ]; do
        if [ "$(date +%s)" -ge "$_wf_end" ]; then
            fail "timed out waiting for $1"
            return 1
        fi
        sleep 0.1
    done
}

# Wait until the lock reaches the state named, for the release that follows
# the wrapper's half-second marker poll.
wait_for_state() {
    _ws_end=$(($(date +%s) + 60))
    while [ "$(lock_state)" != "$1" ]; do
        if [ "$(date +%s)" -ge "$_ws_end" ]; then
            return 1
        fi
        sleep 0.1
    done
}

# The hook under test: one line per call, with whether the lock was held when
# it ran.
HOOK="$TEST_TMPDIR/hook"
HOOK_LOG="$TEST_TMPDIR/hook.log"
cat >"$HOOK" <<EOF
#!/bin/sh
state=\$(if SIM_BOOT_ACQUIRE_TIMEOUT=0 "$PROBE" true >/dev/null 2>&1; then echo free; else echo held; fi)
echo "\$* pid=\$XCTEST_BOOT_MUTEX_PID lock=\$state" >>"$HOOK_LOG"
[ "\$1" != acquired ] || [ ! -e "$TEST_TMPDIR/fail-acquired" ]
EOF
chmod +x "$HOOK"
export XCTEST_BOOT_MUTEX_HOOK="$HOOK"

# 1 + 2. A run that prints the suite line on cue and exits 3 later.
STAGE="$TEST_TMPDIR/stage"
mkdir "$STAGE"
FAKE_XCODEBUILD="$TEST_TMPDIR/fake-xcodebuild"
cat >"$FAKE_XCODEBUILD" <<'FAKE'
#!/bin/sh
touch "$1/booting"
while [ ! -e "$1/boot-done" ]; do sleep 0.1; done
echo "Test Suite 'All tests' started at 2026-01-01 00:00:00.000"
while [ ! -e "$1/tests-done" ]; do sleep 0.1; done
exit 3
FAKE
chmod +x "$FAKE_XCODEBUILD"
"$WRAPPER" "$FAKE_XCODEBUILD" "$STAGE" >"$TEST_TMPDIR/run1.out" 2>&1 &
WRAPPER_PID=$!

if wait_for "$STAGE/booting"; then
    check_eq "lock before the suite line" held "$(lock_state)"
    touch "$STAGE/boot-done"
    if wait_for_state free; then
        pass
    else
        fail "the lock was still held after the suite-started line"
    fi
    # The wrapped command has not exited yet: the release came from the line.
    if [ -e "$STAGE/tests-done" ]; then
        fail "the wrapped command finished before the release was observed"
    else
        pass
    fi
fi
touch "$STAGE/boot-done" "$STAGE/tests-done"
run_rc=0
wait "$WRAPPER_PID" || run_rc=$?
check_eq "wrapped command's status propagates" 3 "$run_rc"
check_eq "hook calls, in order, with lock state" \
    "acquired pid=$WRAPPER_PID lock=held|releasing pid=$WRAPPER_PID lock=held|exited 3 pid=$WRAPPER_PID lock=free|" \
    "$(tr '\n' '|' <"$HOOK_LOG")"

# 3. A failing acquired-call: the wrapped command never starts.
: >"$HOOK_LOG"
touch "$TEST_TMPDIR/fail-acquired"
abort_rc=0
"$WRAPPER" touch "$TEST_TMPDIR/should-not-run" >"$TEST_TMPDIR/run2.out" 2>&1 || abort_rc=$?
rm -f "$TEST_TMPDIR/fail-acquired"
check_eq "failed acquired-call exits 1" 1 "$abort_rc"
if [ -e "$TEST_TMPDIR/should-not-run" ]; then
    fail "the wrapped command ran after its acquired-call failed"
else
    pass
fi
check_eq "lock after an aborted run" free "$(lock_state)"

# 4. No suite line: held for the whole run, released at exit, hook still told.
: >"$HOOK_LOG"
silent_rc=0
"$WRAPPER" sh -c 'exit 0' >"$TEST_TMPDIR/run3.out" 2>&1 || silent_rc=$?
check_eq "silent passing run exits 0" 0 "$silent_rc"
check_eq "silent run's hook calls" \
    "acquired lock=held|releasing lock=held|exited 0 lock=free|" \
    "$(sed 's/ pid=[0-9]*//' "$HOOK_LOG" | tr '\n' '|')"
check_eq "lock after a silent run" free "$(lock_state)"

# A hook that was named and cannot run is refused before the lock is taken.
missing_rc=0
XCTEST_BOOT_MUTEX_HOOK="$TEST_TMPDIR/no-such-hook" "$WRAPPER" true >/dev/null 2>&1 || missing_rc=$?
check_eq "missing hook is refused" 1 "$missing_rc"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "FAIL - $FAIL assertions failed, $PASS passed" >&2
    for out in "$TEST_TMPDIR"/run*.out; do
        echo "--- $out" >&2
        cat "$out" >&2
    done
    exit 1
fi
echo "OK - $PASS assertions passed"
SUITE_COMPLETE=1
