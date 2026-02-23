#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Stage a bundled CPython runtime into this package.

Usage:
  scripts/stage_python_runtime.sh [options]

Options:
  --python PATH           Python interpreter to use (default: python3)
  --installer NAME        Package installer to use: auto|uv|pip (default: auto)
  --runtime-root PATH     Destination runtime root
                          (default: Sources/TTMPythonRuntimeBundle/Resources/Runtime/current)
  --restage               Remove existing runtime root before staging
  --model-id ID           Additional Qwen model id to pre-download (repeatable)
  --include-cv-1.7b       Also pre-download Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
  --install-qwen          Install qwen-tts and dependencies into the runtime environment (default)
  --no-install-qwen       Skip package installation; stage from current environment only
  --help                  Show this help
USAGE
}

PYTHON_BIN="python3"
INSTALLER="auto"
RUNTIME_ROOT="Sources/TTMPythonRuntimeBundle/Resources/Runtime/current"
MODEL_IDS=()
DEFAULT_MODELS=(
  "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
  "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
)
INCLUDE_CV_17B="0"
INSTALL_QWEN="1"
RESTAGE="0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements-qwen.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --installer)
      INSTALLER="$2"
      shift 2
      ;;
    --runtime-root)
      RUNTIME_ROOT="$2"
      shift 2
      ;;
    --restage)
      RESTAGE="1"
      shift
      ;;
    --model-id)
      MODEL_IDS+=("$2")
      shift 2
      ;;
    --include-cv-1.7b)
      INCLUDE_CV_17B="1"
      shift
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

if [[ "$RESTAGE" == "1" ]]; then
  rm -rf "$RUNTIME_ROOT"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
VENV_DIR="$WORK_DIR/venv"

"$PYTHON_BIN" -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

case "$INSTALLER" in
  auto|uv|pip)
    ;;
  *)
    echo "Unsupported installer: $INSTALLER (expected auto|uv|pip)" >&2
    exit 1
    ;;
esac

install_with_pip() {
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install -r "$REQUIREMENTS_FILE"
}

install_with_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv installer requested but uv was not found on PATH" >&2
    exit 1
  fi
  local uv_cache_dir="${UV_CACHE_DIR:-$WORK_DIR/uv-cache}"
  mkdir -p "$uv_cache_dir"
  UV_CACHE_DIR="$uv_cache_dir" uv pip install --python "$VENV_DIR/bin/python" --upgrade pip setuptools wheel
  UV_CACHE_DIR="$uv_cache_dir" uv pip install --python "$VENV_DIR/bin/python" -r "$REQUIREMENTS_FILE"
}

if [[ "$INSTALL_QWEN" == "1" ]]; then
  if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    echo "Pinned requirements file not found: $REQUIREMENTS_FILE" >&2
    exit 1
  fi
  if [[ "$INSTALLER" == "uv" ]]; then
    install_with_uv
  elif [[ "$INSTALLER" == "pip" ]]; then
    install_with_pip
  elif command -v uv >/dev/null 2>&1; then
    install_with_uv
  else
    install_with_pip
  fi
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
rm -rf "$STDLIB_DEST"
mkdir -p "$STDLIB_DEST"
cp -R "$STDLIB_DIR/." "$STDLIB_DEST/"

SITE_PACKAGES_DEST="$STDLIB_DEST/site-packages"
rm -rf "$SITE_PACKAGES_DEST"
mkdir -p "$SITE_PACKAGES_DEST"
cp -R "$PURELIB_DIR/." "$SITE_PACKAGES_DEST/"

if [[ "$INSTALL_QWEN" == "1" ]]; then
  mkdir -p "$RUNTIME_ROOT/models"
  DOWNLOAD_MODELS=("${DEFAULT_MODELS[@]}")
  if [[ "$INCLUDE_CV_17B" == "1" ]]; then
    DOWNLOAD_MODELS+=("Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
  fi
  if [[ "${#MODEL_IDS[@]}" -gt 0 ]]; then
    DOWNLOAD_MODELS+=("${MODEL_IDS[@]}")
  fi
  if command -v huggingface-cli >/dev/null 2>&1; then
    for model_id in "${DOWNLOAD_MODELS[@]}"; do
      HF_HUB_DISABLE_XET=1 huggingface-cli download "$model_id" --local-dir "$RUNTIME_ROOT/models/$(basename "$model_id")" || true
    done
  fi
fi

# qwen-tts depends on the external `sox` executable through pysox.
# Prefer static-sox from the staged env (portable for app sandboxing),
# then fall back to host sox if static-sox is unavailable.
SOX_SOURCE=""
SOX_SOURCE="$(python - <<'PY'
import importlib
import os
import shutil
import sys

def executable(path):
    return bool(path and os.path.isfile(path) and os.access(path, os.X_OK))

try:
    mod = importlib.import_module("static_sox")
except Exception:
    print("")
    raise SystemExit(0)

candidates = []
for name in ("SOX_PATH", "sox_path", "BINARY_PATH", "STATIC_SOX_PATH"):
    value = getattr(mod, name, None)
    if isinstance(value, str):
        candidates.append(value)

for name in ("get_sox_path", "get_binary_path", "get_path", "path"):
    fn = getattr(mod, name, None)
    if callable(fn):
        try:
            value = fn()
        except Exception:
            continue
        if isinstance(value, str):
            candidates.append(value)

module_dir = os.path.dirname(os.path.realpath(getattr(mod, "__file__", "")))
for rel in ("bin/sox", "sox", "resources/sox", "static_sox/sox"):
    candidates.append(os.path.join(module_dir, rel))

for candidate in candidates:
    if executable(candidate):
        print(os.path.realpath(candidate))
        raise SystemExit(0)

print("")
PY
)"

if [[ -z "$SOX_SOURCE" ]] && command -v sox >/dev/null 2>&1; then
  SOX_SOURCE="$(command -v sox)"
fi

if [[ -n "$SOX_SOURCE" && -f "$SOX_SOURCE" ]]; then
  mkdir -p "$RUNTIME_ROOT/bin"
  chmod u+w "$RUNTIME_ROOT/bin" 2>/dev/null || true
  rm -f "$RUNTIME_ROOT/bin/sox" "$RUNTIME_ROOT/bin/soxi"
  cp "$SOX_SOURCE" "$RUNTIME_ROOT/bin/sox"
  chmod +x "$RUNTIME_ROOT/bin/sox"
  if command -v soxi >/dev/null 2>&1; then
    cp "$(command -v soxi)" "$RUNTIME_ROOT/bin/soxi"
    chmod +x "$RUNTIME_ROOT/bin/soxi"
  fi
else
  echo "Warning: sox executable not found on host and static-sox fallback unavailable." >&2
fi

cat <<DONE
Runtime staged at: $RUNTIME_ROOT
Python version: $PY_VERSION
libpython: $RUNTIME_ROOT/lib/libpython$PY_VERSION.dylib
stdlib: $STDLIB_DEST
site-packages: $SITE_PACKAGES_DEST
DONE
