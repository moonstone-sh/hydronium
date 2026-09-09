#!/bin/sh
set -eu

case "$(uname -m)" in
    arm64|aarch64)
        architecture=aarch64
        ;;
    x86_64|amd64)
        architecture=x86_64
        ;;
    *)
        echo "hydronium-ink: unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

mkdir -p native/selected
cp "native/dist/${architecture}-macos/libyogacore.dylib" native/selected/libyogacore.dylib
cp "native/dist/${architecture}-linux-gnu/libyogacore.so" native/selected/libyogacore.so
