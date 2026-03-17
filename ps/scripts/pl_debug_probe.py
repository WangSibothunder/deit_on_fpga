#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PL 侧接口排查脚本（PYNQ 运行）
仅使用已有 AXI-Lite + AXI DMA 接口进行诊断与最小验证。
"""
import argparse
import time
import numpy as np
import pynq


# AXI-Lite register map (from axi_lite_control.v)
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


def calc_pad(x, align):
    return ((x + align - 1) // align) * align


def dma_status(ch):
    # 0x04 is SR for both MM2S and S2MM in Xilinx AXI DMA
    return ch._mmio.read(0x04)


def wait_dma_idle(ch, timeout_s=2.0, name="DMA"):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        sr = dma_status(ch)
        if sr & 0x2:  # Idle bit
            return True, sr
        time.sleep(0.001)
    return False, dma_status(ch)


def dump_regs(axi_ctrl):
    regs = {
        "CTRL": axi_ctrl.read(REG_CTRL),
        "STATUS": axi_ctrl.read(REG_STATUS),
        "CFG_SEQ": axi_ctrl.read(REG_CFG_SEQ),
        "CFG_ACC": axi_ctrl.read(REG_CFG_ACC),
        "VERSION": axi_ctrl.read(REG_VERSION),
        "PPU_MULT": axi_ctrl.read(REG_PPU_MULT),
        "PPU_SHIFT": axi_ctrl.read(REG_PPU_SHIFT),
        "PPU_ZP": axi_ctrl.read(REG_PPU_ZP),
        "PPU_BIAS": axi_ctrl.read(REG_PPU_BIAS),
        "OUT_EN": axi_ctrl.read(REG_OUT_EN),
    }
    print("=== AXI-Lite Register Dump ===")
    for k, v in regs.items():
        print(f"{k:>8} = 0x{v:08x}")
    return regs


def soft_reset(axi_ctrl):
    # reg_ctrl[1] = soft_rst_n (level), reg_ctrl[0] = ap_start pulse
    axi_ctrl.write(REG_CTRL, 0x00)
    time.sleep(0.01)
    axi_ctrl.write(REG_CTRL, 0x02)
    time.sleep(0.01)


def start_pulse(axi_ctrl):
    # Keep soft_rst_n=1, pulse ap_start
    axi_ctrl.write(REG_CTRL, 0x03)
    axi_ctrl.write(REG_CTRL, 0x02)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", default="./deit/deit_accel.bit")
    ap.add_argument("--ip", default="deit_accelerator_top_0")
    ap.add_argument("--dma", default="axi_dma_0")
    ap.add_argument("--m", type=int, default=2)
    ap.add_argument("--k", type=int, default=12)
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--stream_order", choices=["A_then_B", "B_then_A"], default="B_then_A")
    ap.add_argument("--input_delay_ms", type=int, default=5)
    args = ap.parse_args()

    print("=== PL Debug Probe (PYNQ) ===")
    print(f"[INFO] bit = {args.bit}")
    print(f"[INFO] ip  = {args.ip}")
    print(f"[INFO] dma = {args.dma}")

    np.random.seed(args.seed)

    overlay = pynq.Overlay(args.bit)
    axi_ctrl = getattr(overlay, args.ip)
    dma = getattr(overlay, args.dma)

    # Pad dimensions
    m_pad = args.m if args.m % 2 == 0 else args.m + 1
    k_pad = calc_pad(args.k, 12)
    n_pad = calc_pad(args.n, 16)

    print(f"[INFO] M={args.m} K={args.k} N={args.n}")
    print(f"[INFO] M_PAD={m_pad} K_PAD={k_pad} N_PAD={n_pad}")

    # Prepare buffers
    buf_A = pynq.allocate(shape=(m_pad * k_pad,), dtype=np.int8)
    buf_B = pynq.allocate(shape=(k_pad * n_pad,), dtype=np.int8)
    buf_C = pynq.allocate(shape=(m_pad * n_pad,), dtype=np.int8)

    # Simple deterministic pattern for debug
    A_sw = (np.ones((m_pad, k_pad), dtype=np.int8) * 1)
    B_sw = (np.ones((k_pad, n_pad), dtype=np.int8) * 2)

    np.copyto(buf_A, A_sw.flatten())
    np.copyto(buf_B, B_sw.flatten())
    buf_A.flush()
    buf_B.flush()

    # Configure registers
    soft_reset(axi_ctrl)
    axi_ctrl.write(REG_CFG_SEQ, m_pad - 1)
    axi_ctrl.write(REG_CFG_ACC, 0)
    axi_ctrl.write(REG_PPU_MULT, 1)
    axi_ctrl.write(REG_PPU_SHIFT, 0)
    axi_ctrl.write(REG_PPU_ZP, 0)
    axi_ctrl.write(REG_PPU_BIAS, 0)
    axi_ctrl.write(REG_OUT_EN, 1)

    dump_regs(axi_ctrl)

    # DMA status before
    print("=== DMA Status (Before) ===")
    print(f"MM2S SR = 0x{dma_status(dma.sendchannel):08x}")
    print(f"S2MM SR = 0x{dma_status(dma.recvchannel):08x}")

    # Issue RX first (wait TLAST)
    dma.recvchannel.transfer(buf_C)

    # Start core first to align bank-swap, then stream in order
    start_pulse(axi_ctrl)

    if args.stream_order == "B_then_A":
        # Send B (weights) first during weight-load window
        dma.sendchannel.transfer(buf_B)
        ok_mm2s, sr_mm2s = wait_dma_idle(dma.sendchannel, args.timeout, "MM2S-B")
        print(f"[INFO] MM2S-B idle={ok_mm2s}, SR=0x{sr_mm2s:08x}")

        # Small delay, then send A (inputs)
        if args.input_delay_ms > 0:
            time.sleep(args.input_delay_ms / 1000.0)

        dma.sendchannel.transfer(buf_A)
        ok_mm2s_2, sr_mm2s_2 = wait_dma_idle(dma.sendchannel, args.timeout, "MM2S-A")
        print(f"[INFO] MM2S-A idle={ok_mm2s_2}, SR=0x{sr_mm2s_2:08x}")
    else:
        # Legacy order: A then B
        dma.sendchannel.transfer(buf_A)
        ok_mm2s, sr_mm2s = wait_dma_idle(dma.sendchannel, args.timeout, "MM2S-A")
        print(f"[INFO] MM2S-A idle={ok_mm2s}, SR=0x{sr_mm2s:08x}")

        dma.sendchannel.transfer(buf_B)
        ok_mm2s_2, sr_mm2s_2 = wait_dma_idle(dma.sendchannel, args.timeout, "MM2S-B")
        print(f"[INFO] MM2S-B idle={ok_mm2s_2}, SR=0x{sr_mm2s_2:08x}")

    # Poll AP_DONE
    t0 = time.time()
    done = False
    while time.time() - t0 < args.timeout:
        if (axi_ctrl.read(REG_STATUS) & 0x1) != 0:
            done = True
            # W1C
            axi_ctrl.write(REG_STATUS, 0x1)
            break
        time.sleep(0.001)
    print(f"[INFO] AP_DONE={done}, STATUS=0x{axi_ctrl.read(REG_STATUS):08x}")

    # Wait RX done (TLAST)
    ok_s2mm, sr_s2mm = wait_dma_idle(dma.recvchannel, args.timeout, "S2MM")
    print(f"[INFO] S2MM idle={ok_s2mm}, SR=0x{sr_s2mm:08x}")

    # Read back
    buf_C.invalidate()
    C_hw = np.array(buf_C).reshape((m_pad, n_pad))

    # Golden (int32 matmul then clip to int8 range)
    C_golden = (A_sw.astype(np.int32) @ B_sw.astype(np.int32))
    C_golden = np.clip(C_golden, -128, 127).astype(np.int8)

    print("=== Validation (Row0) ===")
    print("Golden:", C_golden[0])
    print("HW    :", C_hw[0])

    if ok_s2mm and np.array_equal(C_hw, C_golden):
        print("[PASS] DMA+TLAST+数值正确")
    elif np.array_equal(C_hw, C_golden):
        print("[WARN] 数值正确但 DMA 未正常完成（可能 TLAST/长度问题）")
    else:
        print("[FAIL] 数值错误或流控失败")

    buf_A.close()
    buf_B.close()
    buf_C.close()


if __name__ == "__main__":
    main()
