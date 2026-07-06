#!/bin/bash
set -e

VENV_DIR="/opt/venv"
PIP_PACKAGES=(
    paddlepaddle==3.3.1
    paddleocr==3.5.0
    fastapi
    uvicorn
    python-multipart
    opencv-python-headless
    loguru
    setuptools
    requests
    pymupdf
)

# ── Install uv and Python 3.12 (paddlepaddle requires Python <= 3.13) ──
if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    pip install uv
fi
export PATH="/root/.local/bin:${PATH}"

if ! uv python find 3.12 &>/dev/null; then
    echo "Installing Python 3.12..."
    uv python install 3.12
fi

# ── Install pip packages into persistent venv ──
if [ ! -f "$VENV_DIR/bin/python" ]; then
    echo "Creating virtual environment with Python 3.12..."
    uv venv --python 3.12 "$VENV_DIR"

    echo "Installing packages..."
    uv pip install --python "$VENV_DIR/bin/python" "${PIP_PACKAGES[@]}"

    echo "Warming up PaddleOCR model..."
    "$VENV_DIR/bin/python" -c "
import numpy as np, cv2
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_textline_orientation=True, lang='ch', device='cpu', enable_mkldnn=False)
img = np.ones((64, 256, 3), dtype=np.uint8) * 255
cv2.putText(img, 'warmup', (10, 45), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 0, 0), 2)
ocr.ocr(img)
print('Model warmup done.')
"
    echo "PaddleOCR setup complete."
else
    echo "Virtual environment already exists, skipping install."
fi

export PATH="$VENV_DIR/bin:${PATH}"

cd /app
exec uvicorn main:app --host 0.0.0.0 --port 8000
