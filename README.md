# HW XADC DMA Overlays

[![Hog Managed](https://img.shields.io/badge/HDL_Management-Hog-blue.svg)](https://cern.ch/hog)
[![Target Board](https://img.shields.io/badge/Board-PYNQ--Z2-orange.svg)](https://tul.com.tw/ProductsPYNQ-Z2.html)
[![Vivado Version](https://img.shields.io/badge/Vivado-2024.2.2-green.svg)](https://www.xilinx.com)
[![Hardware Release](https://img.shields.io/badge/Release-v1.5.3-blue.svg)](https://github.com/SiririComun/hw-xadc-dma-overlays/releases/tag/v1.5.3)

A high-performance multi-regime hardware overlay for the **PYNQ-Z2 (`xc7z020clg400-1`)** that provides **true zero-skew simultaneous dual-ADC sampling ($0.00\,\mu\text{s}$ inter-channel skew)**, **FPGA anti-aliasing decimation ($M \in \{1, 10, 20, 50\}$)**, **active buzzer pulse generation on Arduino pin AR2 (`U13`)**, **hardware-accelerated 100 MHz ToA/TDOA cycle counters ($10.0\,\text{ns}$ ticks)**, **quasi-anechoic direct-path energy accumulation**, and concurrent dual AXI DMA streaming to DDR memory.

Managed using **Hog (HDL on Git)** for strict design traceability and automated bitstream versioning.

---

## 🏛 Hardware Architecture & Dataflow

```
                     [ PYNQ-Z2 Header A0 (Vaux1) ]       [ PYNQ-Z2 Header A1 (Vaux9) ]
                                   │                                   │
                                   └───────────────┬───────────────────┘
                                                   ▼
                                  [ XADC Wizard Dual Continuous Sequencer ]
                                       (1 MSPS Dual Stream, 0.00 µs Skew)
                                                   │
                                                   ▼
                                         [ axis_trigger_unit ]
                         ├── Generates AR2 (U13) Buzzer Pulses (Reg 0x20, Bit 7)
                         ├── 100 MHz ToA Counters (Regs 0x24, 0x28, 0x2C, 0x30)
                         └── 2-Stage Pipelined Direct Energy Accumulator (Regs 0x34, 0x38, 0x3C)
                                                   │ (Gated Stream)
                                                   ▼
                                         [ axis_decimator IP ]
                               (Programmable M = 1, 10, 20, 50 w/ DSP48 Reciprocal)
                                                   │
                                                   ▼
                                          [ tlast_generator ]
                                (Programmable Packet Limit via Reg 0x1C)
                                                   │
                                         [ axis_broadcaster ]
                                  ┌────────────────┴────────────────┐
                         (Time Stream w/ TLAST)            (Interleaved Stream w/ TLAST)
                                  │                                 ▼
                                  │                    [ axis_channel_demux ]
                                  │                    (Routes A0 vs A1 to FFT via Reg 0x00[6])
                                  │                                 ▼
                                  │                    [ axis_subset_converter_0 ]
                                  │                                 ▼
                                  │                    [ xfft Core (Runtime N FFT) ]
                                  │                    (N = 512, 1024, 2048 w/ TREADY Handshake)
                                  │                                 ▼
                                  │                    [ CORDIC IP (Translate Mode) ]
                                  │                    (32-bit: Phase [31:16], Magnitude [15:0])
                                  ▼                                 ▼
                        [ AXI DMA 0 (Time) ]              [ AXI DMA 1 (Polar FFT) ]
                           (0x40400000)                      (0x40410000)
                                  │                                 │
                                  └────────────────┬────────────────┘
                                                   ▼ (AXI SmartConnect HP0)
                                        [ Processing System DDR ]
```

---

## 🔌 Physical Package Pin Constraints

| Signal Port | Physical Pin | Header Location | Description |
| :--- | :--- | :--- | :--- |
| `Vaux1_0_v_p` / `v_n` | `E17` / `D18` | **Header `J1` Pin A0** (Pin 6) | Channel 1 Analog Differential Pair |
| `Vaux9_0_v_p` / `v_n` | `E18` / `E19` | **Header `J1` Pin A1** (Pin 5) | Channel 2 Analog Differential Pair ($0.00\,\mu\text{s}$ skew) |
| `buzzer_pulse_out` | **`U13`** | **Header Digital Pin AR2** (LVCMOS33) | Active Buzzer Hardware Pulse Output to 2N2222A Base |

---

## 🗃 Complete Register Map (`axis_trigger_unit_0` @ `0x43C10000`)

The AXI4-Lite slave decoder supports full 6-bit byte addressing (`0x00` through `0x3C`):

| Offset | Register Name | Bits | Description |
| :---: | :--- | :---: | :--- |
| **`0x00`** | **`CONTROL_REG`** | `[0]`<br>`[1]`<br>`[2]`<br>`[3]`<br>`[4]`<br>`[5]`<br>`[6]`<br>`[7]` | **Arm** trigger unit<br>**Auto Mode** (1) vs Normal Mode (0)<br>**Slope**: Rising edge (0) vs Falling edge (1)<br>**Single Shot** (1) vs Continuous (0)<br>**Force Trigger** software strobe<br>**Trigger Source**: Channel 1 / A0 (0) vs Channel 2 / A1 (1)<br>**FFT Stream Routing**: Channel 1 / A0 (0) vs Channel 2 / A1 (1)<br>**FIRE_PULSE**: Strobes buzzer pulse on `AR2` & resets ToA/energy counters |
| **`0x04`** | **`STATUS_REG`** | `[0]`<br>`[1]`<br>`[2]`<br>`[3]`<br>`[4]`<br>`[5]`<br>`[6]`<br>`[7]`<br>`[8]` | **Armed** state<br>**Triggered** flag<br>**Streaming** active<br>**PulseActive** (HIGH while buzzer pin `AR2` is firing)<br>**Mic1ToaLocked** (Channel 1 wavefront arrival latched)<br>**Mic2ToaLocked** (Channel 2 wavefront arrival latched)<br>**ToaDone** (Both channels latched or 50 ms timeout expired)<br>**Mic1GateDone** (Channel 1 direct-path gate complete)<br>**Mic2GateDone** (Channel 2 direct-path gate complete) |
| **`0x08`** | **`THRESHOLD_REG`** | `[15:0]` | 12-bit left-aligned comparator threshold ($0.0\,\text{V} - 3.3\,\text{V}$) |
| **`0x0C`** | **`TIMEOUT_REG`** | `[31:0]` | Auto-trigger timeout in 100 MHz clock cycles (Default: $5{,}000{,}000 = 50.0\,\text{ms}$) |
| **`0x10`** | **`HYSTERESIS_REG`** | `[15:0]` | Noise rejection hysteresis band |
| **`0x14`** | **`DECIMATION_REG`** | `[1:0]` | `00` $\implies M=1$ (Bypass: $500\,\text{kSPS}$), `01` $\implies M=10$ ($50\,\text{kSPS}$), `10` $\implies M=20$ ($25\,\text{kSPS}$), `11` $\implies M=50$ ($10\,\text{kSPS}$) |
| **`0x18`** | **`FFT_CONFIG_REG`** | `[15:0]` | `(FWD_INV << 8) | NFFT` (Dynamic LogiCORE FFT handshake on write) |
| **`0x1C`** | **`PACKET_SIZE_REG`** | `[15:0]` | Programmable sample limit per DMA frame ($N$) |
| **`0x20`** | **`PULSE_WIDTH_REG`** | `[31:0]` | Hardware buzzer pulse duration in 100 MHz clock cycles ($10\,\text{ns}$ ticks, up to $42.9\,\text{s}$) |
| **`0x24`** | **`MIC1_TOA_REG`** | `[31:0]` | Mic 1 acoustic arrival timestamp in 100 MHz clock cycles |
| **`0x28`** | **`MIC2_TOA_REG`** | `[31:0]` | Mic 2 acoustic arrival timestamp in 100 MHz clock cycles |
| **`0x2C`** | **`TOA_CONFIG_REG`** | `[31:16]`<br>`[15:0]` | **Blanking cycles** (Default: 30,000 cycles = $0.30\,\text{ms}$)<br>**Threshold delta counts** above DC reference baseline |
| **`0x30`** | **`MIC_DC_REF_REG`** | `[31:16]`<br>`[15:0]` | **Mic 2 DC bias baseline** (Default: `0x8000` = $1.65\,\text{V}$)<br>**Mic 1 DC bias baseline** (Default: `0x8000` = $1.65\,\text{V}$) |
| **`0x34`** | **`MIC1_ENERGY_REG`** | `[31:0]` | Line-of-sight squared sample sum for Mic 1 ($\sum (v - v_{\text{DC}})^2$) |
| **`0x38`** | **`MIC2_ENERGY_REG`** | `[31:0]` | Line-of-sight squared sample sum for Mic 2 ($\sum (v - v_{\text{DC}})^2$) |
| **`0x3C`** | **`GATE_CONFIG_REG`** | `[15:0]` | Direct-gate integration sample count $N_{\text{gate}}$ (Default: $576$ samples = 3 cycles @ $2610\,\text{Hz}$) |

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