import asyncio
import base64
import math
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import piexif
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, UnidentifiedImageError

from ai.model_service import AIModelService

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except Exception:
    pillow_heif = None


app = FastAPI(title="Truth Stamp Detector", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 初始化 AI 推理服务（IFAKE Keras 模型 或 MobileNetV2 ELA patch 分析）
ai_service = AIModelService(model_path="ai/model.h5")


@dataclass
class MetadataResult:
    score: int
    reasons: list[str]


@dataclass
class ElaResult:
    score: int
    heatmap_b64: str
    mask_b64: str
    details: dict[str, Any]


def _normalize_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8", errors="ignore").strip()
        except Exception:
            return ""
    return str(value).strip()


def analyze_exif_metadata(image_bytes: bytes) -> MetadataResult:
    score = 100
    reasons: list[str] = []

    try:
        image = Image.open(BytesIO(image_bytes))
    except UnidentifiedImageError:
        return MetadataResult(score=0, reasons=["文件不是有效图片格式"])

    exif_dict: dict[str, Any] = {}
    software = ""

    try:
        raw_exif = image.info.get("exif")
        if raw_exif:
            exif_dict = piexif.load(raw_exif)
    except Exception:
        exif_dict = {}

    zeroth = exif_dict.get("0th", {}) if exif_dict else {}
    exif_ifd = exif_dict.get("Exif", {}) if exif_dict else {}

    make = _normalize_text(zeroth.get(piexif.ImageIFD.Make))
    model = _normalize_text(zeroth.get(piexif.ImageIFD.Model))
    software = _normalize_text(zeroth.get(piexif.ImageIFD.Software)).lower()

    edited_keywords = [
        "photoshop",
        "lightroom",
        "snapseed",
        "meitu",
        "canva",
        "gimp",
        "ai",
        "midjourney",
        "stable diffusion",
    ]
    if software and any(k in software for k in edited_keywords):
        score -= 40
        reasons.append(f"检测到编辑软件痕迹: {software}")

    camera_fields = [
        make,
        model,
        _normalize_text(exif_ifd.get(piexif.ExifIFD.DateTimeOriginal)),
        _normalize_text(exif_ifd.get(piexif.ExifIFD.LensMake)),
        _normalize_text(exif_ifd.get(piexif.ExifIFD.LensModel)),
        str(exif_ifd.get(piexif.ExifIFD.ISOSpeedRatings, "")),
        str(exif_ifd.get(piexif.ExifIFD.ExposureTime, "")),
        str(exif_ifd.get(piexif.ExifIFD.FNumber, "")),
        str(exif_ifd.get(piexif.ExifIFD.FocalLength, "")),
    ]
    present_count = sum(1 for f in camera_fields if _normalize_text(f))
    if present_count <= 2:
        score -= 45
        reasons.append("相机关键 EXIF 参数严重缺失")
    elif present_count <= 5:
        score -= 20
        reasons.append("相机 EXIF 参数不完整")

    if image.format not in {"JPEG", "JPG", "HEIC", "PNG"}:
        score -= 5
        reasons.append(f"图像格式非常见相机输出: {image.format}")

    score = max(0, min(100, score))
    if not reasons:
        reasons.append("EXIF 信息整体正常")
    return MetadataResult(score=score, reasons=reasons)


def run_ela_and_edge_detection(image_bytes: bytes, quality: int = 95, enhance: float = 45.0) -> ElaResult:
    try:
        pil_image = Image.open(BytesIO(image_bytes)).convert("RGB")
    except UnidentifiedImageError as exc:
        raise ValueError("无法读取图片内容") from exc

    original_rgb = np.array(pil_image, dtype=np.uint8)

    buffer = BytesIO()
    pil_image.save(buffer, format="JPEG", quality=quality)
    recompressed_rgb = np.array(Image.open(BytesIO(buffer.getvalue())).convert("RGB"), dtype=np.uint8)

    if original_rgb.shape != recompressed_rgb.shape:
        recompressed_rgb = cv2.resize(
            recompressed_rgb,
            (original_rgb.shape[1], original_rgb.shape[0]),
            interpolation=cv2.INTER_LINEAR,
        )

    ela_rgb = cv2.absdiff(original_rgb, recompressed_rgb)
    ela_enhanced = np.clip(ela_rgb.astype(np.float32) * enhance, 0, 255).astype(np.uint8)

    ela_gray = cv2.cvtColor(ela_enhanced, cv2.COLOR_RGB2GRAY)
    original_gray = cv2.cvtColor(original_rgb, cv2.COLOR_RGB2GRAY)

    original_laplacian = cv2.convertScaleAbs(cv2.Laplacian(original_gray, cv2.CV_16S, ksize=3))
    _, original_edge_mask = cv2.threshold(
        original_laplacian, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    suppress_kernel = np.ones((3, 3), np.uint8)
    original_edge_mask = cv2.morphologyEx(
        original_edge_mask, cv2.MORPH_CLOSE, suppress_kernel, iterations=1
    )
    original_edge_mask = cv2.dilate(original_edge_mask, suppress_kernel, iterations=1)
    suppressed_gray = cv2.subtract(ela_gray, original_edge_mask)

    edges = cv2.Canny(suppressed_gray, threshold1=35, threshold2=120)
    edge_energy = cv2.GaussianBlur(suppressed_gray.astype(np.float32), (5, 5), 0)
    high_energy_threshold = float(np.percentile(edge_energy, 96))
    high_energy_mask = (edge_energy >= high_energy_threshold) & (edges > 0)

    heatmap = cv2.applyColorMap(suppressed_gray, cv2.COLORMAP_TURBO)
    heatmap = cv2.cvtColor(heatmap, cv2.COLOR_BGR2RGB)

    # Neon highlights for suspicious edges
    heatmap[high_energy_mask] = np.array([57, 255, 245], dtype=np.uint8)

    # Blend subtle original edges for readability
    original_edges = cv2.Canny(original_gray, threshold1=60, threshold2=160)
    edge_overlay = np.zeros_like(heatmap)
    edge_overlay[original_edges > 0] = [255, 255, 255]
    heatmap = cv2.addWeighted(heatmap, 0.92, edge_overlay, 0.08, 0)

    ela_strength = float(np.mean(suppressed_gray) / 255.0 * 100.0)
    high_energy_ratio = float(np.count_nonzero(high_energy_mask) / high_energy_mask.size * 100.0)
    high_energy_score = min(100.0, high_energy_ratio * 10.0)
    forgery_score = int(round(min(100.0, 0.65 * ela_strength + 0.35 * high_energy_score)))

    heatmap_image = Image.fromarray(heatmap)
    output = BytesIO()
    heatmap_image.save(output, format="PNG")
    heatmap_b64 = base64.b64encode(output.getvalue()).decode("utf-8")

    # Tactical Action 2: pixel-level tamper mask overlay (RGBA, red @40% alpha).
    diff_gray = cv2.cvtColor(ela_rgb, cv2.COLOR_RGB2GRAY)
    blur = cv2.GaussianBlur(diff_gray, (5, 5), 0)
    _, binary = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    kernel = np.ones((3, 3), np.uint8)
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=2)
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel, iterations=1)

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    min_area = 200.0
    valid_contours = [cnt for cnt in contours if cv2.contourArea(cnt) >= min_area]

    mask_rgba = np.zeros((original_rgb.shape[0], original_rgb.shape[1], 4), dtype=np.uint8)
    if valid_contours:
        mask_bgra = np.zeros_like(mask_rgba)
        cv2.drawContours(mask_bgra, valid_contours, -1, color=(0, 0, 255, 102), thickness=cv2.FILLED)
        mask_rgba = cv2.cvtColor(mask_bgra, cv2.COLOR_BGRA2RGBA)

    mask_output = BytesIO()
    Image.fromarray(mask_rgba, mode="RGBA").save(mask_output, format="PNG")
    mask_b64 = base64.b64encode(mask_output.getvalue()).decode("utf-8")

    return ElaResult(
        score=forgery_score,
        heatmap_b64=heatmap_b64,
        mask_b64=mask_b64,
        details={
            "ela_strength": round(ela_strength, 2),
            "high_energy_ratio": round(high_energy_ratio, 2),
            "enhance_factor": enhance,
            "jpeg_quality": quality,
            "tamper_contours": len(valid_contours),
        },
    )


