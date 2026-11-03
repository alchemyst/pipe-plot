xcode_derived_data := env_var_or_default("PIPEPLOT_XCODE_DERIVED_DATA", ".build/xcode")

# Show the available project commands.
default:
    @just --list

# Format only the package manifest and maintained Swift sources/tests.
format:
    xcrun swift-format format --configuration .swift-format --in-place --recursive Package.swift Sources Tests

# Check formatting without changing files; findings fail the command.
format-check:
    xcrun swift-format lint --configuration .swift-format --strict --recursive Package.swift Sources Tests

# Build release products and sign the app bundle without installing it.
build:
    ./scripts/build-app-bundle.sh

# Run shared-code/CLI package tests and the Xcode app tests.
test:
    swift test
    xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath "{{xcode_derived_data}}" test

# Build and sign the app bundle without installing it.
bundle:
    ./scripts/build-app-bundle.sh

# Build and install the app and CLI in the current user's home directory.
install:
    ./scripts/install-local.sh

# Regenerate the icon and its compositing layers.
icon:
    ./scripts/render-icon.sh .build/icon

# Run package/app tests and the independent transport regression tests.
check: test
    ./scripts/test-transport.sh

# Compile all Swift package and hosted app/test targets in Swift 6 with diagnostics fatal.
strict-build:
    swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
    xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath "{{xcode_derived_data}}" SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build-for-testing
