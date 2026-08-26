# HW XADC DMA Overlays

[![Hog Managed](https://img.shields.io/badge/HDL_Management-Hog-blue.svg)](https://cern.ch/hog)
[![Target Board](https://img.shields.io/badge/Board-PYNQ--Z2-orange.svg)](https://tul.com.tw/ProductsPYNQ-Z2.html)
[![Vivado Version](https://img.shields.io/badge/Vivado-2024.2.2-green.svg)](https://www.xilinx.com)
[![Hardware Release](https://img.shields.io/badge/Release-v1.6.0-blue.svg)](https://github.com/SiririComun/hw-xadc-dma-overlays/releases/tag/v1.6.0)

A high-performance multi-regime hardware overlay for the **PYNQ-Z2** (`xc7z020clg400-1`) providing **simultaneous true dual-ADC parallel sampling ($0.00\,\mu\text{s}$ inter-channel skew)**, **FPGA-accelerated programmable decimation ($M \in \{1, 10, 20, 50\}$)**, dynamic packetization, **frame-locked channel demultiplexing**, **runtime-reconfigurable 2048-point Forward FFT (`xfft_0`)**, **Hermitian-symmetric real-time spectral frequency filtering (`axis_spectral_mask`)**, **hardware Inverse FFT (`xfft_1`) with calibrated 1:1 amplitude reconstruction**, and **concurrent 3-DMA streaming** directly to DDR memory.

Managed using **Hog (HDL on Git)** for strict design traceability and automated bitstream versioning.

---

## 🏛 Hardware Architecture & Memory Map

The hardware overlay captures analog data across **Arduino Header A0 (`Vaux1`)** and **A1 (`Vaux9`)** using the XADC dual continuous sequencer in true parallel sampling mode, gates frames via `axis_trigger_unit` with **selectable trigger source (A0 vs A1)**, applies runtime decimation via `axis_decimator`, packetizes frames with programmable `tlast_generator`, forks the stream via `axis_broadcaster_0`, isolates a clean single-channel stream via `axis_channel_demux`, computes the Forward FFT via `xfft_0`, applies dynamic frequency masking with Hermitian symmetry via `axis_spectral_mask`, forks the masked complex spectrum to both CORDIC (for magnitude extraction via `axi_dma_1`) and `xfft_1` (for time-domain IFFT reconstruction via `axi_dma_2`), and transfers all 3 data streams synchronously to DDR memory.

### Block Design Schematic
![PYNQ-Z2 XADC Multi-Regime Block Design with PL Filter & IFFT](docs/images/xadc_bd.svg)

### Dataflow Diagram
```
                     [ PYNQ-Z2 Header A0 (Vaux1) ]       [ PYNQ-Z2 Header A1 (Vaux9) ]
                                   │                                   │
                                   └───────────────┬───────────────────┘
                                                   ▼
                                  [ XADC Wizard Dual Simultaneous Sampling ]
                                                   │ (1 MSPS Interleaved Stream, 0.00 µs Skew)
                                                   ▼
                                         [ axis_trigger_unit ]
                                         (Selectable Trigger: A0/A1, Phase-Locked to A0)
                                                   │ (Gated Stream)
                                                   ▼
                                         [ axis_decimator IP ]
                               (Programmable M = 1, 10, 20, 50 via Reg 0x14)
                                                   │
                                                   ▼
                                          [ tlast_generator ]
                               (Programmable Packet Limit via Reg 0x1C)
                                                   │ (w/ TLAST)
                                        [ axis_broadcaster_0 ]
                                  ┌────────────────┴────────────────┐
                         (Time Stream w/ TLAST)            (Interleaved Stream w/ TLAST)
                                  │                                 │
                                  │                                 ▼
                                  │                    [ axis_channel_demux ]
                                  │                    (Clean A0 vs A1 Routing via Reg 0x00[6])
                                  │                                 │
                                  │                                 ▼
                                  │                    [ xfft_0 Core (Forward FFT) ]
                                  │                    (N = 512, 1024, 2048 via Reg 0x18)
                                  │                                 │ (Complex Spectrum: Re + j*Im)
                                  │                                 ▼
                                  │                    [ axis_spectral_mask ]
                                  │                    (Hermitian Masking: k_eff = min(k, N-k))
                                  │                                 │ (Masked Complex Spectrum)
                                  │                                 ▼
                                  │                      [ axis_broadcaster_1 ]
                                  │                        ┌────────┴────────┐
                                  │                        ▼                 ▼
                                  │                   [ cordic_0 ]      [ xfft_1 Core (IFFT) ]
                                  │                (Magnitude Engine) (Time-Domain Reconstruction)
                                  │                        │                 │
                                  ▼                        ▼                 ▼
                        [ AXI DMA 0 (Time) ]     [ AXI DMA 1 (FFT) ]   [ AXI DMA 2 (Filtered) ]
                           (0x40400000)             (0x40410000)          (0x40420000)
                                  │                        │                 │
                                  └────────────────────────┼─────────────────┘
                                                           ▼ (AXI SmartConnect HP0)
                                                [ Processing System DDR ]
```

---

## 🎛 Frequency-Domain Filtering & Hermitian Symmetry

Real physical signals $x[n] \in \mathbb{R}$ require their discrete Fourier spectrum $X[k]$ to satisfy Hermitian symmetry:
$$X[N - k] = X^*[k]$$

If only the positive frequencies $k \in [0, N/2]$ are masked while negative frequencies $k \in (N/2, N-1]$ remain unmasked, the reconstructed time-domain signal $y[n]$ produces severe imaginary leakage, phase distortion, and amplitude attenuation.

The `axis_spectral_mask` core computes the **effective symmetric bin index**:
$$k_{\text{eff}} = \min(k, N - k)$$

This guarantees strict real-signal Hermitian symmetry across all 4 filtering modes with **$< 1\%$ amplitude reconstruction error** and **$> 40\,\text{dB}$ stopband rejection**.

---

## 📍 Physical Pin Constraints (Arduino Header `J1`)

| Signal Port | Physical Pin | Header Location | Description |
| :--- | :--- | :--- | :--- |
| `Vaux1_0_v_p` / `v_n` | `E17` / `D18` | **Header `J1` Pin A0** (Pin 6 - Bottom) | Channel 1 Analog Differential Pair |
| `Vaux9_0_v_p` / `v_n` | `E18` / `E19` | **Header `J1` Pin A1** (Pin 5 - 2nd from Bottom) | Channel 2 Analog Differential Pair |

---

## 🗺 AXI Memory Address Table

| Peripheral Block | Interface | Base Address | Address Range | Description |
| :--- | :--- | :--- | :--- | :--- |
| **AXI DMA Time** (`axi_dma_0`) | `S_AXI_LITE` | `0x40400000` | 64K | Raw Time-Domain Interleaved Stereo DMA Controller |
| **AXI DMA FFT** (`axi_dma_1`) | `S_AXI_LITE` | `0x40410000` | 64K | Frequency-Domain Magnitude DMA Controller ($N/2$ bins) |
| **AXI DMA Filtered** (`axi_dma_2`) | `S_AXI_LITE` | `0x40420000` | 64K | Filtered & Reconstructed Time-Domain DMA Controller |
| **AXI Timer** (`axi_timer_0`) | `S_AXI` | `0x42800000` | 64K | System Timer / Hardware Capture Trigger |
| **XADC Wizard** (`xadc_wiz_0`) | `s_axi_lite` | `0x43C00000` | 64K | XADC DRP & Dual Simultaneous Sampling Configuration |
| **AXIS Trigger Unit** (`axis_trigger_unit_0`) | `s_axi` | `0x43C10000` | 64K | Trigger, Decimation ($M$), FFT Config, Routing & Packet Limits |
| **AXIS Spectral Mask** (`axis_spectral_mask_0`) | `s_axi` | `0x43C20000` | 64K | Hardware Filter Mode, Cutoff Bins ($k_{\text{start}}, k_{\text{stop}}$) & $N$ |

---

## 📋 Register Maps

### 1. `axis_trigger_unit_0` (`0x43C10000`)
* **`0x00: REG_CONTROL`**
  * `[0]`: Arm Trigger Unit (`1` = Arm)
  * `[1]`: Auto-Trigger Mode (`1` = Auto, `0` = Normal)
  * `[2]`: Trigger Edge Direction (`0` = Rising, `1` = Falling)
  * `[3]`: Single-Shot Mode (`1` = Single Shot, `0` = Continuous)
  * `[4]`: Software Force Trigger Pulse
  * `[5]`: Trigger Source Selection (`0` = Channel 1 / A0, `1` = Channel 2 / A1)
  * `[6]`: FFT Source Routing (`0` = Route A0 to FFT, `1` = Route A1 to FFT)
* **`0x04: REG_STATUS`** — `[0]`: Armed, `[1]`: Triggered, `[2]`: Streaming
* **`0x08: REG_THRESHOLD`** — `[15:0]`: 12-bit left-aligned comparator threshold ($0.0\,\text{V} - 3.3\,\text{V}$)
* **`0x0C: REG_TIMEOUT`** — `[31:0]`: Auto-trigger timeout in clock cycles (Default: $5{,}000{,}000 = 50\,\text{ms}$)
* **`0x10: REG_HYSTERESIS`** — `[15:0]`: Noise rejection hysteresis band
* **`0x14: REG_DECIMATION`** — `[1:0]`: `00` $\implies M=1$ (Bypass), `01` $\implies M=10$, `10` $\implies M=20$, `11` $\implies M=50$
* **`0x18: REG_FFT_CONFIG`** — `[15:0]`: `(FWD_INV << 8) | NFFT` (Pushes configuration word to `xfft_0` and `xfft_1` via `axis_broadcaster_cfg`)
* **`0x1C: REG_PACKET_SIZE`** — `[15:0]`: Samples per DMA frame ($N$)

### 2. `axis_spectral_mask_0` (`0x43C20000`)
* **`0x00: REG_CTRL`**
  * `[0]`: Filter Enable (`0` = Hardware Bypass, `1` = Engage Masking)
  * `[2:1]`: Filter Mode:
    * `00`: **Lowpass / Bass** (Pass $k_{\text{eff}} \le k_{\text{stop}}$)
    * `01`: **Highpass / Treble** (Pass $k_{\text{eff}} \ge k_{\text{start}}$)
    * `10`: **Bandpass** (Pass $k_{\text{start}} \le k_{\text{eff}} \le k_{\text{stop}}$)
    * `11`: **Notch / Bandstop** (Zero $k_{\text{start}} \le k_{\text{eff}} \le k_{\text{stop}}$)
* **`0x04: REG_BIN_START`** — `[15:0]`: Lower cutoff bin index ($k_{\text{start}}$)
* **`0x08: REG_BIN_STOP`** — `[15:0]`: Upper cutoff bin index ($k_{\text{stop}}$)
* **`0x0C: REG_FFT_LEN`** — `[15:0]`: FFT transform length $N$ (Default: $1024$)
* **`0x10: REG_STATUS`** — `[0]`: Frame Active, `[31:16]`: Current streaming bin count ($k$)

---

## ⚡ Multi-Regime Operating Profiles

| Profile Mode | Decimator ($M$) | Transform ($N$) | Sampling Rate ($f_s$) | Nyquist Bandwidth | Time Window ($T_{\text{win}}$) | Resolution ($\Delta f$) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Wideband Lab Scope** | **$1$** (Bypass) | $2048$ | $500\,\text{kSPS}$ | $0 - 250\,\text{kHz}$ | $2.05\,\text{ms}$ | $244.14\,\text{Hz}$ |
| **Full-Band Audio** | **$10$** | $1024$ | $50\,\text{kSPS}$ | $0 - 25\,\text{kHz}$ | $20.48\,\text{ms}$ | $48.83\,\text{Hz}$ |
| **Speech / Vocal** | **$20$** | $1024$ | $25\,\text{kSPS}$ | $0 - 12.5\,\text{kHz}$ | $40.96\,\text{ms}$ | $24.41\,\text{Hz}$ |
| **Deep Bass Zoom** | **$50$** | $1024$ | $10\,\text{kSPS}$ | $0 - 5\,\text{kHz}$ | $102.40\,\text{ms}$ | **$9.77\,\text{Hz}$** |

---

## 📦 For Software Developers (Consuming this Overlay)

Specify the `v1.6.0` dependency in your `hardware.json`:

```json
{
  "repo": "SiririComun/hw-xadc-dma-overlays",
  "version": "v1.6.0",
  "overlay_name": "pynq_z2"
}
```

```python
from pynq_oscilloscope import OscilloscopeOverlay

ol = OscilloscopeOverlay()
ol.set_profile("audio")

# Engage hardware Lowpass filter at 250 Hz
ol.filter.set_lowpass(cutoff_hz=250.0)

# Capture Raw Time, Filtered Time, and Spectrum simultaneously
v_raw_a0, v_raw_a1, v_filtered, freqs, mags = ol.capture_all()
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