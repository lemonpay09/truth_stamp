#!/usr/bin/env python3
from __future__ import annotations

from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageEnhance
from sklearn.model_selection import train_test_split
from tqdm import tqdm

ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = ROOT / 'data'
MODEL_PATH = Path(__file__).resolve().parent / 'model.h5'
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


def load_sample(path: Path) -> np.ndarray:
    img = Image.open(path).convert('RGB')
    ela = compute_ela(img)
    arr = np.array(ela.resize(IMAGE_SIZE), dtype=np.float32) / 255.0
    return arr


def load_dataset():
    x, y = [], []
    for folder, label in ((DATA_ROOT / 'Au', 0), (DATA_ROOT / 'Tp', 1)):
        if not folder.exists():
            continue
        files = [p for p in folder.iterdir() if p.suffix.lower() in {'.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff'}]
        for path in tqdm(files, desc=f'Loading {folder.name}'):
            try:
                x.append(load_sample(path))
                y.append(label)
            except Exception:
                pass
    if not x:
        raise RuntimeError(f'No images found in {DATA_ROOT}/Au or {DATA_ROOT}/Tp')
    return np.array(x, dtype=np.float32), np.array(y, dtype=np.float32)


def build_model():
    import tensorflow as tf
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(128, 128, 3)),
        tf.keras.layers.Conv2D(32, (5, 5), activation='relu'),
        tf.keras.layers.MaxPool2D((2, 2)),
        tf.keras.layers.Conv2D(64, (3, 3), activation='relu'),
        tf.keras.layers.MaxPool2D((2, 2)),
        tf.keras.layers.Conv2D(128, (3, 3), activation='relu'),
        tf.keras.layers.MaxPool2D((2, 2)),
        tf.keras.layers.Flatten(),
        tf.keras.layers.Dense(128, activation='relu'),
        tf.keras.layers.Dropout(0.5),
        tf.keras.layers.Dense(1, activation='sigmoid'),
    ])
    model.compile(optimizer='adam', loss='binary_crossentropy', metrics=['accuracy'])
    return model


def main():
    import tensorflow as tf

    print('Loading dataset...')
    x, y = load_dataset()
    x_train, x_val, y_train, y_val = train_test_split(
        x, y, test_size=0.2, random_state=42, stratify=y if len(set(y.tolist())) > 1 else None
    )

    model = build_model()
    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor='val_accuracy', patience=8, restore_best_weights=True
        ),
        tf.keras.callbacks.ModelCheckpoint(
            filepath=str(MODEL_PATH), monitor='val_accuracy', save_best_only=True, verbose=1
        ),
    ]

    model.fit(
        x_train, y_train,
        validation_data=(x_val, y_val),
        epochs=40,
        batch_size=19,
        callbacks=callbacks,
        verbose=1,
    )

    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    model.save(MODEL_PATH)
    print(f'Saved model to {MODEL_PATH}')


if __name__ == '__main__':
    main()
