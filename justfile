# Show the available project commands.
default:
    @just --list

# Build release products and sign the app bundle without installing it.
build:
    ./scripts/build-app-bundle.sh

# Run shared-code/CLI package tests and the Xcode app tests.
test:
    swift test
    xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath .build/xcode test

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
