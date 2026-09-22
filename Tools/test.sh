#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Desktop/Documents могут обслуживаться File Provider: FinderInfo на .xctest
# ломает подпись нового SwiftPM. Кэш сборки держим в локальном Library/Caches.
# Явный --scratch-path остаётся приоритетным, в том числе в CI и при отладке.
for argument in "$@"; do
    case "$argument" in
        --scratch-path|--scratch-path=*) exec swift test "$@" ;;
    esac
done
project_key=$(printf '%s' "$PWD" | shasum -a 256 | cut -c 1-16)
test_build_dir="${KC_TEST_BUILD_DIR:-$HOME/Library/Caches/KeeneticControl/SwiftPM/$project_key}"
mkdir -p "$test_build_dir"
chmod 700 "$test_build_dir"
exec swift test --scratch-path "$test_build_dir" "$@"