def calibrate_low_risk_scores(
    metadata_score: int,
    ai_score_100: int,
    combined_score: int,
    ela_score: int,
    tamper_contours: int,
) -> tuple[int, int, str]:
    # Tactical Action 1: confidence calibration to avoid false positives.
    if tamper_contours > 0 or ela_score >= 35:
        return ai_score_100, combined_score, "疑似局部修改"

    if metadata_score == 100 and ela_score < 30:
        smooth = (ela_score / 30.0) ** 1.5
        calibrated = int(round(3 + smooth * 9))
        calibrated = max(3, min(12, calibrated))
        safe_score = calibrated
        return safe_score, safe_score, "安全 (未见篡改)"

    if metadata_score == 55 and ela_score < 25:
        smooth = (ela_score / 25.0) ** 1.5
        calibrated = int(round(10 + smooth * 8))
        calibrated = max(10, min(18, calibrated))
        safe_score = calibrated
        return safe_score, safe_score, "安全 (未见篡改的平面截图)"

    if ela_score >= 25:
        return ai_score_100, combined_score, "疑似局部修改"

    return ai_score_100, combined_score, "安全 (未见篡改)"


def build_report_message(metadata_score: int, forgery_score: int, reasons: list[str]) -> str:
    if forgery_score >= 75 or metadata_score <= 40:
        return f"检测到较高篡改风险。EXIF: {'；'.join(reasons[:2])}"
    if forgery_score >= 55 or metadata_score <= 60:
        return f"检测到中等篡改风险，建议人工复核。EXIF: {'；'.join(reasons[:2])}"
    return f"当前样本未发现明显篡改痕迹。EXIF: {'；'.join(reasons[:2])}"


