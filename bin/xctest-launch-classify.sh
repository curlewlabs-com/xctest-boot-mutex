#!/bin/sh
# The launch retry's classifiers: which failed `xcodebuild test` runs are the
# transient SpringBoard launch denial it retries, which are the DVT abort it
# only attributes, and the parallel-testing width it passes on. Sourced, never
# run, by xctest-with-launch-retry.sh beside it, and by its suite, so the suite
# exercises the real functions rather than a copy.
# shellcheck disable=SC2034 # LAUNCH_DENIAL_REASON is read by the sourcing script

# Set by is_transient_launch_denial to the matched reason, for the caller's
# log messages. Empty when no transient denial matched.
LAUNCH_DENIAL_REASON=""
LAUNCH_DENIAL_EXIT=65
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

# saw_test_case_line LOGFILE - exit 0 iff the log carries xcodebuild's per-case
# line for at least one test case, the reliable "a real test ran" signal:
# `Test case '<test>' passed on '<device>'` in parallel-testing output, which is
# what CI prints, and `Test Case '<test>' started.` in serial output. A match on
# the serial form alone does not fire on CI output. Serial output under -quiet
# prints neither.
saw_test_case_line() {
    grep -q "Test [Cc]ase '" "$1"
}

# is_transient_launch_denial LOGFILE EXIT_CODE
# Exit 0 (retry) iff xcodebuild exited with the denial's own status, the
# captured combined output shows a transient SpringBoard launch denial (Busy or
# NotFound), AND no test case ever executed. Exit 1 (do not retry - propagate
# the real failure) for everything else. Every grep is guarded, so the body is
# -e-safe in a caller that sets it.
is_transient_launch_denial() {
    _log="$1"
    LAUNCH_DENIAL_REASON=""
    # A denied launch ends `** TEST EXECUTE FAILED **` with exit 65. Any other
    # status - the DVT abort's 134, a crash, a signal - is a different failure
    # that merely also printed a denial, and keeps its own attribution.
    [ "$2" = "$LAUNCH_DENIAL_EXIT" ] || return 1
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
