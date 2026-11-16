#!/bin/sh
# Run an xcodebuild test command under a host-level boot mutex.
#
# Why: several `xcodebuild test` (or test-without-building) invocations on one
# Mac saturate CoreSimulatorService during the simultaneous XCTestDevice clone
# and simulated-launchd startup phase, producing `(ipc/mig) server died` on the
# simulator's Darwin notification IPC. Once a run gets past the boot phase, the
# host load drops and test execution itself does not trigger the storm. So
# serialize the boot phase only; let test execution run concurrently.
#
# Marker: the first line in which xcodebuild reports a test suite starting -
# `Test suite '<class>' started on '<device>'` in parallel-testing output,
# `Test Suite '<name>' started at <time>` in serial output. A suite starts only
# on a device that has booted and is running the tests, so the line follows
# the first parallel-testing worker's boot, which is what this mutex
# serializes. Whatever xcodebuild does before that line is inside the lock
# too - a build under `xcodebuild test`, that worker's app install and launch.
# Serial output under `-quiet` has no suite line, so a serial `-quiet` run holds
# the lock to its end, and warns if it passes (below).
#
# Not "Testing started": xcodebuild prints that on entering the test action,
# which has been observed before the first worker's clone has booted, so
# releasing on it would leave even that boot outside the lock.
#
# "The boot" is the first parallel-testing worker's. The marker does not wait
# for the others: a later worker's clone that has not booted by then is created
# or booted outside the lock, while the lock admits the next waiter's boot.
# xctest-with-launch-retry.sh runs one worker by default for this reason.
#
# Lock primitive: lockf(1) or flock(1) on a file descriptor, acquired through
# sim-boot-lock.sh, which owns the primitive and the shape of the wait. This
# shell opens FD 9 against $LOCK_FILE and the lock lands on that file
# description, which is what the rest of this script's protocol rests on: the
# kernel releases it when that descriptor closes - normal exit, SIGKILL, OOM,
# panic - and this script can drop it mid-run by closing that one descriptor.
# The wrapped command and the hook are launched with `9>&-` so neither
# inherits FD 9 and extends the lock past the explicit release.
#
# Why 9: POSIX sh redirection syntax requires a literal single digit for the FD
# position (`N>file`), so the choice is one of 3..9. 9 is the high end of the
# user range and the conventional `flock` descriptor. Bash 4.1+ supports
# `{varname}>>file` auto-allocation, but macOS ships bash 3.2 and this runs
# under `/bin/sh` without a Homebrew dependency.
#
# Cross-user: the lock path is per-uid, because the daemon contended on is
# itself per-user (sim-boot-lock.sh). That separation is about the daemon and
# not about the machine: separate users running simulators still compete for
# the host's capacity, which no lock here bounds.
#
# Mutex acquisition is HARD-required. Lock-file open failure, timeout, or any
# other failure to enter the protected window exits non-zero; there is no
# fail-open fallback, because an unprotected boot is the failure being
# prevented.
#
# Hook (XCTEST_BOOT_MUTEX_HOOK, optional): an executable run at the three points
# where the lock state matters to a caller's own bookkeeping - for example,
# recording which simulator clones this run created, which is only sound while
# no other run can be creating one:
#
#   HOOK acquired     the lock is held and the wrapped command has not started.
#                     A non-zero exit aborts the run (exit 1) without starting
#                     it.
#   HOOK releasing    the lock is still held and is about to be released,
#                     whether on the marker or at exit. Exit status is reported
#                     and otherwise ignored.
#   HOOK exited RC    the lock is released and the wrapped command has exited
#                     with RC (1 if it never started). Exit status is reported
#                     and otherwise ignored.
#
# Each call gets XCTEST_BOOT_MUTEX_PID, this wrapper's PID: the same value for
# all three calls of one run, and the process whose lifetime is the run's. A
# hook that records ownership by process keys on it rather than on its own
# parent, which is this shell only for as long as nothing sits in between.
#
# Usage: $0 xcodebuild test|test-without-building [args...]
# The caller passes the entire xcodebuild invocation (verb, flags and
# destination), so one wrapper serves every caller.

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 xcodebuild test-without-building [args...]" >&2
    exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# The lock taken here is the host's simulator boot lock, shared with every
