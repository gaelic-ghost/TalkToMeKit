#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Stage a bundled CPython runtime into this package.

Usage:
  scripts/stage_python_runtime.sh [options]

Options:
  --python PATH           Python interpreter to use (default: python3)
  --runtime-root PATH     Destination runtime root
                          (default: Sources/TTMPythonRuntimeBundle/Resources/Runtime/current)
  --model-id ID           Qwen model id pre-download hint (default: Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice)
  --install-qwen          Install qwen-tts and dependencies into the runtime environment (default)
  --no-install-qwen       Skip package installation; stage from current environment only
  --help                  Show this help
USAGE
}

PYTHON_BIN="python3"
RUNTIME_ROOT="Sources/TTMPythonRuntimeBundle/Resources/Runtime/current"
MODEL_ID="Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
INSTALL_QWEN="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --runtime-root)
      RUNTIME_ROOT="$2"
      shift 2
      ;;
    --model-id)
      MODEL_ID="$2"
      shift 2
      ;;
    --install-qwen)
      INSTALL_QWEN="1"
      shift
      ;;
    --no-install-qwen)
      INSTALL_QWEN="0"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python interpreter not found: $PYTHON_BIN" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
VENV_DIR="$WORK_DIR/venv"

"$PYTHON_BIN" -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

if [[ "$INSTALL_QWEN" == "1" ]]; then
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install "qwen-tts"
  python -m pip install "huggingface_hub[cli]"
fi

PY_INFO_FILE="$WORK_DIR/python-info.json"
python - <<'PY' > "$PY_INFO_FILE"
import json
import os
import site
import sys
import sysconfig

def resolve_libpython():
    libdir = sysconfig.get_config_var("LIBDIR") or ""
    ldlibrary = sysconfig.get_config_var("LDLIBRARY") or ""
    framework_prefix = sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX") or ""
    framework_name = sysconfig.get_config_var("PYTHONFRAMEWORK") or ""
    version = f"{sys.version_info.major}.{sys.version_info.minor}"

    candidates = []
    if ldlibrary:
        if os.path.isabs(ldlibrary):
            candidates.append(ldlibrary)
        else:
            candidates.append(os.path.join(libdir, ldlibrary))
            if "/" in ldlibrary:
                candidates.append(os.path.join(framework_prefix, ldlibrary))

    if framework_prefix and framework_name:
        candidates.append(
            os.path.join(framework_prefix, f"{framework_name}.framework", "Versions", version, framework_name)
        )

    candidates.append(os.path.join(libdir, f"libpython{version}.dylib"))

    for path in candidates:
        if path and os.path.isfile(path):
            return os.path.realpath(path)
    return ""

info = {
    "version": f"{sys.version_info.major}.{sys.version_info.minor}",
    "stdlib": sysconfig.get_path("stdlib"),
    "purelib": sysconfig.get_path("purelib"),
    "libpython_path": resolve_libpython(),
    "sitepackages": site.getsitepackages(),
}
print(json.dumps(info))
PY

PY_VERSION="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PY_INFO_FILE")"
STDLIB_DIR="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["stdlib"])' "$PY_INFO_FILE")"
PURELIB_DIR="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["purelib"])' "$PY_INFO_FILE")"
LIBPY_SOURCE="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["libpython_path"] or "")' "$PY_INFO_FILE")"
if [[ -z "$LIBPY_SOURCE" ]]; then
  echo "Unable to locate libpython from interpreter metadata" >&2
  exit 1
fi
if [[ ! -f "$LIBPY_SOURCE" ]]; then
  echo "libpython not found at $LIBPY_SOURCE" >&2
  exit 1
fi

mkdir -p "$RUNTIME_ROOT/lib"

cp "$LIBPY_SOURCE" "$RUNTIME_ROOT/lib/libpython$PY_VERSION.dylib"

STDLIB_DEST="$RUNTIME_ROOT/lib/python$PY_VERSION"
mkdir -p "$STDLIB_DEST"
cp -R "$STDLIB_DIR/." "$STDLIB_DEST/"

SITE_PACKAGES_DEST="$STDLIB_DEST/site-packages"
rm -rf "$SITE_PACKAGES_DEST"
mkdir -p "$SITE_PACKAGES_DEST"
cp -R "$PURELIB_DIR/." "$SITE_PACKAGES_DEST/"

if [[ "$INSTALL_QWEN" == "1" ]]; then
  mkdir -p "$RUNTIME_ROOT/models"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$MODEL_ID" --local-dir "$RUNTIME_ROOT/models/$(basename "$MODEL_ID")" || true
  fi
fi

cat <<DONE
Runtime staged at: $RUNTIME_ROOT
Python version: $PY_VERSION
libpython: $RUNTIME_ROOT/lib/libpython$PY_VERSION.dylib
stdlib: $STDLIB_DEST
site-packages: $SITE_PACKAGES_DEST
DONE
