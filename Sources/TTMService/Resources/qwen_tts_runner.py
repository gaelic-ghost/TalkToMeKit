"""TalkToMeKit Qwen3-TTS runner.

This module is imported by the in-process CPython bridge and provides:
    load_model(mode: str, model_id: str) -> bool
    unload_model() -> bool
    is_model_loaded() -> bool
    synthesize_voice_design(text: str, instruct: str, language: str, sample_rate: int, model_id: str) -> bytes
    synthesize_custom_voice(text: str, speaker: str, instruct: str, language: str, sample_rate: int, model_id: str) -> bytes
    synthesize_voice_clone(text: str, reference_audio: bytes, language: str, sample_rate: int, model_id: str) -> bytes
"""

from __future__ import annotations

import io
import os
import platform
import struct
import sys
import time
import wave
from typing import Any, Optional, Sequence

_MODEL_LOADED = False
_QWEN_MODEL: Optional[Any] = None
_QWEN_MODULE: Optional[Any] = None
_ACTIVE_MODE: Optional[str] = None
_ACTIVE_MODEL_ID: Optional[str] = None

DEFAULT_MODE = os.getenv("TTM_QWEN_MODE", "voice_design")
DEFAULT_VOICE_DESIGN_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
DEFAULT_CUSTOM_VOICE_MODEL = "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
DEFAULT_VOICE_CLONE_MODEL = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
DEFAULT_LANGUAGE = os.getenv("TTM_QWEN_LANGUAGE", "English")
DEFAULT_SPEAKER = os.getenv("TTM_QWEN_SPEAKER", "ryan")
_ALLOW_FALLBACK = os.getenv("TTM_QWEN_ALLOW_FALLBACK", "0") == "1"
_DEBUG = os.getenv("TTM_QWEN_DEBUG", "0") == "1"
_ALLOW_CROSS_MODE_FALLBACK = os.getenv("TTM_QWEN_ALLOW_CROSS_MODE_FALLBACK", "1") == "1"

MODEL_REGISTRY: dict[str, list[str]] = {
    "voice_design": [
        DEFAULT_VOICE_DESIGN_MODEL,
    ],
    "custom_voice": [
        DEFAULT_CUSTOM_VOICE_MODEL,
        "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    ],
    "voice_clone": [
        DEFAULT_VOICE_CLONE_MODEL,
        "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    ],
}


def _silent_wav(sample_rate: int, seconds: float = 0.35) -> bytes:
    frame_count = max(1, int(sample_rate * seconds))
    pcm = b"\x00\x00" * frame_count
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm)
        return buffer.getvalue()


def _flatten_numeric_samples(data: Any) -> list[float]:
    if hasattr(data, "detach") and callable(data.detach):
        try:
            data = data.detach().cpu().numpy()
        except Exception:
            pass
    if hasattr(data, "tolist") and callable(data.tolist):
        try:
            data = data.tolist()
        except Exception:
            pass

    if isinstance(data, (list, tuple)):
        flattened: list[float] = []
        for item in data:
            flattened.extend(_flatten_numeric_samples(item))
        return flattened

    return [float(data)]


def _to_wav_bytes(samples: Sequence[float], sample_rate: int) -> bytes:
    clipped = [max(-1.0, min(1.0, sample)) for sample in _flatten_numeric_samples(samples)]
    pcm = b"".join(struct.pack("<h", int(sample * 32767.0)) for sample in clipped)
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm)
        return buffer.getvalue()


def _normalize_samples(data: Any) -> Sequence[float]:
    if hasattr(data, "detach") and callable(data.detach):
        try:
            data = data.detach().cpu().numpy().tolist()
        except Exception:
            pass
    elif hasattr(data, "tolist") and callable(data.tolist):
        try:
            data = data.tolist()
        except Exception:
            pass

    if isinstance(data, tuple):
        data = list(data)

    if isinstance(data, list) and data and isinstance(data[0], (list, tuple)):
        if len(data) == 1:
            return data[0]
        flattened = []
        for item in data:
            if isinstance(item, (list, tuple)):
                flattened.extend(item)
            else:
                flattened.append(item)
        return flattened

    return data


def _extract_audio_and_sample_rate(output: Any, default_sample_rate: int) -> tuple[Any, int]:
    if isinstance(output, dict):
        wav = output.get("wav")
        sample_rate = int(output.get("sampling_rate", output.get("sample_rate", default_sample_rate)))
        return wav, sample_rate

    if isinstance(output, tuple) and len(output) == 2:
        first, second = output
        if isinstance(second, (int, float)):
            return first, int(second)

    return output, default_sample_rate


