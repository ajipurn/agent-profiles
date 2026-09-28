# Contributing

Requires macOS 14+, Swift 6+ and Python 3. Full Xcode is needed for universal builds; everything else works with the Command Line Tools (see "Building without Xcode" in the README).

```sh
make build
make test
python3 -m unittest discover -s scripts/tests -v
python3 scripts/release_metadata.py check
python3 scripts/check-repository.py
make demo
```

Keep account tests isolated with the temporary homes and sample identities the test suites already use. Do not use real authentication tokens or profile folders in fixtures, logs, issues or screenshots; `make demo` gives safe screenshots.

Use conventional commit prefixes such as `feat:`, `fix:`, `docs:` or `chore:`. Explain behavior changes and validation in the pull request. Keep the paths listed under "Compatibility with the old apps" in the README unchanged.

`Config/release.json` is the release metadata source. After changing it, run `python3 scripts/release_metadata.py sync`. The app icon is drawn by `scripts/make-icon.swift` (`make icon`).

The update signing key is not needed for development or pull-request checks. See [docs/RELEASING.md](docs/RELEASING.md).
