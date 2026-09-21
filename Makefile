SCHEME   = Mango
PROJECT  = Mango.xcodeproj
SIM     ?= iPhone Air
PAD     ?= iPad Pro 13-inch (M4)
DEST     = platform=iOS Simulator,name=$(SIM)

.PHONY: gen build build-ipad test run run-ipad lint fixtures install-fixtures icon clean archive upload testflight bump

gen:            ## Regenerate Mango.xcodeproj from project.yml
	xcodegen generate

build: gen      ## Build for the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' build | tail -20

build-ipad: gen ## Build for the iPad simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(PAD)' build | tail -20

test: gen       ## Run unit tests on the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' test | tail -40

run: gen        ## Build, install, and launch on the simulator (uses xcodebuildmcp)
	xcodebuildmcp simulator build-and-run --project-path $(PROJECT) --scheme $(SCHEME) --simulator-name "$(SIM)"

run-ipad: gen   ## Same, on the iPad simulator
	xcodebuildmcp simulator build-and-run --project-path $(PROJECT) --scheme $(SCHEME) --simulator-name "$(PAD)"

lint:           ## SwiftLint
	swiftlint lint --quiet

fixtures:       ## Generate sample comics (CBZ, PDF, loose pages) into ./fixtures
	scripts/make-fixtures.sh

install-fixtures: ## Copy fixtures into the booted simulator's "On My iPhone > Mango"
	scripts/install-fixtures.sh

icon:           ## Re-render the app icon
	swift scripts/render-icon.swift Mango/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

clean:
	rm -rf build DerivedData

# ---------------------------------------------------------------------------
# TestFlight. Needs .env.appstore-connect (see .env.appstore-connect.example) and
# Config/Signing.xcconfig with your DEVELOPMENT_TEAM. Build numbers are managed by
# App Store Connect (manageAppVersionAndBuildNumber in ExportOptions.plist).
# ---------------------------------------------------------------------------
-include .env.appstore-connect
export
ARCHIVE = build/Mango.xcarchive
# Only pass API-key auth when configured; otherwise xcodebuild uses the Apple ID signed into Xcode.
ASC_AUTH = $(if $(APPSTORE_CONNECT_KEY_ID),-authenticationKeyPath "$(abspath $(APPSTORE_CONNECT_KEY_FILE))" -authenticationKeyID "$(APPSTORE_CONNECT_KEY_ID)" -authenticationKeyIssuerID "$(APPSTORE_CONNECT_ISSUER_ID)",)

archive: gen    ## Release archive for iOS devices
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates $(ASC_AUTH) | tail -20

# Two things bite here:
#   1. System PATH only: Xcode's IPA step runs Apple's rsync with -E, which breaks if
#      Homebrew's rsync is found first.
#   2. NO $(ASC_AUTH). Passing the API key makes export use cloud signing, which this key
#      isn't permitted for ("Cloud signing permission error / No profiles were found"), and
#      there is no local Apple Distribution certificate to fall back on. Without the key,
#      xcodebuild uses the Apple ID signed into Xcode, which can mint the profile and upload.
#      The key is still right for `archive` and for every scripts/*.py call.
upload:         ## Sign for App Store Connect and upload the archive (TestFlight)
	env -u APPSTORE_CONNECT_KEY_ID -u APPSTORE_CONNECT_ISSUER_ID -u APPSTORE_CONNECT_KEY_FILE \
	  PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath $(ARCHIVE) \
	  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates | tail -20

testflight: archive upload ## Archive + upload in one go
	@echo "Uploaded. Processing takes a few minutes; then: uv run --script scripts/testflight.py status"

bump:           ## Bump the marketing version, e.g. make bump V=0.2.0
	@test -n "$(V)" || (echo "usage: make bump V=0.2.0" && exit 1)
	sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: $(V)/' project.yml && xcodegen generate
