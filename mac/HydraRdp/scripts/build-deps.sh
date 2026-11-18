#!/usr/bin/env bash
# Build OpenSSL 3.5.9 (static) and json-c 0.19 (shared) for arm64 and x86_64.
# Deployment target is macOS 13 so the libraries can ship inside the app.
set -euo pipefail

OPENSSL_VERSION="3.5.9"
JSONC_VERSION="0.19"
JSONC_TAG="json-c-0.19-20260627"
DEPLOYMENT_TARGET="13.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPS="${ROOT}/ThirdParty/deps"
SRC="${DEPS}/src"
OPENSSL_SRC="${SRC}/openssl"
JSONC_SRC="${SRC}/json-c"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' on PATH"
}

require_cmd curl
require_cmd tar
require_cmd cmake
require_cmd ninja
require_cmd clang
require_cmd make
require_cmd perl

ensure_rosetta() {
  if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    return
  fi
  log "installing Rosetta 2 so the Intel slice can be configured and checked"
  softwareupdate --install-rosetta --agree-to-license
  arch -x86_64 /usr/bin/true >/dev/null 2>&1 || die "Rosetta 2 is required to build the Intel slice"
}

fetch() {
  local url="$1"
  local dest="$2"
  curl -L --fail --retry 3 --retry-delay 2 -o "${dest}" "${url}"
}

prepare_openssl_source() {
  if [[ -x "${OPENSSL_SRC}/Configure" ]]; then
    return
  fi
  local tarball="${SRC}/openssl-${OPENSSL_VERSION}.tar.gz"
  local url="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
  mkdir -p "${SRC}"
  log "downloading OpenSSL ${OPENSSL_VERSION}"
  fetch "${url}" "${tarball}"
  rm -rf "${SRC}/openssl-${OPENSSL_VERSION}" "${OPENSSL_SRC}"
  tar -xzf "${tarball}" -C "${SRC}"
  mv "${SRC}/openssl-${OPENSSL_VERSION}" "${OPENSSL_SRC}"
}

prepare_jsonc_source() {
  if [[ -f "${JSONC_SRC}/CMakeLists.txt" ]]; then
    return
  fi
  local tarball="${SRC}/json-c-${JSONC_VERSION}.tar.gz"
  local url="https://github.com/json-c/json-c/archive/refs/tags/${JSONC_TAG}.tar.gz"
  mkdir -p "${SRC}"
  log "downloading json-c ${JSONC_VERSION}"
  fetch "${url}" "${tarball}"
  rm -rf "${SRC}/json-c-extract" "${JSONC_SRC}"
  mkdir -p "${SRC}/json-c-extract"
  tar -xzf "${tarball}" -C "${SRC}/json-c-extract"
  local extracted
  extracted="$(find "${SRC}/json-c-extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "${extracted}" && -f "${extracted}/CMakeLists.txt" ]] || die "json-c archive did not contain a CMake project"
  mv "${extracted}" "${JSONC_SRC}"
  rm -rf "${SRC}/json-c-extract"
}

openssl_target() {
  case "$1" in
    arm64) printf 'darwin64-arm64-cc' ;;
    x86_64) printf 'darwin64-x86_64-cc' ;;
    *) die "unsupported architecture $1" ;;
  esac
}

# OpenSSL's makefile splits the source and prefix paths on spaces. The checkout
# lives under a path with spaces, so the compiler runs against a space-free copy
# and installs through a space-free symlink back into ThirdParty/deps.
NOSPACE_SRC="/tmp/hydra-avd-src"
NOSPACE_PREFIX="/tmp/hydra-avd-deps"

stage_spacefree_sources() {
  mkdir -p "${NOSPACE_SRC}"
  ln -sfn "${DEPS}" "${NOSPACE_PREFIX}"
  if [[ ! -x "${NOSPACE_SRC}/openssl/Configure" ]]; then
    rm -rf "${NOSPACE_SRC}/openssl"
    cp -R "${OPENSSL_SRC}" "${NOSPACE_SRC}/openssl"
  fi
  if [[ ! -f "${NOSPACE_SRC}/json-c/CMakeLists.txt" ]]; then
    rm -rf "${NOSPACE_SRC}/json-c"
    cp -R "${JSONC_SRC}" "${NOSPACE_SRC}/json-c"
  fi
}

build_openssl() {
  local arch="$1"
  local prefix="${NOSPACE_PREFIX}/${arch}"
  local build="${NOSPACE_SRC}/openssl-build-${arch}"
  log "OpenSSL ${OPENSSL_VERSION} for ${arch}"
  rm -rf "${build}"
  mkdir -p "${build}"
  (
    cd "${build}"
    export MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
    "${NOSPACE_SRC}/openssl/Configure" "$(openssl_target "${arch}")" \
      no-shared \
      no-tests \
      --prefix="${prefix}" \
      --libdir=lib \
      -mmacosx-version-min="${DEPLOYMENT_TARGET}"
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
  )
  [[ -f "${DEPS}/${arch}/lib/libssl.a" && -f "${DEPS}/${arch}/lib/libcrypto.a" ]] \
    || die "OpenSSL static libraries were not installed at ${DEPS}/${arch}"
}

build_jsonc() {
  local arch="$1"
  local prefix="${NOSPACE_PREFIX}/${arch}"
  local build="${NOSPACE_SRC}/json-c-build-${arch}"
  log "json-c ${JSONC_VERSION} for ${arch}"
  rm -rf "${build}"
  export MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
  cmake -S "${NOSPACE_SRC}/json-c" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_MACOSX_RPATH=ON
  cmake --build "${build}" --parallel
  cmake --install "${build}"
  [[ -f "${DEPS}/${arch}/lib/libjson-c.5.dylib" || -f "${DEPS}/${arch}/lib/libjson-c.dylib" ]] \
    || die "json-c shared library was not installed at ${DEPS}/${arch}"
}

jsonc_ready() {
  local prefix="$1"
  [[ -f "${prefix}/lib/libjson-c.5.dylib" || -f "${prefix}/lib/libjson-c.dylib" ]]
}

ensure_rosetta
prepare_openssl_source
prepare_jsonc_source
[[ -f "${OPENSSL_SRC}/LICENSE.txt" ]] || die "OpenSSL LICENSE.txt is missing from ${OPENSSL_SRC}"
[[ -f "${JSONC_SRC}/COPYING" ]] || die "json-c COPYING is missing from ${JSONC_SRC}"
stage_spacefree_sources

for arch in arm64 x86_64; do
  prefix="${DEPS}/${arch}"
  if [[ -f "${prefix}/lib/libssl.a" && -f "${prefix}/lib/libcrypto.a" ]] && jsonc_ready "${prefix}"; then
    log "dependencies for ${arch} already installed at ${prefix}"
    continue
  fi
  mkdir -p "${prefix}"
  build_openssl "${arch}"
  build_jsonc "${arch}"
done

log "OpenSSL ${OPENSSL_VERSION} and json-c ${JSONC_VERSION} are installed for arm64 and x86_64"
