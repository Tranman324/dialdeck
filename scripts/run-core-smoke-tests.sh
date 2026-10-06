#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift test --package-path "$ROOT_DIR" --arch arm64
