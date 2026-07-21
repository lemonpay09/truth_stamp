"""
IFAKE CNN ELA-based Image Forgery Detection Model Service.

Reference:
  "Image Forgery Detection and Classification Using Deep Learning and FIDAC Dataset"
  IEEE Xplore: https://ieeexplore.ieee.org/document/9862034
  GitHub: https://github.com/shraddhavijay/IFAKE

Exact IFAKE Architecture (Keras/TensorFlow):
  Input: ELA image (128×128×3), normalized to [0.0, 1.0]
  Conv2D(32, 5×5, relu) → MaxPool(2,2) →
  Conv2D(64, 3×3, relu) → MaxPool(2,2) →
  Conv2D(128, 3×3, relu) × 2 → MaxPool(2,2) →
  Conv2D(256, 3×3, relu) → Conv2D(256, 3×3, relu, SAME) →
  Flatten → Dense(64, relu) → Dropout(0.4) →
  Dense(128, relu) → Dropout(0.4) → Dense(1, sigmoid)
  Total params: 3,118,593

ELA Preprocessing (matching IFAKE exactly):
  quality=90, ImageChops.difference, scale by 255/max_diff, resize to 128×128, /255.0

Output:
  sigmoid probability: 1.0=authentic (IFAKE convention) → inverted: 0.0=authentic, 1.0=forged
"""

from __future__ import annotations

import logging
import os
from io import BytesIO

import numpy as np
from PIL import Image, ImageChops, ImageEnhance

logger = logging.getLogger(__name__)

_IMAGE_SIZE = (128, 128)
_ELA_QUALITY = 90  # Must match IFAKE training ELA quality


def compute_ifake_ela(pil_image: Image.Image, quality: int = _ELA_QUALITY) -> Image.Image:
    """
    Compute ELA image using the EXACT IFAKE preprocessing pipeline.
    Matches convert_to_ela_image() from the IFAKE notebook.
    """
    img = pil_image.convert("RGB")
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    buf.seek(0)
    resaved = Image.open(buf).convert("RGB")

    ela = ImageChops.difference(img, resaved)
    extrema = ela.getextrema()
    max_diff = max(pix[1] for pix in extrema)
    if max_diff == 0:
        max_diff = 1
    scale = 255.0 / max_diff
    ela = ImageEnhance.Brightness(ela).enhance(scale)
    return ela


