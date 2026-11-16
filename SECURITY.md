# Security policy

Report suspected vulnerabilities privately using
[GitHub private vulnerability reporting](https://github.com/curlewlabs-com/xctest-boot-mutex/security/advisories/new).
Include the affected release or commit, the host and macOS version, the
reproduction steps, and the observed impact.

Curlew Labs maintains this repository; Jeffrey Wall
([jeffwall-curlewlabs](https://github.com/jeffwall-curlewlabs)) is the release
and security contact through GitHub. Reports are reviewed on a best-effort
basis without a guaranteed response time. Fixes target the latest published
release.

## Trust boundary

The lock is advisory and cooperative. It serializes the processes that take
it; it does not stop a process that boots a simulator without it, and any
process that can write the lock file can hold it and stall every waiter until
their budget runs out. Every holder on a host is trusted with every other
holder's runs, as processes under one user account already are.
`XCTEST_BOOT_MUTEX_HOOK` runs whatever executable it names with the wrapper's
privileges.
