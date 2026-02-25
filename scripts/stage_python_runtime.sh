#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Stage a bundled CPython runtime into this package.

Usage:
  scripts/stage_python_runtime.sh [options]

Options:
  -uv                     Use uv installer (default installer mode is auto)
  --installer NAME        Package installer to use: auto|uv|pip (default: auto)
  --runtime-root PATH     Destination runtime root
                          (default: Sources/TTMPythonRuntimeBundle/Resources/Runtime/current)
  --restage               Remove existing runtime root before staging
  --restage-runtime       Rebuild runtime files (libpython/stdlib/bin tools)
  --restage-packages      Reinstall and restage Python site-packages
  --restage-models        Redownload selected model directories
  --model-id ID           Additional Qwen model id to pre-download (repeatable)
  --bigcv                 Also pre-download Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
  --bigvd                 Also pre-download Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign
  --bigvc                 Also pre-download Qwen/Qwen3-TTS-12Hz-1.7B-Base
  --noload                Skip downloading model files
  --install-qwen          Install qwen-tts and dependencies into the runtime environment (default)
  --no-install-qwen       Skip package installation; stage from current environment only
  --help                  Show this help
USAGE
}

PYTHON_BIN="python3.11"
INSTALLER="auto"
RUNTIME_ROOT="Sources/TTMPythonRuntimeBundle/Resources/Runtime/current"
MODEL_IDS=()
DEFAULT_MODELS=(
  "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
  "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
)
BIG_CV="0"
BIG_VD="0"
BIG_VC="0"
NO_LOAD="0"
INSTALL_QWEN="1"
RESTAGE="0"
RESTAGE_RUNTIME="0"
RESTAGE_PACKAGES="0"
RESTAGE_MODELS="0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UV_PROJECT_DIR="$SCRIPT_DIR/python-runtime"
UV_LOCK_FILE="$UV_PROJECT_DIR/uv.lock"
UV_PYPROJECT_FILE="$UV_PROJECT_DIR/pyproject.toml"
PY_VERSION="3.11"

run_python_clean_env() {
  env -u PYTHONHOME -u PYTHONPATH "$PYTHON_BIN" "$@"
}

require_value() {
  if [[ $# -lt 2 ]]; then
    echo "Missing value for option: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -uv)
      INSTALLER="uv"
      shift
      ;;
    --installer)
      require_value "$@"
      INSTALLER="$2"
      shift 2
      ;;
    --runtime-root)
      require_value "$@"
      RUNTIME_ROOT="$2"
      shift 2
      ;;
    --restage)
      RESTAGE="1"
      shift
      ;;
    --restage-runtime)
      RESTAGE_RUNTIME="1"
      shift
      ;;
    --restage-packages)
      RESTAGE_PACKAGES="1"
      shift
      ;;
    --restage-models)
      RESTAGE_MODELS="1"
      shift
      ;;
    --model-id)
      require_value "$@"
      MODEL_IDS+=("$2")
      shift 2
      ;;
    --bigcv)
      BIG_CV="1"
      shift
      ;;
    --bigvd)
      BIG_VD="1"
      shift
      ;;
    --bigvc)
      BIG_VC="1"
      shift
      ;;
    --noload)
      NO_LOAD="1"
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
  RESTAGE_RUNTIME="1"
  RESTAGE_PACKAGES="1"
  RESTAGE_MODELS="1"
  rm -rf "$RUNTIME_ROOT"
fi

LIB_DEST="$RUNTIME_ROOT/lib/libpython$PY_VERSION.dylib"
STDLIB_DEST="$RUNTIME_ROOT/lib/python$PY_VERSION"
SITE_PACKAGES_DEST="$STDLIB_DEST/site-packages"
MODELS_DEST="$RUNTIME_ROOT/models"
WORK_DIR=""
VENV_DIR=""
PY_INFO_FILE=""
STDLIB_DIR=""
PURELIB_DIR=""
LIBPY_SOURCE=""
PRESERVED_SITE_PACKAGES=""

