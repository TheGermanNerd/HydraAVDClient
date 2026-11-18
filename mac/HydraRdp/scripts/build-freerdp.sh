#!/usr/bin/env bash
# Build pinned FreeRDP 3.33.1 as static macOS libraries for one architecture.
# Usage: build-freerdp.sh arm64|x86_64
#
# Plan names and the cmake options this tag actually uses:
#   WITH_AAD                         -DWITH_AAD=ON
#     (needs WinPR JSON; this script requires json-c from scripts/build-deps.sh)
#   ARM gateway /gateway:type:arm    no separate option. libfreerdp/core/gateway/arm.c
#                                    is compiled when WITH_AAD=ON (arm_resolve_endpoint).
#   graphics pipeline [MS-RDPEGFX]   -DCHANNEL_RDPGFX=ON -DCHANNEL_RDPGFX_CLIENT=ON
#     H.264 inside that pipeline     -DWITH_APPLE_VIDEOTOOLBOX=ON (sets WITH_GFX_H264)
#   clipboard (cliprdr)              -DCHANNEL_CLIPRDR=ON -DCHANNEL_CLIPRDR_CLIENT=ON
#   display control (disp)           -DCHANNEL_DISP=ON -DCHANNEL_DISP_CLIENT=ON
#   dynamic virtual channels         -DCHANNEL_DRDYNVC=ON -DCHANNEL_DRDYNVC_CLIENT=ON
#   printer redirection (rdpdr)      -DCHANNEL_PRINTER=ON -DCHANNEL_PRINTER_CLIENT=ON
#   UDP multitransport               -DWITH_RDPEUDP=ON
#     (experimental; needs OpenSSL, which this script already requires)
#
# Produces static libs (.a) under ThirdParty/freerdp-install/<arch>.
# OpenSSL 3 is linked statically from ThirdParty/deps/<arch>. json-c and the
# system libz stay shared dependencies recorded by the installed pkg-config files.

set -euo pipefail

FREERDP_TAG="3.33.1"
FREERDP_REPO="https://github.com/FreeRDP/FreeRDP.git"

ARCH="${1:-}"
case "${ARCH}" in
  arm64|x86_64) ;;
  *) printf 'usage: %s arm64|x86_64\n' "$(basename "$0")" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_RDP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${HYDRA_RDP_ROOT}/ThirdParty/freerdp-src"
BUILD_DIR="${HYDRA_RDP_ROOT}/ThirdParty/freerdp-build/${ARCH}"
PREFIX="${HYDRA_RDP_ROOT}/ThirdParty/freerdp-install/${ARCH}"
DEPS_PREFIX="${HYDRA_RDP_ROOT}/ThirdParty/deps/${ARCH}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' on PATH"
}

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd pkg-config
require_cmd clang

OPENSSL_PREFIX="${DEPS_PREFIX}"
JSONC_PREFIX="${DEPS_PREFIX}"

[[ -f "${OPENSSL_PREFIX}/lib/libssl.a" && -f "${OPENSSL_PREFIX}/lib/libcrypto.a" ]] \
  || die "OpenSSL 3 static libraries not found under ${OPENSSL_PREFIX}. Run scripts/build-deps.sh first."
[[ -f "${JSONC_PREFIX}/include/json-c/json.h" ]] \
  || die "json-c headers not found under ${JSONC_PREFIX}. Run scripts/build-deps.sh first."

# Only the prefixes this script builds. An inherited Homebrew pkg-config path
# would turn optional codecs and libraries on and link them into the app.
export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig:${JSONC_PREFIX}/lib/pkgconfig"

log "FreeRDP tag ${FREERDP_TAG}"
log "source ${SRC_DIR}"
log "build  ${BUILD_DIR}"
log "prefix ${PREFIX}"
log "OpenSSL ${OPENSSL_PREFIX}"
log "json-c  ${JSONC_PREFIX}"

if [[ -e "${SRC_DIR}" && ! -d "${SRC_DIR}/.git" ]]; then
  die "${SRC_DIR} exists but is not a git checkout. Move it aside and re-run."
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  log "cloning ${FREERDP_TAG} (depth 1, no full history)"
  git clone --depth 1 --branch "${FREERDP_TAG}" "${FREERDP_REPO}" "${SRC_DIR}"
fi

