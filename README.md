# Voice Assistant (ESP32-C3 Firmware + Flutter App)

An end-to-end edge AI offline voice assistant ecosystem featuring an **ESP32-C3 Super Mini** IoT microphone node and a cross-platform **Flutter** companion app powered by the **Vosk Offline Speech Engine** with real-time **English & Banglish** output.

---

## 📁 Repository Structure

```
.
├── esp32_firmware/
│   └── voicebox_esp32_c3.ino          # Dual-transport (BLE & Wi-Fi WebSocket) ESP32-C3 audio streaming firmware
├── voice_assistant/                   # Flutter Application
│   ├── android/                       # Native Android setup (Gradle 8.7, AGP 8.6, Proguard, MultiDex)
│   ├── assets/models/                 # Bundled Vosk offline models (~40MB small-en-us)
│   ├── lib/
│   │   └── main.dart                  # Flutter app UI & logic (BLE, WebSocket, Vosk Engine, Banglish transliteration)
│   ├── pubspec.yaml                   # Flutter dependencies (vosk_flutter, flutter_blue_plus, etc.)
│   ├── analysis_options.yaml
│   └── README.md
├── .gitignore
└── README.md
```

---

## ⚡ System Architecture & Components

```
 [ESP32-C3 Node + Mic]
   ├── BLE Server ("VoiceBox-CTRL") ─── Command State & Control ───> [Flutter App]
   └── Wi-Fi AP ("VoiceBox", ws://:81) ─ Raw 16kHz PCM Audio Stream ─> [Vosk Engine] ──> [Banglish Converter] ──> [UI]
```

### 1. ESP32-C3 Firmware (`esp32_firmware/`)
- **Microcontroller:** ESP32-C3 Super Mini (RISC-V single-core).
- **Microphone Input:** Pin 0 (ADC1 Channel 0). ADC1 is safe to sample while Wi-Fi is active.
- **Dual Transport:**
  - **Wi-Fi WebSocket Server:** Runs on port `81` (`ws://192.168.4.1:81/`). SoftAP SSID: `VoiceBox`, Password: `voice1234`. Transmits raw 16kHz 16-bit mono PCM chunks (20ms / 640 bytes).
  - **Bluetooth Low Energy (BLE):** Controls microphone state (Start/Stop streaming) and status telemetry. Advertised device name: `VoiceBox-CTRL`.

### 2. Flutter Companion App (`voice_assistant/`)
- **Vosk Offline Engine:** High-performance, lightweight on-device speech recognition without cloud API dependency.
  - Bundled with `vosk-model-small-en-us-0.15` (~40MB) directly in APK assets.
  - Supports streaming recognition as audio chunks arrive from ESP32.
- **Banglish Transliteration Engine:** Built-in phonetic converter that detects Bengali Unicode text and automatically transliterates it into natural Romanized **Banglish** in real time; English text remains untouched.
- **Pre-flight Socket Diagnostics:** Tests raw TCP socket connectivity (`Socket.connect`) before initiating WebSocket handshake, with detailed error reporting.
- **Customizable Network Endpoints:** In-app modal sheet to switch between ESP32 AP mode (`192.168.4.1:81`) or home router LAN IPs.
- **Modern Dark UI:** Includes live VU audio level meter, transport status chips (Wi-Fi, BLE, Vosk), interactive partial transcript bubble, and 1-tap copy cards.

---

## 🛠️ Step-by-Step Setup Guide

### Hardware Setup (ESP32-C3 + Microphone)
1. **Microphone (e.g., MAX9814 or Analog Mic):**
   - `OUT` -> ESP32-C3 `GPIO 0` (ADC1_CH0)
   - `VCC` -> `3.3V`
   - `GND` -> `GND`
2. **Flashing Firmware:**
   - Open Arduino IDE.
   - Select Board: `ESP32C3 Dev Module`.
   - Install required libraries: `WebSockets` (by Markus Sattler), `WiFi`, `BLEDevice`.
   - Open [esp32_firmware/voicebox_esp32_c3.ino](file:///home/sufi/Downloads/bhaia/esp32_firmware/voicebox_esp32_c3.ino) and click **Upload**.

### Mobile App Setup (Flutter)
1. Navigate to the app directory:
   ```bash
   cd voice_assistant
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run or Build the Release APK:
   ```bash
   flutter build apk --release --no-tree-shake-icons --android-skip-build-dependency-validation
   ```
   Built APK location: `voice_assistant/build/app/outputs/flutter-apk/app-release.apk`

---

## 🔄 End-to-End Workflow

1. **Power up the ESP32-C3:** It starts the `VoiceBox` Wi-Fi Access Point (`SSID: VoiceBox`, `Password: voice1234`) and advertises over BLE (`VoiceBox-CTRL`).
2. **Connect Phone to Wi-Fi:** On your Android phone, connect to Wi-Fi `VoiceBox`.
   > **Note:** If Android prompts "No Internet Access", choose **Stay Connected**. It is recommended to temporarily disable Mobile Data (LTE/5G) so Android routes socket traffic to the ESP32 local network.
3. **Open Flutter App:**
   - Grant Bluetooth and Nearby Devices permissions.
   - Tap **Connect Wi-Fi** (or configure custom IP/Port via the Wi-Fi icon).
   - Tap **Scan & Connect BLE** to pair with the ESP32 node.
   - Tap **Start Vosk Listening**; the app starts streaming audio directly into Vosk and prints live transcripts in English or Banglish.
