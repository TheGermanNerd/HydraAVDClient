#!/usr/bin/env bash
# Build the self-contained universal Hydra AVD Client disk image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP="${ROOT}/build/HydraRdp.app"
DMG="${ROOT}/build/Hydra AVD Client.dmg"
VOLUME="Hydra AVD Client"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

ensure_rosetta() {
  if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    return
  fi
  log "installing Rosetta 2"
  softwareupdate --install-rosetta --agree-to-license
  arch -x86_64 /usr/bin/true >/dev/null 2>&1 || die "Rosetta 2 is required to build the Intel slice"
}

require_license() {
  local path="$1"
  [[ -f "${path}" ]] || die "missing license file ${path}"
}

copy_licenses() {
  local dest="${APP}/Contents/Resources/Licenses"
  mkdir -p "${dest}"
  require_license "${ROOT}/ThirdParty/freerdp-src/LICENSE"
  require_license "${ROOT}/ThirdParty/deps/src/openssl/LICENSE.txt"
  require_license "${ROOT}/ThirdParty/deps/src/json-c/COPYING"
  cp "${ROOT}/ThirdParty/freerdp-src/LICENSE" "${dest}/FreeRDP-LICENSE.txt"
  cp "${ROOT}/ThirdParty/deps/src/openssl/LICENSE.txt" "${dest}/OpenSSL-LICENSE.txt"
  cp "${ROOT}/ThirdParty/deps/src/json-c/COPYING" "${dest}/json-c-COPYING.txt"
}

sign_app() {
  codesign --force --sign - "${APP}/Contents/Frameworks/libjson-c.5.dylib"
  codesign --force --sign - "${APP}/Contents/Frameworks/libHydraSession.dylib"
  codesign --force --sign - "${APP}"
  codesign --verify --deep --strict "${APP}"
}

allowed_dependency() {
  local dep="$1"
  local app="$2"
  case "${dep}" in
    /System/Library/*|/usr/lib/*) return 0 ;;
    @rpath/*)
      local name="${dep#@rpath/}"
      [[ -e "${app}/Contents/Frameworks/${name}" ]]
      return
      ;;
    *) return 1 ;;
  esac
}

check_minos() {
  local bin="$1"
  local arch="$2"
  local minos
  minos="$(vtool -show-build -arch "${arch}" "${bin}" | awk '/minos/ { print $2; exit }')"
  [[ "${minos}" == "13.0" || "${minos}" == "13.0.0" ]] \
    || die "${bin} ${arch} minimum system is '${minos:-missing}', expected 13.0"
}

check_linkage() {
  local bin dep arch
  while IFS= read -r bin; do
    file "${bin}" | grep -q Mach-O || continue
    lipo -info "${bin}" | grep -q arm64 || die "${bin} is missing an arm64 slice"
    lipo -info "${bin}" | grep -q x86_64 || die "${bin} is missing an x86_64 slice"
    for arch in arm64 x86_64; do
      check_minos "${bin}" "${arch}"
      while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        if ! allowed_dependency "${dep}" "${APP}"; then
          die "${bin} (${arch}) links ${dep}"
        fi
      done < <(otool -L -arch "${arch}" "${bin}" | awk 'NR>1 { print $1 }')
    done
  done < <(find "${APP}" -type f)
}

ensure_rosetta
"${SCRIPT_DIR}/build-deps.sh"
"${SCRIPT_DIR}/build-freerdp.sh" arm64
"${SCRIPT_DIR}/build-freerdp.sh" x86_64
"${SCRIPT_DIR}/build-app.sh"

[[ -d "${APP}" ]] || die "app bundle was not built"
copy_licenses
sign_app
check_linkage

log "staging disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R "${APP}" "${STAGE}/Hydra AVD Client.app"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${STAGE}/Licenses"
cp "${APP}/Contents/Resources/Licenses/"* "${STAGE}/Licenses/"
cat > "${STAGE}/Read Me.txt" <<'EOF'
Hydra AVD Client

1. Control-click Hydra AVD Client and choose Open. If macOS says the app is damaged, run this in Terminal and open it again:

   xattr -dr com.apple.quarantine "/Applications/Hydra AVD Client.app"

2. Accept the license agreement. The same license texts are in the Licenses folder.
3. Enter the Hydra client key from your administrator. It is saved in the Keychain on this Mac.
4. Install the app into the Applications folder.

The disk image already contains everything the app needs. No extra packages are required.
EOF

hdiutil create -volname "${VOLUME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
hdiutil verify "${DMG}"

SMOKE="${ROOT}/ThirdParty/freerdp-build/x86_64/link-smoke/build/smoke"
[[ -x "${SMOKE}" ]] || die "Intel FreeRDP link smoke test is missing"
log "Intel FreeRDP link smoke test"
arch -x86_64 "${SMOKE}" >/dev/null

printf 'built %s\n' "${DMG}"
