#!/usr/bin/env bash
# The release gate: build, test and install the release artifacts of the
# checked-out revision, and keep the results.
#
#   1. the native engine and programs (scripts/build_odin.sh)
#   2. the Odin test groups and the Python tests
#   3. the source distribution, and the wheel built from it (as an installer
#      would: in a temporary directory that is gone afterwards)
#   4. the wheel installed into a new environment outside the checkout: the
#      programs, the Python package, Sphinx, and the documentation builds
#   5. the PDF books, when a TeX engine is installed (skipped, and said so,
#      otherwise)
#
# The tree must be clean.  Results go to build/release-gate/<revision>/
# (gate.log, the artifacts and the built documentation).
#
# Usage: scripts/release_gate.sh [--allow-dirty]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ "${1:-}" != "--allow-dirty" && -n "$(git status --porcelain)" ]]; then
    echo "release gate: the working tree has changes; commit them or pass --allow-dirty" >&2
    exit 2
fi
REVISION="$(git rev-parse HEAD)"
OUT="${ROOT}/build/release-gate/${REVISION}"
rm -rf "${OUT}"
mkdir -p "${OUT}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
exec > >(tee "${OUT}/gate.log") 2>&1

step() { printf '\n=== %s ===\n' "$*"; }

step "revision ${REVISION}"
echo "platform: $(uname -srm)"
echo "odin: $(odin version)"
echo "uv: $(uv --version)"

step "native engine and programs"
scripts/build_odin.sh

step "Odin tests"
for dir in odin/tests odin/*/tests; do
    [[ -d "${dir}" ]] || continue
    echo "--- ${dir}"
    odin test "${dir}" -vet -strict-style
done

step "Python tests"
uv run --extra test python -m pytest -q tests

step "source distribution and wheel"
uv build --sdist -o "${OUT}/dist"
SDIST="$(ls "${OUT}"/dist/*.tar.gz)"
tar -xzf "${SDIST}" -C "${WORK}"
(cd "${WORK}"/docodin-*/ && uv build --wheel -o "${OUT}/dist")
rm -rf "${WORK}"/docodin-*/   # the installed programs must not need their build tree
WHEEL="$(ls "${OUT}"/dist/*.whl)"
echo "${SDIST}"
echo "${WHEEL}"

step "install outside the checkout"
VENV="${WORK}/venv"
uv venv -q "${VENV}"
uv pip install -q -p "${VENV}/bin/python" "${WHEEL}" "sphinx>=8.0"
BIN="${VENV}/bin"
cd "${WORK}"
for program in docodin docodin-check docodin-lsp; do
    "${BIN}/${program}" --version
done
printf 'Smoke\n=====\n\n.. include:: <isonum.txt>\n\n|copy| docodin, *native*.\n' > smoke.rst
"${BIN}/docodin" smoke.rst smoke.html
grep -q '© docodin' smoke.html
"${BIN}/docodin" latex smoke.rst smoke.tex
"${BIN}/docodin-check" smoke.rst
"${BIN}/python" -c 'import docodin; print("docodin", docodin.__version__, docodin.native().version)'
mkdir -p sphinx-project
printf 'project = "Smoke"\n' > sphinx-project/conf.py
cp smoke.rst sphinx-project/index.rst
"${BIN}/docodin" sphinx -q -W -b html sphinx-project sphinx-out
DOCODIN_DOCUTILS=1 "${BIN}/docodin-sphinx-build" -q -W -b html sphinx-project sphinx-out2
echo "installed programs, library, Sphinx wrapper: ok"

step "documentation, built by the installed docodin"
ENGINE=""
for candidate in lualatex /Library/TeX/texbin/lualatex; do
    if command -v "${candidate}" > /dev/null; then ENGINE="${candidate}"; break; fi
done
for project in book dod; do
    if [[ -n "${ENGINE}" ]]; then
        PATH="$(dirname "$(command -v "${ENGINE}")"):${PATH}" \
            "${BIN}/docodin" book build "${ROOT}/docs/${project}" -o "${OUT}/docs/${project}" -W
    else
        "${BIN}/docodin" book build "${ROOT}/docs/${project}" -o "${OUT}/docs/${project}" \
            --html -W
    fi
done
if [[ -n "${ENGINE}" ]]; then
    ls -l "${OUT}"/docs/*/latex/*.pdf
else
    echo "PDF books: SKIPPED (no lualatex on this machine)"
fi

step "passed"
echo "revision ${REVISION}: all gate steps passed; results in ${OUT}"