def _resolve_local_model_path(model_id: str) -> Optional[str]:
    explicit = os.getenv("TTM_QWEN_LOCAL_MODEL_PATH")
    if explicit:
        return explicit

    python_home = os.getenv("PYTHONHOME")
    if not python_home:
        return None

    local_candidate = os.path.join(python_home, "models", os.path.basename(model_id))
    if os.path.isdir(local_candidate):
        return local_candidate
    return None


def _debug(message: str) -> None:
    if not _DEBUG:
        return
    try:
        print(f"[qwen_tts_runner] {message}", flush=True)
    except Exception:
        pass


def _torch_debug_summary() -> str:
    try:
        import torch  # type: ignore[import-not-found]
    except Exception as error:
        return f"torch unavailable ({error})"
    try:
        mps_available = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    except Exception:
        mps_available = False
    try:
        mps_built = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_built())
    except Exception:
        mps_built = False
    return f"torch={getattr(torch, '__version__', 'unknown')} mps_built={mps_built} mps_available={mps_available}"


def get_runtime_diagnostics() -> str:
    details: list[str] = [
        f"python={sys.version.split()[0]}",
        f"executable={sys.executable}",
        f"platform={platform.platform()}",
        f"machine={platform.machine()}",
        f"pythonhome={os.getenv('PYTHONHOME', '')}",
        f"device_map={os.getenv('TTM_QWEN_DEVICE_MAP', 'cpu')}",
        f"dtype={os.getenv('TTM_QWEN_TORCH_DTYPE', 'float32')}",
        _torch_debug_summary(),
    ]

    try:
        import torch  # type: ignore[import-not-found]

        try:
            mps_available = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
        except Exception:
            mps_available = False

        if mps_available:
            try:
                tensor = torch.empty(1, device="mps")
                details.append(f"mps_alloc_ok={tensor.device}")
            except Exception as error:
                details.append(f"mps_alloc_error={type(error).__name__}:{error}")
        else:
            details.append("mps_alloc_skipped=unavailable")
    except Exception as error:
        details.append(f"torch_diag_error={type(error).__name__}:{error}")

    return " | ".join(details)


def _target_dtype() -> Any:
    try:
        import torch  # type: ignore[import-not-found]
    except Exception:
        return None

    requested = os.getenv("TTM_QWEN_TORCH_DTYPE", "float32").lower()
    if requested == "float16":
        return torch.float16
    if requested == "bfloat16":
        return torch.bfloat16
    return torch.float32


def _load_qwen_module() -> Optional[Any]:
    global _QWEN_MODULE
    if _QWEN_MODULE is not None:
        return _QWEN_MODULE

    try:
        import qwen_tts  # type: ignore[import-not-found]
    except Exception:
        return None

    _QWEN_MODULE = qwen_tts
    return _QWEN_MODULE


def _create_model(model_id: str) -> Optional[Any]:
    qwen_module = _load_qwen_module()
    if qwen_module is None:
        return None

    model_type = getattr(qwen_module, "Qwen3TTSModel", None)
    if model_type is None:
        return None

    source = _resolve_local_model_path(model_id) or model_id
    kwargs = {
        "device_map": os.getenv("TTM_QWEN_DEVICE_MAP", "cpu"),
    }

    dtype = _target_dtype()
    if dtype is not None:
        kwargs["dtype"] = dtype

    attn_impl = os.getenv("TTM_QWEN_ATTN_IMPLEMENTATION")
    if attn_impl:
        kwargs["attn_implementation"] = attn_impl

    _debug(f"loading model source={source!r} kwargs={kwargs!r} {_torch_debug_summary()}")
    return model_type.from_pretrained(source, **kwargs)


def _resolve_mode(mode: Optional[str]) -> str:
    requested = (mode or DEFAULT_MODE).strip().lower()
    if requested not in MODEL_REGISTRY:
        return DEFAULT_MODE
    return requested


def _resolve_default_model_for_mode(mode: str) -> str:
    return MODEL_REGISTRY[mode][0]


def _resolve_model(mode: str, model_id: Optional[str]) -> str:
    requested = (model_id or "").strip()
    if not requested:
        return _resolve_default_model_for_mode(mode)
    return requested


def _candidates_for_mode(mode: str, requested_model: str, strict: bool = False) -> list[tuple[str, str]]:
    ordered: list[tuple[str, str]] = []

    same_mode = MODEL_REGISTRY.get(mode, [])
    if requested_model:
        ordered.append((mode, requested_model))

    for model_id in same_mode:
        if model_id != requested_model:
            ordered.append((mode, model_id))

    if not strict and _ALLOW_CROSS_MODE_FALLBACK:
        for fallback_mode, model_ids in MODEL_REGISTRY.items():
            if fallback_mode == mode:
                continue
            for model_id in model_ids:
                if model_id == requested_model:
                    continue
                ordered.append((fallback_mode, model_id))

    seen: set[tuple[str, str]] = set()
    unique: list[tuple[str, str]] = []
    for entry in ordered:
        if entry in seen:
            continue
        seen.add(entry)
        unique.append(entry)
    return unique


