#!/usr/bin/env bash
# Build a universal HydraRdp.app (arm64 + x86_64) against the FreeRDP prefixes
# from scripts/build-freerdp.sh and the libraries from scripts/build-deps.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

jsonc_library() {
  local prefix="$1"
  if [[ -f "${prefix}/lib/libjson-c.5.dylib" ]]; then
    printf '%s\n' "${prefix}/lib/libjson-c.5.dylib"
    return
  fi
  if [[ -f "${prefix}/lib/libjson-c.dylib" ]]; then
    printf '%s\n' "${prefix}/lib/libjson-c.dylib"
    return
  fi
  die "json-c shared library is missing under ${prefix}/lib. Run scripts/build-deps.sh."
}

rewrite_jsonc() {
  local lib="$1"
  local dep
  while IFS= read -r dep; do
    case "${dep}" in
      *libjson-c*.dylib)
        if [[ "${dep}" != "@rpath/libjson-c.5.dylib" ]]; then
          install_name_tool -change "${dep}" "@rpath/libjson-c.5.dylib" "${lib}"
        fi
        ;;
    esac
  done < <(otool -L "${lib}" | awk 'NR>1 {print $1}')
}

strip_rpaths() {
  local bin="$1"
  local path
  while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    case "${path}" in
      /usr/lib/swift|@*) ;;
      *) install_name_tool -delete_rpath "${path}" "${bin}" || true ;;
    esac
  done < <(otool -l "${bin}" | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}')
}

build_session() {
  local arch="$1"
  local freerdp="${ROOT}/ThirdParty/freerdp-install/${arch}"
  local deps="${ROOT}/ThirdParty/deps/${arch}"
  [[ -f "${freerdp}/lib/libfreerdp-client3.a" ]] \
    || die "FreeRDP for ${arch} is not installed. Run scripts/build-freerdp.sh ${arch}."
  jsonc_library "${deps}" >/dev/null
  local build="${ROOT}/build/session-${arch}"
  local out="${ROOT}/build/lib-${arch}"
  mkdir -p "${out}"
  cmake -S "${ROOT}/SessionEngine" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_PREFIX_PATH="${freerdp};${deps}" \
    -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="${out}"
  cmake --build "${build}" --parallel
  [[ -f "${out}/libHydraSession.dylib" ]] || die "session library for ${arch} was not built"
  rewrite_jsonc "${out}/libHydraSession.dylib"
  strip_rpaths "${out}/libHydraSession.dylib"
}

log "session library"
build_session arm64
build_session x86_64
mkdir -p "${ROOT}/build/lib"
lipo -create \
  "${ROOT}/build/lib-arm64/libHydraSession.dylib" \
  "${ROOT}/build/lib-x86_64/libHydraSession.dylib" \
  -output "${ROOT}/build/lib/libHydraSession.dylib"

build_swift() {
  local triple="$1"
  local arch="${triple%%-*}"
  local scratch="${ROOT}/.build/${arch}"
  local built copied
  swift build --package-path "${ROOT}" -c release --product HydraRdp \
    --triple "${triple}" --scratch-path "${scratch}" \
    -Xlinker -L"${ROOT}/build/lib" \
    -Xlinker -lHydraSession \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks >&2
  built="$(swift build --package-path "${ROOT}" -c release --product HydraRdp \
    --triple "${triple}" --scratch-path "${scratch}" --show-bin-path 2>/dev/null)/HydraRdp"
  [[ -f "${built}" ]] || die "Swift build for ${triple} did not produce ${built}"
  mkdir -p "${ROOT}/build/bin"
  copied="${ROOT}/build/bin/HydraRdp-${arch}"
  cp "${built}" "${copied}"
  printf '%s\n' "${copied}"
}

log "Swift app"
ARM_BIN="$(build_swift arm64-apple-macosx13.0)"
X64_BIN="$(build_swift x86_64-apple-macosx13.0)"
[[ -f "${ARM_BIN}" && -f "${X64_BIN}" ]] || die "Swift build did not produce both architecture binaries"
strip_rpaths "${ARM_BIN}"
strip_rpaths "${X64_BIN}"
mkdir -p "${ROOT}/build/bin"
lipo -create "${ARM_BIN}" "${X64_BIN}" -output "${ROOT}/build/bin/HydraRdp"

ARM_JSONC="$(jsonc_library "${ROOT}/ThirdParty/deps/arm64")"
X64_JSONC="$(jsonc_library "${ROOT}/ThirdParty/deps/x86_64")"
WORKDIR="$(mktemp -d)"
cp -L "${ARM_JSONC}" "${WORKDIR}/libjson-c-arm64.dylib"
cp -L "${X64_JSONC}" "${WORKDIR}/libjson-c-x86_64.dylib"
install_name_tool -id "@rpath/libjson-c.5.dylib" "${WORKDIR}/libjson-c-arm64.dylib"
install_name_tool -id "@rpath/libjson-c.5.dylib" "${WORKDIR}/libjson-c-x86_64.dylib"
lipo -create "${WORKDIR}/libjson-c-arm64.dylib" "${WORKDIR}/libjson-c-x86_64.dylib" \
  -output "${WORKDIR}/libjson-c.5.dylib"

APP="${ROOT}/build/HydraRdp.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Frameworks" "${APP}/Contents/Resources/Licenses"
cp "${ROOT}/build/bin/HydraRdp" "${APP}/Contents/MacOS/HydraRdp"
cp "${ROOT}/build/lib/libHydraSession.dylib" "${APP}/Contents/Frameworks/libHydraSession.dylib"
cp "${WORKDIR}/libjson-c.5.dylib" "${APP}/Contents/Frameworks/libjson-c.5.dylib"
cp "${ROOT}/Support/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/Support/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
rm -rf "${WORKDIR}"

copy_license() {
  local source="$1"
  local name="$2"
  if [[ -f "${source}" ]]; then
    cp "${source}" "${APP}/Contents/Resources/Licenses/${name}"
  fi
}
copy_license "${ROOT}/ThirdParty/freerdp-src/LICENSE" "FreeRDP-LICENSE.txt"
copy_license "${ROOT}/ThirdParty/deps/src/openssl/LICENSE.txt" "OpenSSL-LICENSE.txt"
copy_license "${ROOT}/ThirdParty/deps/src/json-c/COPYING" "json-c-COPYING.txt"

log "signing ${APP}"
codesign --force --sign - "${APP}/Contents/Frameworks/libjson-c.5.dylib"
codesign --force --sign - "${APP}/Contents/Frameworks/libHydraSession.dylib"
codesign --force --sign - "${APP}"
codesign --verify --deep --strict "${APP}"
lipo -info "${APP}/Contents/MacOS/HydraRdp" "${APP}/Contents/Frameworks/libHydraSession.dylib" "${APP}/Contents/Frameworks/libjson-c.5.dylib"
printf 'built %s\n' "${APP}"
