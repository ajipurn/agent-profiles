.PHONY: build test package run demo clean icon release release-local signing-key

build:
	zsh -c 'source scripts/swift-env.sh && swift build "$${SWIFT_FLAGS[@]}" --product AgentProfiles'

test:
	./scripts/test.sh

package:
	./scripts/package-app.sh debug

# Real mode: manages your actual Claude and Codex accounts.
run: package
	open "dist/Agent Profiles.app"

# Preview mode: sample accounts in temporary folders, safe next to the old apps.
demo: package
	open -n "dist/Agent Profiles.app" --args --demo

clean:
	rm -rf .build dist

icon:
	swift scripts/make-icon.swift "$(CURDIR)"

# Tags, builds in CI, verifies and publishes. BUMP=patch|minor|major or VERSION=x.y.z.
release:
	python3 scripts/release.py --version "$(VERSION)" --bump "$(BUMP)"

release-local: test
	./scripts/build-release.sh

signing-key:
	./scripts/setup-update-signing.sh
