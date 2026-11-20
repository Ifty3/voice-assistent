# Voice Assistant Companion App (Flutter + Vosk Offline Engine)

A complete offline, edge-AI Flutter companion application for the ESP32-C3 IoT microphone node. It connects via **BLE (Bluetooth Low Energy)** for commands/state control, streams raw 16kHz 16-bit mono PCM audio over a local **Wi-Fi WebSocket**, and performs offline speech recognition via the **Vosk Offline Engine** with automatic **Bengali to Banglish** transliteration.

---

## 📁 Project Architecture & Files

```
voice_assistant/
├── android/
│   ├── app/
│   │   ├── build.gradle                 # AGP 8.6, compileSdk 36, multiDexEnabled true, R8 disabled
│   │   ├── proguard-rules.pro           # Preserves Vosk, JNA, and Android Context classes
│   │   └── src/main/
│   │       ├── AndroidManifest.xml      # BLE & Internet permissions, cleartext traffic enabled
│   │       ├── kotlin/com/example/voice_assistant/MainActivity.kt
│   │       └── res/                     # Adaptive launcher icons & drawables
│   ├── gradle/wrapper/
│   │   └── gradle-wrapper.properties    # Gradle 8.7
│   ├── build.gradle                     # Top-level Gradle configuration
│   └── settings.gradle                  # Plugin management with AGP 8.6.0 & Kotlin 1.9.24
├── assets/
│   └── models/
│       └── vosk-model-small-en-us-0.15.zip # Bundled offline Vosk model (~40MB)
├── lib/
│   └── main.dart                        # Complete reactive Voice Assistant app
├── pubspec.yaml                         # vosk_flutter, flutter_blue_plus, path_provider_android: 2.2.23
├── analysis_options.yaml
└── README.md
```

---

## 🚀 Key Features

### 1. Vosk Offline Engine (~40MB)
- Replaced heavy Whisper models (150MB - 500MB) with lightweight Vosk models (~40MB).
- Model is bundled directly in `assets/models/vosk-model-small-en-us-0.15.zip` for instant offline availability.
- Fast streaming recognition that feeds 16kHz PCM audio buffers directly from the ESP32 WebSocket in real time.

### 2. Phonetic Banglish Transcriber
- Custom `BanglishTranscriber` engine written in pure Dart.
- Detects Bengali Unicode characters (`\u0980-\u09FF`) and transliterates them phonetically into readable Romanized **Banglish** (e.g., `কেমন আছেন` ➔ `kemon achen`).
- English transcripts pass through completely untouched.

### 3. Pre-flight Network Diagnostics
- Probes target IP and port using raw TCP `Socket.connect` before launching WebSocket handshakes.
- Gives clear error messages (connection timeout, host unreachable, connection refused) instead of silent failures.
- Wi-Fi configuration modal bottom sheet allows entering custom IP/Port with quick presets for ESP32 SoftAP (`192.168.4.1:81`) or home router IP.

### 4. Modern Dark UI
- Live VU level meter reflecting ESP32 microphone audio energy.
- Dual transport status badges (Wi-Fi Socket, Bluetooth BLE, Vosk Engine).
- Live partial typing bubble during ongoing speech.
- Transcript history list with timestamp, language indicator, and 1-tap copy to clipboard.

---

## 🛠️ Resolved Build & Runtime Challenges

1. **`ClassNotFoundException: Didn't find class "Landroid/content/Context;"`:**
   - *Cause:* `path_provider_android: 2.3.1` introduced experimental `package:jni` FFI bindings that looked up `Context` using an invalid JNI descriptor signature, crashing on Dalvik/ART.
   - *Fix:* Pinned `path_provider_android: 2.2.23` in `pubspec.yaml`, removing `jni`, `jni_flutter`, and `jni_util`, restoring stable platform channels.
2. **Release Build Vosk / JNA Class Stripping:**
   - *Cause:* Default Flutter release builds run R8 code shrinking, which stripped Java Native Access (JNA) reflection classes and Vosk models.
   - *Fix:* Set `minifyEnabled false` and `shrinkResources false` in `android/app/build.gradle` and added comprehensive keep rules in `android/app/proguard-rules.pro`.
3. **Android 14/15 Gradle & AGP Upgrades:**
   - Updated Gradle wrapper to `8.7`, AGP to `8.6.0`, and `compileSdk` to `36`.
   - Added vector and adaptive launcher icons to satisfy Android 14+ manifest requirements.
4. **Mobile Data Priority Conflict:**
   - Added user warning banner advising users to disable mobile data when connected to the ESP32 `VoiceBox` AP without internet, preventing Android from routing socket traffic through cellular interfaces.

---

## 📦 Building the Release APK

```bash
cd voice_assistant
flutter pub get
flutter build apk --release --no-tree-shake-icons --android-skip-build-dependency-validation
```

Output:
`build/app/outputs/flutter-apk/app-release.apk` (~117MB)
