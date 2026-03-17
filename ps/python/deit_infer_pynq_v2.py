#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DeiT PYNQ Inference v2
- PS ???? + ?????? PL ???????? tile ???/??
- ??? deit_accelerator_top + axi_dma_0 ?????
"""
import argparse
import os
import sys
import time

import numpy as np

try:
    import pynq
except Exception as e:
    print('[FATAL] PYNQ not available:', e)
    sys.exit(1)

# -----------------------------------------------------------------------------
# ????
# -----------------------------------------------------------------------------
ARRAY_ROW = 12
ARRAY_COL = 16
ACT_RANGE = 3.0
ACT_TARGET = 64

# AXI-Lite register map (axi_lite_control.v)
REG_CTRL      = 0x00
REG_STATUS    = 0x04
REG_CFG_SEQ   = 0x08
REG_CFG_ACC   = 0x0C
REG_VERSION   = 0x10
REG_PPU_MULT  = 0x14
REG_PPU_SHIFT = 0x18
REG_PPU_ZP    = 0x1C
REG_PPU_BIAS  = 0x20
REG_OUT_EN    = 0x24
REG_DBG_SNAP  = 0x28
REG_DBG0      = 0x30


# -----------------------------------------------------------------------------
# ????
# -----------------------------------------------------------------------------

def ceil_to(x, base):
    return ((x + base - 1) // base) * base


def calc_pad(m, k, n):
    m_pad = m if (m % 2 == 0) else (m + 1)
    k_pad = ceil_to(k, ARRAY_ROW)
    n_pad = ceil_to(n, ARRAY_COL)
    return m_pad, k_pad, n_pad


def to_u8(x):
    return int(x) & 0xFF


def u8_to_i8(arr_u8):
    arr_u8 = np.array(arr_u8, dtype=np.uint8)
    return np.where(arr_u8 < 128, arr_u8, arr_u8 - 256).astype(np.int8)


def pack_input_tile(a_tile):
    bytes_list = []
    for r in range(a_tile.shape[0]):
        for c in range(ARRAY_ROW):
            bytes_list.append(to_u8(a_tile[r, c]))
    words = []
    for i in range(0, len(bytes_list), 8):
        w = 0
        for b_i in range(8):
            w |= (bytes_list[i + b_i] << (8 * b_i))
        words.append(np.uint64(w))
    return np.array(words, dtype=np.uint64)


def pack_weight_tile(b_tile):
    words = []
    for r in range(ARRAY_ROW):
        val128 = 0
        for c in range(ARRAY_COL):
            val = to_u8(b_tile[r, c])
            val128 |= (val << (8 * c))
        low = val128 & 0xFFFFFFFFFFFFFFFF
        high = (val128 >> 64) & 0xFFFFFFFFFFFFFFFF
        words.append(np.uint64(low))
        words.append(np.uint64(high))
    return np.array(words, dtype=np.uint64)


def unpack_output_tile(words, m_pad):
    out = np.zeros((m_pad, ARRAY_COL), dtype=np.int8)
    for r in range(m_pad):
        low = int(words[2 * r])
        high = int(words[2 * r + 1])
        val128 = low | (high << 64)
        bytes_row = [(val128 >> (8 * c)) & 0xFF for c in range(ARRAY_COL)]
        out[r, :] = u8_to_i8(bytes_row)
    return out


def compute_ppu_params(ratio):
    if ratio <= 0:
        return 0, 0
    best = (1, 0, 1.0)
    for shift in range(0, 32):
        mult = int(round(ratio * (1 << shift)))
        if mult <= 0 or mult > 32767:
            continue
        err = abs(ratio - (mult / float(1 << shift)))
        if err < best[2]:
            best = (mult, shift, err)
    return best[0], best[1]


def quantize_act(x_fp32):
    scale = ACT_RANGE / float(ACT_TARGET)
    q = np.rint(x_fp32 / scale)
    q = np.clip(q, -127, 127).astype(np.int8)
    return q, scale


def dequantize_int8(x_int8, scale):
    return x_int8.astype(np.float32) * scale


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


# -----------------------------------------------------------------------------
# ????
# -----------------------------------------------------------------------------

def axi_write(axi_ctrl, addr, val):
    axi_ctrl.write(addr, int(val))


def axi_read(axi_ctrl, addr):
    return axi_ctrl.read(addr)


def soft_reset(axi_ctrl):
    axi_write(axi_ctrl, REG_CTRL, 0x00)
    time.sleep(0.01)
    axi_write(axi_ctrl, REG_CTRL, 0x02)
    time.sleep(0.01)


def start_pulse(axi_ctrl):
    axi_write(axi_ctrl, REG_CTRL, 0x03)
    axi_write(axi_ctrl, REG_CTRL, 0x02)


def dbg_snap(axi_ctrl):
    axi_write(axi_ctrl, REG_DBG_SNAP, 1)


def dbg_read_dma_req(axi_ctrl):
    dbg_snap(axi_ctrl)
    d0 = axi_read(axi_ctrl, REG_DBG0)
    return (d0 >> 3) & 0x1


def dma_status(ch):
    return ch._mmio.read(0x04)


def wait_dma_idle(ch, timeout=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        sr = dma_status(ch)
        if sr & 0x2:
            return True, sr
        time.sleep(0.001)
    return False, dma_status(ch)


# -----------------------------------------------------------------------------
# PL GEMM (v2: ??? + ????)
# -----------------------------------------------------------------------------

def run_gemm_pl_v2(a_int8, b_int8, scale_a, scale_b, scale_out, axi_ctrl, dma, timeout=3.0):
    m, k = a_int8.shape
    k2, n = b_int8.shape
    assert k2 == k

    m_pad, k_pad, n_pad = calc_pad(m, k, n)
    k_tiles = k_pad // ARRAY_ROW
    n_tiles = n_pad // ARRAY_COL

    a_pad = np.zeros((m_pad, k_pad), dtype=np.int8)
    b_pad = np.zeros((k_pad, n_pad), dtype=np.int8)
    a_pad[:m, :k] = a_int8
    b_pad[:k, :n] = b_int8

    ratio = (scale_a * scale_b) / scale_out
    mult, shift = compute_ppu_params(ratio)

    soft_reset(axi_ctrl)
    axi_write(axi_ctrl, REG_CFG_SEQ, m_pad)
    axi_write(axi_ctrl, REG_CFG_ACC, 0)
    axi_write(axi_ctrl, REG_PPU_MULT, mult)
    axi_write(axi_ctrl, REG_PPU_SHIFT, shift)
    axi_write(axi_ctrl, REG_PPU_ZP, 0)
    axi_write(axi_ctrl, REG_PPU_BIAS, 0)
    axi_write(axi_ctrl, REG_OUT_EN, 0)

    c_hw = np.zeros((m_pad, n_pad), dtype=np.int8)

    in_words_len = (m_pad * ARRAY_ROW) // 8
    w_words_len = ARRAY_ROW * 2
    out_words_len = m_pad * 2

    # ??? (ping-pong)
    buf_A = [pynq.allocate(shape=(in_words_len,), dtype=np.uint64),
             pynq.allocate(shape=(in_words_len,), dtype=np.uint64)]
    buf_B = [pynq.allocate(shape=(w_words_len,), dtype=np.uint64),
             pynq.allocate(shape=(w_words_len,), dtype=np.uint64)]
    buf_C = [pynq.allocate(shape=(out_words_len,), dtype=np.uint64),
             pynq.allocate(shape=(out_words_len,), dtype=np.uint64)]

    def prep_tile_to_buf(n_idx, k_idx, buf_idx):
        a_tile = a_pad[:, k_idx * ARRAY_ROW:(k_idx + 1) * ARRAY_ROW]
        b_tile = b_pad[k_idx * ARRAY_ROW:(k_idx + 1) * ARRAY_ROW,
                       n_idx * ARRAY_COL:(n_idx + 1) * ARRAY_COL]
        in_words = pack_input_tile(a_tile)
        w_words = pack_weight_tile(b_tile)
        buf_A[buf_idx][:] = in_words
        buf_B[buf_idx][:] = w_words
        buf_A[buf_idx].flush()
        buf_B[buf_idx].flush()

    try:
        # ?? tile ??
        tiles = [(n_idx, k_idx) for n_idx in range(n_tiles) for k_idx in range(k_tiles)]
        if len(tiles) == 0:
            return c_hw[:m, :n]

        # ?????? tile
        prep_tile_to_buf(tiles[0][0], tiles[0][1], buf_idx=0)

        for t_idx, (n_idx, k_idx) in enumerate(tiles):
            buf_idx = t_idx % 2
            next_idx = (t_idx + 1) % 2
            acc_mode = 0 if (k_idx == 0) else 1
            out_en = 1 if (k_idx == k_tiles - 1) else 0

            axi_write(axi_ctrl, REG_CFG_ACC, acc_mode)
            axi_write(axi_ctrl, REG_OUT_EN, out_en)

            # 1) ???? (A)
            dma.sendchannel.transfer(buf_A[buf_idx])
            ok_mm2s, _ = wait_dma_idle(dma.sendchannel, timeout=timeout)
            if not ok_mm2s:
                raise RuntimeError('MM2S not idle after A preload')

            # 2) ????????? S2MM
            if out_en:
                dma.recvchannel.transfer(buf_C[buf_idx])

            # 3) ?? PL
            start_pulse(axi_ctrl)

            # 4) ?? DMA_REQ ????? (B)
            t0 = time.time()
            while time.time() - t0 < timeout:
                if dbg_read_dma_req(axi_ctrl) == 1:
                    break
                time.sleep(0.0005)
            else:
                raise RuntimeError('DMA_REQ timeout')

            dma.sendchannel.transfer(buf_B[buf_idx])
            ok_mm2s2, _ = wait_dma_idle(dma.sendchannel, timeout=timeout)
            if not ok_mm2s2:
                raise RuntimeError('MM2S not idle after weight')

            # 5) ? PL ???????? tile???/????
            if t_idx + 1 < len(tiles):
                n2, k2 = tiles[t_idx + 1]
                prep_tile_to_buf(n2, k2, buf_idx=next_idx)

            # 6) ?? AP_DONE
            t0 = time.time()
            done = False
            while time.time() - t0 < timeout:
                if (axi_read(axi_ctrl, REG_STATUS) & 0x1) != 0:
                    done = True
                    axi_write(axi_ctrl, REG_STATUS, 0x1)  # W1C
                    break
                time.sleep(0.0005)
            if not done:
                raise RuntimeError('AP_DONE timeout')

            # 7) ??????? S2MM ???
            if out_en:
                ok_s2mm, _ = wait_dma_idle(dma.recvchannel, timeout=timeout)
                if not ok_s2mm:
                    raise RuntimeError('S2MM timeout')
                buf_C[buf_idx].invalidate()
                out_tile = unpack_output_tile(np.array(buf_C[buf_idx]), m_pad)
                c_hw[:, n_idx * ARRAY_COL:(n_idx + 1) * ARRAY_COL] = out_tile

    finally:
        for b in buf_A + buf_B + buf_C:
            b.close()

    return c_hw[:m, :n]


# -----------------------------------------------------------------------------
# ???????
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# ?????
# -----------------------------------------------------------------------------

def run_infer_pynq_quant_v2(args):
    print('=== DeiT-Tiny Inference (PYNQ v2) ===')
    print('bit =', args.bit)
    print('weight_dir =', args.weight_dir)
    print('image =', args.image)
    print('image_npy =', args.image_npy)

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

    # Load overlay
    overlay = pynq.Overlay(args.bit)
    axi_ctrl = getattr(overlay, args.ip)
    dma = getattr(overlay, args.dma)
    print('[INFO] Overlay loaded')
    print('VERSION = 0x%08x' % axi_read(axi_ctrl, REG_VERSION))

    # Patch embedding (CPU)
    patch_w2 = patch_w.reshape(D, -1)
    img_C, img_H, img_W = img_chw.shape
    ps = 16
    nH = img_H // ps
    nW = img_W // ps
    patches = []
    for i in range(nH):
        for j in range(nW):
            patch = img_chw[:, i * ps:(i + 1) * ps, j * ps:(j + 1) * ps].reshape(-1)
            patches.append(patch)
    patches = np.stack(patches, axis=0)
    tokens = patches @ patch_w2.T + patch_b

    cls = cls_token.reshape(1, D)
    tokens = np.concatenate([cls, tokens], axis=0)
    tokens = tokens + pos_embed.reshape(tokens.shape)
    print('[OK] tokens shape =', tokens.shape)

    # Transformer blocks
    x = tokens
    for i in range(min(NUM_BLOCKS, args.max_blocks)):
        t_block = time.time()
        print(f'[BLOCK {i:02d}] start')
        w = load_block_weights(args.weight_dir, i)

        # LN1
        t0 = time.time()
        x1 = layernorm_ps(x, w['ln1_w'], w['ln1_b'])
        print(f'  LN1 done, dt={time.time()-t0:.3f}s')

        # QKV (PL)
        t0 = time.time()
        a_q, scale_a = quantize_act(x1)
        qkv_i8 = run_gemm_pl_v2(a_q, w['qkv_w_i8'].T, scale_a, w['qkv_w_scale'], scale_a,
                                axi_ctrl, dma, timeout=args.timeout)
        qkv_fp = dequantize_int8(qkv_i8, scale_a) + w['qkv_b']
        print(f'  QKV GEMM done, dt={time.time()-t0:.3f}s')

        q = qkv_fp[:, :D]
        k = qkv_fp[:, D:2 * D]
        v = qkv_fp[:, 2 * D:]

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
            score_i8 = run_gemm_pl_v2(q_i8, k_i8.T, s_q, s_k, s_q,
                                      axi_ctrl, dma, timeout=args.timeout)
            score_fp = dequantize_int8(score_i8, s_q)
            score_fp = score_fp / np.sqrt(float(HEAD_DIM))
            score_sm = softmax_ps(score_fp)
            s_q_i8 = np.clip(np.rint(score_sm * 127.0), 0, 127).astype(np.int8)

            print(f'  [HEAD {h}] SV')
            v_i8, s_v = quantize_act(vh_h)
            sv_i8 = run_gemm_pl_v2(s_q_i8, v_i8, 1.0 / 127.0, s_v, s_v,
                                   axi_ctrl, dma, timeout=args.timeout)
            sv_fp = dequantize_int8(sv_i8, s_v)
            attn_out.append(sv_fp)

        attn = np.concatenate(attn_out, axis=1)

        # Proj (PL)
        t0 = time.time()
        attn_i8, s_attn = quantize_act(attn)
        proj_i8 = run_gemm_pl_v2(attn_i8, w['proj_w_i8'].T, s_attn, w['proj_w_scale'], s_attn,
                                 axi_ctrl, dma, timeout=args.timeout)
        proj_fp = dequantize_int8(proj_i8, s_attn) + w['proj_b']
        print(f'  Proj GEMM done, dt={time.time()-t0:.3f}s')

        x = x + proj_fp

        # LN2
        t0 = time.time()
        x2 = layernorm_ps(x, w['ln2_w'], w['ln2_b'])
        print(f'  LN2 done, dt={time.time()-t0:.3f}s')

        # MLP1 (PL)
        t0 = time.time()
        x2_i8, s_x2 = quantize_act(x2)
        mlp1_i8 = run_gemm_pl_v2(x2_i8, w['mlp1_w_i8'].T, s_x2, w['mlp1_w_scale'], s_x2,
                                 axi_ctrl, dma, timeout=args.timeout)
        mlp1_fp = dequantize_int8(mlp1_i8, s_x2) + w['mlp1_b']
        mlp1_fp = gelu_ps(mlp1_fp)
        print(f'  MLP1 GEMM+GELU done, dt={time.time()-t0:.3f}s')

        # MLP2 (PL)
        t0 = time.time()
        mlp1_i8b, s_m1 = quantize_act(mlp1_fp)
        mlp2_i8 = run_gemm_pl_v2(mlp1_i8b, w['mlp2_w_i8'].T, s_m1, w['mlp2_w_scale'], s_m1,
                                 axi_ctrl, dma, timeout=args.timeout)
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

    print('=== DONE ===')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bit', type=str, default='ps/deit/deit_accel.bit')
    ap.add_argument('--ip', type=str, default='deit_accelerator_top_0')
    ap.add_argument('--dma', type=str, default='axi_dma_0')
    ap.add_argument('--weight_dir', type=str, default='ps/deit/weights_npy')
    ap.add_argument('--image', type=str, default='ps/deit/Puppy-Cover.jpg')
    ap.add_argument('--image_npy', type=str, default='ps/deit/image_fp32.npy')
    ap.add_argument('--use_image_npy', action='store_true')
    ap.add_argument('--timeout', type=float, default=3.0)
    ap.add_argument('--max_blocks', type=int, default=12)
    args = ap.parse_args()

    run_infer_pynq_quant_v2(args)


if __name__ == '__main__':
    main()
