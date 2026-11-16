#!/bin/sh
# Tests for bin/xctest-with-launch-retry.sh's failure classifiers.
#
# This classifier is the safety-critical piece: it decides whether a failed
# `xcodebuild test` is retried. The invariant that keeps a retry from masking
# a regression is "every real failure mode falls through unretried" - only a transient SpringBoard launch
# denial (reason Busy or NotFound), with zero test cases run, may be retried.
# These tests feed representative captured-log fixtures and assert the
# retry/no-retry decision, so a future edit that loosens the signature (and
# would start retrying - and masking - real failures) fails here.
# The DVT classifier only labels an already-unretried exit, but still requires
# its complete signature so an unrelated abort keeps its original attribution.
#
# Regressions these fixtures specifically guard, in the "did a real test run?"
# check:
# - It must key on a per-case result line, NOT the bare "Testing started"
#   marker. xcodebuild emits "Testing started" before the launch outcome is
#   known, so that marker is present on every real-world launch failure, as is
#   the boot-mutex wrapper's own report that no test suite started. Keying on
#   "Testing started" silently disabled the retry in practice (see the
#   "markers present, zero tests" fixtures below).
# - It must match that line as parallel testing prints it,
#   `Test case '<test>' passed on '<device>'`, which is what CI runs print. A
#   match on the serial `Test Case '...'` form alone does not fire on CI output,
#   so it retries a denial after real test work as the zero-tests flake (see
#   the "parallel-testing case" fixtures below).
#
# The classifier is reached by sourcing the wrapper with the source-only guard
# set, so we exercise the real function, not a copy.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/xctest-with-launch-retry.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "ERROR: $SCRIPT not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
XCTEST_LAUNCH_RETRY_SOURCE_ONLY=1 . "$SCRIPT"

PASSED=0
FAILED=0

for value in 1 2 17; do
    if ! validate_parallel_testing_workers "$value"; then
        echo "FAIL: positive parallel-testing width '$value' was rejected"
        FAILED=$((FAILED + 1))
    else
        PASSED=$((PASSED + 1))
    fi
done
for value in '' 0 00 -1 1.5 two '2 '; do
    if validate_parallel_testing_workers "$value"; then
        echo "FAIL: invalid parallel-testing width '$value' was accepted"
        FAILED=$((FAILED + 1))
    else
        PASSED=$((PASSED + 1))
    fi
done

if [ "$(XCTEST_PARALLEL_TESTING_WORKERS=3 resolve_parallel_testing_workers)" = "3" ]; then
    PASSED=$((PASSED + 1))
else
    echo "FAIL: explicit worker width did not override the default"
    FAILED=$((FAILED + 1))
fi

