# Contributing

Keep changes on a branch and open a pull request that states the behavior
change and how you verified it.

## Maintainership and review

Curlew Labs maintains this project. Jeffrey Wall
([jeffwall-curlewlabs](https://github.com/jeffwall-curlewlabs)) reviews changes
and approves releases. Use issues for reproducible defects and proposals; use
[private vulnerability reporting](SECURITY.md) for security concerns.

## Rules

- Scripts are `#!/bin/sh`, POSIX, and pass `shellcheck -x` with no findings.
  macOS's `/bin/sh` and bash 3.2 must run them.
- No dependencies beyond `sh`, `lockf` or `flock`, and POSIX utilities
  (`xcrun` and `jq` for the xcresult printer).
- A change to locking or release behavior ships with a test that drives the
  real lock. A test that stubs the lock asserts only that the stub was called.
- Comments say why, not what.
- Tracked text is ASCII.
- The default lock path and the hook's call names are release contract; see
  the README's "Releases".

## Local checks

```sh
shellcheck -x bin/*.sh test/*.sh
for suite in test/*.sh; do sh "$suite" || echo "FAILED: $suite"; done
```

CI runs the suites on Linux and macOS; only the macOS run exercises `lockf`.
