#!/bin/sh
# Tests for sim_boot_lock_acquire_fd (bin/sim-boot-lock.sh).
#
# Tested here rather than through a wrapper because only one of the lock's
# holders uses it: with-sim-boot-lock.sh hands its whole command to the
# primitive and has its own suite, while xctest-with-boot-mutex.sh needs
# the lock on a descriptor it can close partway through xcodebuild - and driving
# that wrapper means driving xcodebuild. The function is the shared surface, so
# it is what these assertions hold.
#
# Real descriptors and a real kernel lock, no stub: a stubbed primitive would
# assert that the stub was called, and the properties below are the kernel's.
#
# The properties, and the failure each one guards:
#   1. A held lock is not acquirable, and the budget bounds a loser rather than
#      hanging. The mutex is the point; without it the CoreSimulatorService boot
#      storm returns as an unattributable `(ipc/mig) server died` in whichever
#      iOS job happened to be running, and a caller that hangs instead of
#      failing loses its runbook pointer to the job's own timeout.
#   2. A waiter polls through to acquisition. Asserted on the SAME waiter as
#      property 3 and only there: a fresh acquire against a lock nobody holds
#      proves nothing about polling, and an implementation that gave up on the
#      first busy status would pass it.
#   3. That waiting costs no CPU. This is the regression that motivated the
#      function: macOS `lockf(1)` spins in FD mode, ~100% of a core for the
#      whole wait, so letting the primitive do the waiting burns a core per
#      waiter on the one host class this lock exists for - several simulator
#      boots contending at once. Nothing else catches it. CI stays green, and
#      the only symptom is the contended host getting slower, which is the
#      condition being serialized in the first place.
#
#      **A green is coverage of that regression only on a Mac.** macOS runs
#      exercise lockf; Linux runs use flock.
#      On a Linux run the `flock` branch takes it, and letting
#      that primitive wait blocks in the kernel at no CPU: the assertion
#      passes, having caught a sleepless poll loop rather than the spin. A
#      Linux green must not be read as having exercised the macOS regression.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/bin/sim-boot-lock.sh"

if [ ! -f "$LIB" ]; then
    echo "ERROR: $LIB not found" >&2
    exit 1
fi

# shellcheck source=SCRIPTDIR/../bin/sim-boot-lock.sh
. "$LIB"

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sim-boot-lock-acquire-test.XXXXXX")
SUITE_COMPLETE=0
trap 'rm -rf "$TEST_TMPDIR" || echo "WARN: cleanup failed (test result unaffected): $TEST_TMPDIR" >&2; [ "$SUITE_COMPLETE" = 1 ] || exit 1' EXIT

# A lock of the test's own, so this never contends with a real simulator boot -
# the suite can run on a Mac that is also a runner.
LOCK="$TEST_TMPDIR/acquire.lock"
: >"$LOCK"

# The holder below keeps the lock until this file appears, so how long it holds
# is the suite's choice rather than a bet on how fast the runner is.
RELEASE="$TEST_TMPDIR/release"

# How long the measured waiter is left waiting before the holder lets go. Long
# enough that a spinning wait would burn well over the CPU bound below.
WAIT_SECONDS=3

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

# Hold the lock in a background process until RELEASE appears. Runs the
# acquire the same way production does - a shell that opens the descriptor and
# keeps it open - so the lock under test is the one the kernel actually sees.
hold_lock() {
    sh -c ". '$LIB'; exec 9>>'$LOCK'; sim_boot_lock_acquire_fd 9 30 || exit 1; while [ ! -e '$RELEASE' ]; do sleep 0.1; done" &
}

# Try to acquire with a $1-second budget; echoes the exit status. `|| rc=$?`
# rather than a bare call, because a losing acquire is an expected non-zero
# under `set -e`.
try_acquire() {
    _try_rc=0
    sh -c ". '$LIB'; exec 9>>'$LOCK'; sim_boot_lock_acquire_fd 9 $1" >/dev/null 2>&1 ||
        _try_rc=$?
    echo "$_try_rc"
}