# simulator boot under this user that does not go through xcodebuild -
# with-sim-boot-lock.sh is the other holder. The path, its per-uid scoping, and
# the acquire budget are owned by the lib so the two cannot name different
# files.
# shellcheck source=SCRIPTDIR/sim-boot-lock.sh
. "$SCRIPT_DIR/sim-boot-lock.sh"

LOCK_FILE=$(sim_boot_lock_file)
ACQUIRE_TIMEOUT_SECONDS=$(sim_boot_lock_timeout)
LOG_FILE="${RUNNER_TEMP:-/tmp}/xctest-stdout-$$.log"
MARKER="^Test [Ss]uite '.*' started"
HOOK="${XCTEST_BOOT_MUTEX_HOOK:-}"

# A hook that was asked for and cannot run is a configuration error, caught
# before the lock is taken rather than surfacing as a half-run protocol.
if [ -n "$HOOK" ] && [ ! -x "$HOOK" ]; then
    echo "::error::xctest boot mutex: XCTEST_BOOT_MUTEX_HOOK is not an executable file: $HOOK" >&2
    exit 1
fi

LOCK_HELD=0
XCBUILD_PID=""
# 1 while this shell is copying the wrapped command's log to stdout, and the
# byte offset up to which it has.
STREAMING=0
STREAM_OFFSET=0
ACQUIRE_START_EPOCH=0
ACQUIRE_END_EPOCH=0
DEFER_FILE=""

ts() { date -u +%FT%TZ; }

# Emit one of this wrapper's own diagnostic lines.
#
# While the wrapped command's log is streaming (STREAMING=1), it reaches stdout
# in whatever chunks it arrived in since the last copy, so its writes are not
# line-aligned, and a line written between two copies can land partway through
# one of xcodebuild's. That is not cosmetic: it is how an XCTest failure line
# gets cut in half and the assertion text is lost, leaving a CI failure whose
# message cannot be recovered from the job log.
#
# So while it streams, these lines wait in DEFER_FILE until `flush_deferred`
# runs after the last copy. They keep their own `$(ts)` timestamps and
# held-durations, so the ordering the deferral costs is still readable off the
# text.
wrapper_say() {
    if [ "$STREAMING" = 1 ] && [ -n "$DEFER_FILE" ]; then
        echo "$@" >>"$DEFER_FILE"
    else
        echo "$@"
    fi
}

# Drain DEFER_FILE to stdout. Called only where streaming has stopped. Safe to call when nothing was deferred
# and safe to call twice - the file is truncated as it is drained, so the EXIT
# trap cannot re-emit what the normal path already printed.
flush_deferred() {
    [ -n "$DEFER_FILE" ] && [ -s "$DEFER_FILE" ] || return 0
    cat "$DEFER_FILE"
    : >"$DEFER_FILE"
}

# Copy to stdout whatever the log gained since the last call. The size is read
# first and the copy bounded to it, so bytes that land mid-copy are left for the
# next call rather than printed twice. Called on every poll tick, and once more
# after the command has exited, when the size it reads is final: that last call
# is what makes the copy complete, where a timed settle could stop short.
stream_new() {
    _stream_size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ') || return 0
    [ -n "$_stream_size" ] && [ "$_stream_size" -gt "$STREAM_OFFSET" ] || return 0
    tail -c +"$((STREAM_OFFSET + 1))" "$LOG_FILE" | head -c "$((_stream_size - STREAM_OFFSET))"
    STREAM_OFFSET=$_stream_size
}

