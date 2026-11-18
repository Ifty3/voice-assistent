# Voice Assistant (BLE + Wi-Fi WebSocket Audio + Whisper AI)

A complete offline, edge-AI Flutter Voice Assistant integration. It connects to an ESP32 or IoT device via **BLE (Bluetooth Low Energy)** for commands/state machine, receives raw 16kHz 16-bit mono PCM audio over a local **Wi-Fi WebSocket**, performs real-time **Voice Activity Detection (VAD)**, and transcribes speech locally using on-device **whisper.cpp (Bengali + English multilingual AI)**.

---

## 📁 Project Architecture & Files Created

```
voice_assistant/
├── android/
│   ├── app/
│   │   ├── build.gradle                 # Sets minSdkVersion 24 (Whisper requirement) & NDK ABI filters
│   │   └── src/main/
│   │       ├── AndroidManifest.xml      # BLE & Internet permissions, cleartext traffic for local WS
│   │       ├── kotlin/com/example/voice_assistant/MainActivity.kt
│   │       └── res/                     # Theme and launch drawables
│   ├── build.gradle                     # Top-level Gradle config
│   ├── settings.gradle                  # Flutter Gradle plugin loader
│   └── gradle.properties
├── lib/
│   └── main.dart                        # Complete reactive Voice Assistant app
├── pubspec.yaml                         # Package dependencies: flutter_blue_plus, whisper_cpp_flutter_plus, permission_handler
├── analysis_options.yaml                # Standard Flutter lints
└── README.md
```

---

## 🛠️ Internal Errors Identified & Resolved

1. **BLE Scan Infinite Hang (Critical):**
   - *Problem:* In the original code, `FlutterBluePlus.scanResults.firstWhere(...)` had no timeout. If `VoiceBox-CTRL` was not in range or turned off, the Future hung forever, permanently locking the UI.
   - *Fix:* Added `.timeout(const Duration(seconds: 10))` with a descriptive exception and auto-cleanup via `FlutterBluePlus.stopScan()` in a `try/finally` block.

2. **Android 11 vs 12+ Bluetooth Permission Discrepancy:**
   - *Problem:* `Permission.bluetoothScan` and `Permission.bluetoothConnect` are only valid on Android 12+ (API 31+). On Android 10/11, BLE discovery requires `Permission.location`.
   - *Fix:* Added cross-version permission request covering `bluetoothScan`, `bluetoothConnect`, and `location` for Android devices.

3. **Android `minSdkVersion` Incompatibility:**
   - *Problem:* Default Flutter projects target `minSdkVersion 21`. `whisper_cpp_flutter_plus`'s native C++ binaries require at least `minSdkVersion 24` (Android 7.0+).
   - *Fix:* Explicitly configured `minSdkVersion 24` and NDK ABI filters (`armeabi-v7a`, `arm64-v8a`, `x86_64`) in `android/app/build.gradle`.

4. **Slow Disk I/O & Potential Temp File Storage Leak:**
   - *Problem:* The original code created a temp directory, wrote WAV bytes to disk, read them back with `WhisperAudio.readWav(file)`, and deleted them. If an exception occurred during transcription, the file deletion was skipped, leaking files on device storage.
   - *Fix:* Replaced disk I/O with direct in-memory decoding using `WhisperAudio.decodeWav(wavBytes)`, which is ~10x faster with zero file system overhead.

5. **Memory Thrashing in `createWav`:**
   - *Problem:* `[...header.buffer.asUint8List(), ...pcm]` used Dart array spreading, creating a temporary list of boxed integers before converting to `Uint8List`. For multiple seconds of audio, this caused heavy garbage collection pauses.
   - *Fix:* Allocated contiguous memory once with `Uint8List(44 + pcm.length)` and used `setRange()`.

6. **Unmounted `setState` Crashes:**
   - *Problem:* Several `catch (e)` and async blocks invoked `setState()` without checking `if (!mounted) return;`. If the user navigated away during download or transcription, this threw unhandled `FlutterError` exceptions.
   - *Fix:* Added `mounted` guards across all async boundaries.

7. **Stale Pre-Roll Audio Pollution:**
   - *Problem:* When a sentence completed, `preRoll` was not cleared, causing the trailing silence or noise from the previous utterance to prepend to the next utterance.
   - *Fix:* Added `preRoll.clear()` on sentence boundaries.

8. **Unhandled BLE Disconnect:**
   - *Problem:* If the BLE device lost connection or power, `bleConnected` remained `true` in state.
   - *Fix:* Subscribed to `device.connectionState` to update UI immediately upon disconnection.

9. **Bengali + English Language Mode Support:**
   - *Problem:* Hardcoded language settings did not allow selecting between Auto-Detect, pure Bengali, or English.
   - *Fix:* Added an interactive language selector in the AppBar for `'auto'`, `'bn'`, and `'en'`.

---

## 📡 Hardware / Firmware Protocol

- **BLE Service UUID:** `12345678-1234-1234-1234-123456789000`
- **BLE Command Characteristic:** `12345678-1234-1234-1234-123456789001` (Sends `START` / `STOP`)
- **BLE Status Characteristic:** `12345678-1234-1234-1234-123456789002` (Notify)
- **Wi-Fi Audio WebSocket:** `ws://192.168.4.1:81/`
  - Format: Raw PCM 16-bit Signed Little-Endian, 16000 Hz, Mono (640 bytes / 20ms per packet).
