#!/bin/sh
# Tests for bin/xctest-with-launch-retry.sh's retry loop, run through the
# executable, the real boot mutex and a real lock. A fake xcodebuild stands in
# for the real one: per attempt it is denied the launch, fails a test, or
# passes, as each case scripts it, and it refuses an existing result bundle as
# xcodebuild does.
#
# The properties, and the failure each one guards:
#   1. A denial that clears is retried until a pass, and the run is green. The
#      retry is the point; without it the denial is a red that means nothing.
#   2. A denial that persists stops at the retry budget and keeps the exit
#      status and the last attempt's result bundle. An unbounded loop holds
#      the job until its timeout, and a deleted bundle loses the only record
#      of the failure.
#   3. Between attempts the previous bundle is cleared. Left in place, the next
#      attempt dies on "Existing file at -resultBundlePath" before it can
#      launch, and the retry never gets a real second try.
#   4. A real test failure is not retried. A retry there would re-run a
#      regression until it happened to pass.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/xctest-with-launch-retry.sh"

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/xctest-launch-retry-loop-test.XXXXXX")
SUITE_COMPLETE=0
trap 'rm -rf "$TEST_TMPDIR" || echo "WARN: cleanup failed (test result unaffected): $TEST_TMPDIR" >&2; [ "$SUITE_COMPLETE" = 1 ] || exit 1' EXIT

# The lock lives in TMPDIR, so pointing TMPDIR here moves it. The retries and
# their backoff are the wrapper's own, so the persisting case below waits out
# the full budget.
TMPDIR="$TEST_TMPDIR"
RUNNER_TEMP="$TEST_TMPDIR"
export TMPDIR RUNNER_TEMP

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

# The fake reads FAKE_PLAN, one word per attempt (deny, fail or pass; the last
# word repeats), and counts its attempts in FAKE_COUNT.
FAKE="$TEST_TMPDIR/fake-xcodebuild"
cat >"$FAKE" <<'FAKE'
#!/bin/sh
count=$(($(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1))
echo "$count" >"$FAKE_COUNT"
bundle=""
previous=""
for arg in "$@"; do
    [ "$previous" != "-resultBundlePath" ] || bundle=$arg
    previous=$arg
done
if [ -n "$bundle" ] && [ -e "$bundle" ]; then
    echo "Existing file at -resultBundlePath \"$bundle\""
    exit 64
fi
[ -z "$bundle" ] || mkdir -p "$bundle"
# shellcheck disable=SC2086 # The plan is a word list.
set -- $FAKE_PLAN
step=$1
while [ "$count" -gt 1 ] && [ "$#" -gt 1 ]; do
    shift
    step=$1
    count=$((count - 1))
done
echo "Testing started"
case "$step" in
deny)
    echo "denied by service delegate (SBMainWorkspace) for reason: Busy (\"Application failed preflight checks\")"
    echo "** TEST EXECUTE FAILED **"
    exit 65
    ;;
fail)
    echo "Test suite 'ATests' started on 'Clone 1 of iPhone'"
    echo "Test case 'ATests.testB()' failed on 'Clone 1 of iPhone' (0.1 seconds)"
    echo "** TEST FAILED **"
    exit 65
    ;;
*)
    echo "Test suite 'ATests' started on 'Clone 1 of iPhone'"
    echo "Test case 'ATests.testB()' passed on 'Clone 1 of iPhone' (0.1 seconds)"
    exit 0
    ;;
esac
FAKE
chmod +x "$FAKE"

# Run the wrapper once; prints "<exit status> <attempts>".
run_case() {
    FAKE_PLAN=$1
    FAKE_COUNT="$TEST_TMPDIR/count-$2"
    export FAKE_PLAN FAKE_COUNT
    _rc=0
    "$SCRIPT" "$FAKE" test -resultBundlePath "$TEST_TMPDIR/$2.xcresult" \
        >"$TEST_TMPDIR/$2.out" 2>&1 || _rc=$?
    echo "$_rc $(cat "$FAKE_COUNT")"
}

# 1 + 3. Two denials, then a pass: the cleared bundle lets each retry launch.
check_eq "denial that clears" "0 3" "$(run_case "deny deny pass" clears)"

# 2. Denied every time: the first attempt and its four retries, then the real
# status.
check_eq "denial that persists" "65 5" "$(run_case "deny" persists)"
if [ -d "$TEST_TMPDIR/persists.xcresult" ]; then
    pass
else
    fail "the last attempt's result bundle was deleted"
fi

# 4. A failing test: one attempt, its own status.
check_eq "real test failure" "65 1" "$(run_case "fail" real)"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "FAIL - $FAIL assertions failed, $PASS passed" >&2
    for out in "$TEST_TMPDIR"/*.out; do
        echo "--- $out" >&2
        cat "$out" >&2
    done
    exit 1
fi
echo "OK - $PASS assertions passed"
SUITE_COMPLETE=1