def prepare_image_bytes_for_analysis(
    image_bytes: bytes,
    filename: str,
    content_type: str,
) -> tuple[bytes, str]:
    extension = Path(filename or "").suffix.lower()
    allowed_ext = {".jpg", ".jpeg", ".png", ".heic", ".heif"}

    if extension and extension not in allowed_ext:
        raise HTTPException(
            status_code=400,
            detail="仅支持 .jpg/.jpeg/.png/.heic/.heif 文件上传",
        )

    is_heif_type = "heic" in content_type or "heif" in content_type
    is_heif_ext = extension in {".heic", ".heif"}
    if is_heif_type or is_heif_ext:
        try:
            image = Image.open(BytesIO(image_bytes)).convert("RGB")
            converted = BytesIO()
            image.save(converted, format="JPEG", quality=96)
            return converted.getvalue(), ".jpeg"
        except Exception as exc:
            raise HTTPException(
                status_code=400,
                detail="HEIC/HEIF 图片解析失败，请确认已安装 pillow-heif 或上传 JPEG/PNG。",
            ) from exc

    return image_bytes, extension


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/detect")
async def detect_forgery(file: UploadFile = File(...)) -> dict[str, Any]:
    content_type = (file.content_type or "").lower()

    image_bytes = await file.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="上传文件为空")

    try:
        normalized_bytes, _ = prepare_image_bytes_for_analysis(
            image_bytes=image_bytes,
            filename=file.filename or "",
            content_type=content_type,
        )
    except HTTPException:
        raise

    try:
        pil_image = Image.open(BytesIO(normalized_bytes)).convert("RGB")
        metadata_task = asyncio.to_thread(analyze_exif_metadata, normalized_bytes)
        ela_task = asyncio.to_thread(run_ela_and_edge_detection, normalized_bytes)
        ai_task = asyncio.to_thread(ai_service.predict_ai_score, pil_image)
        metadata_result, ela_result, ai_score_float = await asyncio.gather(
            metadata_task, ela_task, ai_task
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"检测失败: {exc}") from exc
    
    ai_score_100 = int(round(ai_score_float * 100))
    final_forgery_score = int(round(0.65 * ela_result.score + 0.35 * ai_score_100))
    tamper_contours = int(ela_result.details.get("tamper_contours", 0))
    ai_score_100, final_forgery_score, calibrated_conclusion = calibrate_low_risk_scores(
        metadata_score=metadata_result.score,
        ai_score_100=ai_score_100,
        combined_score=final_forgery_score,
        ela_score=ela_result.score,
        tamper_contours=tamper_contours,
    )
    is_forgery = final_forgery_score >= 60 or tamper_contours > 0

    message = build_report_message(metadata_result.score, final_forgery_score, metadata_result.reasons)

    return {
        "is_forgery": is_forgery,
        "metadata_score": metadata_result.score,
        "forgery_score": final_forgery_score,
        "heatmap_image": ela_result.heatmap_b64,
        "mask_image_base64": ela_result.mask_b64,
        "conclusion": calibrated_conclusion,
        "status": "safe" if calibrated_conclusion.startswith("安全") else "suspicious",
        "message": message,
        "details": {
            "ela_score": ela_result.score,
            "ai_score": ai_score_100,
            "combined_risk_score": final_forgery_score,
            "status": "safe" if calibrated_conclusion.startswith("安全") else "suspicious",
            "conclusion": calibrated_conclusion,
            "mask_image_base64": ela_result.mask_b64,
            "metadata_reasons": metadata_result.reasons,
            "ela": ela_result.details,
            "filename": file.filename,
        },
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)
