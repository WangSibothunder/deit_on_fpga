#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Export DeiT-Tiny weights to .npy for PYNQ inference.
- Save float32 weights/bias
- Save int8 weights + scale (static PTQ)
"""
import argparse
import os
import numpy as np


def quantize_weight(w, target_int8=64):
    w = w.astype(np.float32)
    max_abs = float(np.max(np.abs(w)))
    if max_abs == 0.0:
        scale = 1.0
    else:
        scale = max_abs / float(target_int8)
    q = np.rint(w / scale)
    q = np.clip(q, -127, 127).astype(np.int8)
    return q, scale


def save_fp(path, arr):
    np.save(path, arr.astype(np.float32))


def save_i8(path, arr):
    np.save(path, arr.astype(np.int8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--weights', type=str, default='ps/deit/deit_tiny_patch16_224_10.pth')
    ap.add_argument('--out_dir', type=str, default='ps/deit/weights_npy')
    ap.add_argument('--target_int8', type=int, default=64)
    args = ap.parse_args()

    try:
        import torch
        import timm
    except Exception as e:
        print('[FATAL] Missing dependency:', e)
        print('Please install: torch, timm')
        return 1

    os.makedirs(args.out_dir, exist_ok=True)

    print('[STEP] Load model')
    model = timm.create_model('deit_tiny_patch16_224', pretrained=False)
    ckpt = torch.load(args.weights, map_location='cpu')
    if isinstance(ckpt, dict):
        if 'model' in ckpt:
            state = ckpt['model']
        elif 'state_dict' in ckpt:
            state = ckpt['state_dict']
        else:
            state = ckpt
    else:
        state = ckpt
    model.load_state_dict(state, strict=False)
    model.eval()

    sd = model.state_dict()

    def save_linear(prefix, w, b):
        save_fp(os.path.join(args.out_dir, prefix + '_weight_fp32.npy'), w)
        save_fp(os.path.join(args.out_dir, prefix + '_bias_fp32.npy'), b)
        w_q, scale = quantize_weight(w, args.target_int8)
        save_i8(os.path.join(args.out_dir, prefix + '_weight_int8.npy'), w_q)
        save_fp(os.path.join(args.out_dir, prefix + '_weight_scale.npy'), np.array(scale, dtype=np.float32))

    # Patch embed
    print('[STEP] Export patch_embed')
    save_fp(os.path.join(args.out_dir, 'patch_embed_weight_fp32.npy'), sd['patch_embed.proj.weight'].cpu().numpy())
    save_fp(os.path.join(args.out_dir, 'patch_embed_bias_fp32.npy'), sd['patch_embed.proj.bias'].cpu().numpy())
    save_fp(os.path.join(args.out_dir, 'cls_token_fp32.npy'), sd['cls_token'].cpu().numpy())
    save_fp(os.path.join(args.out_dir, 'pos_embed_fp32.npy'), sd['pos_embed'].cpu().numpy())

    # Blocks
    print('[STEP] Export blocks')
    num_blocks = len(model.blocks)
    for i in range(num_blocks):
        p = f'blocks.{i}.'
        idx = f'blk{i:02d}'
        # LN1
        save_fp(os.path.join(args.out_dir, f'{idx}_ln1_weight_fp32.npy'), sd[p + 'norm1.weight'].cpu().numpy())
        save_fp(os.path.join(args.out_dir, f'{idx}_ln1_bias_fp32.npy'), sd[p + 'norm1.bias'].cpu().numpy())
        # QKV
        save_linear(f'{idx}_qkv', sd[p + 'attn.qkv.weight'].cpu().numpy(), sd[p + 'attn.qkv.bias'].cpu().numpy())
        # Proj
        save_linear(f'{idx}_proj', sd[p + 'attn.proj.weight'].cpu().numpy(), sd[p + 'attn.proj.bias'].cpu().numpy())
        # LN2
        save_fp(os.path.join(args.out_dir, f'{idx}_ln2_weight_fp32.npy'), sd[p + 'norm2.weight'].cpu().numpy())
        save_fp(os.path.join(args.out_dir, f'{idx}_ln2_bias_fp32.npy'), sd[p + 'norm2.bias'].cpu().numpy())
        # MLP
        save_linear(f'{idx}_mlp1', sd[p + 'mlp.fc1.weight'].cpu().numpy(), sd[p + 'mlp.fc1.bias'].cpu().numpy())
        save_linear(f'{idx}_mlp2', sd[p + 'mlp.fc2.weight'].cpu().numpy(), sd[p + 'mlp.fc2.bias'].cpu().numpy())

    # Final norm + head
    print('[STEP] Export final norm + head')
    save_fp(os.path.join(args.out_dir, 'norm_weight_fp32.npy'), sd['norm.weight'].cpu().numpy())
    save_fp(os.path.join(args.out_dir, 'norm_bias_fp32.npy'), sd['norm.bias'].cpu().numpy())
    save_linear('head', sd['head.weight'].cpu().numpy(), sd['head.bias'].cpu().numpy())

    # Meta
    # timm VisionTransformer may not expose num_heads at top-level
    num_heads = int(model.blocks[0].attn.num_heads)
    meta = {
        'embed_dim': int(model.embed_dim),
        'num_heads': num_heads,
        'num_blocks': num_blocks,
        'mlp_ratio': float(getattr(model, 'mlp_ratio', 4)),
        'patch_size': getattr(model.patch_embed, 'patch_size', (16, 16)),
        'img_size': getattr(model.patch_embed, 'img_size', (224, 224)),
        'target_int8': args.target_int8,
    }
    np.save(os.path.join(args.out_dir, 'meta.npy'), meta, allow_pickle=True)

    print('[OK] Exported to', args.out_dir)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