selected_models=("${DEFAULT_MODELS[@]}")
if [[ "$BIG_CV" == "1" ]]; then
  selected_models+=("Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
fi
if [[ "$BIG_VD" == "1" ]]; then
  selected_models+=("Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
fi
if [[ "$BIG_VC" == "1" ]]; then
  selected_models+=("Qwen/Qwen3-TTS-12Hz-1.7B-Base")
fi
if [[ "${#MODEL_IDS[@]}" -gt 0 ]]; then
  selected_models+=("${MODEL_IDS[@]}")
fi

runtime_present="0"
if [[ -f "$LIB_DEST" && -d "$STDLIB_DEST" ]]; then
  runtime_present="1"
fi

packages_present="0"
if [[ -d "$SITE_PACKAGES_DEST" && -d "$SITE_PACKAGES_DEST/qwen_tts-0.1.1.dist-info" && -d "$SITE_PACKAGES_DEST/torch-2.10.0.dist-info" ]]; then
  packages_present="1"
fi

models_present="1"
if [[ "$INSTALL_QWEN" == "1" && "$NO_LOAD" != "1" ]]; then
  for model_id in "${selected_models[@]}"; do
    if [[ ! -d "$MODELS_DEST/$(basename "$model_id")" ]]; then
      models_present="0"
      break
    fi
  done
fi

need_runtime_stage="0"
need_packages_stage="0"
need_models_stage="0"

if [[ "$RESTAGE_RUNTIME" == "1" || "$runtime_present" != "1" ]]; then
  need_runtime_stage="1"
fi

if [[ "$INSTALL_QWEN" == "1" ]]; then
  if [[ "$RESTAGE_PACKAGES" == "1" || "$packages_present" != "1" ]]; then
    need_packages_stage="1"
  fi
  if [[ "$NO_LOAD" != "1" ]]; then
    if [[ "$RESTAGE_MODELS" == "1" || "$models_present" != "1" ]]; then
      need_models_stage="1"
    fi
  fi
fi

if [[ "$RESTAGE_RUNTIME" == "1" ]]; then
  if [[ "$RESTAGE_PACKAGES" != "1" && -d "$SITE_PACKAGES_DEST" ]]; then
    if [[ -z "$WORK_DIR" ]]; then
      WORK_DIR="$(mktemp -d)"
    fi
    PRESERVED_SITE_PACKAGES="$WORK_DIR/site-packages-preserved"
    rm -rf "$PRESERVED_SITE_PACKAGES"
    mv "$SITE_PACKAGES_DEST" "$PRESERVED_SITE_PACKAGES"
  fi
  rm -f "$LIB_DEST"
  rm -rf "$STDLIB_DEST"
  rm -f "$RUNTIME_ROOT/bin/sox" "$RUNTIME_ROOT/bin/soxi"
fi
if [[ "$RESTAGE_PACKAGES" == "1" ]]; then
  rm -rf "$SITE_PACKAGES_DEST"
fi
if [[ "$RESTAGE_MODELS" == "1" ]]; then
  rm -rf "$MODELS_DEST"
fi

if [[ "$need_runtime_stage" != "1" && "$need_packages_stage" != "1" && "$need_models_stage" != "1" ]]; then
  cat <<DONE
Runtime already staged at: $RUNTIME_ROOT
Python version: $PY_VERSION
No staging required (all requested categories already present).
DONE
  exit 0
fi

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

ensure_venv() {
  if [[ -n "$VENV_DIR" ]]; then
    return
  fi
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
  fi
  VENV_DIR="$WORK_DIR/venv"
  run_python_clean_env -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"
}

case "$INSTALLER" in
  auto|uv|pip)
    ;;
  *)
    echo "Unsupported installer: $INSTALLER (expected auto|uv|pip)" >&2
    exit 1
    ;;
esac

install_with_pip() {
  ensure_venv
  if ! command -v uv >/dev/null 2>&1; then
    echo "pip installer mode requires uv to export locked requirements" >&2
    exit 1
  fi
  local requirements_export="$WORK_DIR/requirements.lock.txt"
  UV_CACHE_DIR="${UV_CACHE_DIR:-$WORK_DIR/uv-cache}" \
    uv export \
      --directory "$UV_PROJECT_DIR" \
      --format requirements.txt \
      --frozen \
      --no-dev \
      --no-editable \
      --no-emit-project \
      -o "$requirements_export"
  env -u PYTHONHOME -u PYTHONPATH python -m pip install --upgrade pip setuptools wheel
  env -u PYTHONHOME -u PYTHONPATH python -m pip install -r "$requirements_export"
}

install_with_uv() {
  ensure_venv
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv installer requested but uv was not found on PATH" >&2
    exit 1
  fi
  local uv_cache_dir="${UV_CACHE_DIR:-$WORK_DIR/uv-cache}"
  mkdir -p "$uv_cache_dir"
  UV_PROJECT_ENVIRONMENT="$VENV_DIR" \
    UV_CACHE_DIR="$uv_cache_dir" \
    uv sync \
      --directory "$UV_PROJECT_DIR" \
      --frozen \
      --no-dev \
      --no-install-project
}

if [[ "$need_packages_stage" == "1" ]]; then
  if [[ ! -f "$UV_PYPROJECT_FILE" ]]; then
    echo "Python runtime project not found: $UV_PYPROJECT_FILE" >&2
    exit 1
  fi
  if [[ ! -f "$UV_LOCK_FILE" ]]; then
    echo "Python runtime lockfile not found: $UV_LOCK_FILE" >&2
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

