# Show the available project commands.
default:
    @just --list

# Compile all products in release mode.
build:
    swift build -c release

# Run the Swift package tests.
test:
    swift test

# Build and sign the app bundle without installing it.
bundle:
    ./scripts/build-app-bundle.sh

# Build and install the app and CLI in the current user's home directory.
install:
    ./scripts/install-local.sh

# Regenerate the icon and its compositing layers.
icon:
    python3 design/icon/build.py

# Run package tests and the independent transport regression tests.
check: test
    ./scripts/test-transport.sh