log "fetching tag ${FREERDP_TAG}"
git -C "${SRC_DIR}" fetch --depth 1 origin "refs/tags/${FREERDP_TAG}:refs/tags/${FREERDP_TAG}"
git -C "${SRC_DIR}" checkout --detach --force "${FREERDP_TAG}"

described="$(git -C "${SRC_DIR}" describe --tags --exact-match HEAD)"
[[ "${described}" == "${FREERDP_TAG}" ]] || die "checkout is '${described}', expected tag ${FREERDP_TAG}"
commit="$(git -C "${SRC_DIR}" rev-parse HEAD)"
log "checked out ${described} (${commit})"

mkdir -p "${BUILD_DIR}"
cat > "${BUILD_DIR}/enable-objc.cmake" <<'EOF'
enable_language(OBJC)
EOF

cmake_args=(
  -G Ninja
  -S "${SRC_DIR}"
  -B "${BUILD_DIR}"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES="${ARCH}"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}"
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_PREFIX_PATH="${OPENSSL_PREFIX};${JSONC_PREFIX}"
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}"
  -DOPENSSL_USE_STATIC_LIBS=ON
  -DCMAKE_PROJECT_INCLUDE="${BUILD_DIR}/enable-objc.cmake"
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
  -DWITH_SERVER=OFF
  -DWITH_SAMPLE=OFF
  -DWITH_CLIENT=ON
  -DWITH_CLIENT_COMMON=ON
  -DWITH_CLIENT_CHANNELS=ON
  -DWITH_CHANNELS=ON
  -DWITH_SERVER_CHANNELS=OFF
  -DWITH_CLIENT_SDL=OFF
  -DWITH_CLIENT_MAC=OFF
  -DWITH_X11=OFF
  -DWITH_MANPAGES=OFF
  -DWITH_CCACHE=OFF
  -DWITH_CLANG_FORMAT=OFF
  -DWITH_FFMPEG=OFF
  -DWITH_SWSCALE=OFF
  -DWITH_CAIRO=OFF
  -DWITH_OPENH264=OFF
  -DWITH_OPENCL=OFF
  -DWITH_MBEDTLS=OFF
  -DWITH_LIBRESSL=OFF
  -DWITH_GSM=OFF
  -DWITH_OPUS=OFF
  -DWITH_URIPARSER=OFF
  -DWITH_LAME=OFF
  -DWITH_FAAD2=OFF
  -DWITH_FAAC=OFF
  -DWITH_SOXR=OFF
  -DWITH_AOM=OFF
  -DWITH_DAV1D=OFF
  -DWITH_YUV=OFF
  -DWITH_GFX_AV1=OFF
  -DWITH_WINPR_TOOLS=OFF
  -DCHANNEL_URBDRC=OFF
  -DCHANNEL_URBDRC_CLIENT=OFF
  -DCHANNEL_PRINTER=ON
  -DCHANNEL_PRINTER_CLIENT=ON
  -DWITH_JSON_DISABLED=OFF
  -DWITH_JSONC_REQUIRED=ON
  -DWITH_AAD=ON
  -DWITH_APPLE_VIDEOTOOLBOX=ON
  -DCHANNEL_DRDYNVC=ON
  -DCHANNEL_DRDYNVC_CLIENT=ON
  -DCHANNEL_CLIPRDR=ON
  -DCHANNEL_CLIPRDR_CLIENT=ON
  -DCHANNEL_DISP=ON
  -DCHANNEL_DISP_CLIENT=ON
  -DCHANNEL_RDPGFX=ON
  -DCHANNEL_RDPGFX_CLIENT=ON
  -DWITH_RDPEUDP=ON
)

log "configuring"
cmake "${cmake_args[@]}"

cache="${BUILD_DIR}/CMakeCache.txt"
require_cache_on() {
  local key="$1"
  if ! grep -E "^${key}:[A-Z]+=ON$" "${cache}" >/dev/null; then
    die "cmake cache does not have ${key}=ON. See ${cache}"
  fi
}

require_cache_on WITH_AAD
require_cache_on WITH_APPLE_VIDEOTOOLBOX
require_cache_on WITH_CLIENT
require_cache_on WITH_CLIENT_CHANNELS
require_cache_on WITH_CHANNELS
require_cache_on CHANNEL_CLIPRDR
require_cache_on CHANNEL_CLIPRDR_CLIENT
require_cache_on CHANNEL_DISP
require_cache_on CHANNEL_DISP_CLIENT
require_cache_on CHANNEL_DRDYNVC
require_cache_on CHANNEL_DRDYNVC_CLIENT
require_cache_on CHANNEL_RDPGFX
require_cache_on CHANNEL_RDPGFX_CLIENT
require_cache_on CHANNEL_PRINTER
require_cache_on CHANNEL_PRINTER_CLIENT
require_cache_on WITH_RDPEUDP

