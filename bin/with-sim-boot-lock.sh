#!/bin/sh
# Run a command while holding the host's simulator boot lock.
#
# For simulator work expressible as a discrete, bounded command - a template
# shutdown and clone, a boot and its bootstatus. xcodebuild callers use
# xctest-with-boot-mutex.sh instead: it takes the same lock (sim-boot-lock.sh
# owns the path) but releases partway through the wrapped command, on
# xcodebuild's own progress line, which is the only way to serialize the boot
# phase of a command that also runs the tests.
#
# Pass the whole boot sequence as one invocation rather than taking the lock
# per simctl call: `simctl boot` returns before the guest's simulated launchd is
# up, so releasing between `boot` and `bootstatus` would let a peer start
# booting into exactly the startup overlap this lock exists to serialize.
#
# Acquisition is HARD-required, matching the xctest wrapper: failing to enter
# the protected window exits non-zero rather than booting unprotected, since an
# unprotected boot is the failure being prevented and it surfaces later as an
# unattributable `(ipc/mig) server died`.
#
# The wrapper adds no bound to the hold. Boot commands normally clear in
# seconds; a `bootstatus` that wedges instead holds the lock until something
# kills it, and waiters fail at their budget rather than hanging. A command that
# can legitimately take longer derives its own bound from the
# SIM_BOOT_ACQUIRE_TIMEOUT this wrapper exports. Wrapping a build, install,
# test, or sampling loop widens the window beyond the shared budget and makes
# every waiter on the host fail; lock the clone and boot, not the work after it.
#
# Usage: $0 command [args...]

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 command [args...]" >&2
    exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=SCRIPTDIR/sim-boot-lock.sh
. "$SCRIPT_DIR/sim-boot-lock.sh"

LOCK_FILE=$(sim_boot_lock_file)
ACQUIRE_TIMEOUT_SECONDS=$(sim_boot_lock_timeout)
# The resolved budget is part of the wrapped command's contract: a command that
# can legitimately outlive peer waiters must derive a shorter internal bound.
SIM_BOOT_ACQUIRE_TIMEOUT=$ACQUIRE_TIMEOUT_SECONDS
export SIM_BOOT_ACQUIRE_TIMEOUT

ts() { date -u +%FT%TZ; }

# Written by the inner shell once the lock is held, and read afterwards to
# tell "never acquired" from "acquired, and the wrapped command failed".
# Each exits non-zero, but only the first is an operator event, and the lock
# primitives report their own timeout with an exit status the wrapped command
# could equally have produced.
STAMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sim-boot-lock-acquired-$$"
rm -f "$STAMP"
RUN_COMPLETE=0
# The EXIT trap fails a run that would exit 0 before RUN_COMPLETE=1: macOS
# /bin/sh can exit 0 after a `set -u` abort.
# shellcheck disable=SC2154  # the trap body assigns _trap_rc before it reads it
trap '_trap_rc=$?; [ "$RUN_COMPLETE" = 1 ] || [ "$_trap_rc" -ne 0 ] || _trap_rc=1; rm -f "$STAMP" 2>/dev/null || true; exit "$_trap_rc"' EXIT

# The wrapped command runs from the inner shell via `exec`, so it replaces
# that shell rather than running as its child - nothing is left holding a
# descriptor the lock primitive did not intend to hand over, and the wrapped
# command's exit status is the inner shell's.
# shellcheck disable=SC2016 # Single-quoted deliberately: this is the inner
# shell's source text, and $1/$@ must be its positional parameters at run
# time, not this shell's at definition time.
INNER='date +%s >"$1"; shift; exec "$@"'

echo "sim boot lock: waiting for lock at $(ts) (lock=$LOCK_FILE timeout=${ACQUIRE_TIMEOUT_SECONDS}s)"
START_EPOCH=$(date +%s)

# flock and lockf each close the lock descriptor in the forked child before it
# execs, so the wrapped command cannot hold the lock past this script - for
# flock that is what `-o` buys, and macOS lockf does it unconditionally.
#
# The probe is the OS detection: macOS has lockf, Linux has flock.
rc=0
if command -v lockf >/dev/null 2>&1; then
    # -k keeps the lock file. Without it lockf UNLINKS the file on release,
    # and the xctest wrapper - which holds this lock on a long-lived
    # descriptor against the old inode - would go on holding a lock nobody
    # else can see, while the next acquirer creates a fresh inode and takes
    # it immediately. That splits the mutex silently, in the one direction
    # nothing downstream would catch.
    lockf -s -t "$ACQUIRE_TIMEOUT_SECONDS" -k "$LOCK_FILE" \
        sh -c "$INNER" sh "$STAMP" "$@" || rc=$?
elif command -v flock >/dev/null 2>&1; then
    # flock never unlinks its lock file, so it needs no -k counterpart.
    flock -o -x -w "$ACQUIRE_TIMEOUT_SECONDS" "$LOCK_FILE" \
        sh -c "$INNER" sh "$STAMP" "$@" || rc=$?
else
    echo "::error::sim boot lock: neither lockf nor flock on PATH - refusing to boot a simulator unprotected" >&2
    exit 1
fi

if [ ! -s "$STAMP" ]; then
    waited=$(($(date +%s) - START_EPOCH))
    echo "::error::sim boot lock: acquire failed after ${waited}s (lock=$LOCK_FILE) - operator action required; see \"When acquisition fails\" in the xctest-boot-mutex README" >&2
    exit 1
fi

ACQUIRED_EPOCH=$(cat "$STAMP")
echo "sim boot lock: released at $(ts) (waited $((ACQUIRED_EPOCH - START_EPOCH))s, held $(($(date +%s) - ACQUIRED_EPOCH))s)"

[ "$rc" -eq 0 ] || exit "$rc"
RUN_COMPLETE=1
exit 0
