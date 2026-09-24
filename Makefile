# Kelvin build shortcuts.
#
# Why a custom build path: this repo lives on a file-provider-backed directory (iCloud /
# sync). Such volumes stamp `com.apple.FinderInfo` onto build products, and `codesign`
# refuses to sign a bundle carrying it ("resource fork, Finder information, or similar
# detritus not allowed") — which breaks `swift test` (the .xctest bundle must be signed).
# Building into $(TMPDIR), a per-user LOCAL directory, sidesteps it entirely.
#
# Override with `make BUILD_PATH=/somewhere test` if you prefer.

BUILD_PATH ?= $(TMPDIR)kelvin-build
SWIFT := swift
SWIFTFLAGS := --scratch-path "$(BUILD_PATH)"

.PHONY: build test ratchet release clean bin eval render app open stage-model app-staged delta trace sparkle-guard ui-test ui-test-build

build:
	$(SWIFT) build $(SWIFTFLAGS)

# The Task.detached ratchet runs first: it is a one-second grep and the thing it guards against
# (D21) cost an afternoon to diagnose. CI's core job runs `make test`, so it is enforced there too.
test: ratchet
	$(SWIFT) test $(SWIFTFLAGS)

ratchet:
	@scripts/check-detached.sh
	@scripts/check-loose-masks.sh

release:
	$(SWIFT) build -c release $(SWIFTFLAGS)

# Print the path to the built kelvin-cli binary (debug).
bin:
	@echo "$$($(SWIFT) build $(SWIFTFLAGS) --show-bin-path)/kelvin-cli"

# make eval CORPUS=./corpus [OUT=report.json]
eval: build
	@"$$($(SWIFT) build $(SWIFTFLAGS) --show-bin-path)/kelvin-cli" eval --corpus "$(CORPUS)" $(if $(OUT),--out "$(OUT)",)

# make render IN=photo.CR3 RECIPE=r.json OUT=out.jpg
render: build
	@"$$($(SWIFT) build $(SWIFTFLAGS) --show-bin-path)/kelvin-cli" render --in "$(IN)" --recipe "$(RECIPE)" --out "$(OUT)"

clean:
	rm -rf "$(BUILD_PATH)" .build

# Repair SwiftPM's Sparkle artifact if it has emptied itself, which it does. See the script; it has
# cost two builds, one of them mid-release. A no-op when everything is fine.
sparkle-guard:
	@scripts/sparkle-guard.sh

# Launch the editor from the build. Fastest path for development — no bundle assembly.
# `scripts/package-app.sh` produces a working double-clickable Kelvin.app as well; the launch
# failure that used to make bundles unusable was MLX not finding default.metallib and is fixed.
app: sparkle-guard
	cd Integrations/KelvinPerceptionMLX && $(SWIFT) run kelvin-app

# Same, but opens on a specific photo — handy for jumping back into one frame.
#   make open PHOTO=~/Pictures/shoot/_DSC0001.ARW
open: sparkle-guard
	cd Integrations/KelvinPerceptionMLX && KELVIN_DEMO_IMAGE="$(PHOTO)" $(SWIFT) run kelvin-app

# Profile the edit panel: an automated slider drag with a main-thread stall monitor. Prints how
# often and how long the thread that draws the window was unavailable. See Diagnostics.swift.
#   make trace PHOTO=~/Pictures/shoot/_DSC0001.ARW [STEPS=200]
STEPS ?= 200
trace: sparkle-guard
	@test -n "$(PHOTO)" || { echo "usage: make trace PHOTO=<photo> [STEPS=$(STEPS)]"; exit 2; }
	cd Integrations/KelvinPerceptionMLX && \
	  KELVIN_DEMO_IMAGE="$(PHOTO)" KELVIN_TRACE_HITCHES=1 \
	  KELVIN_STRESS_DRAG=$(STEPS) KELVIN_STRESS_EXIT=1 $(SWIFT) run kelvin-app

# Stage the perception weights for bundling into the app (see D-model-4). Refuses to stage weights
# whose licence file is not present, because bundling them is redistribution.
stage-model:
	scripts/stage-model.sh

# The Sparkle delta patch from a previously shipped release to the app now in dist/. Without one,
# every update re-downloads the bundled weights; see docs/RELEASING.md.
#   make delta OLD=~/Downloads/Kelvin-0.1.0.dmg
NEW ?= dist/Kelvin.app
delta:
	@test -n "$(OLD)" || { echo "usage: make delta OLD=<previous .dmg or .app> [NEW=$(NEW)]"; exit 2; }
	scripts/make-delta.sh "$(OLD)" "$(NEW)"

# Run against the staged weights instead of the Hugging Face cache — the same path a shipped bundle
# takes, so "does it load from disk" is testable before there is a bundle.
app-staged: stage-model sparkle-guard
	cd Integrations/KelvinPerceptionMLX && \
	  KELVIN_MODEL_PATH="$(PWD)/Vendor/PerceptionModel" $(SWIFT) run kelvin-app

# The Mac app's UI tests (Apps/KelvinMacUITests): package a dev Kelvin.app, generate the test project,
# run. ⚠️ They drive the real mouse and keyboard — start them when nobody is at the Mac.
# `make ui-test-build` compiles them without running anything.
UI_DD ?= $(TMPDIR)kelvin-uitest-dd
UI_APP ?= $(TMPDIR)kelvin-uitest-app
ui-test-build:
	cd Apps/KelvinMacUITests && xcodegen generate --quiet
	cd Apps/KelvinMacUITests && xcodebuild -project KelvinMacUITests.xcodeproj -scheme KelvinMacUITests \
	  -derivedDataPath "$(UI_DD)" build-for-testing

ui-test: ui-test-build
	KELVIN_DMG=0 scripts/package-app.sh --debug "$(UI_APP)"
	cd Apps/KelvinMacUITests && TEST_RUNNER_KELVIN_UI_APP="$(UI_APP)/Kelvin.app" xcodebuild \
	  -project KelvinMacUITests.xcodeproj -scheme KelvinMacUITests -derivedDataPath "$(UI_DD)" \
	  test-without-building
