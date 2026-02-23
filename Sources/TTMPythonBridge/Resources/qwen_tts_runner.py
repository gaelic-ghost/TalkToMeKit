"""TalkToMeKit Qwen3-TTS runner.

This module is imported by the in-process CPython bridge and provides:
    load_model() -> bool
    unload_model() -> bool
    is_model_loaded() -> bool
    synthesize(text: str, voice: str, sample_rate: int) -> bytes
"""

from __future__ import annotations

import io
import os
import struct
import time
import wave
from typing import Any, Optional, Sequence

_MODEL_LOADED = False
_QWEN_MODEL: Optional[Any] = None
_QWEN_MODULE: Optional[Any] = None

_MODEL_ID = os.getenv("TTM_QWEN_MODEL_ID", "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
_MODEL_MODE = os.getenv("TTM_QWEN_MODEL_MODE", "custom_voice")
_LANGUAGE = os.getenv("TTM_QWEN_LANGUAGE", "auto")
_DEFAULT_SPEAKER = os.getenv("TTM_QWEN_SPEAKER", "serena")
_ALLOW_FALLBACK = os.getenv("TTM_QWEN_ALLOW_FALLBACK", "0") == "1"
_DEBUG = os.getenv("TTM_QWEN_DEBUG", "0") == "1"


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
    # PyTorch/Numpy style containers.
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

    # Common model output: [ [samples...] ] for single-item batch.
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


def _resolve_local_model_path() -> Optional[str]:
    value = os.getenv("TTM_QWEN_LOCAL_MODEL_PATH")
    if value:
        return value
    python_home = os.getenv("PYTHONHOME")
    if python_home:
        local_candidate = os.path.join(python_home, "models", os.path.basename(_MODEL_ID))
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


def _target_dtype() -> Any:
    # Keep this conservative for portable macOS embedding.
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


def _create_model() -> Optional[Any]:
    qwen_module = _load_qwen_module()
    if qwen_module is None:
        return None

    model_type = getattr(qwen_module, "Qwen3TTSModel", None)
    if model_type is None:
        return None

    source = _resolve_local_model_path() or _MODEL_ID
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


def load_model() -> bool:
    global _MODEL_LOADED
    global _QWEN_MODEL

    if _MODEL_LOADED and _QWEN_MODEL is not None:
        _debug("model already loaded")
        return True

    started_at = time.monotonic()
    model = _create_model()
    elapsed = time.monotonic() - started_at
    if model is None:
        _QWEN_MODEL = None
        _MODEL_LOADED = False
        _debug(f"model load failed in {elapsed:.2f}s; fallback_allowed={_ALLOW_FALLBACK}")
        return _ALLOW_FALLBACK

    _QWEN_MODEL = model
    _MODEL_LOADED = True
    _debug(f"model loaded in {elapsed:.2f}s")
    return True


def unload_model() -> bool:
    global _MODEL_LOADED
    global _QWEN_MODEL

    _QWEN_MODEL = None
    _MODEL_LOADED = False
    return True


def is_model_loaded() -> bool:
    return _MODEL_LOADED


def _generate_with_qwen(text: str, voice: str) -> Optional[bytes]:
    if _QWEN_MODEL is None:
        return None

    language = _LANGUAGE
    if language == "auto":
        language = "auto"

    if _MODEL_MODE == "voice_design":
        output = _QWEN_MODEL.generate_voice_design(
            text=text,
            language=language,
            instruct=voice or "",
        )
    else:
        requested_speaker = (voice or _DEFAULT_SPEAKER).lower()
        get_supported_speakers = getattr(_QWEN_MODEL, "get_supported_speakers", None)
        if callable(get_supported_speakers):
            supported = get_supported_speakers() or []
            if supported and requested_speaker not in supported:
                requested_speaker = supported[0]
        output = _QWEN_MODEL.generate_custom_voice(
            text=text,
            language=language,
            speaker=requested_speaker,
        )

    wav_payload, sr = _extract_audio_and_sample_rate(output, 24_000)

    if isinstance(wav_payload, (bytes, bytearray, memoryview)):
        return bytes(wav_payload)
    if wav_payload is not None:
        return _to_wav_bytes(_normalize_samples(wav_payload), sr)

    return None


def synthesize(text: str, voice: str, sample_rate: int) -> bytes:
    """Synthesize speech and return WAV bytes."""
    if not text.strip():
        raise ValueError("text must not be empty")

    if not is_model_loaded() and not load_model():
        raise RuntimeError("Qwen3-TTS runtime unavailable: failed to load model")

    audio = _generate_with_qwen(text=text, voice=voice)
    if audio is not None:
        return audio

    if _ALLOW_FALLBACK:
        return _silent_wav(sample_rate=sample_rate)

    raise RuntimeError("Qwen3-TTS synthesis failed")
