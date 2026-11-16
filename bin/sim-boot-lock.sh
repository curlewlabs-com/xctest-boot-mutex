#!/bin/sh
# The host's simulator boot lock: its path, its acquire budget, and the
# descriptor-mode wait. Sourced, never run, by xctest-with-boot-mutex.sh and
# with-sim-boot-lock.sh beside it.
#
# Why the path lives here rather than in either wrapper: they hold the lock
# through different primitives - xctest-with-boot-mutex.sh on a file descriptor
# it can close partway through xcodebuild, with-sim-boot-lock.sh for a whole
# command - and they exclude each other only while they name the same file. A
# divergence fails silently in the worst direction: each side acquires, neither
# waits, and the boot storm comes back looking exactly like the bug the lock was
# added to fix. One definition makes that unrepresentable.
#
# Per-uid, because the contended daemon is the per-user CoreSimulatorService:
# the lock only has to span one user's runners, which share a uid. A single
# fixed path collides across users instead - the first creator owns it
# `-rw-r--r--` and a second user's write open fails EACCES, wedging every later
# run on that host.
#
# A host can run an older copy of these scripts in one job while a newer copy
# runs in another, and each locks the file its own copy names. So the default
# basename is part of the release contract: changing it buys a window in which
# live boots hold different locks, which is the one state this lock exists to
# prevent.
sim_boot_lock_file() {
    printf '%s\n' "${TMPDIR:-/tmp}/xctest-sim-boot.$(id -u).lock"
}

# One acquire budget for both wrappers, so an operator reading either log sees
# the same number. It also reaches the wrapped command as
# SIM_BOOT_ACQUIRE_TIMEOUT, so a longer discrete operation can bound itself
# below its peer waiters from this same source.
sim_boot_lock_timeout() {
    printf '%s\n' "${SIM_BOOT_ACQUIRE_TIMEOUT:-600}"
}

# How long a descriptor-mode waiter sleeps between attempts.
#
# **macOS lockf(1) waits by spinning in FD mode, and only in FD mode.** Measured
# on a self-hosted runner Mac: a waiter on a descriptor burns ~100% of one core
# for the whole wait, with `-t` and without it, while the same wait in the
# file+command form the man page recommends `-k` for costs nothing measurable.
# The man page describes neither - it says the untimed case "waits
# indefinitely" and credits `-k` with "an algorithm which minimizes CPU load",
# which FD mode implies and evidently does not take.
#
# That asymmetry is the whole reason this exists, because the holders of this
# lock are split across it: with-sim-boot-lock.sh takes the cheap form and needs
# nothing from here, while xctest-with-boot-mutex.sh cannot - it releases
# partway through xcodebuild, which is only reachable by holding the lock on a
# descriptor of its own. Its waiters are the common case rather than the rare
# one, since the contention this lock serializes is several simulator boots on
# one host: every xctest job queued behind a boot would burn a core spinning
# while that boot ran, on exactly the contended host whose contention the lock
# is there to reduce.
#
# The interval is slack against a hold measured in tens of seconds (a simulator
# boot), so it is invisible in acquire latency, and one fork per interval is
# nothing next to what it replaces.
_SBL_POLL_SECONDS=1

# Take the lock on an already-open file descriptor: 0 acquired, 1 the budget
# ran out, 127 no primitive on PATH, anything else the primitive's own failure.
#
# **FD mode on lockf and flock alike**, so the lock lives on the file
# description the caller holds open. The kernel then releases it when that
# descriptor closes - normal exit, SIGKILL, panic alike, which is what the
# callers' crash recovery rests on - and neither primitive can unlink the file
# from under a peer still holding the old inode, since `lockf` implies `-k` in
# FD mode and `flock` never unlinks at all. That unlink is not a hypothetical
# tidiness point: it splits the mutex silently, one holder per inode, in the one
# direction nothing downstream would catch.
#
# Waiters race for each attempt rather than queueing inside the primitive.
# flock(2) orders no queue either, so the property that changes is barging - a
# process arriving mid-interval can win ahead of one that has waited - bounded
# by the acquire budget, which fails the loser loudly.
sim_boot_lock_acquire_fd() {
    _sbl_fd=$1
    _sbl_deadline=$(($(date +%s) + $2))
    # Each primitive's "someone else holds it" status, which is the only one
    # worth trying again. Retrying anything else would spend the whole budget on
    # a condition that cannot clear and then surface it as a timeout, naming
    # contention that was never the problem. On macOS that separation is exact:
    # BSD lockf answers EX_TEMPFAIL for a held lock and a different status for a
    # broken one (measured: 73 for a descriptor that is not open). `flock -n`
    # answers 1 for a held lock and does not promise to distinguish, so on Linux
    # a broken descriptor still costs the budget before it surfaces.
    if command -v lockf >/dev/null 2>&1; then
        _sbl_try="lockf -s -t 0"
        _sbl_busy=75
    elif command -v flock >/dev/null 2>&1; then
        _sbl_try="flock -x -n"
        _sbl_busy=1
    else
        return 127
    fi
    while :; do
        # `|| rc=$?` rather than `if attempt; then`, because a failed `if`
        # condition leaves `$?` at the *if statement's* own status - zero when
        # no branch ran - so reading the attempt's status after `fi` reports
        # every refusal as a success, and this function would hand back a lock
        # it does not hold.
        _sbl_rc=0
        # shellcheck disable=SC2086 # Deliberate split: _sbl_try is a command
        # and its flags, chosen once above rather than re-probed per attempt.
        $_sbl_try "$_sbl_fd" || _sbl_rc=$?
        if [ "$_sbl_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$_sbl_rc" -ne "$_sbl_busy" ]; then
            return "$_sbl_rc"
        fi
        [ "$(date +%s)" -lt "$_sbl_deadline" ] || return 1
        sleep "$_SBL_POLL_SECONDS"
    done
}
