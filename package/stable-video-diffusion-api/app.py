#!/usr/bin/env python3
"""Local HTTP API for Diffusers Stable Video Diffusion image-to-video."""

import os
import threading
import uuid
from importlib import import_module
from pathlib import Path
from typing import Any

torch = import_module("torch")
uvicorn = import_module("uvicorn")
diffusers = import_module("diffusers")
diffusers_utils = import_module("diffusers.utils")
fastapi = import_module("fastapi")
pil_image = import_module("PIL.Image")
pil_unidentified_image_error = import_module("PIL").UnidentifiedImageError

FastAPI = fastapi.FastAPI
File = fastapi.File
Form = fastapi.Form
HTTPException = fastapi.HTTPException
Request = fastapi.Request
UploadFile = fastapi.UploadFile
StableVideoDiffusionPipeline = diffusers.StableVideoDiffusionPipeline
export_to_video = diffusers_utils.export_to_video


HOST = os.environ.get("SVD_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("SVD_API_PORT", "8000"))
MODEL_ID = os.environ.get("SVD_MODEL_ID", "stabilityai/stable-video-diffusion-img2vid-xt")
CACHE_DIR = os.environ.get("SVD_CACHE_DIR") or os.environ.get("HF_HOME")
OUTPUT_DIR = Path(os.environ.get("SVD_OUTPUT_DIR", "/var/lib/stable-video-diffusion-api/outputs"))
DEVICE = os.environ.get("SVD_DEVICE", "cuda" if torch.cuda.is_available() else "cpu")
DTYPE = os.environ.get("SVD_DTYPE", "float16")
ENABLE_CPU_OFFLOAD = os.environ.get("SVD_ENABLE_CPU_OFFLOAD", "0").lower() in ("1", "true", "yes", "on")
DEFAULT_DECODE_CHUNK_SIZE = int(os.environ.get("SVD_DECODE_CHUNK_SIZE", "8"))
DEFAULT_FPS = int(os.environ.get("SVD_FPS", "7"))


app = FastAPI(title="Stable Video Diffusion API")
pipeline_lock = threading.Lock()
pipeline: Any | None = None


def torch_dtype() -> Any:
  dtypes = {
    "float16": torch.float16,
    "fp16": torch.float16,
    "float32": torch.float32,
    "fp32": torch.float32,
    "bfloat16": torch.bfloat16,
    "bf16": torch.bfloat16,
  }
  try:
    return dtypes[DTYPE.lower()]
  except KeyError as exc:
    raise RuntimeError(f"Unsupported SVD_DTYPE: {DTYPE}") from exc


def get_pipeline() -> Any:
  global pipeline

  if pipeline is not None:
    return pipeline

  with pipeline_lock:
    if pipeline is not None:
      return pipeline

    kwargs: dict[str, Any] = {"torch_dtype": torch_dtype()}
    if CACHE_DIR:
      kwargs["cache_dir"] = CACHE_DIR

    loaded = StableVideoDiffusionPipeline.from_pretrained(MODEL_ID, **kwargs)
    if ENABLE_CPU_OFFLOAD:
      loaded.enable_model_cpu_offload()
    else:
      loaded.to(DEVICE)

    pipeline = loaded
    return loaded


def positive_int(name: str, value: Any, default: int) -> int:
  if value in (None, ""):
    return default
  try:
    parsed = int(value)
  except (TypeError, ValueError) as exc:
    raise HTTPException(status_code=400, detail=f"{name} must be an integer") from exc
  if parsed <= 0:
    raise HTTPException(status_code=400, detail=f"{name} must be greater than zero")
  return parsed


def optional_int(name: str, value: Any) -> int | None:
  if value in (None, ""):
    return None
  try:
    return int(value)
  except (TypeError, ValueError) as exc:
    raise HTTPException(status_code=400, detail=f"{name} must be an integer") from exc


def optional_float(name: str, value: Any) -> float | None:
  if value in (None, ""):
    return None
  try:
    return float(value)
  except (TypeError, ValueError) as exc:
    raise HTTPException(status_code=400, detail=f"{name} must be a number") from exc


def load_image_from_path(input_image_path: str) -> Any:
  path = Path(input_image_path).expanduser()
  if not path.exists() or not path.is_file():
    raise HTTPException(status_code=400, detail="input_image_path does not exist or is not a file")
  try:
    return pil_image.open(path).convert("RGB")
  except (OSError, pil_unidentified_image_error) as exc:
    raise HTTPException(status_code=400, detail="input_image_path could not be decoded as an image") from exc


async def load_uploaded_image(image: UploadFile) -> Any:
  try:
    return pil_image.open(image.file).convert("RGB")
  except (OSError, pil_unidentified_image_error) as exc:
    raise HTTPException(status_code=400, detail="uploaded image could not be decoded") from exc


async def json_payload(request: Request) -> dict[str, Any]:
  content_type = request.headers.get("content-type", "")
  if not content_type.startswith("application/json"):
    return {}
  try:
    payload = await request.json()
  except ValueError as exc:
    raise HTTPException(status_code=400, detail="request body must be valid JSON") from exc
  if not isinstance(payload, dict):
    raise HTTPException(status_code=400, detail="JSON request body must be an object")
  return payload


@app.get("/health")
def health() -> dict[str, Any]:
  return {
    "status": "ok",
    "model_loaded": pipeline is not None,
    "model_id": MODEL_ID,
    "device": DEVICE,
    "dtype": DTYPE,
    "cpu_offload": ENABLE_CPU_OFFLOAD,
    "cache_dir": CACHE_DIR,
    "output_dir": str(OUTPUT_DIR),
  }


@app.post("/generate")
async def generate(
  request: Request,
  image: UploadFile | None = File(default=None),
  input_image_path: str | None = Form(default=None),
  num_frames: int | None = Form(default=None),
  num_inference_steps: int | None = Form(default=None),
  fps: int | None = Form(default=None),
  decode_chunk_size: int | None = Form(default=None),
  seed: int | None = Form(default=None),
  motion_bucket_id: int | None = Form(default=None),
  noise_aug_strength: float | None = Form(default=None),
) -> dict[str, Any]:
  payload = await json_payload(request)
  path = input_image_path or payload.get("input_image_path")
  upload = image

  if upload is None and not path:
    raise HTTPException(status_code=400, detail="provide input_image_path or upload image")
  if upload is not None and path:
    raise HTTPException(status_code=400, detail="provide only one image source")

  source_image = await load_uploaded_image(upload) if upload is not None else load_image_from_path(str(path))
  chunk_size = positive_int("decode_chunk_size", decode_chunk_size if decode_chunk_size is not None else payload.get("decode_chunk_size"), DEFAULT_DECODE_CHUNK_SIZE)
  output_fps = positive_int("fps", fps if fps is not None else payload.get("fps"), DEFAULT_FPS)
  request_seed = optional_int("seed", seed if seed is not None else payload.get("seed"))
  generator = None
  if request_seed is not None:
    generator = torch.Generator(device="cpu").manual_seed(request_seed)

  call_args: dict[str, Any] = {
    "image": source_image,
    "decode_chunk_size": chunk_size,
  }
  for key, value in {
    "num_frames": num_frames if num_frames is not None else payload.get("num_frames"),
    "num_inference_steps": num_inference_steps if num_inference_steps is not None else payload.get("num_inference_steps"),
    "motion_bucket_id": motion_bucket_id if motion_bucket_id is not None else payload.get("motion_bucket_id"),
  }.items():
    parsed = optional_int(key, value)
    if parsed is not None:
      call_args[key] = parsed

  parsed_noise = optional_float("noise_aug_strength", noise_aug_strength if noise_aug_strength is not None else payload.get("noise_aug_strength"))
  if parsed_noise is not None:
    call_args["noise_aug_strength"] = parsed_noise
  if generator is not None:
    call_args["generator"] = generator

  OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
  output_path = OUTPUT_DIR / f"svd-{uuid.uuid4().hex}.mp4"

  try:
    frames = get_pipeline()(**call_args).frames[0]
    export_to_video(frames, str(output_path), fps=output_fps)
  except Exception as exc:
    raise HTTPException(status_code=500, detail=str(exc)) from exc

  return {
    "output_path": str(output_path),
    "model_id": MODEL_ID,
    "seed": request_seed,
    "fps": output_fps,
  }


def main() -> None:
  uvicorn.run("app:app", host=HOST, port=PORT)


if __name__ == "__main__":
  main()