# Stop the wrapped command - the process this shell started, and only that one -
# and wait for it, so a directly wrapped xcodebuild cannot still be booting when
# the lock is released. TERM first, which xcodebuild answers by cancelling its
# run and its own children; KILL if it is still there after STOP_GRACE_SECONDS.
# A launcher that forks xcodebuild instead of exec'ing it is not covered: its
# child outlives it, which the README's Limits says.
STOP_GRACE_SECONDS=30
# shellcheck disable=SC2329 # called from the EXIT trap's string body
stop_command() {
    [ -n "$XCBUILD_PID" ] && kill -0 "$XCBUILD_PID" 2>/dev/null || return 0
    kill -TERM "$XCBUILD_PID" 2>/dev/null || true
    _stop_deadline=$(($(date +%s) + STOP_GRACE_SECONDS))
    while kill -0 "$XCBUILD_PID" 2>/dev/null && [ "$(date +%s)" -lt "$_stop_deadline" ]; do
        sleep 0.2
    done
    # Escalate only a command still there at the deadline. One that has gone is
    # already reaped - this shell reaps its children as they exit - and its PID
    # may belong to an unrelated process by now. The check and the KILL run back
    # to back, which leaves only a reuse inside that gap uncovered.
    if kill -0 "$XCBUILD_PID" 2>/dev/null; then
        kill -KILL "$XCBUILD_PID" 2>/dev/null || true
    fi
    # Collect its status. A trapped signal can return this early; by then the
    # command has exited or been sent SIGKILL, which it cannot outrun, so
    # nothing it started is still being driven when the lock is released.
    wait "$XCBUILD_PID" 2>/dev/null || true
}
release_lock() {
    [ "$LOCK_HELD" = "1" ] || return 0
    LOCK_HELD=0
    # Close FD 9 - the last reference to the file description from this
    # process drops, and the kernel releases the lock. The wrapped command and
    # the hook were started with `9>&-`, so they have no FD 9 and cannot extend
    # the lock past this point.
    exec 9>&-
    released_epoch=$(date +%s)
    held=$((released_epoch - ACQUIRE_END_EPOCH))
    wrapper_say "xctest boot mutex: released at $(ts) (held ${held}s)"
}

# Run the hook's `releasing` call while the lock is still held. Same
# single-writer rule as wrapper_say: the hook may print, and this runs mid-run
# while the log streams, so its output joins the deferred lines then.
#
# In a subshell because the EXIT trap reaches this: whatever runs in a subshell
# can end only the subshell, never the trap.
hook_releasing() {
    [ -n "$HOOK" ] || return 0
    _hook_rc=0
    if [ "$STREAMING" = 1 ] && [ -n "$DEFER_FILE" ]; then
        (XCTEST_BOOT_MUTEX_PID=$$ "$HOOK" releasing 9>&-) >>"$DEFER_FILE" 2>&1 || _hook_rc=$?
    else
        (XCTEST_BOOT_MUTEX_PID=$$ "$HOOK" releasing 9>&-) || _hook_rc=$?
    fi
    [ "$_hook_rc" -eq 0 ] ||
        wrapper_say "::warning::xctest boot mutex: hook releasing-call returned $_hook_rc"
}

# Inline EXIT trap (not a `cleanup()` function) so shellcheck 0.8.x's
# SC2317 does not flag the body as unreachable; trap-via-function-name
# reachability tracking requires shellcheck >=0.9.
#
# Order matters. A further signal is swallowed from here on (on_signal has
# already done the same when a signal began the exit): its handler would
# otherwise `exit` out of this trap, closing FD 9 with the command still
# running. A no-op handler rather than an ignore, because an ignored signal is
# inherited by what the trap starts next, the hook. The wrapped command is
# stopped first, so a run ended early -
# a signal, an internal error - cannot leave the command it started still
# booting once the lock is gone. Then, if the lock is still held, the hook's `releasing` call runs
# BEFORE the release, so it still sees a host no other run can be starting on.
# The rest of the log is copied before it is deleted. The `exited` call runs
# last, after the lock is gone and this wrapper's own lines are flushed. rc
# defaults to 1, so any early-exit path reads as a failure - fail-closed.
RUN_COMPLETE=0
# The EXIT trap fails a run that would exit 0 before RUN_COMPLETE=1: macOS
# /bin/sh can exit 0 after a `set -u` abort.
# shellcheck disable=SC2154  # the trap body assigns _trap_rc before it reads it
trap '
    _trap_rc=$?; [ "$RUN_COMPLETE" = 1 ] || [ "$_trap_rc" -ne 0 ] || _trap_rc=1
    trap ":" HUP INT TERM
    stop_command
    if [ "$LOCK_HELD" = "1" ]; then
        hook_releasing
        release_lock
    fi
    if [ "$STREAMING" = 1 ]; then
        stream_new
        STREAMING=0
    fi
    flush_deferred
    rm -f "$LOG_FILE" 2>/dev/null || true
    rm -f "$DEFER_FILE" 2>/dev/null || true
    if [ -n "$HOOK" ]; then
        _exited_rc=0
        (XCTEST_BOOT_MUTEX_PID=$$ "$HOOK" exited "${rc:-1}" 9>&-) || _exited_rc=$?
        [ "$_exited_rc" -eq 0 ] ||
            echo "::warning::xctest boot mutex: hook exited-call returned $_exited_rc"
    fi
    exit "$_trap_rc"