def load_model(mode: Optional[str] = None, model_id: Optional[str] = None, strict: Optional[str] = None) -> bool:
    global _MODEL_LOADED
    global _QWEN_MODEL
    global _ACTIVE_MODE
    global _ACTIVE_MODEL_ID

    strict_load = strict == "1" if strict is not None else False

    resolved_mode = _resolve_mode(mode)
    resolved_model = _resolve_model(resolved_mode, model_id)

    if _MODEL_LOADED and _QWEN_MODEL is not None and _ACTIVE_MODE == resolved_mode and _ACTIVE_MODEL_ID == resolved_model:
        _debug("model already loaded")
        return True

    for candidate_mode, candidate_model in _candidates_for_mode(resolved_mode, resolved_model, strict=strict_load):
        started_at = time.monotonic()
        model = _create_model(candidate_model)
        elapsed = time.monotonic() - started_at
        if model is None:
            _debug(f"model load failed mode={candidate_mode!r} model={candidate_model!r} in {elapsed:.2f}s")
            continue

        _QWEN_MODEL = model
        _MODEL_LOADED = True
        _ACTIVE_MODE = candidate_mode
        _ACTIVE_MODEL_ID = candidate_model
        _debug(f"model loaded mode={candidate_mode!r} model={candidate_model!r} in {elapsed:.2f}s")
        return True

    _QWEN_MODEL = None
    _MODEL_LOADED = False
    _ACTIVE_MODE = None
    _ACTIVE_MODEL_ID = None
    return _ALLOW_FALLBACK


def unload_model() -> bool:
    global _MODEL_LOADED
    global _QWEN_MODEL
    global _ACTIVE_MODE
    global _ACTIVE_MODEL_ID

    _QWEN_MODEL = None
    _MODEL_LOADED = False
    _ACTIVE_MODE = None
    _ACTIVE_MODEL_ID = None
    return True


def is_model_loaded() -> bool:
    return _MODEL_LOADED


def _ensure_loaded(mode: str, model_id: str) -> bool:
    if _MODEL_LOADED and _QWEN_MODEL is not None and _ACTIVE_MODE == mode and _ACTIVE_MODEL_ID == model_id:
        return True
    return load_model(mode=mode, model_id=model_id, strict="0")


def _generate_voice_design(text: str, instruct: str, language: str) -> Optional[bytes]:
    if _QWEN_MODEL is None:
        return None

    output = _QWEN_MODEL.generate_voice_design(
        text=text,
        language=language,
        instruct=instruct,
    )
    wav_payload, sr = _extract_audio_and_sample_rate(output, 24_000)
    if isinstance(wav_payload, (bytes, bytearray, memoryview)):
        return bytes(wav_payload)
    if wav_payload is not None:
        return _to_wav_bytes(_normalize_samples(wav_payload), sr)
    return None


def _generate_custom_voice(text: str, speaker: str, instruct: Optional[str], language: str) -> Optional[bytes]:
    if _QWEN_MODEL is None:
        return None

    requested_speaker = (speaker or DEFAULT_SPEAKER).lower()
    get_supported_speakers = getattr(_QWEN_MODEL, "get_supported_speakers", None)
    if callable(get_supported_speakers):
        supported = get_supported_speakers() or []
        if supported and requested_speaker not in supported:
            requested_speaker = supported[0]

    kwargs = {
        "text": text,
        "language": language,
        "speaker": requested_speaker,
    }
    if instruct:
        kwargs["instruct"] = instruct

    try:
        output = _QWEN_MODEL.generate_custom_voice(**kwargs)
    except TypeError:
        # Runtime compatibility fallback for older qwen_tts builds.
        kwargs.pop("instruct", None)
        output = _QWEN_MODEL.generate_custom_voice(**kwargs)
    wav_payload, sr = _extract_audio_and_sample_rate(output, 24_000)
    if isinstance(wav_payload, (bytes, bytearray, memoryview)):
        return bytes(wav_payload)
    if wav_payload is not None:
        return _to_wav_bytes(_normalize_samples(wav_payload), sr)
    return None


