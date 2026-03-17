#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Export Q/K/V data for attention verification.
- Generate float32 Q,K,V
- Quantize to int8 with per-tensor scale
- Save .npy files
"""
import argparse
import os
import numpy as np


def quantize_int8(x, target_int8=16):
    max_abs = float(np.max(np.abs(x)))
    if max_abs == 0.0:
        scale = 1.0
    else:
        scale = max_abs / float(target_int8)
    q = np.rint(x / scale)
    q = np.clip(q, -127, 127).astype(np.int8)
    return q, scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--m', type=int, default=197, help='Sequence length (M)')
    ap.add_argument('--dh', type=int, default=64, help='Head dim (Dh)')
    ap.add_argument('--seed', type=int, default=1, help='Random seed')
    ap.add_argument('--out_dir', type=str, default='ps/python/attn_data', help='Output directory')
    ap.add_argument('--target_int8', type=int, default=16, help='Target int8 range for quantization')
    ap.add_argument('--range', type=float, default=1.0, help='Uniform range for float data')
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    rng = np.random.RandomState(args.seed)
    q_fp = rng.uniform(-args.range, args.range, size=(args.m, args.dh)).astype(np.float32)
    k_fp = rng.uniform(-args.range, args.range, size=(args.m, args.dh)).astype(np.float32)
    v_fp = rng.uniform(-args.range, args.range, size=(args.m, args.dh)).astype(np.float32)

    q_int8, scale_q = quantize_int8(q_fp, args.target_int8)
    k_int8, scale_k = quantize_int8(k_fp, args.target_int8)
    v_int8, scale_v = quantize_int8(v_fp, args.target_int8)

    np.save(os.path.join(args.out_dir, 'q_fp32.npy'), q_fp)
    np.save(os.path.join(args.out_dir, 'k_fp32.npy'), k_fp)
    np.save(os.path.join(args.out_dir, 'v_fp32.npy'), v_fp)

    np.save(os.path.join(args.out_dir, 'q_int8.npy'), q_int8)
    np.save(os.path.join(args.out_dir, 'k_int8.npy'), k_int8)
    np.save(os.path.join(args.out_dir, 'v_int8.npy'), v_int8)

    np.save(os.path.join(args.out_dir, 'scale_q.npy'), np.array(scale_q, dtype=np.float32))
    np.save(os.path.join(args.out_dir, 'scale_k.npy'), np.array(scale_k, dtype=np.float32))
    np.save(os.path.join(args.out_dir, 'scale_v.npy'), np.array(scale_v, dtype=np.float32))

    meta = {
        'm': args.m,
        'dh': args.dh,
        'seed': args.seed,
        'target_int8': args.target_int8,
        'range': args.range,
    }
    np.save(os.path.join(args.out_dir, 'meta.npy'), meta, allow_pickle=True)

    print('[OK] Exported attention data to:', args.out_dir)


if __name__ == '__main__':
    main()