if ! grep -E '^BUILD_SHARED_LIBS:BOOL=OFF$' "${cache}" >/dev/null; then
  die "BUILD_SHARED_LIBS is not OFF. See ${cache}"
fi
if ! grep -E "^CMAKE_OSX_ARCHITECTURES:STRING=${ARCH}$" "${cache}" >/dev/null; then
  die "CMAKE_OSX_ARCHITECTURES is not ${ARCH}. See ${cache}"
fi
if ! grep -E '^WITH_WINPR_JSON:INTERNAL=ON$' "${cache}" >/dev/null; then
  die "WITH_WINPR_JSON is not ON (AAD and the ARM gateway need it). See ${cache}"
fi
openssl_version="$(sed -n 's/^_OPENSSL_VERSION:INTERNAL=//p' "${cache}" | head -1)"
case "${openssl_version}" in
  3.*) ;;
  *) die "expected OpenSSL 3.x, cmake found '${openssl_version:-<missing>}'. See ${cache}" ;;
esac
log "OpenSSL version selected by cmake: ${openssl_version}"

log "building"
cmake --build "${BUILD_DIR}" --parallel

log "installing"
rm -rf "${PREFIX}"
cmake --install "${BUILD_DIR}"

require_file() {
  [[ -f "$1" ]] || die "missing installed file $1"
}

require_file "${PREFIX}/lib/libfreerdp3.a"
require_file "${PREFIX}/lib/libfreerdp-client3.a"
require_file "${PREFIX}/lib/libwinpr3.a"
require_file "${PREFIX}/include/freerdp3/freerdp/freerdp.h"
require_file "${PREFIX}/include/winpr3/winpr/wtypes.h"

# nm exits non-zero when an archive member has no symbols. The ARM gateway
# object still has to be present.
arm_sym="$(nm "${PREFIX}/lib/libfreerdp3.a" 2>/dev/null | grep 'arm_resolve_endpoint' || true)"
[[ -n "${arm_sym}" ]] || die "libfreerdp3.a does not contain arm_resolve_endpoint (ARM gateway was not compiled)"

config_header="$(find "${PREFIX}/include" -name config.h -path '*freerdp*' | head -1)"
[[ -n "${config_header}" ]] || config_header="$(find "${BUILD_DIR}" -name config.h -path '*freerdp/config.h' | head -1)"
[[ -n "${config_header}" ]] || die "could not find freerdp config.h to confirm WITH_AAD / WITH_GFX_H264"
grep -q 'WITH_AAD' "${config_header}" || die "WITH_AAD is missing from ${config_header}"
grep -q 'WITH_GFX_H264' "${config_header}" || die "WITH_GFX_H264 is missing from ${config_header} (graphics pipeline H.264)"
grep -q '#define WITH_RDPEUDP' "${config_header}" || die "WITH_RDPEUDP is missing from ${config_header}"

smoke_dir="${BUILD_DIR}/link-smoke"
mkdir -p "${smoke_dir}"
cat > "${smoke_dir}/smoke.c" <<'EOF'
#include <stdio.h>
#include <freerdp/freerdp.h>

/* Entry points compiled into libfreerdp-client3.a for the channels we require. */
void rdpgfx_DVCPluginEntry(void);
void disp_DVCPluginEntry(void);
void cliprdr_VirtualChannelEntryEx(void);
void drdynvc_VirtualChannelEntryEx(void);

int main(void)
{
	void (*entries[])(void) = {
		rdpgfx_DVCPluginEntry,
		disp_DVCPluginEntry,
		cliprdr_VirtualChannelEntryEx,
		drdynvc_VirtualChannelEntryEx,
	};
	const char* version = freerdp_get_version_string();
	const char* config = freerdp_get_build_config();
	if (!version || !config || !entries[0] || !entries[1] || !entries[2] || !entries[3])
		return 1;
	puts(version);
	puts(config);
	return 0;
}
EOF

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
# The printer channel records CUPS as a private dependency. macOS provides
# libcups without a cups.pc, and the CMake targets link that system library.
if ! pkg-config --exists cups; then
  cups_pc="${BUILD_DIR}/pkgconfig"
  mkdir -p "${cups_pc}"
  cat > "${cups_pc}/cups.pc" <<'EOF'
