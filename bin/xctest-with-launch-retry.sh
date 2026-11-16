#!/bin/sh
# Run an xcodebuild test command through the boot mutex, retrying ONLY a
# transient SpringBoard launch denial and attributing known unretried
# infrastructure exits.
#
# The retry targets this failure: on a loaded host, the test-host launch is
# denied with a SpringBoard (SBMainWorkspace) `Busy` or `NotFound` reason and
# zero test cases run. Both are treated as transient host contention from what
# the run leaves behind, not from any claim about SpringBoard's internals:
#   denied by service delegate (SBMainWorkspace) for reason: Busy
#     ("Application failed preflight checks")
#   denied by service delegate (SBMainWorkspace) for reason: NotFound
#     ("Application "<id>" is unknown to FrontBoard")
# For the NotFound case the simulator's CoreSimulator log shows the app install
# completing seconds before the denial, and no crash report for the app is
# written. Either reason yields `** TEST EXECUTE FAILED **`, xcodebuild exit 65,
# and zero test cases - the app never starts.
#
# Why retry and not a wider boot mutex: a unit-test bundle hosted in an app
# (TEST_HOST set) launches that app before XCTest runs any test case - and the
# boot mutex already holds its lock through the first parallel worker's launch.
# It releases once a test suite starts, which a denied launch never reaches
# (xctest-with-boot-mutex.sh owns that release point, and why later workers are
# outside it). The denial happens anyway: the starvation comes from host load
# the mutex does not cover - an archive build, other jobs, a hand-run on the
# same Mac - overwhelming the freshly-booted clone's SpringBoard, not from
# contention between xctest launches. Serializing xctest launches against each
# other cannot relieve that load; absorbing the transient denial can.
#
# Why an auto-retry is safe here, when retrying failures usually hides them:
# the retried signature is observably distinct from every real failure mode, so
# it cannot mask a real regression. It is either SBMainWorkspace reason string
# above with zero test cases run; each real failure leaves a different trace -
# an app crash on launch writes a crash report and carries a different
# FBSOpenApplication reason, an assertion failure prints test output, a build
# error prints a compiler diagnostic, and a code-sign or entitlement rejection
# carries its own distinct, reproducible reason. The classifier additionally
# requires that no test case ever executed, so a run that launched successfully
# is never re-run. test/xctest-launch-retry.sh pins is_transient_launch_denial:
# every real failure mode must fall through unretried. The retry is also loud
# (a ::warning:: per attempt, a distinct one when retries are exhausted) so the
# flake stays visible in the run, and the caller's own failure diagnostics
# still fire on the final, real failure.
#
# Config (env): XCTEST_LAUNCH_RETRIES (retries after the first attempt, default
# 4; set 0 to disable), XCTEST_LAUNCH_RETRY_BACKOFF (seconds between attempts,
# default 15 - lets the host-pressure spike subside before the next clone
# boots), XCTEST_PARALLEL_TESTING_WORKERS (optional positive-integer override
# of the parallel-testing width, default 1), and XCTEST_LAUNCH_EVENTS_FILE
# (optional; one line is appended per classified infrastructure event, for a
# caller that measures them).
#
# The attempt count carries this, not the backoff. An attempt is a re-run of
# the whole xcodebuild invocation, so it re-creates and re-boots the clone -
# putting far more wall clock between one launch and the next than the backoff
# adds, and nearly every denial clears on the next one. The jobs that still go
# red are the ones whose host condition outlives several of those cycles, and
# only more cycles cover that; a longer pause inside each buys a fraction of
# the same wait. Raising the count lengthens the total window as a side effect.
#
# Result bundles: a failed `xcodebuild test` still writes its -resultBundlePath,
# and xcodebuild refuses to overwrite an existing one - so between retries the
# wrapper clears the caller's -resultBundlePath (if any), or the next attempt
# would die on "Existing file at -resultBundlePath" before it ever re-attempts
# the launch. The final attempt's bundle is left in place for the caller's
# failure diagnostics (print-xcresult-failures.sh, for one).
#
# Usage: $0 xcodebuild test|test-without-building [args...]
# The full xcodebuild invocation is passed through to the boot-mutex wrapper
# with the parallel-testing width and xcodebuild's diagnostics policy appended
# (each set below), so this composes in front of any caller that would
# otherwise call the boot-mutex wrapper.

