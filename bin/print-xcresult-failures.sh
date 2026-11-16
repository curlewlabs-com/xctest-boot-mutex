#!/bin/sh
# print-xcresult-failures.sh
#
# Surface the per-test assertion failures from an xcodebuild .xcresult bundle.
#
# `xcodebuild test ... -quiet` keeps a green run's log readable, but on failure
# it prints only "Test case '...' failed" and drops the XCTAssert/XCTFail line -
# so a red iOS run leaves no assertion text in the console or the CI job log.
# Diagnosing it otherwise means opening the .xcresult bundle in Xcode, which on
# a CI host means first getting the bundle off it. This reads the bundle
# xcodebuild already wrote and prints each failure's test id and assertion
# message (with file:line) inline at the point of failure.
#
# It also prints what the test host itself logged while each failing case ran.
# The bundle captures the host app's stdout, but the job log carries only
# xcodebuild's per-case result stream, never that output, so a branch the
# production code names in a log line is invisible to whoever reads the red
# job. Those are exactly the lines that separate one cause of a nil value from
# another, and without them the diagnosis needs access to the host that ran the
# test.
#
# Fails open at every step: a missing bundle, an unavailable xcrun/jq, an
# unreadable summary, or a host-log section this Xcode version does not emit each
# print a note (or nothing extra) and exit 0, so a diagnostic gap never masks or
# compounds the real test failure that triggered it.

set -eu

# Per failing case, so one pathological test cannot bury the assertion list that
# precedes it. Truncation is announced, never silent.
HOST_LOG_LINE_CAP=200

bundle="${1:-}"

note() {
    printf 'print-xcresult-failures: %s\n' "$1" >&2
}

if [ -z "$bundle" ] || [ ! -e "$bundle" ]; then
    note "no result bundle at '${bundle:-<unset>}' - nothing to summarize"
    exit 0
fi

if ! command -v xcrun >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    note "xcrun or jq unavailable - open the bundle in Xcode: $bundle"
    exit 0
fi

summary=$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null) || {
    note "could not read test summary - open the bundle in Xcode: $bundle"
    exit 0
}

# Normalize `testFailures` to a list before iterating: xcresulttool's --schema
# declares it as a single TestFailure ref while the runtime emits an array, so
# the shape can't be assumed stable across Xcode versions - accept either, plus
# absent/empty (a build/crash failure records no per-test assertions).
failures=$(printf '%s\n' "$summary" | jq -r '
    def as_list: if type == "array" then . else [.] end;
    (.testFailures // [] | as_list) as $list
    | if ($list | length) == 0 then
        "(no per-test assertion failures recorded - likely a build or crash failure; open the bundle in Xcode)"
    else
        $list[]
        | "[FAIL] \(.testIdentifierString // .testName // "(unknown test)")\n    \(.failureText // "(no assertion text)")\n"
    end
') || {
    note "could not parse test summary - open the bundle in Xcode: $bundle"
    exit 0
}

printf '\n-------- XCTest assertion failures --------\n%s\n-------------------------------------------\n' "$failures"

# The host's own stdout, sliced to each failing case. `--type action` is the
# section that carries it; an Xcode that stops emitting it, or a run whose host
# logged nothing, leaves `$host_log` empty and this whole block silent.
host_log=$(xcrun xcresulttool get log --path "$bundle" --type action 2>/dev/null |
    jq -r '.. | objects | .emittedOutput? // empty') || host_log=''

[ -n "$host_log" ] || exit 0

# `Class/method()` per failure; the console stream writes the same case
# `-[<TestTarget>.Class method]`, which is what the slice below anchors on.
# De-duplicated: one case can record several assertion failures (the flake this
# was written for failed two, one line apart), and they share a host-log window.
ids=$(printf '%s\n' "$summary" | jq -r '
    def as_list: if type == "array" then . else [.] end;
    [ (.testFailures // [] | as_list)[] | .testIdentifierString // empty ]
    | unique[]
') || ids=''

for id in $ids; do
    case "$id" in
    */*) ;;
    *) continue ;;
    esac
    class=${id%%/*}
    method=${id#*/}
    method=${method%\(\)}
    # Deliberately the FIRST match only: xcresulttool repeats the same emitted
    # text once per nesting level, so every window would otherwise print once
    # per level the failure sits under.
    slice=$(printf '%s\n' "$host_log" | awk \
        -v marker=".$class $method]' started" \
        -v cap="$HOST_LOG_LINE_CAP" '
        !inwin && !done && index($0, marker) { inwin = 1; next }
        inwin {
            if ($0 ~ /^Test (Case|Suite) '"'"'/) { inwin = 0; done = 1; next }
            # The assertion text is already printed above, verbatim, by name.
            if (index($0, ": error: -[") > 0) next
            if (++n > cap) { over++; next }
            print
        }
        END { if (over > 0) printf "    ... %d more line(s) suppressed (cap %d)\n", over, cap }
    ')
    [ -n "$slice" ] || continue
    printf '\n-------- host log during %s --------\n%s\n-------------------------------------------\n' \
        "$id" "$slice"
done
