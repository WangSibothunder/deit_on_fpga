# DeiT on FPGA (PL/PS Co-Design)

This repository implements a DeiT inference accelerator on FPGA. The PL side provides a systolic-array-based matrix engine with input/weight/output buffers, while the PS side handles DMA, configuration, and post-processing. The RTL is documented in detail and aligned with module-level specifications.

## Highlights
- Systolic array compute core with explicit timing alignment (Input Skew / Output Deskew)
- Ping-pong buffering for input/weight to overlap load and compute
- PPU quantization (bias/scale/shift/zero-point) producing INT8 output
- AXI-Lite control plane and AXI-Stream data plane

## Architecture Overview
- Control: PS writes registers through AXI-Lite to configure the accelerator.
- Data: PS streams input/weight through AXI DMA into PL buffers.
- Compute: deit_core orchestrates loading, compute, and drain phases.
- Output: results are quantized and streamed back to DDR via AXI DMA.

## Repository Structure
- `src/rtl`: PL RTL modules
- `docs`: Module specs and project-level documentation
- `ps/python`: PS-side python utilities and inference scripts
- `ps/notebooks`: PYNQ notebooks for validation and profiling
- `src/tb`: Testbenches (if used)

## Documentation
- `docs/PL_RTL_Project_Spec.md`: Full project spec with dataflow and diagrams
- `docs/input_buffer_ctrl.md`: Input buffer spec (includes FSM diagram)
- `docs/weight_buffer_ctrl.md`: Weight buffer spec
- `docs/output_buffer_ctrl.md`: Output buffer spec (includes FSM diagram)
- Other module specs are in `docs/`

## Running (PS side)
Example entry point for PYNQ:
```bash
python ps/python/deit_infer_pynq_v2.py
```

## Notes
- This update focuses on documentation and specification completeness.
- Tests were not run as part of this documentation update.