' EXIT

# A signal ends the run through the EXIT trap, which stops the wrapped command
# before it releases the lock. Without these, the shell would die on the signal
# with the lock released by the kernel and xcodebuild still booting. SIGKILL
# cannot be caught; the README says what that leaves.
#
# The handler swallows further signals before anything else, so a second one
# cannot exit out of the cleanup the first began. While the command is being
# launched (LAUNCHING=1) it does not exit at all: the exit waits until the
# command's PID is recorded, or the cleanup would not know what to stop.
LAUNCHING=0
PENDING_SIGNAL_EXIT=""
# shellcheck disable=SC2329 # called from the signal traps' string bodies
on_signal() {
    trap ":" HUP INT TERM
    if [ "$LAUNCHING" = 1 ]; then
        PENDING_SIGNAL_EXIT=$1
        return 0
    fi
    exit "$1"
}
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# An open that fails - a file under this name owned by someone else - is a HARD
# failure; the run will not proceed unprotected. Probe writability in a subshell
# so the probe's `2>/dev/null` does not leak into this shell's stderr (an
# `exec 9>>FILE 2>/dev/null` on the parent shell would permanently silence
# stderr). The real open follows on probe success.
if ! (exec 9>>"$LOCK_FILE") 2>/dev/null; then
    lock_owner=$(stat -c '%U' "$LOCK_FILE" 2>/dev/null || stat -f '%Su' "$LOCK_FILE" 2>/dev/null || echo unknown)
    echo "::error::xctest boot mutex: cannot open $LOCK_FILE for append (owner=$lock_owner, user=$(id -un)) - operator action required; see \"When acquisition fails\" in the xctest-boot-mutex README" >&2
    exit 1
fi
exec 9>>"$LOCK_FILE"

echo "xctest boot mutex: waiting for lock at $(ts) (lock=$LOCK_FILE timeout=${ACQUIRE_TIMEOUT_SECONDS}s)"
ACQUIRE_START_EPOCH=$(date +%s)
# The wait is the lib's, which owns why a waiter sleeps between attempts
# rather than letting the primitive do the waiting, and what FD mode gives
# this script's release protocol.
acquire_rc=0
sim_boot_lock_acquire_fd 9 "$ACQUIRE_TIMEOUT_SECONDS" || acquire_rc=$?
ACQUIRE_END_EPOCH=$(date +%s)
waited=$((ACQUIRE_END_EPOCH - ACQUIRE_START_EPOCH))
if [ "$acquire_rc" -eq 0 ]; then
    LOCK_HELD=1
    echo "xctest boot mutex: acquired at $(ts) (waited ${waited}s)"
elif [ "$acquire_rc" -eq 127 ]; then
    echo "::error::xctest boot mutex: neither lockf nor flock on PATH - refusing to boot a simulator unprotected" >&2
    exec 9>&-
    exit 1
elif [ "$acquire_rc" -eq 1 ]; then
    echo "::error::xctest boot mutex: acquire timed out after ${waited}s - operator action required; see \"When acquisition fails\" in the xctest-boot-mutex README" >&2
    exec 9>&-
    exit 1
else
    # Separated from the timeout because it is not one: the lock primitive
    # itself failed, so nothing about host contention is implied and the first
    # move for a timeout - find the holder - would be a hunt for a process
    # that does not exist.
    echo "::error::xctest boot mutex: the lock primitive failed (rc=$acquire_rc) after ${waited}s - operator action required; see \"When acquisition fails\" in the xctest-boot-mutex README" >&2
    exec 9>&-
    exit 1
fi

# From here on the boot mutex is held. The hook's `acquired` call and the
# wrapped command's launch run inside the protected window; the marker
# releases it so test execution can run concurrently.
if [ -n "$HOOK" ]; then
    hook_rc=0
    XCTEST_BOOT_MUTEX_PID=$$ "$HOOK" acquired 9>&- || hook_rc=$?
    if [ "$hook_rc" -ne 0 ]; then
        echo "::error::xctest boot mutex: hook acquired-call returned $hook_rc - refusing to launch the wrapped command" >&2
        exit 1
    fi