def _generate_voice_clone(text: str, reference_audio: bytes, language: str) -> Optional[bytes]:
    if _QWEN_MODEL is None:
        return None

    reference_path: Optional[str] = None
    try:
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
            handle.write(reference_audio)
            reference_path = handle.name

        candidates: list[dict[str, Any]] = [
            {
                "method": "generate_voice_clone",
                "kwargs": {
                    "text": text,
                    "language": language,
                    "reference_audio": reference_path,
                },
            },
            {
                "method": "generate_voice_clone",
                "kwargs": {
                    "text": text,
                    "language": language,
                    "prompt_audio": reference_path,
                },
            },
            {
                "method": "generate_base",
                "kwargs": {
                    "text": text,
                    "language": language,
                    "prompt_audio": reference_path,
                },
            },
        ]

        for candidate in candidates:
            method_name = candidate["method"]
            method = getattr(_QWEN_MODEL, method_name, None)
            if not callable(method):
                continue
            try:
                output = method(**candidate["kwargs"])
                wav_payload, sr = _extract_audio_and_sample_rate(output, 24_000)
                if isinstance(wav_payload, (bytes, bytearray, memoryview)):
                    return bytes(wav_payload)
                if wav_payload is not None:
                    return _to_wav_bytes(_normalize_samples(wav_payload), sr)
            except TypeError:
                continue
    finally:
        if reference_path and os.path.exists(reference_path):
            try:
                os.remove(reference_path)
            except Exception:
                pass

    return None


def get_supported_speakers(mode: Optional[str] = None, model_id: Optional[str] = None) -> list[str]:
    resolved_mode = _resolve_mode(mode)
    if resolved_mode != "custom_voice":
        return []
    resolved_model = _resolve_model(resolved_mode, model_id)
    if not load_model(mode=resolved_mode, model_id=resolved_model, strict="1"):
        return []
    if _QWEN_MODEL is None:
        return []
    get_speakers = getattr(_QWEN_MODEL, "get_supported_speakers", None)
    if not callable(get_speakers):
        return []
    try:
        speakers = get_speakers() or []
    except Exception:
        return []
    return [str(speaker) for speaker in speakers if str(speaker)]


def get_supported_speakers_csv(mode: Optional[str] = None, model_id: Optional[str] = None) -> str:
    return ",".join(get_supported_speakers(mode=mode, model_id=model_id))


def synthesize_voice_design(text: str, instruct: str, language: str, sample_rate: int, model_id: str) -> bytes:
    if not text.strip():
        raise ValueError("text must not be empty")

    resolved_mode = "voice_design"
    resolved_model = _resolve_model(resolved_mode, model_id)
    resolved_language = language or DEFAULT_LANGUAGE

    if not _ensure_loaded(mode=resolved_mode, model_id=resolved_model):
        raise RuntimeError("Qwen3-TTS runtime unavailable: failed to load model")

    audio = _generate_voice_design(text=text, instruct=instruct or "", language=resolved_language)
    if audio is not None:
        return audio

    if _ALLOW_FALLBACK:
        return _silent_wav(sample_rate=sample_rate)

    raise RuntimeError("Qwen3-TTS VoiceDesign synthesis failed")


def synthesize_custom_voice(text: str, speaker: str, instruct: str, language: str, sample_rate: int, model_id: str) -> bytes:
    if not text.strip():
        raise ValueError("text must not be empty")

    resolved_mode = "custom_voice"
    resolved_model = _resolve_model(resolved_mode, model_id)
    resolved_language = language or DEFAULT_LANGUAGE

    if not _ensure_loaded(mode=resolved_mode, model_id=resolved_model):
        raise RuntimeError("Qwen3-TTS runtime unavailable: failed to load model")

    audio = _generate_custom_voice(
        text=text,
        speaker=speaker or DEFAULT_SPEAKER,
        instruct=instruct,
        language=resolved_language,
    )
    if audio is not None:
        return audio

    if _ALLOW_FALLBACK:
        return _silent_wav(sample_rate=sample_rate)

    raise RuntimeError("Qwen3-TTS CustomVoice synthesis failed")


def synthesize_voice_clone(text: str, reference_audio: bytes, language: str, sample_rate: int, model_id: str) -> bytes:
    if not text.strip():
        raise ValueError("text must not be empty")
    if not reference_audio:
        raise ValueError("reference_audio must not be empty")

    resolved_mode = "voice_clone"
    resolved_model = _resolve_model(resolved_mode, model_id)
    resolved_language = language or DEFAULT_LANGUAGE

    if not _ensure_loaded(mode=resolved_mode, model_id=resolved_model):
        raise RuntimeError("Qwen3-TTS runtime unavailable: failed to load model")

    audio = _generate_voice_clone(
        text=text,
        reference_audio=reference_audio,
        language=resolved_language,
    )
    if audio is not None:
        return audio

    if _ALLOW_FALLBACK:
        return _silent_wav(sample_rate=sample_rate)

    raise RuntimeError("Qwen3-TTS VoiceClone synthesis failed")
