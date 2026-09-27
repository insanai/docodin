#!/usr/bin/env bash
# Build the docodin shared library (libdocodin.{dylib,so} / docodin.dll) and
# the native checker (bin/docodin-check).
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
        odin build "${ODIN_DIR}/lib" -build-mode:obj -use-single-module "${OPT[@]}" -out:"${BUILD_DIR}/docodin.o"
        clang -shared -o "${BUILD_DIR}/${LIB_NAME}" "${BUILD_DIR}/docodin.o" \
            -Wl,-init,_docodin_init -Wl,-dead_strip
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

cp "${BUILD_DIR}/${LIB_NAME}" "${PKG_DIR}/${LIB_NAME}"
echo "Built ${PKG_DIR}/${LIB_NAME}"

echo "=== Building docodin native checker ==="
mkdir -p "${PROJECT_DIR}/bin"
odin build "${PROJECT_DIR}/cmd/docodin-check" "${OPT[@]}" -out:"${PROJECT_DIR}/bin/docodin-check"
echo "Built ${PROJECT_DIR}/bin/docodin-check"

echo "=== Building docodin standalone CLI compiler ==="
odin build "${PROJECT_DIR}/cmd/docodin" "${OPT[@]}" -out:"${PROJECT_DIR}/bin/docodin"
echo "Built ${PROJECT_DIR}/bin/docodin"