fi

# Launch the wrapped command with FD 9 explicitly closed so the kernel lock is
# not extended past release_lock. stdout/stderr are captured to LOG_FILE, which
# this shell copies to stdout as it grows. NSUnbufferedIO=YES gets each of xcodebuild's stdout
# lines into LOG_FILE as it is written. Without it that stdout, going to a
# regular file, is block-buffered: a line reaches LOG_FILE only when its buffer
# fills or xcodebuild exits, so the marker arrives late, stderr lines land
# inside half-written stdout lines, and whatever is still buffered when
# xcodebuild dies never reaches the job log.
LAUNCHING=1
NSUnbufferedIO=YES "$@" 9>&- >"$LOG_FILE" 2>&1 &
XCBUILD_PID=$!
LAUNCHING=0
[ -z "$PENDING_SIGNAL_EXIT" ] || exit "$PENDING_SIGNAL_EXIT"

# Opened BEFORE STREAMING is set, because wrapper_say routes to the buffer on
# STREAMING being 1: setting it first would leave a window whose lines go to a
# DEFER_FILE that does not exist yet. If the open fails, the variable stays
# empty and wrapper_say falls back to writing stdout directly - interleaved
# output is worse than deferred output, but either beats losing the diagnostics
# outright, and the run itself is unaffected either way.
DEFER_FILE="${RUNNER_TEMP:-/tmp}/xctest-boot-mutex-deferred-$$.log"
: >"$DEFER_FILE" 2>/dev/null || DEFER_FILE=""
STREAMING=1

# Copy the log out and poll for the marker until the command exits; run the
# hook's `releasing` call and release the lock the moment the marker appears.
# A command that exits before the marker leaves both to the code below, still
# in that order, with the EXIT trap as the fail-safe.
while kill -0 "$XCBUILD_PID" 2>/dev/null; do
    stream_new
    if [ "$LOCK_HELD" = "1" ] && [ -s "$LOG_FILE" ] && grep -Eq "$MARKER" "$LOG_FILE" 2>/dev/null; then
        wrapper_say "xctest boot mutex: first test suite started at $(ts)"
        hook_releasing
        release_lock
    fi
    sleep 0.5
done

# Capture the wrapped command's exit code; `|| rc=$?` keeps set -e from
# exiting before the log is copied out. The command has already exited.
rc=0
wait "$XCBUILD_PID" || rc=$?
XCBUILD_PID=""
# Everything the command wrote is in the log now: copy the rest, then this
# wrapper's own lines from the run, before anything below prints.
stream_new
STREAMING=0
flush_deferred

if [ "$LOCK_HELD" = "1" ]; then
    # The loop ended on process death rather than the marker. One last grep -
    # the marker may have landed between the loop's final poll (500 ms cadence)
    # and the process's exit. If it did, release late: still a kindness to the
    # next waiter. If it did not, no test suite ever started and the EXIT trap
    # releases. On a failed run that is the attempt failing before its first
    # test - a clone that never booted, a denied host-app launch, a build or
    # destination error - and the lock was held only as long as the attempt.
    # On a passing run it is output this wrapper does not recognize (see
    # Marker above), and the whole run was serialized behind the lock.
    if [ -s "$LOG_FILE" ] && grep -Eq "$MARKER" "$LOG_FILE" 2>/dev/null; then
        wrapper_say "xctest boot mutex: first test suite started (seen after exit) at $(ts)"
        hook_releasing
        release_lock
    elif [ "$rc" -eq 0 ]; then
        wrapper_say "::warning::xctest boot mutex: the wrapped command passed without printing a test-suite start line, so the lock was held for the whole run - has Xcode changed that line, or did this caller run tests serially under -quiet? See Marker in xctest-with-boot-mutex.sh"
    else
        wrapper_say "xctest boot mutex: no test suite started before the wrapped command exited (rc=$rc) - lock held for the whole attempt"
    fi
fi

[ "$rc" -eq 0 ] || exit "$rc"
RUN_COMPLETE=1
exit 0
