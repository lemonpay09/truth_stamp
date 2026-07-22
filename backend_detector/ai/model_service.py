from __future__ import annotations

import logging
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageEnhance

logger = logging.getLogger(__name__)

IMAGE_SIZE = (128, 128)
ELA_QUALITY = 90


def compute_ela(image: Image.Image, quality: int = ELA_QUALITY) -> Image.Image:
    original = image.convert('RGB')
    buf = BytesIO()
    original.save(buf, format='JPEG', quality=quality)
    buf.seek(0)
    resaved = Image.open(buf).convert('RGB')

    ela = ImageChops.difference(original, resaved)
    extrema = ela.getextrema()
    max_diff = max(channel[1] for channel in extrema)
    if max_diff == 0:
        max_diff = 1
    ela = ImageEnhance.Brightness(ela).enhance(255.0 / max_diff)
    return ela


class AIModelService:
    def __init__(self, model_path: str = 'ai/model.h5') -> None:
        self._model_path = Path(model_path)
        self._model = None
        self._load_error: Exception | None = None
        self._tf = None

        try:
            import tensorflow as tf
            self._tf = tf
            if self._model_path.exists():
                self._model = tf.keras.models.load_model(self._model_path)
                self._model.compile(optimizer='adam', loss='binary_crossentropy', metrics=['accuracy'])
                logger.info('Loaded IFAKE model from %s', self._model_path)
            else:
                logger.warning('IFAKE model not found at %s. Run ai/train_model.py first.', self._model_path)
        except Exception as exc:
            self._load_error = exc
            logger.exception('Failed to initialize AIModelService')

    @property
    def ready(self) -> bool:
        return self._model is not None

    def predict_ai_score(self, image: Image.Image) -> float:
        if self._model is None:
            raise RuntimeError(
                f'AI model is not ready: {self._load_error or self._model_path}. '
                'Train backend_detector/ai/model.h5 by running python ai/train_model.py.'
            )

        ela = compute_ela(image)
        arr = np.array(ela.resize(IMAGE_SIZE), dtype=np.float32) / 255.0
        tensor = np.expand_dims(arr, axis=0)
        prob_tampered = float(self._model.predict(tensor, verbose=0)[0][0])
        return max(0.0, min(1.0, prob_tampered))
