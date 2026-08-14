# HW XADC DMA Overlays

[![Hog Managed](https://img.shields.io/badge/HDL_Management-Hog-blue.svg)](https://cern.ch/hog)
[![Target Board](https://img.shields.io/badge/Board-PYNQ--Z2-orange.svg)](https://tul.com.tw/ProductsPYNQ-Z2.html)
[![Vivado Version](https://img.shields.io/badge/Vivado-2024.2.2-green.svg)](https://www.xilinx.com)

A high-performance hardware overlay for the **PYNQ-Z2** (Zynq-7000 `xc7z020clg400-1`) that captures analog signals using the XADC and streams them directly into processing system DDR memory using AXI Direct Memory Access (DMA) with **sub-microsecond hardware edge triggering**.

Managed using **Hog (HDL on Git)** for strict design traceability and automated versioning.

---

## 🏛 Hardware Architecture & Memory Map

The design captures data from external analog channels (`Vaux1` / `Vp_Vn`), passes it through the custom `axis_trigger_unit` IP for hardware edge and threshold detection, packetizes it via `tlast_generator`, and transfers frames to DDR memory via AXI DMA.

```
 [Analog Inputs] ──> [ XADC Wizard ] ──(AXIS)──> [ axis_trigger_unit ] ──(AXIS)──> [ TLAST Generator ]
                                                   (Edge & Threshold)                      │ (w/ TLAST)
                                                                                           ▼
 [ Processing System DDR ] <──────────(AXI HP0)────────── [ AXI DMA (S2MM) ] <────────────┘
```

### AXI Memory Address Table
Downstream PYNQ software drivers interface with the peripherals using the following base addresses:

| Peripheral Block | Interface | Base Address | Address Range | Description |
| :--- | :--- | :--- | :--- | :--- |
| **AXI DMA** (`axi_dma_0`) | `S_AXI_LITE` | `0x40400000` | 64K | Direct Memory Access Controller (S2MM Channel) |
| **AXI Timer** (`axi_timer_0`) | `S_AXI` | `0x42800000` | 64K | System Timer / Timestamping / Triggering |
| **XADC Wizard** (`xadc_wiz_0`) | `s_axi_lite` | `0x43C00000` | 64K | XADC Register Configuration & Monitoring |
| **AXIS Trigger Unit** (`axis_trigger_unit_0`) | `s_axi` | `0x43C10000` | 64K | Hardware Edge/Level Trigger Control & Status |

### Hardware Parameters
* **Clock Frequency:** `100 MHz` (`FCLK_CLK0`)
* **Sampling Rate:** `1 MSPS` (1,000,000 samples per second)
* **DMA Transfer Mode:** Simple DMA S2MM (Scatter-Gather disabled)
* **Default Packet Size:** `16,384` samples per TLAST frame (`tlast_generator_0`)
* **Trigger Capabilities:** Rising/Falling edge detection, 12-bit voltage comparator, Auto-timeout counter (50 ms default), Single-shot auto-disarm.
* **Analog Inputs:** Differential `Vp_Vn_0` and Auxiliary channel `Vaux1_0` (Header A0)

---

## 📦 For Software Developers (Consuming this Overlay)

You **do not** need Vivado installed to use this overlay in your software projects.

### Fetching Binaries Automatically
This repository releases pre-compiled `.bit` and `.hwh` binaries on GitHub Releases upon every version tag (e.g., `v1.1.0`).

In your PYNQ Python application, specify the dependency in a `hardware.json` file:

```json
{
  "repo": "SiririComun/hw-xadc-dma-overlays",
  "version": "v1.1.0",
  "overlay_name": "pynq_z2"
}
```

Use `OscilloscopeOverlay` or a loader script to download and program the PYNQ board:

```python
from pynq_oscilloscope import OscilloscopeOverlay

# Automatically downloads v1.1.0 release and programs FPGA
ol = OscilloscopeOverlay()
print("XADC Hardware-Triggered Overlay loaded successfully!")
```

---

## 🛠 For Firmware Developers (Building Locally)

### Prerequisites
* **AMD Vivado 2024.2.2** (or compatible)
* Git installed with submodule support

### 1. Clone the Repository
```bash
git clone --recursive https://github.com/SiririComun/hw-xadc-dma-overlays.git
cd hw-xadc-dma-overlays
```

### 2. Create & Build Project
Use Hog Tcl commands to generate and build the local project:
```bash
./Hog/Do CREATE pynq_z2
./Hog/Do WORK pynq_z2
```
Upon successful bitstream creation, Hog executes `Top/pynq_z2/post-bitstream.tcl` to copy and rename the compiled artifacts into `bin/pynq_z2.bit` and `bin/pynq_z2.hwh`.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
