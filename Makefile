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

.PHONY: build test release clean bin eval render app open stage-model app-staged

build:
	$(SWIFT) build $(SWIFTFLAGS)

test:
	$(SWIFT) test $(SWIFTFLAGS)

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

# Launch the editor. This is the command to use for a real shoot — it runs the app straight
# from the build, which is the path that reliably loads the perception model (a hand-assembled
# .app bundle still trips a launch issue; see docs).
app:
	cd Integrations/KelvinPerceptionMLX && $(SWIFT) run kelvin-app

# Same, but opens on a specific photo — handy for jumping back into one frame.
#   make open PHOTO=~/Pictures/shoot/_DSC0001.ARW
open:
	cd Integrations/KelvinPerceptionMLX && KELVIN_DEMO_IMAGE="$(PHOTO)" $(SWIFT) run kelvin-app

# Stage the perception weights for bundling into the app (see D-model-4). Refuses to stage weights
# whose licence file is not present, because bundling them is redistribution.
stage-model:
	scripts/stage-model.sh

# Run against the staged weights instead of the Hugging Face cache — the same path a shipped bundle
# takes, so "does it load from disk" is testable before there is a bundle.
app-staged: stage-model
	cd Integrations/KelvinPerceptionMLX && \
	  KELVIN_MODEL_PATH="$(PWD)/Vendor/PerceptionModel" $(SWIFT) run kelvin-app
