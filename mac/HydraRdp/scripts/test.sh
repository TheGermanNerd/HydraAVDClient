#!/usr/bin/env bash
# Unit tests do not link FreeRDP. SwiftPM's test emit step in this workspace
# does not load the Testing macro plugin unless it is named on the command line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ ! -f "${PLUGIN}" ]]; then
  TOOLCHAIN="$(xcode-select -p)"
  PLUGIN="${TOOLCHAIN}/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
fi

swift build --package-path "${ROOT}" --target HydraRdpCoreTests \
  -Xswiftc -load-plugin-library -Xswiftc "${PLUGIN}"
swift test --package-path "${ROOT}" --skip-build
