# Contributing

Keep changes on a branch and open a pull request that states the behavior
change and how you verified it.

## Maintainership and review

Curlew Labs maintains this project. Jeffrey Wall
([jeffwall-curlewlabs](https://github.com/jeffwall-curlewlabs)) reviews changes
and approves the releases that [need approval](#releasing). Use issues for
reproducible defects and proposals; use
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

## Releasing

A release is a fixed `vMAJOR.MINOR.PATCH` tag on a `main` commit and the
GitHub Release published on it, carrying `xctest-boot-mutex-<version>.tar.gz`
and `SHA256SUMS`. A fix is a patch release. A new, changed or removed option
or behavior is a minor release until 1.0. The README's "Releases" says what no
release may change.

A patch or minor release needs no approval beyond the checks in the steps below:
whoever cuts it follows them in order, and each step's check is the gate. A
major version, a 1.0, or a minor before 1.0 that changes an interface consumers
use needs the maintainer's explicit approval before its tag is pushed.

1. Merge the release's pull request with a merge commit, and wait for the `CI`
   and `CodeQL` runs on the merge commit on `main` to pass.
2. Tag that commit and push the tag. The fixed-version-tag ruleset blocks
   moving or deleting a pushed tag, so check the commit first.

   ```sh
   git fetch origin
   git tag -a v0.2.1 -m v0.2.1 <commit>
   git push origin v0.2.1
   ```

3. The tag starts `release.yml`. It fails unless the tagged commit is on
   `main`, runs CI on it again, builds the archive from the tag with
   `git archive`, and drafts the release with the archive and `SHA256SUMS`.
4. Check the draft against a local build: the archive matches `SHA256SUMS`,
   and it holds exactly what the tag holds. Compare contents, not the archive's
   digest, since gzip output can differ between git versions.

   ```sh
   v=0.2.1
   dir=$(mktemp -d)
   gh release download "v$v" -D "$dir/draft"
   (cd "$dir/draft" && shasum -a 256 -c SHA256SUMS)
   mkdir "$dir/released" "$dir/local"
   tar -xzf "$dir/draft/xctest-boot-mutex-$v.tar.gz" -C "$dir/released"
   git archive --prefix="xctest-boot-mutex-$v/" "v$v" | tar -x -C "$dir/local"
   diff -r "$dir/released" "$dir/local"
   ```

5. Replace the draft's placeholder notes with notes in the shape of the
   previous releases: what was fixed, closed with a reason, added or removed,
   each entry naming its issue, ending with the `SHA256SUMS` and 0.x lines.

   ```sh
   gh release edit "v$v" --notes-file notes.md
   ```

6. Publish the draft:

   ```sh
   gh release edit "v$v" --draft=false
   ```

   Release immutability is on, so publishing locks the tag and both assets for
   good. A mistake found after this ships in the next patch release.
