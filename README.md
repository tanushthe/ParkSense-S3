<div align="center">

<img src="docs/images/prototype.jpg" alt="ParkSense-S3 prototype" height="360">

# 🅿️ ParkSense-S3

**A camera-based smart parking node that decides on-device which bays are free, using TinyML on an ESP32-S3.**

![Platform](https://img.shields.io/badge/MCU-ESP32--S3--N16R8-blue)
![Camera](https://img.shields.io/badge/Camera-OV2640-lightgrey)
![ML](https://img.shields.io/badge/TinyML-INT8%20CNN%20(10.12%20KB)-orange)
![Radio](https://img.shields.io/badge/Wi--Fi%20%2B%20BLE%205.0-NimBLE-green)
![Framework](https://img.shields.io/badge/Arduino-ESP32%20core%203.x-teal)
![Status](https://img.shields.io/badge/Status-Working%20prototype-brightgreen)

*Electronic Product Development (Sessional) · KIIT School of Electronics Engineering*

</div>

---

## Table of contents

1. [What it does](#what-it-does)
2. [Key specifications](#key-specifications)
3. [How it works](#how-it-works)
4. [Hardware](#hardware)
5. [Repository layout](#repository-layout)
6. [Getting started](#getting-started)
7. [Using the node](#using-the-node)
8. [Interfaces reference](#interfaces-reference)
9. [The TinyML model](#the-tinyml-model)
10. [Verification and results](#verification-and-results)
11. [PCB and enclosure (concept stage)](#pcb-and-enclosure-concept-stage)
12. [Known limitations](#known-limitations)
13. [Roadmap](#roadmap)
14. [Troubleshooting](#troubleshooting)
15. [Standards and sustainability](#standards-and-sustainability)
16. [Team](#team)
17. [License](#license)

---

## What it does

ParkSense-S3 is a single, low-cost edge node that watches a row of **five parking bays** with one OV2640 camera and decides for each bay, **on the device itself**, whether it is *vacant* or *occupied*. No images leave the board and no cloud service is needed.

- **Edge inference.** A small INT8 convolutional network runs on the ESP32-S3 for every bay, once per polling cycle.
- **Two ways to read the result.**
  - A built-in **Wi-Fi web dashboard** (any browser on the same network).
  - A **Bluetooth LE GATT service** (any phone with a BLE scanner or the companion Android app).
- **Tunable at runtime.** The occupancy confidence threshold and polling interval can be changed from the dashboard (or the threshold over BLE) with no reboot.
- **Built-in logging.** Every cycle is logged and can be downloaded as a CSV file.
- **Built from COTS modules.** No custom silicon; the whole node is an ESP32-S3-N16R8 board, an OV2640 camera and a 5 V USB supply.

The project replaces an earlier concept (Raspberry Pi + Firebase cloud sync) with a much smaller, cheaper and fully local design. The reasoning is documented in the lifecycle report.

## Key specifications

| Parameter | Value |
|---|---|
| MCU module | ESP32-S3-WROOM-1 **N16R8** (16 MB flash, 8 MB octal PSRAM) |
| Camera | OV2640, QVGA **320 × 240** JPEG |
| Bays monitored | **5** fixed regions of interest (ROIs) |
| Model | INT8 CNN, **10.12 KB**, 48 × 48 × 3 input per bay |
| Tensor arena | 80 KB |
| Decision rule | occupied if `probability ≥ threshold` |
| Threshold | default **0.70**, adjustable **0.50 – 0.99** |
| Polling interval | default **2000 ms**, adjustable 500 – 10 000 ms |
| Measured inference latency | **234 – 236 ms** per 5-bay pass (requirement ≤ 500 ms) |
| Connectivity | 2.4 GHz Wi-Fi (HTTP, port 80) + Bluetooth 5.0 LE (NimBLE GATT) |
| BLE payload | 34 bytes, MTU 128, notify every cycle |
| Power | Regulated 5 V DC over USB |

## How it works

```
 ┌──────────┐   JPEG QVGA   ┌────────────────────────────────────────────┐
 │  OV2640  │ ────────────► │ ESP32-S3-N16R8                             │
 └──────────┘  (PSRAM       │                                            │
                frame       │  decode ► crop 5 ROIs ► resize 48×48×3     │
                buffers)    │        ► INT8 CNN (TFLite Micro)           │
                            │        ► prob ≥ threshold ? occupied : free│
                            │                                            │
                            │   ┌── Wi-Fi HTTP server (port 80) ──► Browser dashboard, CSV
                            │   └── NimBLE GATT server ───────────► Phone (notify + write)
                            └────────────────────────────────────────────┘
```

Each polling cycle:

1. Grab one JPEG frame from the OV2640 into PSRAM.
2. Decode to RGB888.
3. For each of the five bays, crop the ROI, resample it to 48 × 48 × 3 and scale the pixels (`INPUT_SCALE_MODE 1` → 0.0 – 1.0).
4. Run the INT8 model and read the occupancy probability.
5. Apply the threshold to get *occupied / vacant* per bay.
6. Update the BLE characteristic (and notify a connected phone), append a row to the CSV log, and print a status line over serial.

Wi-Fi is brought up first and BLE is started after association, so the two radios coexist reliably on the single 2.4 GHz front end.

## Hardware

### Bill of materials

| # | Item | Notes |
|---|---|---|
| 1 | ESP32-S3-N16R8 development board | 16 MB flash, 8 MB OPI PSRAM, USB |
| 2 | OV2640 camera module | Wired to the S3 DVP camera pins (table below) |
| 3 | 5 V USB supply | Regulated, 4.75 – 5.25 V |
| 4 | Enclosure and overhead mount | Camera must look down on the marked bays |

### Camera pin map (from the firmware)

| Signal | GPIO | Signal | GPIO |
|---|---|---|---|
| XCLK | 15 | Y5 | 10 |
| SIOD (SDA) | 4 | Y4 | 8 |
| SIOC (SCL) | 5 | Y3 | 9 |
| Y9 | 16 | Y2 | 11 |
| Y8 | 17 | VSYNC | 6 |
| Y7 | 18 | HREF | 7 |
| Y6 | 12 | PCLK | 13 |
| PWDN / RESET | not used (−1) | | |

## Repository layout

> Adjust this block to match what you have actually pushed.

```
ParkSense-S3/
├── ParkSense_S3/
│   ├── ParkSense_S3.ino        # main sketch (camera, TinyML, BLE, web server)
│   ├── model_data.h            # INT8 model as a C array (10.12 KB)
│   ├── secrets.example.h       # template for Wi-Fi credentials
│   └── board_config.txt        # Arduino IDE settings and library list
├── docs/
│   ├── images/                 # photos, PCB, CAD and screenshots used below
│   └── ParkSense_S3_Lifecycle_Report.pdf
├── .gitignore                  # must contain secrets.h
└── README.md
```

## Getting started

### 1. Install the toolchain

- **Arduino IDE 2.x**
- **esp32 board package by Espressif**, v3.x recommended
- Libraries from the Library Manager:
  - **NimBLE-Arduino** by h2zero, **v2.x** (the sketch uses the NimBLE 2.x API)
  - **MicroTFLite** (TFLite Micro wrapper for ESP32)

### 2. Arduino IDE settings

| Setting | Value |
|---|---|
| Board | ESP32S3 Dev Module |
| USB CDC On Boot | Enabled |
| Flash Size | 16MB (128Mb) |
| Partition Scheme | 16M Flash (3MB APP / 9.9MB FATFS) or Huge APP (3MB No OTA / 1MB SPIFFS) |
| PSRAM | **OPI PSRAM** |
| Upload Speed | 921600 |
| Serial Monitor | 115200 baud |

> **PSRAM must be set to OPI PSRAM.** Without it the camera frame buffers cannot be allocated and the camera will fail to start.

### 3. Add your Wi-Fi credentials

```bash
cp secrets.example.h secrets.h
```

Edit `secrets.h`:

```cpp
static const char* WIFI_SSID = "YOUR_WIFI_SSID";
static const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";
```

Use a **2.4 GHz** network. `secrets.h` is git-ignored so your credentials are never pushed.

### 4. Provide the model

`model_data.h` must contain your trained, INT8-quantised model as a C array. The model shipped with this project is 10.12 KB. If you retrain, keep the 48 × 48 × 3 input, or update the preprocessing in the sketch to match.

### 5. Flash and verify

Upload the sketch, open the Serial Monitor at 115200 baud and look for:

```
[BLE] Name='ParkSense-S3' | AdvStarted=1 | IsAdv=1 | MAC=xx:xx:xx:xx:xx:xx
[HTTP] Web dashboard server started on port 80
[ML+BLE] Cycle #1 | Avail: 5/5 | Lat: 235 ms | BLE Clients: 0 | Adv: 1
```

The serial log also shows the IP address to open in a browser.

### 6. Calibrate the bay regions

The five ROIs are fixed rectangles in QVGA pixels at the top of the sketch. Mount the camera, open `/capture` to see what it sees, and adjust the numbers until each rectangle sits on one bay:

```cpp
struct SlotROI { int x; int y; int w; int h; };
SlotROI slots[5] = {
  { 20,  75, 55, 65 },  // Slot 1
  { 78,  75, 55, 65 },  // Slot 2
  { 135, 75, 55, 65 },  // Slot 3
  { 192, 75, 58, 65 },  // Slot 4
  { 250, 75, 60, 65 }   // Slot 5
};
```

## Using the node

### Web dashboard

Open `http://<node-ip>/` from any device on the same Wi-Fi. The three-tab dashboard shows live bay status with confidence, a camera snapshot, and system health (latency, Wi-Fi RSSI, heap and PSRAM, BLE state, uptime). Sliders change the confidence threshold and polling interval on the fly, and a button downloads the CSV log.

<div align="center">
<img src="docs/images/dashboard_chrome.png" alt="Web dashboard in Chrome" width="720">
</div>

### Bluetooth LE

The node advertises as **`ParkSense-S3`**. With any BLE scanner (for example nRF Connect) connect, subscribe to the slot characteristic and you receive a notification every cycle.

<div align="center">
<img src="docs/images/ble_nrf_connect.png" alt="nRF Connect view of the GATT service" width="520">
</div>

## Interfaces reference

### HTTP endpoints (port 80)

| Route | Method | Returns |
|---|---|---|
| `/` | GET | HTML dashboard |
| `/capture` | GET | Current camera frame as `image/jpeg` (503 if the camera is not ready) |
| `/api/status` | GET | JSON status (below) |
| `/api/settings?thr=0.70&intv=2000` | GET | Sets threshold (clamped 0.50 – 0.99) and interval (clamped 500 – 10000 ms); replies `OK` |
| `/export.csv` | GET | `parking_log.csv` download |

Example `/api/status` response:

```json
{
  "available": 3,
  "latency_ms": 235,
  "cam_ok": true, "frame_ok": true, "fb_fails": 0, "mod_ok": true,
  "ble_ok": true, "ble_clients": 1,
  "ble_payload": "AVAIL:3/5|S1:1,S2:0,S3:0,S4:1,S5:0",
  "rssi": -58, "heap_kb": 180, "psram_kb": 7400,
  "uptime_s": 1234, "cycles": 617,
  "slots": [
    {"occ": true,  "conf": 0.962},
    {"occ": false, "conf": 0.031},
    {"occ": false, "conf": 0.054},
    {"occ": true,  "conf": 0.911},
    {"occ": false, "conf": 0.047}
  ]
}
```

*(Values are illustrative.)*

### CSV log

Columns: `Timestamp_s, Slot1 … Slot5, Available, Latency_ms` (1 = occupied). The log is held in RAM and trimmed to about 4 KB, so download it periodically; it does not survive a reboot.

### BLE GATT

| Item | UUID | Properties |
|---|---|---|
| Service | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` | n/a |
| Slot status characteristic | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | Read, Notify |
| Control characteristic | `1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e` | Write |

**Slot payload** (ASCII, 34 bytes):

```
AVAIL:<free>/5|S1:<0|1>,S2:<0|1>,S3:<0|1>,S4:<0|1>,S5:<0|1>
e.g.  AVAIL:3/5|S1:1,S2:0,S3:0,S4:1,S5:0        (1 = occupied, 0 = vacant)
```

**Control commands** (write ASCII to the control characteristic):

| Command | Effect |
|---|---|
| `THR:<50-99>` | Sets the confidence threshold in percent, e.g. `THR:80` → 0.80. Values outside 50 – 99 are ignored. |

## The TinyML model

| Item | Detail |
|---|---|
| Task | Per-bay binary classification (vacant / occupied) |
| Input | One 48 × 48 × 3 crop per bay, scaled to 0.0 – 1.0 |
| Quantisation | Full INT8 |
| Size | 10.12 KB |
| Runtime | TFLite Micro through MicroTFLite, 80 KB tensor arena |
| Decision | Occupied when `prob ≥ threshold` (default 0.70) |
| Data | Cropped bay images, vacant and occupied examples, including mixed rows |

Lowering the threshold makes the node flag *occupied* more readily (fewer missed cars, more false alarms); raising it does the opposite. The default of 0.70 was chosen from the calibration runs.

<div align="center">
<img src="docs/images/confidence_plot.png" alt="Model confidence on test crops" width="640">
</div>

## Verification and results

The prototype was verified against a 12-requirement baseline (`REQ-01` to `REQ-12`) using a Product Test Report.

| Result | Value |
|---|---|
| Test cases planned / executed | 52 / 34 |
| Executed cases passed | **34 of 34** |
| Not tested (NT) / not applicable (NA) | 14 / 4 |
| Requirements verified PASS | **10 of 12** |
| Requirements not tested | `REQ-10`, `REQ-11` (EMC and environmental), covered by waiver `DEV-01` |
| Inference latency | 234 – 236 ms (limit 500 ms) |
| Calibration | 20 / 20 occupancy transitions detected, in two separate runs |

The EMC and environmental tests need lab equipment that was not available, so those two requirements are recorded as not tested rather than passed. See the Product Test Report for the full matrix.

## PCB and enclosure (concept stage)

A custom **ESP32-CAM Interface Board (Rev A)** and a 3-D enclosure were designed as a concept for a future revision. **The tested prototype does not use them**; it uses COTS modules wired directly. There are no Gerber files, DRC report or test record for this board yet.

<div align="center">
<img src="docs/images/pcb_schematic_revA.png" alt="Rev A schematic" width="48%">
<img src="docs/images/pcb_layout_revA.png" alt="Rev A PCB layout" width="48%">
<br>
<img src="docs/images/cad_concept.png" alt="Concept enclosure 3D model" width="48%">
</div>

## Known limitations

- **Fixed ROIs.** The five bays are hard-coded rectangles; moving the camera means re-editing the sketch.
- **One camera, five bays.** Coverage and angle limit how many bays one node can watch.
- **Binary decision only.** There is no "unknown" state for uncertain frames; the threshold is the only control.
- **Lighting.** Calibration used lab LED lighting and sheltered daylight. Night, glare and rain are untested.
- **EMC and environmental testing** (`REQ-10`, `REQ-11`) were not performed.
- **Log is volatile.** The CSV log lives in RAM.
- **No authentication.** The web server and BLE control are open; use only on a trusted network.
- **Maintainability grade** (64.4 %, Grade C) is a documentary estimate, not a measured figure.

## Roadmap

- [ ] Browser-based ROI editor that stores bay rectangles in flash
- [ ] An "unknown" output for low-confidence frames
- [ ] MQTT publishing for multi-node deployments
- [ ] Night and IR illumination, plus an enclosure with a sunshade
- [ ] Fabricate the Rev A interface board and run DRC and bring-up tests
- [ ] OTA firmware updates
- [ ] EMC pre-compliance and ingress-protection testing

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Camera init fails / `cam_ok: false` | PSRAM not set to **OPI PSRAM** in the IDE, or loose camera ribbon/wiring |
| Compile error about NimBLE methods | Installed NimBLE-Arduino is v1.x; install **v2.x** |
| Cannot connect to Wi-Fi | Network is 5 GHz only; use 2.4 GHz and recheck `secrets.h` |
| BLE not visible | Wait for Wi-Fi association (BLE starts after it); check the `[BLE] ... AdvStarted=1` line |
| Wrong bay readings | ROIs not aligned; view `/capture` and adjust `slots[]` |
| Everything reads occupied or vacant | Threshold too low/high, or `INPUT_SCALE_MODE` does not match how the model was trained |
| Brown-outs or resets | Weak USB supply or cable; use a stable 5 V source |

## Standards and sustainability

The lifecycle documentation follows ISO/IEC/IEEE 29148 (requirements), IEC 62368-1 (safety), IPC-A-610 (assembly acceptability), IEC/IEEE 82079-1 (user documentation) and the Misra IoT Level 1 model. The project maps to UN SDGs 9, 11 and 12 and considers end-of-life under India's E-Waste (Management) Rules, 2022.


## License

No license has been chosen yet. Add a `LICENSE` file (MIT or Apache-2.0 are common for projects like this) before others reuse the code.