Name: cups
Description: System CUPS
Version: 2.0
Libs: -lcups
Cflags:
EOF
  export PKG_CONFIG_PATH="${cups_pc}:${PKG_CONFIG_PATH}"
fi
pkg-config --exists freerdp3
pkg-config --exists freerdp-client3

# The install prefix contains spaces. Link through the exported CMake targets
# instead of splitting pkg-config output on those spaces.
cat > "${smoke_dir}/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.13)
project(freerdp_link_smoke LANGUAGES C OBJC)
set(CMAKE_OSX_ARCHITECTURES ${ARCH})
set(CMAKE_OSX_DEPLOYMENT_TARGET ${MACOSX_DEPLOYMENT_TARGET})
find_package(WinPR 3 REQUIRED CONFIG)
find_package(FreeRDP 3 REQUIRED CONFIG)
find_package(FreeRDP-Client 3 REQUIRED CONFIG)
add_executable(smoke smoke.c)
target_link_libraries(smoke PRIVATE freerdp-client)
EOF

cmake -S "${smoke_dir}" -B "${smoke_dir}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${PREFIX};${JSONC_PREFIX}" \
  -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}"
cmake --build "${smoke_dir}/build" --parallel
smoke_out="$("${smoke_dir}/build/smoke")"
printf '%s\n' "${smoke_out}" | head -1 | grep -q '^3\.33\.1' \
  || die "link smoke test did not report FreeRDP 3.33.1: ${smoke_out}"
printf '%s\n' "${smoke_out}" | grep -q 'WITH_AAD=ON' \
  || die "linked build config does not contain WITH_AAD=ON"
printf '%s\n' "${smoke_out}" | grep -q 'WITH_RDPEUDP=ON' \
  || die "linked build config does not contain WITH_RDPEUDP=ON"
file "${smoke_dir}/build/smoke" | grep -q "${ARCH}" \
  || die "link smoke test binary is not ${ARCH}"

info="${PREFIX}/freerdp-build-info.txt"
{
  echo "tag=${FREERDP_TAG}"
  echo "commit=${commit}"
  echo "prefix=${PREFIX}"
  echo "libraries=static"
  echo "openssl=${openssl_version}"
  echo "openssl_prefix=${OPENSSL_PREFIX}"
  echo "jsonc_prefix=${JSONC_PREFIX}"
  echo "config_header=${config_header}"
  echo "link=find_package(WinPR 3 CONFIG) find_package(FreeRDP 3 CONFIG) find_package(FreeRDP-Client 3 CONFIG) then target_link_libraries(app PRIVATE freerdp-client)"
  echo "cmake_prefix_path=${PREFIX};${JSONC_PREFIX}"
  echo "pkgconfig_dir=${PREFIX}/lib/pkgconfig"
  echo "cmake_cache_flags:"
  grep -E '^(WITH_AAD|WITH_RDPEUDP|WITH_WINPR_JSON|WITH_APPLE_VIDEOTOOLBOX|WITH_GFX_H264|WITH_CLIENT|WITH_CLIENT_CHANNELS|WITH_CHANNELS|WITH_SERVER|WITH_FFMPEG|BUILD_SHARED_LIBS|CHANNEL_CLIPRDR|CHANNEL_CLIPRDR_CLIENT|CHANNEL_DISP|CHANNEL_DISP_CLIENT|CHANNEL_DRDYNVC|CHANNEL_DRDYNVC_CLIENT|CHANNEL_RDPGFX|CHANNEL_RDPGFX_CLIENT|CHANNEL_URBDRC|_OPENSSL_VERSION|CMAKE_OSX_ARCHITECTURES):' \
    "${cache}" | sort
  echo "installed_libraries:"
  find "${PREFIX}/lib" -type f \( -name '*.a' -o -name '*.dylib' \) | sort
  echo "installed_header_roots:"
  find "${PREFIX}/include" -type d -mindepth 1 -maxdepth 1 | sort
} > "${info}"

log "installed ${FREERDP_TAG} (${commit}) into ${PREFIX}"
log "static libraries, OpenSSL ${openssl_version}"
cat "${info}"