if [[ "$need_runtime_stage" == "1" || "$need_packages_stage" == "1" ]]; then
  if [[ "$need_packages_stage" == "1" ]]; then
    ensure_venv
    PY_INFO_PYTHON="python"
  else
    PY_INFO_PYTHON="$PYTHON_BIN"
  fi

  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
  fi
  PY_INFO_FILE="$WORK_DIR/python-info.json"
  env -u PYTHONHOME -u PYTHONPATH "$PY_INFO_PYTHON" - <<'PY' > "$PY_INFO_FILE"
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

  STDLIB_DIR="$(env -u PYTHONHOME -u PYTHONPATH "$PY_INFO_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["stdlib"])' "$PY_INFO_FILE")"
  PURELIB_DIR="$(env -u PYTHONHOME -u PYTHONPATH "$PY_INFO_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["purelib"])' "$PY_INFO_FILE")"
  LIBPY_SOURCE="$(env -u PYTHONHOME -u PYTHONPATH "$PY_INFO_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["libpython_path"] or "")' "$PY_INFO_FILE")"
fi

if [[ "$need_runtime_stage" == "1" ]]; then
  if [[ -z "$LIBPY_SOURCE" ]]; then
    echo "Unable to locate libpython from interpreter metadata" >&2
    exit 1
  fi
  if [[ ! -f "$LIBPY_SOURCE" ]]; then
    echo "libpython not found at $LIBPY_SOURCE" >&2
    exit 1
  fi

  mkdir -p "$RUNTIME_ROOT/lib"
  cp "$LIBPY_SOURCE" "$LIB_DEST"
  rm -rf "$STDLIB_DEST"
  mkdir -p "$STDLIB_DEST"
  cp -R "$STDLIB_DIR/." "$STDLIB_DEST/"
fi

if [[ "$need_packages_stage" == "1" ]]; then
  mkdir -p "$STDLIB_DEST"
  rm -rf "$SITE_PACKAGES_DEST"
  mkdir -p "$SITE_PACKAGES_DEST"
  cp -R "$PURELIB_DIR/." "$SITE_PACKAGES_DEST/"
elif [[ -n "$PRESERVED_SITE_PACKAGES" && -d "$PRESERVED_SITE_PACKAGES" ]]; then
  mkdir -p "$STDLIB_DEST"
  rm -rf "$SITE_PACKAGES_DEST"
  mv "$PRESERVED_SITE_PACKAGES" "$SITE_PACKAGES_DEST"
fi

if [[ "$need_models_stage" == "1" ]]; then
  mkdir -p "$MODELS_DEST"
  if command -v huggingface-cli >/dev/null 2>&1; then
    for model_id in "${selected_models[@]}"; do
      HF_HUB_DISABLE_XET=1 huggingface-cli download "$model_id" --local-dir "$MODELS_DEST/$(basename "$model_id")" || true
    done
  fi
fi

if [[ "$INSTALL_QWEN" == "1" ]]; then
  SOX_SOURCE=""
  SOX_SOURCE="$(env -u PYTHONHOME PYTHONPATH="$SITE_PACKAGES_DEST" "$PYTHON_BIN" - <<'PY'
import importlib
import os

def executable(path):
    return bool(path and os.path.isfile(path) and os.access(path, os.X_OK))

try:
    mod = importlib.import_module("static_sox")
except Exception:
    print("")
    raise SystemExit(0)

candidates = []
# static-sox 1.0.2 downloads platform binaries on first use.
# Force resolution so staging works from a clean environment.
try:
    run_mod = importlib.import_module("static_sox.run")
    fetch = getattr(run_mod, "get_or_fetch_platform_executables_else_raise", None)
    if callable(fetch):
        path = fetch()
        if isinstance(path, str):
            candidates.append(path)
except Exception:
    pass

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
  SOX_SOURCE="$(printf '%s\n' "$SOX_SOURCE" | tail -n 1 | tr -d '\r')"
  if [[ -z "$SOX_SOURCE" || ! -f "$SOX_SOURCE" ]]; then
    FALLBACK_SOX="$(find "$SITE_PACKAGES_DEST/static_sox" -type f -name sox -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -n "$FALLBACK_SOX" ]]; then
      SOX_SOURCE="$FALLBACK_SOX"
    fi
  fi

  if [[ -z "$SOX_SOURCE" || ! -f "$SOX_SOURCE" ]]; then
    echo "static-sox executable not found in staged environment" >&2
    exit 1
  fi

  SOX_DIR="$(dirname "$SOX_SOURCE")"
  mkdir -p "$RUNTIME_ROOT/bin"
  chmod u+w "$RUNTIME_ROOT/bin" 2>/dev/null || true
  rm -f "$RUNTIME_ROOT/bin/sox" "$RUNTIME_ROOT/bin/soxi"
  cp "$SOX_SOURCE" "$RUNTIME_ROOT/bin/sox"
  chmod +x "$RUNTIME_ROOT/bin/sox"
  if [[ -f "$SOX_DIR/soxi" ]]; then
    cp "$SOX_DIR/soxi" "$RUNTIME_ROOT/bin/soxi"
    chmod +x "$RUNTIME_ROOT/bin/soxi"
  fi
fi

cat <<DONE
Runtime staged at: $RUNTIME_ROOT
Python version: $PY_VERSION
libpython: $LIB_DEST
stdlib: $STDLIB_DEST
site-packages: $SITE_PACKAGES_DEST
DONE