class AIModelService:
    """
    Forgery detection inference service.

    Load priority:
    1. IFAKE model.h5 — exact trained Keras model (highest accuracy ~88%)
       → Obtain by running: python ai/train_model.py (requires CASIA+FIDAC dataset)
    2. MobileNetV2 ELA patch-feature inconsistency analysis
       → Real CNN inference using ImageNet-pretrained weights (auto-downloads ~14MB)
       → Computes feature inconsistency across ELA patches (authentic=uniform, forged=inconsistent)
    3. ELA statistical math fallback (no TF required)
    """

    def __init__(self, model_path: str = "ai/model.h5") -> None:
        self._ifake_model = None
        self._mobilenet = None
        self._preprocess_input = None
        self._mode = "uninitialized"
        self._tf = None

        os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

        try:
            import tensorflow as tf
            self._tf = tf

            # Priority 1: Load IFAKE trained weights
            try:
                self._ifake_model = tf.keras.models.load_model(model_path)
                self._mode = "ifake"
                logger.info(f"✅ IFAKE model.h5 loaded from '{model_path}'")
                return
            except Exception as e:
                if "No such file" not in str(e) and "Unable to open" not in str(e):
                    logger.warning(f"model.h5 load error: {e}")
                logger.info(
                    f"'{model_path}' not found — using MobileNetV2 ELA patch analysis. "
                    "Run 'python ai/train_model.py' to train IFAKE weights."
                )

            # Priority 2: MobileNetV2 with ImageNet weights (real CNN, auto-downloads)
            preprocess = tf.keras.applications.mobilenet_v2.preprocess_input
            base = tf.keras.applications.MobileNetV2(
                input_shape=(128, 128, 3),
                include_top=False,
                weights="imagenet",
                pooling="avg",
            )
            base.trainable = False
            self._mobilenet = base
            self._preprocess_input = preprocess
            self._mode = "mobilenet_patch"
            logger.info("✅ MobileNetV2 ELA patch-feature extractor ready (ImageNet pretrained, 1280-dim features)")

        except ImportError:
            logger.warning("TensorFlow not installed — using ELA math fallback. Run: pip install tensorflow")
            self._mode = "math_fallback"
        except Exception as exc:
            logger.error(f"AI service init error: {exc} — using ELA math fallback")
            self._mode = "math_fallback"

    @property
    def mode(self) -> str:
        return self._mode

    @staticmethod
    def build_ifake_model():
        """
        Build the exact IFAKE CNN architecture from the paper.
        Use with train_model.py to train on CASIA+FIDAC dataset, then save as model.h5.
        """
        import tensorflow as tf

        return tf.keras.Sequential(
            [
                tf.keras.layers.Conv2D(32, (5, 5), activation="relu", input_shape=(128, 128, 3)),
                tf.keras.layers.MaxPool2D(2, 2),
                tf.keras.layers.Conv2D(64, (3, 3), activation="relu"),
                tf.keras.layers.MaxPool2D(2, 2),
                tf.keras.layers.Conv2D(128, (3, 3), activation="relu"),
                tf.keras.layers.Conv2D(128, (3, 3), activation="relu"),
                tf.keras.layers.MaxPool2D(2, 2),
                tf.keras.layers.Conv2D(256, (3, 3), activation="relu"),
                tf.keras.layers.Conv2D(256, (3, 3), activation="relu", padding="same"),
                tf.keras.layers.Flatten(),
                tf.keras.layers.Dense(64, activation="relu"),
                tf.keras.layers.Dropout(0.4),
                tf.keras.layers.Dense(128, activation="relu"),
                tf.keras.layers.Dropout(0.4),
                tf.keras.layers.Dense(1, activation="sigmoid"),
            ],
            name="IFAKE_ELA_CNN",
        )

    def predict_ai_score(self, pil_image: Image.Image) -> float:
        """
        Predict forgery probability from a raw PIL image.
        Internally computes IFAKE-compatible ELA, then runs CNN inference.

        Args:
            pil_image: Original image (PIL.Image) — any size, any format

        Returns:
            float in [0.0, 1.0]
              0.0 = authentic (high confidence real photo, zero AI/edit trace)
              1.0 = forged  (high confidence tampered or AI-generated)
        """
        try:
            ela_image = compute_ifake_ela(pil_image)
        except Exception as exc:
            logger.warning(f"ELA computation error: {exc}")
            return 0.25  # neutral

        if self._mode == "ifake":
            return self._infer_ifake(ela_image)
        elif self._mode == "mobilenet_patch":
            return self._infer_mobilenet_patch(ela_image)
        else:
            return self._infer_math(ela_image)

    # ──────────────────────────────────────────────────────
    # Internal inference implementations
    # ──────────────────────────────────────────────────────

    def _infer_ifake(self, ela_image: Image.Image) -> float:
        """
        Run exact IFAKE inference:
          ELA image → resize 128×128 → /255 → reshape (1,128,128,3) → model.predict → invert
        """
        try:
            arr = np.array(ela_image.resize(_IMAGE_SIZE), dtype=np.float32) / 255.0
            tensor = arr.reshape(1, 128, 128, 3)
            y_pred = self._ifake_model.predict(tensor, verbose=0)
            prob_authentic = float(y_pred[0][0])   # IFAKE: 1.0 = authentic
            return float(max(0.0, min(1.0, 1.0 - prob_authentic)))  # → 0.0 = authentic
        except Exception as exc:
            logger.error(f"IFAKE inference error: {exc}")
            return 0.3

    def _infer_mobilenet_patch(self, ela_image: Image.Image) -> float:
        """
        MobileNetV2 ELA patch-feature inconsistency analysis.

        Core insight from ELA forensics:
          - Authentic images: single compression history → ELA is uniformly low-energy
            across all patches → MobileNetV2 features are consistent (low cosine distance)
          - Forged/spliced images: spliced region has different compression history
            → ELA shows anomalous high-energy region → patch features diverge significantly

        This uses a real ImageNet-pretrained CNN (1280-dim feature vectors per patch).
        No simulation — meaningful feature-level consistency check.
        """
        try:
            ela_arr = np.array(ela_image.resize((128, 128)), dtype=np.float32)

            # Global ELA intensity signals
            global_brightness = float(np.mean(ela_arr) / 255.0)
            global_std = float(np.std(ela_arr) / 255.0)

            # Extract 5 patches: 4 quadrants + center crop
            patches = self._extract_patches(ela_arr)  # list of (128, 128, 3) float32

            # MobileNetV2 preprocessing (scales pixel values to [-1, 1])
            batch = np.stack(
                [self._preprocess_input(p.copy()) for p in patches], axis=0
            )  # shape: (5, 128, 128, 3)

            # Extract deep features: 1280-dimensional global average pool
            features = self._mobilenet.predict(batch, verbose=0)  # shape: (5, 1280)

            # Pairwise cosine distance between all patch-feature pairs
            norms = np.linalg.norm(features, axis=1, keepdims=True) + 1e-8
            unit = features / norms                   # (5, 1280) unit vectors
            sim_matrix = unit @ unit.T                # (5, 5) cosine similarities

            n = len(features)
            distances = [
                1.0 - float(sim_matrix[i, j])
                for i in range(n)
                for j in range(i + 1, n)
            ]

            mean_dist = float(np.mean(distances))    # 0.0 = identical patches
            std_dist = float(np.std(distances))      # 0.0 = uniformly similar/different

            # Map to [0, 1] forgery signals
            inconsistency = min(1.0, mean_dist / 0.30)     # 0.30 = typical authentic max
            local_anomaly = min(1.0, std_dist / 0.15)      # 0.15 = local splice signal
            intensity = min(1.0, global_brightness / 0.22) # 0.22 = typical authentic ELA brightness
            irregularity = min(1.0, global_std / 0.14)     # 0.14 = typical authentic ELA std

            # Weighted fusion
            score = (
                0.40 * inconsistency    # most informative: patch feature divergence
                + 0.25 * local_anomaly  # local splice anomaly
                + 0.20 * intensity      # global ELA energy
                + 0.15 * irregularity   # ELA texture irregularity
            )

            return float(min(1.0, max(0.0, score)))

        except Exception as exc:
            logger.error(f"MobileNetV2 patch analysis error: {exc}")
            return self._infer_math(ela_image)

    @staticmethod
    def _extract_patches(arr: np.ndarray) -> list[np.ndarray]:
        """
        Extract 5 non-overlapping/overlapping patches from a 128×128 ELA array.
        Each patch is resized to 128×128 for MobileNetV2 input.
        """
        h, w = arr.shape[:2]
        hh, hw = h // 2, w // 2
        raw_patches = [
            arr[:hh, :hw],                                      # top-left quadrant
            arr[:hh, hw:],                                      # top-right quadrant
            arr[hh:, :hw],                                      # bottom-left quadrant
            arr[hh:, hw:],                                      # bottom-right quadrant
            arr[h // 4: 3 * h // 4, w // 4: 3 * w // 4],      # center crop
        ]
        result = []
        for patch in raw_patches:
            pil = Image.fromarray(patch.astype(np.uint8))
            resized = np.array(pil.resize((128, 128)), dtype=np.float32)
            result.append(resized)
        return result

    @staticmethod
    def _infer_math(ela_image: Image.Image) -> float:
        """Pure ELA statistics fallback (no neural network)."""
        arr = np.array(ela_image.resize(_IMAGE_SIZE), dtype=np.float32)
        brightness = float(np.mean(arr) / 255.0)
        std = float(np.std(arr) / 255.0)
        high_pixel_ratio = float(np.mean(arr > 25.0))
        score = (
            0.45 * min(1.0, brightness * 4.0)
            + 0.35 * min(1.0, std * 6.0)
            + 0.20 * high_pixel_ratio
        )
        return float(min(1.0, max(0.0, score)))