# Block until the holder has actually taken the lock.
#
# Observed rather than slept for: "the holder holds it" is the precondition
# every assertion below rests on, and a fixed margin makes that precondition a
# bet on how loaded the runner is - which, on a Mac that is also a CI runner,
# is the one thing not worth betting on. A probe that wins the race
# releases immediately (the subshell exits), so polling with one cannot keep the
# holder out.
wait_until_held() {
    _wuh_end=$(($(date +%s) + 30))
    while [ "$(try_acquire 0)" -eq 0 ]; do
        if [ "$(date +%s)" -ge "$_wuh_end" ]; then
            echo "ERROR: the holder never took the lock - suite cannot run" >&2
            exit 1
        fi
        sleep 0.2
    done
}

hold_lock
HOLDER_PID=$!
wait_until_held

# 1. A held lock is not acquirable, and a budget the contender cannot win bounds
# it.
contend_rc=$(try_acquire 1)
if [ "$contend_rc" -eq 1 ]; then
    pass
else
    fail "a contender took a held lock (or failed some other way): rc=$contend_rc"
fi

# 2 + 3. One waiter carries each assertion, and it has to be the same waiter: the
# CPU figure is only meaningful for a wait that actually waited, and the
# acquisition is only meaningful for one that was contended when it started.
#
# `times` reports the running subshell's own children plus everything they
# waited for, which is where a spinning primitive's time lands - not in the
# caller's own - so it stays inside the `( )` that ran the waiter rather than in
# a pipeline stage of its own, which would fork away the numbers. The rc rides
# out on the first line. The CPU bound is loose against the observed spin
# (seconds of CPU for a seconds-long wait, against milliseconds for a sleeping
# one), so a loaded runner cannot reach it.
WAITER_STARTED="$TEST_TMPDIR/waiter-started"
WAITER_REPORT="$TEST_TMPDIR/waiter-report"
(
    _wait_rc=0
    sh -c "touch '$WAITER_STARTED'; . '$LIB'; exec 9>>'$LOCK'; sim_boot_lock_acquire_fd 9 30" >/dev/null 2>&1 ||
        _wait_rc=$?
    echo "$_wait_rc"
    times
) >"$WAITER_REPORT" &
WAITER_PID=$!

# The waiter is measured only if it actually waited: it has started, and it is
# still running after WAIT_SECONDS against a lock nobody has released.
started_deadline=$(($(date +%s) + 60))
while [ ! -e "$WAITER_STARTED" ]; do
    if [ "$(date +%s)" -ge "$started_deadline" ]; then
        echo "ERROR: the waiter never started - suite cannot run" >&2
        exit 1
    fi
    sleep 0.1
done
sleep "$WAIT_SECONDS"
if kill -0 "$WAITER_PID" 2>/dev/null; then
    pass
else
    fail "the waiter returned while the lock was still held - it never waited"
fi
touch "$RELEASE"
wait "$WAITER_PID" || true
wait "$HOLDER_PID" 2>/dev/null || true
waiter_report=$(awk 'NR == 1 { rc = $0 } END { gsub(/[ms]/, " "); print rc, ($1 * 60) + $2 + ($3 * 60) + $4 }' "$WAITER_REPORT")
waiter_rc=${waiter_report%% *}
waiter_cpu=${waiter_report##* }

if [ "$waiter_rc" = "0" ]; then
    pass
else
    fail "a waiter that outlived the holder never acquired: rc=$waiter_rc - the poll gave up instead of polling"
fi

if awk -v cpu="$waiter_cpu" 'BEGIN { exit !(cpu != "" && cpu < 1) }'; then
    pass
else
    fail "a waiter burned '${waiter_cpu}'s of CPU waiting for a lock - the wait is spinning, not sleeping"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "FAIL - $FAIL assertions failed, $PASS passed" >&2
    exit 1
fi
echo "OK - $PASS assertions passed"
SUITE_COMPLETE=1
