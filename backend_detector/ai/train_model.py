#!/usr/bin/env python3
"""
train_model.py — Train the IFAKE ELA-CNN forgery detection model.

Implements the exact training pipeline from:
  "Image Forgery Detection and Classification Using Deep Learning and FIDAC Dataset"
  GitHub: https://github.com/shraddhavijay/IFAKE

Dataset (place in backend_detector/data/):
  data/Au/   ← authentic (original) images  → label 1
  data/Tp/   ← tampered/forged images       → label 0

Recommended datasets (free):
  1. CASIA2: https://www.kaggle.com/datasets/divg07/casia-20-image-tampering-detection-dataset
  2. FIDAC:   https://ieee-dataport.org/documents/fidac-forged-images-detection-and-classification

Usage:
  cd backend_detector
  pip install tensorflow pillow numpy tqdm scikit-learn
  python ai/train_model.py

Output:
  ai/model.h5 — saved IFAKE model (auto-loaded by model_service.py on next startup)
"""

import sys
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageEnhance

ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = ROOT / "data"
MODEL_OUTPUT = Path(__file__).resolve().parent / "model.h5"
IMAGE_SIZE = (128, 128)
ELA_QUALITY = 90  # Must match model_service.py


def convert_to_ela_image(path: Path, quality: int = ELA_QUALITY) -> Image.Image:
    """Exact IFAKE ELA preprocessing — matches convert_to_ela_image() from notebook."""
    original = Image.open(path).convert("RGB")
    buf = BytesIO()
    original.save(buf, format="JPEG", quality=quality)
    buf.seek(0)
    resaved = Image.open(buf)
    ela = ImageChops.difference(original, resaved)
    extrema = ela.getextrema()
    max_diff = max(pix[1] for pix in extrema)
    if max_diff == 0:
        max_diff = 1
    ela = ImageEnhance.Brightness(ela).enhance(255.0 / max_diff)
    return ela


def prepare_image(path: Path) -> np.ndarray:
    """ELA → resize 128×128 → /255.0  (matches IFAKE prepare_image)."""
    ela = convert_to_ela_image(path)
    return np.array(ela.resize(IMAGE_SIZE), dtype=np.float32) / 255.0


def load_dataset() -> tuple[np.ndarray, np.ndarray]:
    authentic_dir = DATA_ROOT / "Au"
    tampered_dir = DATA_ROOT / "Tp"
    extensions = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"}

    X, Y = [], []
    for folder, label in [(authentic_dir, 1), (tampered_dir, 0)]:
        if not folder.exists():
            print(f"  ⚠️  '{folder}' not found — skipping")
            continue
        files = [f for f in folder.iterdir() if f.suffix.lower() in extensions]
        tag = "authentic" if label == 1 else "tampered"
        print(f"  Processing {len(files)} {tag} images from {folder.name}/...")
        for fpath in files:
            try:
                X.append(prepare_image(fpath))
                Y.append(float(label))
            except Exception as e:
                print(f"    skip {fpath.name}: {e}")

    if not X:
        raise RuntimeError(
            f"\nNo images found!\n"
            f"Place your dataset in:\n"
            f"  {DATA_ROOT}/Au/   (authentic images)\n"
            f"  {DATA_ROOT}/Tp/   (tampered images)\n\n"
            f"Download CASIA2 from Kaggle:\n"
            f"  https://www.kaggle.com/datasets/divg07/casia-20-image-tampering-detection-dataset"
        )

    return np.array(X, dtype=np.float32), np.array(Y, dtype=np.float32)


def train() -> None:
    try:
        import tensorflow as tf
        from sklearn.model_selection import train_test_split
        from sklearn.utils import shuffle as sk_shuffle
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Run: pip install tensorflow scikit-learn")
        sys.exit(1)

    print("=" * 60)
    print("IFAKE ELA-CNN Training")
    print("=" * 60)

    print(f"\n📂 Loading dataset from {DATA_ROOT}")
    X, Y = load_dataset()
    X, Y = sk_shuffle(X, Y, random_state=42)
    n_authentic = int(Y.sum())
    n_tampered = len(Y) - n_authentic
    print(f"✅ {len(X)} total images | {n_authentic} authentic | {n_tampered} tampered")

    # Split: 75% train, 20% val, 5% test (matches IFAKE paper)
    X_temp, X_test, Y_temp, Y_test = train_test_split(X, Y, test_size=0.05, random_state=5)
    X_train, X_val, Y_train, Y_val = train_test_split(X_temp, Y_temp, test_size=0.20, random_state=5)
    print(f"📊 Train: {len(X_train)} | Val: {len(X_val)} | Test: {len(X_test)}")

    # Build exact IFAKE model
    sys.path.insert(0, str(Path(__file__).parent))
    from model_service import AIModelService
    model = AIModelService.build_ifake_model()
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-4, decay=1e-4 / 50),
        loss="binary_crossentropy",
        metrics=["accuracy"],
    )
    model.summary()

    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy", patience=10, restore_best_weights=True, verbose=1
        ),
        tf.keras.callbacks.ModelCheckpoint(
            str(MODEL_OUTPUT), save_best_only=True, monitor="val_accuracy", verbose=1
        ),
    ]

    print(f"\n🚀 Training IFAKE ELA-CNN (50 epochs max)...")
    model.fit(
        X_train, Y_train,
        validation_data=(X_val, Y_val),
        epochs=50,
        batch_size=19,
        callbacks=callbacks,
        verbose=1,
    )

    loss, acc = model.evaluate(X_test, Y_test, verbose=0)
    print(f"\n🎯 Test Accuracy: {acc * 100:.2f}% | Test Loss: {loss:.4f}")
    print(f"✅ IFAKE model saved: {MODEL_OUTPUT}")
    print("\nRestart backend_detector to load the trained model automatically.")


if __name__ == "__main__":
    train()
