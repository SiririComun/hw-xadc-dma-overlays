# HW XADC DMA Overlays

[![Hog Managed](https://img.shields.io/badge/HDL_Management-Hog-blue.svg)](https://cern.ch/hog)
[![Target Board](https://img.shields.io/badge/Board-PYNQ--Z2-orange.svg)](https://tul.com.tw/ProductsPYNQ-Z2.html)
[![Vivado Version](https://img.shields.io/badge/Vivado-2024.2.2-green.svg)](https://www.xilinx.com)
[![Hardware Release](https://img.shields.io/badge/Release-v1.2.0-blue.svg)](https://github.com/SiririComun/hw-xadc-dma-overlays/releases/tag/v1.2.0)

A high-performance hardware overlay for the **PYNQ-Z2** (Zynq-7000 `xc7z020clg400-1`) that captures analog signals using the XADC and streams them directly into DDR memory using AXI DMA with **sub-microsecond hardware edge triggering** and **real-time FPGA-accelerated 2048-point FFT & CORDIC magnitude extraction**.

Managed using **Hog (HDL on Git)** for strict design traceability and automated versioning.

---

## 🏛 Hardware Architecture & Memory Map

The design captures data from external analog channels (`Vaux1` / `Vp_Vn`), gates and synchronizes frames with `axis_trigger_unit` and `tlast_generator`, forks the stream via `axis_broadcaster`, computes the real-time Fourier transform via `xfft` and `cordic`, and transfers both Time-Domain and Frequency-Domain frames concurrently to DDR memory via dual AXI DMA engines.

### Block Design Schematic
![PYNQ-Z2 XADC FFT Dual-DMA Block Design](docs/images/xadc_bd.svg)

### Dataflow Diagram
```
                                          [ XADC Wizard (1 MSPS) ]
                                                     │ (AXIS)
                                           [ axis_trigger_unit ]
                                                     │ (AXIS Trigger-Gated)
                                            [ tlast_generator ] (2048 pts/frame)
                                                     │ (w/ TLAST)
                                           [ axis_broadcaster ]
                                    ┌────────────────┴────────────────┐
                           (Time Stream w/ TLAST)            (Signed 32-bit Stream w/ TLAST)
                                    │                                 ▼
                                    │                    [ xfft Core (2048-pt BFP) ]
                                    │                                 │ (Complex Re + j*Im)
                                    │                                 ▼
                                    │                    [ CORDIC IP (Translate Mode) ]
                                    │                                 │ (16-bit Magnitude)
                                    ▼                                 ▼
                          [ AXI DMA 0 (Time) ]              [ AXI DMA 1 (FFT Mag) ]
                             (0x40400000)                      (0x40410000)
                                    │                                 │
                                    └────────────────┬────────────────┘
                                                     ▼ (AXI SmartConnect HP0)
                                          [ Processing System DDR ]
```

### AXI Memory Address Table
Downstream PYNQ software drivers interface with the peripherals using the following base addresses:

| Peripheral Block | Interface | Base Address | Address Range | Description |
| :--- | :--- | :--- | :--- | :--- |
| **AXI DMA Time** (`axi_dma_0`) | `S_AXI_LITE` | `0x40400000` | 64K | Time-Domain DMA Controller (2,048 samples) |
| **AXI DMA FFT** (`axi_dma_1`) | `S_AXI_LITE` | `0x40410000` | 64K | Frequency-Domain Magnitude DMA Controller (1,024 bins) |
| **AXI Timer** (`axi_timer_0`) | `S_AXI` | `0x42800000` | 64K | System Timer / Timestamping / Triggering |
| **XADC Wizard** (`xadc_wiz_0`) | `s_axi_lite` | `0x43C00000` | 64K | XADC Register Configuration & Monitoring |
| **AXIS Trigger Unit** (`axis_trigger_unit_0`) | `s_axi` | `0x43C10000` | 64K | Hardware Edge/Level Trigger Control & Status |

### Hardware Parameters
* **Clock Frequency:** `100 MHz` (`FCLK_CLK0`)
* **Sampling Rate:** `1 MSPS` (1,000,000 samples per second)
* **Frame / Packet Size:** `2,048` samples per TLAST frame
* **FFT Engine:** 2048-point Xilinx LogiCORE FFT v9.1 in Pipelined Streaming I/O with Block Floating Point scaling
* **Frequency Resolution:** $\Delta f = \frac{1\,\text{MSPS}}{2048} \approx 488.28\,\text{Hz}$ per bin (1024 unique single-sided bins from $0\,\text{Hz}$ to $500\,\text{kHz}$)
* **Magnitude Engine:** CORDIC v6.0 in Translate mode with TLAST propagation
* **Trigger Capabilities:** Rising/Falling edge detection, 12-bit voltage comparator, Auto-timeout counter (50 ms default), Single-shot auto-disarm

---

## 📦 For Software Developers (Consuming this Overlay)

Specify the `v1.2.0` dependency in your `hardware.json`:

```json
{
  "repo": "SiririComun/hw-xadc-dma-overlays",
  "version": "v1.2.0",
  "overlay_name": "pynq_z2"
}
```

```python
from pynq_oscilloscope import OscilloscopeOverlay

ol = OscilloscopeOverlay()
app = ol.dashboard()
```

---

## 🛠 For Firmware Developers (Building Locally)

```bash
git clone --recursive https://github.com/SiririComun/hw-xadc-dma-overlays.git
cd hw-xadc-dma-overlays
./Hog/Do CREATE pynq_z2
./Hog/Do WORK pynq_z2
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.