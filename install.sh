#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="bragilauncher"
INSTALL_DIR="/usr/local/bin"

# Build release binary
echo "Building $BINARY_NAME..."
odin build "$SCRIPT_DIR/src" -out:"$SCRIPT_DIR/$BINARY_NAME" -o:speed

if [[ ! -f "$SCRIPT_DIR/$BINARY_NAME" ]]; then
    echo "Error: Build failed - binary not found"
    exit 1
fi

echo "Installing to $INSTALL_DIR..."

# Remove existing symlink if present
if [[ -L "$INSTALL_DIR/$BINARY_NAME" ]]; then
    sudo rm "$INSTALL_DIR/$BINARY_NAME"
elif [[ -e "$INSTALL_DIR/$BINARY_NAME" ]]; then
    echo "Error: $INSTALL_DIR/$BINARY_NAME exists and is not a symlink"
    exit 1
fi

sudo ln -s "$SCRIPT_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"

echo "Successfully installed $BINARY_NAME to $INSTALL_DIR"