# Set by is_transient_launch_denial to the matched reason, for the caller's
# log messages. Empty when no transient denial matched.
LAUNCH_DENIAL_REASON=""
DVT_ABORT_EXIT=134

validate_parallel_testing_workers() {
    case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

# One worker: a later worker's clone can boot and launch its host app after the
# boot mutex has released and after a case has run, where neither the mutex nor
# is_transient_launch_denial covers it. A wider run trades that exposure for
# wall clock, which is the caller's call to make.
DEFAULT_PARALLEL_TESTING_WORKERS=1

resolve_parallel_testing_workers() {
    printf '%s\n' "${XCTEST_PARALLEL_TESTING_WORKERS:-$DEFAULT_PARALLEL_TESTING_WORKERS}"
}

record_width_event() {
    if [ -n "${XCTEST_LAUNCH_EVENTS_FILE:-}" ] &&
        ! printf '%s\n' "$1" >>"$XCTEST_LAUNCH_EVENTS_FILE"; then
        echo "::warning::xctest launch-retry: could not record event '$1'" >&2
    fi
}

# saw_test_case_line LOGFILE - exit 0 iff the log carries xcodebuild's per-case
# line for at least one test case, the reliable "a real test ran" signal:
# `Test case '<test>' passed on '<device>'` in parallel-testing output, which is
# what CI prints, and `Test Case '<test>' started.` in serial output. A match on
# the serial form alone does not fire on CI output. Serial output under -quiet
# prints neither.
saw_test_case_line() {
    grep -q "Test [Cc]ase '" "$1"
}

# is_transient_launch_denial LOGFILE
# Exit 0 (retry) iff the captured combined output shows a transient SpringBoard
# launch denial (Busy or NotFound) AND no test case ever executed. Exit 1 (do
# not retry - propagate the real failure) for everything else. Defined before
# any `set -e` so the unit test can source this file and exercise the classifier
# without inheriting -e; the body is -e-safe regardless (every grep is guarded).
is_transient_launch_denial() {
    _log="$1"
    LAUNCH_DENIAL_REASON=""
    [ -f "$_log" ] || return 1
    # SpringBoard (the SBMainWorkspace scene delegate) denied the launch...
    grep -q 'SBMainWorkspace' "$_log" || return 1
    # ...for `Busy` or `NotFound`, the transient host-contention reasons. Each
    # is a (reason + detail) conjunction so an unrelated mention can't match. A
    # code-sign / entitlement / missing-binary rejection carries a different,
    # reproducible reason and must NOT be retried away.
    if grep -q 'for reason: Busy' "$_log" && grep -q 'Application failed preflight checks' "$_log"; then
        LAUNCH_DENIAL_REASON='Busy ("Application failed preflight checks")'
    elif grep -q 'for reason: NotFound' "$_log" && grep -q 'unknown to FrontBoard' "$_log"; then
        LAUNCH_DENIAL_REASON='NotFound ("unknown to FrontBoard")'
    else
        return 1
    fi
    # ...and no test case ever executed (saw_test_case_line). The bare
    # "Testing started" orchestration marker is NOT reliable: xcodebuild emits
    # it before the launch outcome is known, so it appears even when the launch
    # failed and zero tests ran.
    # Keying on "Testing started" here silently disabled the retry for every
    # real-world failure (the marker is always present). If a test case ran, a
    # later failure is not this flake and retrying could mask an in-test failure.
    if saw_test_case_line "$_log"; then
        LAUNCH_DENIAL_REASON=""
        return 1
    fi
    return 0
}

# saw_springboard_launch_denial LOGFILE - exit 0 iff the log shows a SpringBoard
# scene-delegate launch denial of any reason. Used only to decide whether to
# emit the "saw a denial but did not retry" breadcrumb on the no-retry path.
saw_springboard_launch_denial() {
    grep -q 'denied by service delegate (SBMainWorkspace)' "$1"
}

# is_dvt_launch_session_abort LOGFILE EXIT_CODE
# Exit 0 only for the DVT simulator assertion that aborts xcodebuild when its
# application-install path has no launch session. This is attribution, not a
# retry decision: the caller always propagates the original exit and preserves
# its failure diagnostics.
is_dvt_launch_session_abort() {
    _log="$1"
    _exit_code="$2"
    [ "$_exit_code" = "$DVT_ABORT_EXIT" ] || return 1
    [ -f "$_log" ] || return 1
    grep -q \
        'DVTAssertions: ASSERTION FAILURE in DVTiOSFrameworks/IDEiOSSupportCore/DVTiPhoneSimulator.m:' \
        "$_log" || return 1
    grep -q 'Details:  (launchSession) should not be nil.' "$_log" || return 1
    grep -q 'Method:   -installApplicationWithLaunchSession:error:' "$_log" || return 1
    return 0
}

# run_once LOGFILE COMMAND... - run the boot-mutex'd command once, teeing the
# combined output to LOGFILE (for the post-hoc signature check) while still
# streaming it live to this process's stdout (CI/terminal log). Sets the global
# RUN_RC to the wrapped command's exit code - NOT tee's.
run_once() {
    _runlog="$1"
    shift
    _rc_file="${_runlog}.rc"
    # set +e around the pipeline: the wrapped command runs on the left of a
    # pipe (its own subshell, which inherits -e). Under -e a non-zero exit
    # there short-circuits the subshell before `echo $?` records the code, and
    # we need that exact code to decide retry-vs-propagate. The brace group's
    # stdout is the only channel out of the subshell, so the code is smuggled
    # via $_rc_file, not a variable.
    set +e
    {
        "$BOOT_MUTEX" "$@"
        echo $? >"$_rc_file"
    } 2>&1 | tee "$_runlog"
    set -e
    RUN_RC=$(cat "$_rc_file" 2>/dev/null || echo 1)
    rm -f "$_rc_file"
}

cleanup() {
    rm -f "$TMP_BASE"/xctest-launch-retry-"$$"-*.log \
        "$TMP_BASE"/xctest-launch-retry-"$$"-*.log.rc 2>/dev/null || true
}

# Sourced by the unit test to reach the classifier without running the retry
# loop. No effect on direct execution (the variable is unset there). `return`
# stops here when sourced; the `|| exit 0` only matters on the executed-with-
# var-set path, which shellcheck's static reachability cannot model (SC2317).
if [ "${XCTEST_LAUNCH_RETRY_SOURCE_ONLY:-}" = "1" ]; then
    # shellcheck disable=SC2317  # exit reachable only when executed, not sourced
    return 0 2>/dev/null || exit 0
fi

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 xcodebuild test|test-without-building [args...]" >&2
    exit 2
fi

BOOT_MUTEX="$(dirname "$0")/xctest-with-boot-mutex.sh"
if [ ! -x "$BOOT_MUTEX" ]; then
    echo "::error::xctest launch-retry: boot-mutex wrapper not found or not executable at $BOOT_MUTEX" >&2
    exit 1
fi

MAX_RETRIES="${XCTEST_LAUNCH_RETRIES:-4}"
BACKOFF_SECONDS="${XCTEST_LAUNCH_RETRY_BACKOFF:-15}"
TMP_BASE="${RUNNER_TEMP:-/tmp}"
ATTEMPTS_TOTAL=$((MAX_RETRIES + 1))
PARALLEL_TESTING_WORKERS=$(resolve_parallel_testing_workers)
if ! validate_parallel_testing_workers "$PARALLEL_TESTING_WORKERS"; then
    echo "::error::XCTEST_PARALLEL_TESTING_WORKERS must be a positive integer; got '$PARALLEL_TESTING_WORKERS'" >&2
    exit 2
fi
set -- "$@" -parallel-testing-worker-count "$PARALLEL_TESTING_WORKERS"
# Off for every caller: xcodebuild's verbose post-test diagnostics copy the
# host's whole CoreSimulator log into the result bundle, and on a long-lived
# host that log grows until CoreSimulatorService next restarts. On a contended
# host the copy outlives xcodebuild's fixed wait for it, and xcodebuild then
# traps saving a bundle the collector is still writing into - after every case
# has passed. What triage reads from the bundle (per-runner output, assertion
# failures, crash logs) is recorded without this collection.
set -- "$@" -collect-test-diagnostics never

# The caller's -resultBundlePath value, if it passes one - not every caller
# does. The retry loop clears this path between attempts - see the "Result
# bundles" note in the header. The two-token form (`-resultBundlePath <path>`)
# is the only one xcodebuild accepts and every caller uses, so scan argv for
# the token and take the next element.
RESULT_BUNDLE=""
_prev=""
for _arg in "$@"; do
    if [ "$_prev" = "-resultBundlePath" ]; then
        RESULT_BUNDLE="$_arg"
        break
    fi
    _prev="$_arg"
done

RUN_COMPLETE=0
# The EXIT trap fails a run that would exit 0 before RUN_COMPLETE=1: macOS
# /bin/sh can exit 0 after a `set -u` abort.
# shellcheck disable=SC2154  # the trap body assigns _trap_rc before it reads it
trap '_trap_rc=$?; [ "$RUN_COMPLETE" = 1 ] || [ "$_trap_rc" -ne 0 ] || _trap_rc=1; cleanup; exit "$_trap_rc"' EXIT

attempt=1
while :; do
    LOG="$TMP_BASE/xctest-launch-retry-$$-$attempt.log"
    run_once "$LOG" "$@"
    rc="$RUN_RC"

    if [ "$rc" -eq 0 ]; then
        # A passing run with no per-case line leaves the zero-tests guard
        # nothing to read in this caller's output, so a denial after real test
        # work would be retried as the flake. Say so on the green run, before a
        # denial depends on it: a guard key that stopped matching xcodebuild's
        # output surfaces here first.
        if ! saw_test_case_line "$LOG"; then
            echo "::warning::xctest launch-retry: the wrapped command passed without printing a per-case test line, so the zero-tests guard cannot see a test run in this caller's output and would retry a SpringBoard denial that followed real test work - has Xcode changed that line, or did this caller run tests serially under -quiet? See saw_test_case_line in xctest-with-launch-retry.sh" >&2
        fi
        rm -f "$LOG"
        RUN_COMPLETE=1
        exit 0
    fi

    if is_transient_launch_denial "$LOG"; then
        record_width_event "springboard-launch-denial:$LAUNCH_DENIAL_REASON"
        if [ "$attempt" -lt "$ATTEMPTS_TOTAL" ]; then
            echo "::warning::xctest launch-retry: attempt $attempt/$ATTEMPTS_TOTAL hit a transient SpringBoard launch denial (reason $LAUNCH_DENIAL_REASON) with zero tests run - retrying after ${BACKOFF_SECONDS}s." >&2
            rm -f "$LOG"
            # Clear the failed attempt's result bundle so the retry's xcodebuild
            # can recreate it (it refuses to overwrite an existing one). Only on
            # the retry path, never after the final attempt - the real failure's
            # bundle must survive for the caller's diagnostics.
            [ -z "$RESULT_BUNDLE" ] || rm -rf "$RESULT_BUNDLE"
            attempt=$((attempt + 1))
            sleep "$BACKOFF_SECONDS"
            continue
        fi
        # Exhausted: the transient denial persisted across every attempt. That
        # is no longer "a transient spike" - the host is under sustained
        # contention or a deeper simulator problem. Surface it distinctly and
        # propagate the real failure so the caller's diagnostics capture runs.
        echo "::warning::xctest launch-retry: SpringBoard launch denial (reason $LAUNCH_DENIAL_REASON) persisted across all $ATTEMPTS_TOTAL attempts - host contention or simulator state may be the cause." >&2
        rm -f "$LOG"
        [ "$rc" -eq 0 ] || exit "$rc"
        RUN_COMPLETE=1
        exit 0
    fi

    # Not a recognized transient launch denial - a real failure (assertion,
    # in-test crash, build error, a non-transient denial reason, or a boot-mutex
    # hard-failure). Propagate the exact exit code immediately, unretried.
    #
    # Diagnostics breadcrumb: if a SpringBoard launch denial is nonetheless
    # present, say so loudly. A launch denial that reaches here is either
    # genuinely real (a test ran, a crash, a reproducible non-transient reason)
    # or a NEW transient infra variant the classifier doesn't yet recognize -
    # make that visible from the run instead of a silent propagate, so the next
    # variant is diagnosed from the log, not from on-host spelunking.
    if is_dvt_launch_session_abort "$LOG" "$rc"; then
        record_width_event "dvt-launch-session-abort"
        echo "::error title=Xcode simulator infrastructure failure::xcodebuild aborted because DVTiPhoneSimulator had no launchSession; not retried. The original output is above and caller diagnostics remain enabled." >&2
    elif saw_springboard_launch_denial "$LOG"; then
        echo "::warning::xctest launch-retry: a SpringBoard launch denial was present but did not match a known transient signature (Busy/NotFound with zero tests run) - not retried. If this is a new transient infra variant, extend is_transient_launch_denial in xctest-with-launch-retry.sh." >&2
    fi
    rm -f "$LOG"
    [ "$rc" -eq 0 ] || exit "$rc"
    RUN_COMPLETE=1
    exit 0
done
