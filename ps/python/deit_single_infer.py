#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Single-image DeiT-Tiny inference.
- mode=torch: timm float32 baseline
- mode=pynq: numpy + quantization strategy matching PYNQ notebook
"""
import argparse
import os
import sys
import time

import numpy as np


# PYNQ quantization params (must match notebook)
ACT_RANGE = 3.0
ACT_TARGET = 64


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


def preprocess_image_to_chw(image_path, resize=256, crop=224):
    try:
        from PIL import Image
    except Exception as e:
        print('[FATAL] Pillow not available:', e)
        sys.exit(1)

    img = Image.open(image_path).convert('RGB')
    img = resize_shorter(img, resize)
    img = center_crop(img, crop)

    arr = np.asarray(img).astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    arr = (arr - mean) / std
    arr = np.transpose(arr, (2, 0, 1))  # HWC -> CHW
    return arr


def layernorm_ps(x, w, b, eps=1e-6):
    mean = x.mean(axis=-1, keepdims=True)
    var = x.var(axis=-1, keepdims=True)
    y = (x - mean) / np.sqrt(var + eps)
    return y * w + b


def gelu_ps(x):
    return 0.5 * x * (1.0 + np.tanh(np.sqrt(2.0 / np.pi) * (x + 0.044715 * (x ** 3))))


def softmax_ps(x):
    x = x - np.max(x, axis=-1, keepdims=True)
    e = np.exp(x)
    return e / np.sum(e, axis=-1, keepdims=True)


def quantize_act(x_fp32):
    scale = ACT_RANGE / float(ACT_TARGET)
    q = np.rint(x_fp32 / scale)
    q = np.clip(q, -127, 127).astype(np.int8)
    return q, scale


def dequantize_int8(x_int8, scale):
    return x_int8.astype(np.float32) * scale


def gemm_i8_sim(a_i8, b_i8, scale_a, scale_b, scale_out):
    # Simulate PL int8 GEMM + fixed-point scaling used by notebook
    acc = a_i8.astype(np.int32) @ b_i8.astype(np.int32)
    ratio = (scale_a * scale_b) / scale_out
    out_fp = acc.astype(np.float32) * ratio
    out_i8 = np.clip(np.rint(out_fp), -127, 127).astype(np.int8)
    return out_i8


def load_block_weights(weight_dir, i):
    idx = f'blk{i:02d}'
    w = {}
    w['ln1_w'] = np.load(os.path.join(weight_dir, f'{idx}_ln1_weight_fp32.npy'))
    w['ln1_b'] = np.load(os.path.join(weight_dir, f'{idx}_ln1_bias_fp32.npy'))
    w['ln2_w'] = np.load(os.path.join(weight_dir, f'{idx}_ln2_weight_fp32.npy'))
    w['ln2_b'] = np.load(os.path.join(weight_dir, f'{idx}_ln2_bias_fp32.npy'))

    w['qkv_w_i8'] = np.load(os.path.join(weight_dir, f'{idx}_qkv_weight_int8.npy'))
    w['qkv_w_scale'] = float(np.load(os.path.join(weight_dir, f'{idx}_qkv_weight_scale.npy')))
    w['qkv_b'] = np.load(os.path.join(weight_dir, f'{idx}_qkv_bias_fp32.npy'))

    w['proj_w_i8'] = np.load(os.path.join(weight_dir, f'{idx}_proj_weight_int8.npy'))
    w['proj_w_scale'] = float(np.load(os.path.join(weight_dir, f'{idx}_proj_weight_scale.npy')))
    w['proj_b'] = np.load(os.path.join(weight_dir, f'{idx}_proj_bias_fp32.npy'))

    w['mlp1_w_i8'] = np.load(os.path.join(weight_dir, f'{idx}_mlp1_weight_int8.npy'))
    w['mlp1_w_scale'] = float(np.load(os.path.join(weight_dir, f'{idx}_mlp1_weight_scale.npy')))
    w['mlp1_b'] = np.load(os.path.join(weight_dir, f'{idx}_mlp1_bias_fp32.npy'))

    w['mlp2_w_i8'] = np.load(os.path.join(weight_dir, f'{idx}_mlp2_weight_int8.npy'))
    w['mlp2_w_scale'] = float(np.load(os.path.join(weight_dir, f'{idx}_mlp2_weight_scale.npy')))
    w['mlp2_b'] = np.load(os.path.join(weight_dir, f'{idx}_mlp2_bias_fp32.npy'))
    return w


def run_infer_pynq_quant(args):
    print('=== DeiT-Tiny Single Image Inference (PYNQ-quant) ===')
    print('image =', args.image)
    print('image_npy =', args.image_npy)
    print('weight_dir =', args.weight_dir)

    if args.use_image_npy:
        img_chw = np.load(args.image_npy).astype(np.float32)
    else:
        img_chw = preprocess_image_to_chw(args.image)

    meta = np.load(os.path.join(args.weight_dir, 'meta.npy'), allow_pickle=True).item()
    D = int(meta['embed_dim'])
    H = int(meta['num_heads'])
    HEAD_DIM = D // H
    NUM_BLOCKS = int(meta['num_blocks'])

    patch_w = np.load(os.path.join(args.weight_dir, 'patch_embed_weight_fp32.npy'))
    patch_b = np.load(os.path.join(args.weight_dir, 'patch_embed_bias_fp32.npy'))
    cls_token = np.load(os.path.join(args.weight_dir, 'cls_token_fp32.npy'))
    pos_embed = np.load(os.path.join(args.weight_dir, 'pos_embed_fp32.npy'))

    norm_w = np.load(os.path.join(args.weight_dir, 'norm_weight_fp32.npy'))
    norm_b = np.load(os.path.join(args.weight_dir, 'norm_bias_fp32.npy'))
    head_w = np.load(os.path.join(args.weight_dir, 'head_weight_fp32.npy'))
    head_b = np.load(os.path.join(args.weight_dir, 'head_bias_fp32.npy'))

    print('[STEP] Patch embedding (numpy)')
    patch_w2 = patch_w.reshape(D, -1)  # [D, 3*16*16]

    img_C, img_H, img_W = img_chw.shape
    ps = 16
    nH = img_H // ps
    nW = img_W // ps
    patches = []
    for i in range(nH):
        for j in range(nW):
            patch = img_chw[:, i*ps:(i+1)*ps, j*ps:(j+1)*ps].reshape(-1)
            patches.append(patch)
    patches = np.stack(patches, axis=0)  # [num_patches, 3*16*16]
    tokens = patches @ patch_w2.T + patch_b  # [num_patches, D]

    cls = cls_token.reshape(1, D)
    tokens = np.concatenate([cls, tokens], axis=0)
    tokens = tokens + pos_embed.reshape(tokens.shape)
    print('[OK] tokens shape =', tokens.shape)

    print('[STEP] Inference start')
    x = tokens
    for i in range(min(NUM_BLOCKS, args.max_blocks)):
        t_block = time.time()
        print(f'[BLOCK {i:02d}] start')
        w = load_block_weights(args.weight_dir, i)

        # LN1
        t0 = time.time()
        x1 = layernorm_ps(x, w['ln1_w'], w['ln1_b'])
        print(f'  LN1 done, dt={time.time()-t0:.3f}s')

        # QKV (quant)
        t0 = time.time()
        a_q, scale_a = quantize_act(x1)
        qkv_i8 = gemm_i8_sim(a_q, w['qkv_w_i8'].T, scale_a, w['qkv_w_scale'], scale_a)
        qkv_fp = dequantize_int8(qkv_i8, scale_a) + w['qkv_b']
        print(f'  QKV GEMM done, dt={time.time()-t0:.3f}s')

        q = qkv_fp[:, :D]
        k = qkv_fp[:, D:2*D]
        v = qkv_fp[:, 2*D:]

        qh = q.reshape(-1, H, HEAD_DIM).transpose(1, 0, 2)
        kh = k.reshape(-1, H, HEAD_DIM).transpose(1, 0, 2)
        vh = v.reshape(-1, H, HEAD_DIM).transpose(1, 0, 2)

        attn_out = []
        for h in range(H):
            print(f'  [HEAD {h}] QK^T')
            qh_h = qh[h]
            kh_h = kh[h]
            vh_h = vh[h]

            q_i8, s_q = quantize_act(qh_h)
            k_i8, s_k = quantize_act(kh_h)
            score_i8 = gemm_i8_sim(q_i8, k_i8.T, s_q, s_k, s_q)
            score_fp = dequantize_int8(score_i8, s_q)
            score_fp = score_fp / np.sqrt(float(HEAD_DIM))
            score_sm = softmax_ps(score_fp)
            s_q_i8 = np.clip(np.rint(score_sm * 127.0), 0, 127).astype(np.int8)

            print(f'  [HEAD {h}] SV')
            v_i8, s_v = quantize_act(vh_h)
            sv_i8 = gemm_i8_sim(s_q_i8, v_i8, 1.0/127.0, s_v, s_v)
            sv_fp = dequantize_int8(sv_i8, s_v)
            attn_out.append(sv_fp)

        attn = np.concatenate(attn_out, axis=1)

        # Proj
        t0 = time.time()
        attn_i8, s_attn = quantize_act(attn)
        proj_i8 = gemm_i8_sim(attn_i8, w['proj_w_i8'].T, s_attn, w['proj_w_scale'], s_attn)
        proj_fp = dequantize_int8(proj_i8, s_attn) + w['proj_b']
        print(f'  Proj GEMM done, dt={time.time()-t0:.3f}s')

        x = x + proj_fp

        # LN2
        t0 = time.time()
        x2 = layernorm_ps(x, w['ln2_w'], w['ln2_b'])
        print(f'  LN2 done, dt={time.time()-t0:.3f}s')

        # MLP1
        t0 = time.time()
        x2_i8, s_x2 = quantize_act(x2)
        mlp1_i8 = gemm_i8_sim(x2_i8, w['mlp1_w_i8'].T, s_x2, w['mlp1_w_scale'], s_x2)
        mlp1_fp = dequantize_int8(mlp1_i8, s_x2) + w['mlp1_b']
        mlp1_fp = gelu_ps(mlp1_fp)
        print(f'  MLP1 GEMM+GELU done, dt={time.time()-t0:.3f}s')

        # MLP2
        t0 = time.time()
        mlp1_i8b, s_m1 = quantize_act(mlp1_fp)
        mlp2_i8 = gemm_i8_sim(mlp1_i8b, w['mlp2_w_i8'].T, s_m1, w['mlp2_w_scale'], s_m1)
        mlp2_fp = dequantize_int8(mlp2_i8, s_m1) + w['mlp2_b']
        print(f'  MLP2 GEMM done, dt={time.time()-t0:.3f}s')

        x = x + mlp2_fp

        print(f'[BLOCK {i:02d}] done, dt={time.time()-t_block:.3f}s')

    print('[STEP] Final norm + head')
    x = layernorm_ps(x, norm_w, norm_b)
    logits = x[0] @ head_w.T + head_b
    probs = np.exp(logits - np.max(logits))
    probs = probs / np.sum(probs)
    top5 = np.argsort(-probs)[:5]
    print('[RESULT] Top-5 indices:', top5.tolist())
    print('[RESULT] Top-5 probs:', probs[top5].tolist())

    if args.dump_tokens:
        print('[STEP] Dump tokens to .npy')
        out_path = os.path.join(args.out_dir, 'tokens_after_norm.npy')
        os.makedirs(args.out_dir, exist_ok=True)
        np.save(out_path, x)
        print('[OK] Saved', out_path)

    print('=== DONE ===')


def run_infer_torch(args):
    try:
        import torch
        import timm
        from PIL import Image
        from timm.data import resolve_data_config
        from timm.data.transforms_factory import create_transform
    except Exception as e:
        print('[FATAL] Missing dependency:', e)
        print('Please install: torch, timm, pillow')
        sys.exit(1)

    print('=== DeiT-Tiny Single Image Inference (torch) ===')
    print('image =', args.image)
    print('weights =', args.weights)
    print('device =', args.device)

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
    model.to(args.device)
    print('[OK] Model loaded')

    print('[STEP] Preprocess image')
    img = Image.open(args.image).convert('RGB')
    cfg = resolve_data_config({}, model=model)
    transform = create_transform(**cfg)
    x = transform(img).unsqueeze(0).to(args.device)
    print('[OK] Input tensor shape =', tuple(x.shape))

    with torch.no_grad():
        print('[STEP] Patch embedding')
        x = model.patch_embed(x)
        print('  patch_embed out =', tuple(x.shape))

        print('[STEP] Add cls token + pos embed')
        cls_token = model.cls_token.expand(x.shape[0], -1, -1)
        x = torch.cat((cls_token, x), dim=1)
        x = x + model.pos_embed
        x = model.pos_drop(x)
        print('  tokens =', tuple(x.shape))

        for i, blk in enumerate(model.blocks):
            t0 = time.time()
            print(f'[BLOCK {i:02d}] start')
            x = blk(x)
            print(f'[BLOCK {i:02d}] done, shape={tuple(x.shape)}, dt={time.time()-t0:.3f}s')

        print('[STEP] Final norm + head')
        x = model.norm(x)
        logits = model.head(x[:, 0])
        print('  logits =', tuple(logits.shape))

        probs = torch.softmax(logits, dim=-1)
        top5 = torch.topk(probs, k=5, dim=-1)
        print('[RESULT] Top-5 indices:', top5.indices.cpu().numpy().tolist())
        print('[RESULT] Top-5 probs:', top5.values.cpu().numpy().tolist())

        if args.dump_tokens:
            print('[STEP] Dump tokens to .npy')
            tokens = x.cpu().numpy()
            out_path = os.path.join(args.out_dir, 'tokens_after_norm.npy')
            np.save(out_path, tokens)
            print('[OK] Saved', out_path)

    print('=== DONE ===')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', type=str, default='pynq', choices=['pynq', 'torch'])
    ap.add_argument('--image', type=str, default='ps/deit/Puppy-Cover.jpg')
    ap.add_argument('--image_npy', type=str, default='ps/deit/image_fp32.npy')
    ap.add_argument('--use_image_npy', action='store_true')
    ap.add_argument('--weight_dir', type=str, default='ps/deit/weights_npy')
    ap.add_argument('--weights', type=str, default='ps/deit/deit_tiny_patch16_224_10.pth')
    ap.add_argument('--device', type=str, default='cpu')
    ap.add_argument('--out_dir', type=str, default='ps/deit/exports')
    ap.add_argument('--dump_tokens', action='store_true')
    ap.add_argument('--max_blocks', type=int, default=12)
    args = ap.parse_args()

    if args.mode == 'torch':
        run_infer_torch(args)
    else:
        run_infer_pynq_quant(args)


if __name__ == '__main__':
    main()
