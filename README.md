# Voice Assistant (ESP32-C3 Firmware + Flutter App)

An end-to-end Edge AI voice assistant ecosystem featuring an **ESP32-C3 Super Mini** IoT microphone node and a cross-platform **Flutter** companion app with on-device speech-to-text (Whisper AI).

---

## 📁 Repository Structure

```
.
├── esp32_firmware/
│   └── voicebox_esp32_c3.ino          # Dual-transport (BLE & Wi-Fi WebSocket) ESP32-C3 audio streaming firmware
├── voice_assistant/                   # Flutter Application
│   ├── android/                       # Native Android setup (NDK, Permissions, MinSdk 24)
│   ├── lib/
│   │   └── main.dart                  # Flutter app UI & logic (BLE, WebSocket, VAD, Whisper STT)
│   ├── pubspec.yaml                   # Flutter dependencies
│   ├── analysis_options.yaml
│   └── README.md
├── .gitignore
└── README.md
```

---

## ⚡ System Architecture & Components

### 1. ESP32-C3 Firmware (`esp32_firmware/`)
- **Microcontroller:** ESP32-C3 Super Mini (RISC-V single-core).
- **Microphone Input:** Pin 0 (ADC1 Channel 0). ADC1 is safe to sample while Wi-Fi is active.
- **Dual Transport:**
  - **Wi-Fi WebSocket Server:** Runs on port `81` (`ws://192.168.4.1:81/`). SoftAP SSID: `VoiceBox`, Password: `voice1234`. Transmits raw 16kHz 16-bit mono PCM chunks (20ms / 640 bytes).
  - **Bluetooth Low Energy (BLE):** Controls microphone state (Start/Stop streaming) and status telemetry.

### 2. Flutter Mobile App (`voice_assistant/`)
- **BLE Connection & Commands:** Scans for `VoiceBox` BLE service to start/stop the microphone.
- **WebSocket Streaming:** Connects to `ws://192.168.4.1:81/` to stream incoming PCM audio in real-time.
- **Voice Activity Detection (VAD):** Calculates frame energy to detect when speech starts and ends.
- **On-Device Whisper AI:** Transcribes spoken audio locally using `whisper.cpp` without needing external cloud APIs. Supports multilingual models (Bengali & English).

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
   flutter build apk --release --no-tree-shake-icons
   ```

---

## 🔄 End-to-End Workflow (Connecting ESP32 + Mobile App)

1. **Power up the ESP32-C3:** It starts the `VoiceBox` Wi-Fi Access Point (`SSID: VoiceBox`, `Password: voice1234`) and advertises over BLE.
2. **Connect Phone to Wi-Fi:** On your Android phone, connect to Wi-Fi `VoiceBox`.
3. **Open Flutter App:**
   - Grant Bluetooth and Nearby Devices permissions.
   - Tap **Scan & Connect BLE** to pair with the ESP32 node.
   - Tap **Start Recording**; the app sends a BLE command to trigger the microphone and receives raw audio via WebSocket (`ws://192.168.4.1:81/`).
   - When speaking stops, the app's VAD triggers transcription via Whisper AI and displays the output text on screen.
