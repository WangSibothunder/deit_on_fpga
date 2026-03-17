#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Preprocess an image to ImageNet-normalized tensor and save .npy.
Requires: Pillow, numpy
"""
import argparse
import os
import numpy as np


def resize_shorter(img, size):
    w, h = img.size
    if w < h:
        new_w = size
        new_h = int(h * size / w)
    else:
        new_h = size
        new_w = int(w * size / h)
    return img.resize((new_w, new_h))


def center_crop(img, size):
    w, h = img.size
    left = (w - size) // 2
    top = (h - size) // 2
    return img.crop((left, top, left + size, top + size))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--image', type=str, required=True)
    ap.add_argument('--out', type=str, required=True)
    ap.add_argument('--resize', type=int, default=256)
    ap.add_argument('--crop', type=int, default=224)
    args = ap.parse_args()

    try:
        from PIL import Image
    except Exception as e:
        print('[FATAL] Pillow not available:', e)
        return 1

    img = Image.open(args.image).convert('RGB')
    img = resize_shorter(img, args.resize)
    img = center_crop(img, args.crop)

    arr = np.asarray(img).astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    arr = (arr - mean) / std
    # HWC -> CHW
    arr = np.transpose(arr, (2, 0, 1))
    np.save(args.out, arr)
    print('[OK] Saved', args.out)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
