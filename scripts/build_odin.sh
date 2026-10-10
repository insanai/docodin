#!/usr/bin/env bash
# Build the docodin shared library (libdocodin.{dylib,so} / docodin.dll) and
# the native programs (bin/docodin, bin/docodin-check, bin/docodin-lsp).
#
# The package is compiled to a single object and linked with the system
# toolchain; ``docodin_init`` is registered as the library initializer so the
# Odin runtime start-up runs on load.  (Linking directly with
# ``-build-mode:shared`` is broken on macOS in current Odin releases.)
#
# Usage: scripts/build_odin.sh [--debug]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ODIN_DIR="${PROJECT_DIR}/odin"
PKG_DIR="${PROJECT_DIR}/python/docodin"
BUILD_DIR="${PROJECT_DIR}/build"
mkdir -p "${BUILD_DIR}"

OPT=(-o:speed -vet -strict-style)
if [[ "${1:-}" == "--debug" ]]; then
    OPT=(-debug -o:none -vet -strict-style)
fi

echo "=== Building docodin native library ==="
case "$(uname -s)" in
    Darwin*)
        LIB_NAME="libdocodin.dylib"
        # the oldest macOS the library supports (also the wheel's platform tag)
        MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
        odin build "${ODIN_DIR}/lib" -build-mode:obj -use-single-module "${OPT[@]}" \
            -minimum-os-version:"${MIN_OS}" -out:"${BUILD_DIR}/docodin.o"
        clang -shared -mmacosx-version-min="${MIN_OS}" -o "${BUILD_DIR}/${LIB_NAME}" \
            "${BUILD_DIR}/docodin.o" -Wl,-init,_docodin_init -Wl,-dead_strip
        ;;
    Linux*)
        LIB_NAME="libdocodin.so"
        odin build "${ODIN_DIR}/lib" -build-mode:obj -use-single-module -reloc-mode:pic "${OPT[@]}" -out:"${BUILD_DIR}/docodin.o"
        cc -shared -fPIC -o "${BUILD_DIR}/${LIB_NAME}" "${BUILD_DIR}/docodin.o" \
            -Wl,-init,docodin_init -Wl,--gc-sections -lm -lpthread
        ;;
    *)
        LIB_NAME="docodin.dll"
        odin build "${ODIN_DIR}/lib" -build-mode:shared "${OPT[@]}" -out:"${BUILD_DIR}/${LIB_NAME}"
        ;;
esac

# Replace the library atomically: overwriting a loaded (and on macOS
# code-signed) library in place makes the kernel kill processes using it.
cp "${BUILD_DIR}/${LIB_NAME}" "${PKG_DIR}/.${LIB_NAME}.tmp"
mv -f "${PKG_DIR}/.${LIB_NAME}.tmp" "${PKG_DIR}/${LIB_NAME}"
echo "Built ${PKG_DIR}/${LIB_NAME}"

# The programs: built aside and moved into place, as running programs (an
# editor's language server) must not be overwritten in place.  On macOS they
# target the library's minimum version: the wheel installs them too.
PROGRAM_OPT=("${OPT[@]}")
if [[ "$(uname -s)" == Darwin* ]]; then
    PROGRAM_OPT+=(-minimum-os-version:"${MIN_OS}")
fi
mkdir -p "${PROJECT_DIR}/bin"

build_program() {
    local name="$1" title="$2"
    echo "=== Building ${title} ==="
    odin build "${PROJECT_DIR}/cmd/${name}" "${PROGRAM_OPT[@]}" -out:"${BUILD_DIR}/${name}"
    mv -f "${BUILD_DIR}/${name}" "${PROJECT_DIR}/bin/${name}"
    echo "Built ${PROJECT_DIR}/bin/${name}"
}

build_program docodin-check "docodin native checker"
build_program docodin "docodin standalone CLI compiler"
build_program docodin-lsp "docodin language server"
