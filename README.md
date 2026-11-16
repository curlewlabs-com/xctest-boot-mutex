# xctest-boot-mutex

## What it is

POSIX shell scripts that let several CI runners on one Mac run
`xcodebuild test` against iOS simulators at the same time without taking down
CoreSimulatorService:

- `bin/xctest-with-boot-mutex.sh` runs an `xcodebuild test` command under a
  host-level lock. It takes the lock before xcodebuild starts and releases it
  when xcodebuild reports the first test suite starting. Simulator boots happen
  one at a time; test execution still runs in parallel.
- `bin/with-sim-boot-lock.sh` holds the same lock around any other simulator
  command, such as an `xcrun simctl boot` followed by `bootstatus`, or a clone.
- `bin/sim-boot-lock.sh` is the library both wrappers source. It defines the
  lock's path, the acquire budget and the wait.
- `bin/xctest-with-launch-retry.sh` composes in front of the boot mutex and
  retries one failure only: a transient SpringBoard denial of the test host's
  launch, in a run where no test case ran.
- `bin/print-xcresult-failures.sh` prints each failed test's assertion message
  from an `.xcresult` bundle, along with what the app logged while that test
  ran. `-quiet` drops both from the console.

The scripts need `/bin/sh`, `lockf(1)` (macOS) or `flock(1)` (Linux), and the
standard POSIX utilities. The xcresult printer also needs `xcrun` and `jq`. They
have no other dependencies and do nothing over the network.

## Why it exists

Several self-hosted runners on one Mac can each start `xcodebuild test` at the
same moment. Each run then clones an XCTestDevice from its destination
simulator, boots the clone and brings up its simulated launchd, all at once,
and all through one daemon. CoreSimulatorService is per user, and every runner
under one account talks to the same instance. Under that simultaneous startup
the daemon saturates, and a run fails with

```
(ipc/mig) server died
```

on the simulator's Darwin notification IPC. The failure lands in whichever job
lost the race, not in the job that caused the load, so it looks like an
unrelated flaky test.

Common ways around this cost a lot. One runner per Mac, or one VM per job,
gives up the hardware you bought for parallelism. A one-slot pool for every
simulator job serializes whole test runs to protect a phase that lasts about a
minute. And CoreSimulatorService cannot be split the way a daemon with a port
can: it is reached through a launchd Mach service name, so there is nothing to
move a second instance onto.

Only the boot phase is contended. Once a run is past it, the host's load drops,
and test execution does not trigger the storm. So the lock is held through the
boot phase and no longer.

### Why the lock is released at the first suite-started line

To serialize a phase in the middle of a running command, the wrapper needs a
signal from that command. xcodebuild prints two candidates:

- `Testing started` is printed when xcodebuild enters the test action. It has
  been observed before the first worker's clone has finished booting. Releasing
  there would leave even that boot outside the lock.
- `Test suite '<class>' started on '<device>'` (parallel testing) or
  `Test Suite '<name>' started at <time>` (serial) is printed only by a device
  that has booted and is running tests. This is the line the wrapper waits for.

Everything xcodebuild does before that line runs inside the lock: a build under
`xcodebuild test`, and the first worker's app install and launch. The lock is
released while xcodebuild is still running, by closing the file descriptor that
holds it, and the next waiting run starts its boot while the first run's tests
are executing.

Limits of what the lock covers:

- **Only the first parallel-testing worker's boot is covered.** A second
  worker's clone that boots after the line is outside the lock. For that reason
  `xctest-with-launch-retry.sh` runs one worker unless told otherwise.
- **A serial run under `-quiet` prints no suite line**, so the lock is held
  until that run ends. Such a run is serialized, not broken, and the wrapper
  warns when it passes without the line.
- **The lock is per user.** Its default path includes the uid, because the
  daemon it protects is also per user. Runners under different accounts take
  different locks and still compete for the machine's disk and CPU.
- **The lock ends with the wrapper, not with its command.** The kernel releases
  the lock when the wrapper's descriptor closes, so a wrapper killed before the
  suite line, by a signal or by SIGKILL, releases it at once. Its xcodebuild,
  if nothing else stops it, can still be booting when the next waiter's boot
  starts. Stop the wrapper's process tree, not the wrapper alone.
- **A simulator boot that does not take the lock is not protected.** If a new
  script calls `simctl boot` directly, the failure it causes shows up in some
  other job on the same Mac. Send every boot through one of the two wrappers.

## How to use it

Download the release archive and check its digest against `SHA256SUMS`, or
check out a fixed tag. Keep the files in `bin/` together, because each
script finds the others through its own directory.