# assert_decision <expected: retry|no-retry> <label> <log-content>
assert_decision() {
    expected="$1"
    label="$2"
    content="$3"
    f=$(mktemp /tmp/xctest-launch-retry-fixture.XXXXXX)
    printf '%s\n' "$content" >"$f"
    if is_transient_launch_denial "$f"; then
        actual=retry
    else
        actual=no-retry
    fi
    rm -f "$f"
    if [ "$actual" = "$expected" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $label - expected $expected, got $actual"
    fi
}

# assert_dvt_decision <expected: infrastructure|other> <label> <rc> <log-content>
assert_dvt_decision() {
    expected="$1"
    label="$2"
    rc="$3"
    content="$4"
    f=$(mktemp /tmp/xctest-dvt-abort-fixture.XXXXXX)
    printf '%s\n' "$content" >"$f"
    if is_dvt_launch_session_abort "$f" "$rc"; then
        actual=infrastructure
    else
        actual=other
    fi
    rm -f "$f"
    if [ "$actual" = "$expected" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $label - expected $expected, got $actual"
    fi
}

# The transient Busy preflight denial, no test ever ran. RETRY.
assert_decision retry "transient SBMainWorkspace Busy preflight, zero tests" \
    "Testing failed:
	Simulator device failed to launch com.example.app.
	The request to open \"com.example.app\" failed. (FBSOpenApplicationServiceErrorDomain Code=1)
	The operation couldn't be completed. Application failed preflight checks (FBSOpenApplicationErrorDomain Code=6)
	denied by service delegate (SBMainWorkspace) for reason: Busy (\"Application failed preflight checks\")
** TEST EXECUTE FAILED **"

# REGRESSION GUARD (Busy): the real CI log always contains "Testing started"
# (xcodebuild orchestration) AND the boot-mutex wrapper's own report that no
# test suite started - yet zero test cases ran. The old classifier keyed on
# "Testing started" and so refused to retry every real-world Busy failure.
# RETRY: the markers are present but no per-case line.
assert_decision retry "Busy denial with Testing-started markers but zero test cases" \
    "Testing started
IDETestOperationsObserverDebug: 35.0 elapsed -- Testing started completed.
	denied by service delegate (SBMainWorkspace) for reason: Busy (\"Application failed preflight checks\")
	Runner encountered an error (Failed to install or launch the test runner.
** TEST EXECUTE FAILED **
xctest boot mutex: no test suite started before the wrapped command exited (rc=65) - lock held for the whole attempt"

# REGRESSION GUARD (NotFound): the log carries the NotFound reason string
# ("unknown to FrontBoard" - a different transient reason than Busy), the
# markers are present, and zero test cases ran. RETRY - same launch race.
assert_decision retry "NotFound unknown-to-FrontBoard with markers, zero test cases" \
    "Testing started
	Simulator device failed to launch com.example.app.
	denied by service delegate (SBMainWorkspace) for reason: NotFound (\"Application \"com.example.app\" is unknown to FrontBoard\").
	Runner encountered an error (Failed to install or launch the test runner.
** TEST EXECUTE FAILED **
xctest boot mutex: no test suite started before the wrapped command exited (rc=65) - lock held for the whole attempt"

# A real test assertion failure - no launch-denial signature at all. NO RETRY:
# retrying would re-run a genuine regression and hide it.
assert_decision no-retry "real assertion failure" \
    "Test Suite 'RunnerTests.xctest' started
Testing started
Test Case '-[WidgetStateTests testExpiry]' started.
/Users/runner/work/.../WidgetStateTests.swift:42: error: -[WidgetStateTests testExpiry] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")
Test Case '-[WidgetStateTests testExpiry]' failed (0.012 seconds).
** TEST FAILED **"

# Busy strings present, but a real test case executed (the host launched, a
# later Busy occurred). NO RETRY - the run executed real test work; retrying
# could mask an in-test failure. This is the case the per-case guard correctly
# distinguishes from the "markers but zero test cases" fixture above.
assert_decision no-retry "Busy strings present but a real Test Case ran" \
    "Testing started
denied by service delegate (SBMainWorkspace) for reason: Busy (\"Application failed preflight checks\")
Test Case '-[FooTests testBar]' failed."

# NotFound denial but a real test case executed. NO RETRY - same reasoning: a
# launch denial after real test work is not the zero-tests launch race.
assert_decision no-retry "NotFound denial but a real Test Case ran" \
    "denied by service delegate (SBMainWorkspace) for reason: NotFound (\"Application \"x\" is unknown to FrontBoard\").
Test Case '-[FooTests testBar]' started.
Test Case '-[FooTests testBar]' passed (0.1 seconds)."

# The cases above as CI prints them: parallel testing reports each case as
# `Test case '<test>' passed on '<device>'`, lowercase "case". The suite and case
# lines are copied from a CI xctest log. NO RETRY - keyed on the serial form
# alone, the classifier retried each of these as the zero-tests flake.
parallel_case_ran="Testing started
Test suite 'UploadQueueTests' started on 'Clone 1 of iPhone 16 - App (41973)'
Test case 'UploadQueueTests.testALostWriteIsRetried()' passed on 'Clone 1 of iPhone 16 - App (41973)' (0.016 seconds)"
assert_decision no-retry "Busy denial after a parallel-testing case passed" \
    "$parallel_case_ran
	denied by service delegate (SBMainWorkspace) for reason: Busy (\"Application failed preflight checks\")
** TEST EXECUTE FAILED **"
assert_decision no-retry "NotFound denial after a parallel-testing case passed" \
    "$parallel_case_ran
	denied by service delegate (SBMainWorkspace) for reason: NotFound (\"Application \"com.example.app\" is unknown to FrontBoard\").
** TEST EXECUTE FAILED **"

# A NotFound denial WITHOUT the "unknown to FrontBoard" detail - a different
# NotFound condition, not the launch race identified by that detail. NO RETRY:
# require the full (reason + detail) conjunction.
assert_decision no-retry "NotFound reason without unknown-to-FrontBoard detail" \
    "denied by service delegate (SBMainWorkspace) for reason: NotFound (\"some other resource\")
** TEST EXECUTE FAILED **"

# A preflight rejection with a DIFFERENT reason (code-sign / entitlement), not
# Busy or NotFound. NO RETRY - that is reproducible, not a transient host spike.
assert_decision no-retry "non-transient preflight rejection (entitlements)" \
    "The operation couldn't be completed. Application failed preflight checks (FBSOpenApplicationErrorDomain Code=6)
denied by service delegate (SBMainWorkspace) for reason: Invalid (\"Failed to verify code signature\")
** TEST EXECUTE FAILED **"

# The host app CRASHED on launch - a backtrace/signal, not a SpringBoard
# denial. NO RETRY - a launch crash is a real defect.
assert_decision no-retry "app crash on launch (not a SpringBoard denial)" \
    "Testing failed:
	com.example.app crashed in Runner
	Exception Type: EXC_BAD_ACCESS (SIGSEGV)
** TEST EXECUTE FAILED **"

# DVT aborted its simulator application-install path after losing the launch
# session. INFRASTRUCTURE attribution, but the wrapper still does not retry it.
dvt_abort_log="2026-09-11 00:50:16.457 xcodebuild[76898:188806205] DVTAssertions: ASSERTION FAILURE in DVTiOSFrameworks/IDEiOSSupportCore/DVTiPhoneSimulator.m:1883
Details:  (launchSession) should not be nil.
Method:   -installApplicationWithLaunchSession:error:"
assert_dvt_decision infrastructure "DVT launchSession assertion abort" \
    "$DVT_ABORT_EXIT" "$dvt_abort_log"
assert_decision no-retry "DVT launchSession assertion remains unretried" \
    "$dvt_abort_log"

# Each component is required. A different exit or a partial assertion retains
# its ordinary failure attribution rather than inheriting this incident's name.
assert_dvt_decision other "DVT launchSession assertion without abort exit" \
    65 "$dvt_abort_log"
assert_dvt_decision other "abort without DVT assertion location" \
    "$DVT_ABORT_EXIT" "Details:  (launchSession) should not be nil.
Method:   -installApplicationWithLaunchSession:error:"
assert_dvt_decision other "DVT abort without nil launchSession detail" \
    "$DVT_ABORT_EXIT" "DVTAssertions: ASSERTION FAILURE in DVTiOSFrameworks/IDEiOSSupportCore/DVTiPhoneSimulator.m:1883
Method:   -installApplicationWithLaunchSession:error:"
assert_dvt_decision other "DVT abort without install method" \
    "$DVT_ABORT_EXIT" "DVTAssertions: ASSERTION FAILURE in DVTiOSFrameworks/IDEiOSSupportCore/DVTiPhoneSimulator.m:1883
Details:  (launchSession) should not be nil."

# A boot-mutex hard failure (acquire timeout) - operator-action-required, no
# SpringBoard strings. NO RETRY - must surface, not be absorbed.
assert_decision no-retry "boot-mutex acquire timeout (hard failure)" \
    "::error::xctest boot mutex: acquire timed out after 600s - operator action required; see \"When acquisition fails\" in the xctest-boot-mutex README"

# A build error from a direct caller that builds before running tests.
# NO RETRY.
assert_decision no-retry "build/compile error" \
    "/Users/runner/work/.../AppDelegate.swift:10:5: error: cannot find 'foo' in scope
** BUILD FAILED **"

# Partial signature - SBMainWorkspace + Busy present but it is NOT a preflight
# launch denial (no 'Application failed preflight checks'). NO RETRY: require
# the full conjunction so an unrelated 'Busy' mention can't trigger a retry.
assert_decision no-retry "partial signature without preflight phrase" \
    "some unrelated line mentioning SBMainWorkspace and the word Busy"

# A clean pass would never reach the classifier (rc 0 short-circuits), but guard
# the empty/clean-log case anyway. NO RETRY.
assert_decision no-retry "clean log, no signature" \
    "Testing started
Test Suite 'All tests' passed
** TEST SUCCEEDED **"

echo ""
echo "xctest-launch-retry classifier: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