Run tests through the launch retry, passing the whole xcodebuild invocation:

```sh
bin/xctest-with-launch-retry.sh xcodebuild test-without-building \
    -xctestrun MyApp.xctestrun \
    -destination "id=$SIMULATOR_UDID" \
    -resultBundlePath "$RUNNER_TEMP/Tests.xcresult" \
    -quiet ||
    { rc=$?; bin/print-xcresult-failures.sh "$RUNNER_TEMP/Tests.xcresult"; exit "$rc"; }
```

To get the boot mutex without the retry, call `bin/xctest-with-boot-mutex.sh`
with the same arguments. The retry wrapper adds
`-parallel-testing-worker-count` and `-collect-test-diagnostics never` to the
command it passes on. The boot mutex passes the command through unchanged.

Boot or clone a simulator outside xcodebuild under the same lock. Pass the
whole sequence as one command, because `simctl boot` returns before the guest
is ready:

```sh
bin/with-sim-boot-lock.sh sh -c 'xcrun simctl boot "$1" && xcrun simctl bootstatus "$1"' sh "$UDID"
```

Any of these scripts can run outside CI. Its `::error::` and `::warning::`
lines are GitHub Actions annotations, which other systems print as plain text.

### Configuration

| Variable                                             | Default                                 | Meaning                                                                                                                                                                                          |
| ---------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SIM_BOOT_LOCK_FILE`                                 | `$TMPDIR/xctest-sim-boot.<uid>.lock`    | The lock file. Leave it at its default unless every holder on the host sets the same path. Two holders that name different files do not exclude each other, and neither reports anything wrong. |
| `SIM_BOOT_ACQUIRE_TIMEOUT`                           | `600`                                   | Seconds to wait for the lock before failing. `with-sim-boot-lock.sh` exports the resolved value to its command, so a long operation can set itself a shorter bound than its waiters have.        |
| `SIM_BOOT_LOCK_POLL_SECONDS`                         | `1`                                     | Sleep between attempts for a descriptor-mode waiter (see below).                                                                                                                                 |
| `XCTEST_BOOT_MUTEX_HOOK`                             | unset                                   | An executable the boot mutex calls at each lock transition (see below).                                                                                                                          |
| `XCTEST_LAUNCH_RETRIES`                              | `4`                                     | Retries after the first attempt. `0` disables retrying.                                                                                                                                          |
| `XCTEST_LAUNCH_RETRY_BACKOFF`                        | `15`                                    | Seconds between attempts.                                                                                                                                                                        |
| `XCTEST_PARALLEL_TESTING_WORKERS`                    | `1`                                     | The parallel-testing width the retry wrapper passes to xcodebuild.                                                                                                                               |
| `XCTEST_LAUNCH_EVENTS_FILE`                          | unset                                   | The retry wrapper appends one line here for each infrastructure event it classifies.                                                                                                             |
| `RUNNER_TEMP`                                        | `/tmp`                                  | Where the wrappers keep their per-run logs.                                                                                                                                                      |

### The hook

Some bookkeeping is only sound while no other run can be booting a simulator,
such as recording which XCTestDevice clones this run created so that they can
be deleted afterwards. `XCTEST_BOOT_MUTEX_HOOK` names an executable that the
boot mutex calls at three points:

| Call             | When                                                                     | A non-zero exit                               |
| ---------------- | ------------------------------------------------------------------------ | --------------------------------------------- |
| `HOOK acquired`  | The lock is held, and the wrapped command has not started.               | Aborts the run with exit 1. The command never starts. |
| `HOOK releasing` | The lock is still held and is about to be released, either at the suite line or at exit. | Logs a warning.                               |
| `HOOK exited RC` | The lock is released, and the command has exited with `RC` (`1` if it never started). | Logs a warning.                               |

Every call receives `XCTEST_BOOT_MUTEX_PID`, the wrapper's process ID. The value
is the same for all three calls in a run, and the process lives exactly as long
as the run. A hook that records ownership by process should use this value
rather than its own parent's PID. The hook does not inherit the lock's file
descriptor, so a process it leaves running cannot keep the lock held.

### The launch retry

On a busy host, SpringBoard sometimes denies the launch of the test host app:

```
denied by service delegate (SBMainWorkspace) for reason: Busy ("Application failed preflight checks")
denied by service delegate (SBMainWorkspace) for reason: NotFound ("Application "<id>" is unknown to FrontBoard")
```

In that case xcodebuild exits 65 and no test case runs. This happens even when
the launch is inside the lock, because the load causing it comes from other
work on the host, not from other launches. The retry wrapper re-runs the whole
xcodebuild invocation, with a fresh clone and boot, only when it sees one of
those reasons together with its detail text and no test case ran. Any other
failure is propagated immediately, with its original exit status: an assertion,
a crash, a build error, a signing rejection, a denial for any other reason, or
a denial after a test has run. The wrapper prints a warning for every retry and
a separate warning when it runs out of retries. Between attempts it deletes the
caller's `-resultBundlePath`, because xcodebuild will not overwrite one. The
bundle from the last attempt is kept.

Two limits of the classifier. It reads the combined output and does not check
the exit status, so a run that printed a matching denial is retried whatever it
exited with. And it learns that a test ran from xcodebuild's per-case lines,
which a serial run under `-quiet` does not print. In that mode a denial after
real test work would be retried, and the wrapper warns on every passing run
that printed no per-case line, so the gap shows up before a failure depends on
it.

It also flags one failure it does not retry. If xcodebuild exits 134 on a
`DVTiPhoneSimulator` assertion about a nil `launchSession`, it reports the
failure as simulator infrastructure.

### Why waiters poll

On macOS, `lockf(1)` spins at about 100% of one core while it waits in
file-descriptor mode. That is the mode the boot mutex has to use, because it
releases the lock partway through its command. This was measured; the man page
does not describe it. So waiters try once per `SIM_BOOT_LOCK_POLL_SECONDS` and
sleep between attempts. `test/sim-boot-lock-acquire.sh` checks that a waiter
uses less than one second of CPU, and only its macOS run exercises the lockf
path.

## When acquisition fails

Each of these exits non-zero before any simulator work starts. That is
deliberate: booting without the lock brings back the failure the lock prevents.

**`acquire timed out after <N>s`** (from `xctest boot mutex:`) or **`acquire
failed after <N>s`** (from `sim boot lock:`): another process held the lock
for the whole budget. In a healthy run the lock is released within seconds of a
boot finishing. Find the holder by the lock file rather than by process name:

```sh
lsof "$LOCK"   # the path printed in the error
```

- If the holder is an `sh` running `xctest-with-boot-mutex.sh`, note that every
  waiter also has descriptor 9 open on the file. A wrapper that has an
  `xcodebuild` child, or that printed `acquired at` in its log, holds the lock.
  The `released at` line can be absent even after the lock was released,
  because the wrapper holds its own log lines back until xcodebuild exits.
- If the holder is a `lockf` or `flock` process, it belongs to
  `with-sim-boot-lock.sh`. Its descendants show what it is doing. A boot or
  `bootstatus` that is still running after its own bound has passed is stuck.

Stop the stuck work itself, wait for it to exit, and only then its holder.
Killing only the `lockf` or `flock` process, or only the wrapper's shell,
releases the lock while the boot it was protecting keeps running. Giving
waiters a longer budget does not fix a stuck holder.

**`the lock primitive failed (rc=<N>)`**: `lockf` or `flock` itself refused, so
no other process holds the lock. Look up the status in the primitive's manual
page. `lockf` uses the `sysexits(3)` range.

**`cannot open <path> for append`**: the lock file belongs to another user and
is not writable. This can only happen when `SIM_BOOT_LOCK_FILE` points several
users at one path. Fix the permissions in place with `chmod 666 <path>`. Never
delete the file: a process may hold the lock on the existing inode, and the next
wrapper would create a new file, lock that, and end up holding a second,
independent lock.

**`neither lockf nor flock on PATH`**: install one of them. The scripts refuse
to run without a lock.

## Tests

```sh
for suite in test/*.sh; do sh "$suite" || echo "FAILED: $suite"; done
```

The suites use a real kernel lock in a temporary directory, so they can run on
a Mac that is also a CI runner. A fake command stands in for xcodebuild, so no
simulator is needed. CI runs them on Linux (flock) and macOS (lockf).

## Releases

Each release is a fixed `vMAJOR.MINOR.PATCH` tag with a GitHub Release that
carries `xctest-boot-mutex-<version>.tar.gz` and `SHA256SUMS`. Tags and release
assets are immutable once published. Pin a tag or the archive's digest. 0.x
releases make no compatibility promise to earlier 0.x releases.

Two things are release contract even within 0.x. The default lock path cannot
change, because a host may run an old copy and a new copy at the same time, and
both must take the same lock. Neither can the hook's call names.

## License

MIT. See [LICENSE](LICENSE).
