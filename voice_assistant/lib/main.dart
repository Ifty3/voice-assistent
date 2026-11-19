import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

// ============================================================================
// CONSTANTS & PROTOCOL IDENTIFIERS
// ============================================================================
const String bleServiceUuid = '12345678-1234-1234-1234-123456789000';
const String bleCommandUuid = '12345678-1234-1234-1234-123456789001';
const String bleStatusUuid = '12345678-1234-1234-1234-123456789002';
const String bleAudioUuid = '12345678-1234-1234-1234-123456789003';
const String bleDeviceName = 'VoiceBox-CTRL';

const String defaultEsp32Ip = '192.168.4.1';
const int defaultEsp32Port = 81;
const String whisperModelFilename = 'ggml-base.bin';
const String whisperModelDownloadUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';

// ============================================================================
// PHONETIC BANGLA TO BANGLISH TRANSLITERATOR
// Converts Bengali Unicode script into clear Romanized Banglish.
// English words remain completely untouched.
// ============================================================================
class BanglishTranscriber {
  static final RegExp _banglaRegex = RegExp(r'[\u0980-\u09FF]');

  static bool containsBangla(String text) {
    return _banglaRegex.hasMatch(text);
  }

  // Exact high-frequency dictionary for common conversational & IoT commands
  static final Map<String, String> _phraseMap = {
    'আমি': 'ami',
    'তুমি': 'tumi',
    'আপনি': 'apni',
    'কেমন': 'kemon',
    'আছো': 'acho',
    'আছেন': 'achen',
    'ভালো': 'bhalo',
    'কি': 'ki',
    'কী': 'ki',
    'হ্যাঁ': 'ha',
    'না': 'na',
    'লাইট': 'light',
    'ফ্যান': 'fan',
    'অন': 'on',
    'অফ': 'off',
    'চালু': 'chalu',
    'বন্ধ': 'bondho',
    'করো': 'koro',
    'করুন': 'korun',
    'বলো': 'bolo',
    'বলুন': 'bolun',
    'শুনো': 'shuno',
    'শুনুন': 'shunun',
    'কোথায়': 'kothay',
    'কখন': 'kokhon',
    'কেন': 'keno',
    'ধন্যবাদ': 'dhonnobad',
    'স্বাগতম': 'shwagotom',
    'নাম': 'nam',
    'আমার': 'amar',
    'তোমার': 'tomar',
    'আপনার': 'apnar',
    'বাতি': 'bati',
    'পানি': 'pani',
    'খাবার': 'khabar',
    'গান': 'gan',
    'বাজাও': 'bajao',
    'থামো': 'thamo',
  };

  // Unicode character map
  static final Map<String, String> _vowels = {
    'অ': 'o',
    'আ': 'a',
    'ই': 'i',
    'ঈ': 'ee',
    'উ': 'u',
    'ঊ': 'oo',
    'ঋ': 'ri',
    'এ': 'e',
    'ঐ': 'oi',
    'ও': 'o',
    'ঔ': 'ou',
  };

  static final Map<String, String> _vowelSigns = {
    'া': 'a',
    'ি': 'i',
    'ী': 'ee',
    'ু': 'u',
    'ূ': 'oo',
    'ৃ': 'ri',
    'ে': 'e',
    'ৈ': 'oi',
    'ো': 'o',
    'ৌ': 'ou',
  };

  static final Map<String, String> _consonants = {
    'ক': 'k',
    'খ': 'kh',
    'গ': 'g',
    'ঘ': 'gh',
    'ঙ': 'ng',
    'চ': 'ch',
    'ছ': 'chh',
    'জ': 'j',
    'ঝ': 'jh',
    'ঞ': 'n',
    'ট': 't',
    'ঠ': 'th',
    'ড': 'd',
    'ঢ': 'dh',
    'ণ': 'n',
    'ত': 't',
    'থ': 'th',
    'দ': 'd',
    'ধ': 'dh',
    'ন': 'n',
    'প': 'p',
    'ফ': 'f',
    'ব': 'b',
    'ভ': 'bh',
    'ম': 'm',
    'য': 'j',
    'র': 'r',
    'ল': 'l',
    'শ': 'sh',
    'ষ': 'sh',
    'স': 's',
    'হ': 'h',
    'ড়': 'r',
    'ঢ়': 'rh',
    'য়': 'y',
    'ৎ': 't',
    'ং': 'ng',
    'ঃ': 'h',
    'ঁ': 'n',
  };

  static String convert(String input) {
    if (!containsBangla(input)) return input;

    final words = input.split(RegExp(r'\s+'));
    final List<String> convertedWords = [];

    for (final word in words) {
      if (word.isEmpty) continue;

      // Check dictionary match first
      final cleanWord = word.replaceAll(RegExp(r'[^\u0980-\u09FF]'), '');
      if (_phraseMap.containsKey(cleanWord)) {
        convertedWords.add(word.replaceAll(cleanWord, _phraseMap[cleanWord]!));
        continue;
      }

      // Phonetic character-by-character translation
      final buffer = StringBuffer();
      final runes = word.runes.toList();

      for (int i = 0; i < runes.length; i++) {
        final char = String.fromCharCode(runes[i]);

        if (_phraseMap.containsKey(char)) {
          buffer.write(_phraseMap[char]);
        } else if (_vowels.containsKey(char)) {
          buffer.write(_vowels[char]);
        } else if (_vowelSigns.containsKey(char)) {
          buffer.write(_vowelSigns[char]);
        } else if (_consonants.containsKey(char)) {
          buffer.write(_consonants[char]);

          // Handle implicit vowel 'o' if next char is not a vowel sign or hasant (্)
          if (i + 1 < runes.length) {
            final nextChar = String.fromCharCode(runes[i + 1]);
            if (!_vowelSigns.containsKey(nextChar) &&
                nextChar != '্' &&
                _consonants.containsKey(nextChar)) {
              buffer.write('o');
            }
          }
        } else if (char == '্') {
          // Halant: suppress inherent vowel (already handled)
          continue;
        } else {
          // Keep punctuation or English letters as-is
          buffer.write(char);
        }
      }
      convertedWords.add(buffer.toString());
    }

    return convertedWords.join(' ');
  }
}

// ============================================================================
// TRANSCRIPTION ITEM DATA MODEL
// ============================================================================
class TranscriptItem {
  final String text;
  final String language;
  final DateTime timestamp;
  final bool isBanglish;

  TranscriptItem({
    required this.text,
    required this.language,
    required this.timestamp,
    required this.isBanglish,
  });
}

// ============================================================================
// MAIN APPLICATION
// ============================================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceBoxApp());
}

class VoiceBoxApp extends StatelessWidget {
  const VoiceBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VoiceBox AI',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D6EFD),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: const VoiceHomeScreen(),
    );
  }
}

class VoiceHomeScreen extends StatefulWidget {
  const VoiceHomeScreen({super.key});

  @override
  State<VoiceHomeScreen> createState() => _VoiceHomeScreenState();
}

class _VoiceHomeScreenState extends State<VoiceHomeScreen>
    with SingleTickerProviderStateMixin {
  // Wi-Fi Configuration
  String espIp = defaultEsp32Ip;
  int espPort = defaultEsp32Port;
  WebSocket? _socket;
  StreamSubscription? _wifiSubscription;
  bool isWifiConnecting = false;
  bool isWifiConnected = false;
  int wifiBytesReceived = 0;
  DateTime? _lastPacketTime;

  // BLE Configuration
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _statusChar;
  BluetoothCharacteristic? _audioChar;
  StreamSubscription? _bleStatusSub;
  StreamSubscription? _bleAudioSub;
  StreamSubscription? _bleConnSub;
  bool isBleScanning = false;
  bool isBleConnected = false;

  // AI & Speech Engine
  final WhisperModelManager _modelManager = WhisperModelManager();
  WhisperEngine? _engine;
  bool isModelReady = false;
  bool isModelDownloading = false;
  double modelDownloadProgress = 0.0;
  String recognitionLang = 'auto'; // 'auto', 'en', 'bn'
  bool enableBanglishConversion = true;

  // Audio Pipeline & VAD State
  bool isListening = false;
  bool isProcessing = false;
  double currentAudioRms = 0.0;
  final List<int> _incomingPcmChunkBuffer = [];
  final List<int> _speechAudioBuffer = [];
  final Queue<Uint8List> _preRollFrames = Queue();

  bool _inSpeech = false;
  int _silentFramesCount = 0;

  static const int _frameBytes = 640; // 20ms @ 16kHz 16-bit mono
  static const int _silenceLimit = 45; // ~900ms silence marks sentence boundary
  static const double _vadThreshold = 550.0; // RMS energy gate

  // Transcripts & UI
  final List<TranscriptItem> transcripts = [];
  String statusMessage = 'Ready. Connect Wi-Fi or Bluetooth to start.';
  bool showMobileDataNotice = true;

  @override
  void initState() {
    super.initState();
    _checkExistingAiModel();
  }

  @override
  void dispose() {
    _disconnectAll();
    _engine?.dispose();
    _modelManager.close();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // MODEL MANAGEMENT
  // --------------------------------------------------------------------------
  Future<void> _checkExistingAiModel() async {
    try {
      final model = await _modelManager.find(whisperModelFilename);
      if (model != null && mounted) {
        final engine = await WhisperEngine.load(model.path);
        if (!mounted) {
          engine.dispose();
          return;
        }
        setState(() {
          _engine = engine;
          isModelReady = true;
          statusMessage = 'Offline AI Engine Ready (Multi-lingual)';
        });
      }
    } catch (_) {}
  }

  Future<void> _downloadModel() async {
    if (isModelDownloading) return;
    setState(() {
      isModelDownloading = true;
      modelDownloadProgress = 0.01;
      statusMessage = 'Connecting to model repository...';
    });

    try {
      final existing = await _modelManager.find(whisperModelFilename);
      if (existing != null) {
        _engine = await WhisperEngine.load(existing.path);
      } else {
        await for (final progress in _modelManager.download(
          Uri.parse(whisperModelDownloadUrl),
          whisperModelFilename,
        )) {
          if (!mounted) return;
          setState(() {
            modelDownloadProgress = progress.fraction;
            statusMessage =
                'Downloading Model: ${(progress.fraction * 100).toStringAsFixed(1)}%';
          });
        }
        final model = await _modelManager.find(whisperModelFilename);
        if (model == null) throw Exception('Model verification failed');
        _engine = await WhisperEngine.load(model.path);
      }

      if (!mounted) return;
      setState(() {
        isModelReady = true;
        isModelDownloading = false;
        statusMessage = 'AI Engine Initialized Successfully';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isModelDownloading = false;
        statusMessage = 'Model Error: $e';
      });
      _showToast('Model download error: $e');
    }
  }

  // --------------------------------------------------------------------------
  // ROBUST WI-FI WEBSOCKET CLIENT & DIAGNOSTICS
  // --------------------------------------------------------------------------
  Future<void> _connectWifi() async {
    if (isWifiConnected || isWifiConnecting) return;

    setState(() {
      isWifiConnecting = true;
      statusMessage = 'Probing TCP socket at $espIp:$espPort...';
    });

    try {
      // Pre-flight check: Verify host and port reachability quickly (3s)
      Socket testSocket;
      try {
        testSocket = await Socket.connect(
          espIp,
          espPort,
          timeout: const Duration(seconds: 4),
        );
        testSocket.destroy();
      } catch (tcpError) {
        throw Exception(
          'Cannot reach $espIp:$espPort.\n'
          '1. Ensure phone Wi-Fi is connected to "VoiceBox".\n'
          '2. Turn OFF Mobile Data (cellular) so Android does not block local traffic.',
        );
      }

      setState(() {
        statusMessage = 'Opening WebSocket stream...';
      });

      final wsUrl = 'ws://$espIp:$espPort/';
      _socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('WebSocket handshake timed out at $wsUrl'),
      );

      _socket!.pingInterval = const Duration(seconds: 3);

      _wifiSubscription?.cancel();
      _wifiSubscription = _socket!.listen(
        (data) {
          if (data is List<int>) {
            wifiBytesReceived += data.length;
            _lastPacketTime = DateTime.now();
            _processAudioChunk(Uint8List.fromList(data));
          } else if (data is String && mounted) {
            setState(() {
              statusMessage = 'ESP32 Status: $data';
            });
          }
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            isWifiConnected = false;
            statusMessage = 'Wi-Fi Connection Error: $err';
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            isWifiConnected = false;
            if (!isBleConnected) isListening = false;
            statusMessage = 'Wi-Fi Connection Closed';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        isWifiConnected = true;
        isWifiConnecting = false;
        statusMessage = 'Wi-Fi Streaming Connected ($espIp:$espPort)';
      });
      _showToast('Connected to ESP32 over Wi-Fi!');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isWifiConnecting = false;
        isWifiConnected = false;
        statusMessage = 'Wi-Fi Failed: $e';
      });
      _showErrorDialog('Wi-Fi Connection Failed', e.toString());
    }
  }

  void _disconnectWifi() {
    _wifiSubscription?.cancel();
    try {
      _socket?.close();
    } catch (_) {}
    setState(() {
      isWifiConnected = false;
      isWifiConnecting = false;
      statusMessage = 'Wi-Fi Disconnected';
    });
  }

  // --------------------------------------------------------------------------
  // BLUETOOTH LOW ENERGY (BLE) FALLBACK
  // --------------------------------------------------------------------------
  Future<void> _connectBle() async {
    if (isBleConnected || isBleScanning) return;

    setState(() {
      isBleScanning = true;
      statusMessage = 'Scanning for Bluetooth device "$bleDeviceName"...';
    });

    try {
      if (Platform.isAndroid) {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Please enable Bluetooth on your phone first.');
      }

      await FlutterBluePlus.startScan(
        withNames: [bleDeviceName],
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 8),
      );

      final scanResult = await FlutterBluePlus.scanResults
          .firstWhere((list) => list.any((r) =>
              r.advertisementData.advName == bleDeviceName ||
              r.device.platformName == bleDeviceName ||
              r.advertisementData.serviceUuids.contains(Guid(bleServiceUuid))))
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw TimeoutException(
              'Device "$bleDeviceName" not found. Please verify ESP32 is powered on.',
            ),
          );

      await FlutterBluePlus.stopScan();
      final matchedDevice = scanResult.firstWhere((r) =>
          r.advertisementData.advName == bleDeviceName ||
          r.device.platformName == bleDeviceName ||
          r.advertisementData.serviceUuids.contains(Guid(bleServiceUuid)));

      _bleDevice = matchedDevice.device;

      setState(() {
        statusMessage = 'Pairing with ${_bleDevice!.platformName}...';
      });

      await _bleDevice!.connect(timeout: const Duration(seconds: 10));

      try {
        await _bleDevice!.requestMtu(512);
      } catch (_) {}

      _bleConnSub?.cancel();
      _bleConnSub = _bleDevice!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            isBleConnected = false;
            if (!isWifiConnected) isListening = false;
            statusMessage = 'Bluetooth Disconnected';
          });
        }
      });

      final services = await _bleDevice!.discoverServices();
      for (final s in services) {
        if (s.uuid == Guid.fromString(bleServiceUuid) ||
            s.uuid == Guid(bleServiceUuid)) {
          for (final c in s.characteristics) {
            if (c.uuid == Guid.fromString(bleCommandUuid) ||
                c.uuid == Guid(bleCommandUuid)) {
              _commandChar = c;
            }
            if (c.uuid == Guid.fromString(bleStatusUuid) ||
                c.uuid == Guid(bleStatusUuid)) {
              _statusChar = c;
            }
            if (c.uuid == Guid.fromString(bleAudioUuid) ||
                c.uuid == Guid(bleAudioUuid)) {
              _audioChar = c;
            }
          }
        }
      }

      if (_commandChar == null) {
        throw Exception('Command characteristic not found on BLE device');
      }

      if (_statusChar != null) {
        await _statusChar!.setNotifyValue(true);
        _bleStatusSub?.cancel();
        _bleStatusSub = _statusChar!.onValueReceived.listen((bytes) {
          if (bytes.isNotEmpty && mounted) {
            setState(() {
              statusMessage = 'ESP32 Status: ${String.fromCharCodes(bytes)}';
            });
          }
        });
      }

      if (_audioChar != null) {
        await _audioChar!.setNotifyValue(true);
        _bleAudioSub?.cancel();
        _bleAudioSub = _audioChar!.onValueReceived.listen((bytes) {
          if (!isWifiConnected && bytes.isNotEmpty) {
            _processAudioChunk(Uint8List.fromList(bytes));
          }
        });
      }

      if (!mounted) return;
      setState(() {
        isBleConnected = true;
        isBleScanning = false;
        statusMessage = 'Bluetooth Connected & Ready';
      });
      _showToast('Connected to ESP32 via Bluetooth!');
    } catch (e) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        isBleScanning = false;
        isBleConnected = false;
        statusMessage = 'BLE Error: $e';
      });
      _showToast('BLE Connection failed: $e');
    }
  }

  void _disconnectBle() {
    _bleStatusSub?.cancel();
    _bleAudioSub?.cancel();
    _bleConnSub?.cancel();
    try {
      _bleDevice?.disconnect();
    } catch (_) {}
    setState(() {
      isBleConnected = false;
      isBleScanning = false;
      statusMessage = 'Bluetooth Disconnected';
    });
  }

  void _disconnectAll() {
    _sendDeviceCommand('STOP');
    _disconnectWifi();
    _disconnectBle();
    setState(() {
      isListening = false;
      statusMessage = 'All Transports Disconnected';
    });
  }

  // --------------------------------------------------------------------------
  // AUDIO SAMPLING & VOICE ACTIVITY DETECTION (VAD)
  // --------------------------------------------------------------------------
  Future<void> _sendDeviceCommand(String cmd) async {
    try {
      if (_commandChar != null) {
        await _commandChar!.write(cmd.codeUnits);
      }
      _socket?.add(cmd);
    } catch (_) {}
  }

  Future<void> _startListening() async {
    if (!isModelReady) {
      _showToast('Please download the AI Model first.');
      return;
    }
    if (!isWifiConnected && !isBleConnected) {
      _showToast('Connect either Wi-Fi OR Bluetooth first.');
      return;
    }

    _incomingPcmChunkBuffer.clear();
    _speechAudioBuffer.clear();
    _preRollFrames.clear();
    _inSpeech = false;
    _silentFramesCount = 0;

    await _sendDeviceCommand('START');

    setState(() {
      isListening = true;
      statusMessage = 'Listening for speech from ESP32 mic...';
    });
  }

  Future<void> _stopListening() async {
    await _sendDeviceCommand('STOP');
    setState(() {
      isListening = false;
      currentAudioRms = 0.0;
      statusMessage = 'Stopped listening.';
    });
  }

  void _processAudioChunk(Uint8List chunk) {
    if (!isListening || isProcessing) return;

    _incomingPcmChunkBuffer.addAll(chunk);

    if (_incomingPcmChunkBuffer.length > 64000) {
      _incomingPcmChunkBuffer.clear();
      return;
    }

    while (_incomingPcmChunkBuffer.length >= _frameBytes) {
      final frame = Uint8List.fromList(
        _incomingPcmChunkBuffer.sublist(0, _frameBytes),
      );
      _incomingPcmChunkBuffer.removeRange(0, _frameBytes);
      _evaluateFrameVad(frame);
    }
  }

  void _evaluateFrameVad(Uint8List frame) {
    final byteData = ByteData.sublistView(frame);
    double energySum = 0;

    for (int i = 0; i < frame.length; i += 2) {
      final sample = byteData.getInt16(i, Endian.little);
      energySum += sample * sample;
    }

    final double rms = sqrt(energySum / (frame.length ~/ 2));

    // Update real-time RMS meter for visualizer
    if (mounted && (rms - currentAudioRms).abs() > 30) {
      setState(() {
        currentAudioRms = rms;
      });
    }

    final bool isVoice = rms > _vadThreshold;

    _preRollFrames.add(frame);
    if (_preRollFrames.length > 10) {
      _preRollFrames.removeFirst();
    }

    if (isVoice) {
      if (!_inSpeech) {
        _inSpeech = true;
        for (final old in _preRollFrames) {
          _speechAudioBuffer.addAll(old);
        }
      } else {
        _speechAudioBuffer.addAll(frame);
      }
      _silentFramesCount = 0;
    } else if (_inSpeech) {
      _speechAudioBuffer.addAll(frame);
      _silentFramesCount++;

      if (_silentFramesCount >= _silenceLimit) {
        _inSpeech = false;
        _silentFramesCount = 0;
        _preRollFrames.clear();
        unawaited(_transcribeSpeechBuffer());
      }
    }
  }

  Uint8List _buildWavHeader(List<int> pcmData) {
    final header = ByteData(44);

    void writeString(int offset, String str) {
      for (int i = 0; i < str.length; i++) {
        header.setUint8(offset + i, str.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    header.setUint32(4, pcmData.length + 36, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM Format
    header.setUint16(22, 1, Endian.little); // 1 Channel Mono
    header.setUint32(24, 16000, Endian.little); // 16kHz
    header.setUint32(28, 32000, Endian.little); // Byte rate (16000 * 2)
    header.setUint16(32, 2, Endian.little); // Block align
    header.setUint16(34, 16, Endian.little); // 16 bits per sample
    writeString(36, 'data');
    header.setUint32(40, pcmData.length, Endian.little);

    final wav = Uint8List(44 + pcmData.length);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + pcmData.length, pcmData);
    return wav;
  }

  Future<void> _transcribeSpeechBuffer() async {
    if (_speechAudioBuffer.isEmpty || isProcessing || _engine == null) return;

    isProcessing = true;
    final pcmSamples = List<int>.from(_speechAudioBuffer);
    _speechAudioBuffer.clear();

    // Discard noise clicks < 350ms
    if (pcmSamples.length < 11200) {
      isProcessing = false;
      return;
    }

    if (!mounted) {
      isProcessing = false;
      return;
    }

    setState(() {
      statusMessage = 'Transcribing speech with on-device AI...';
    });

    try {
      final wavBytes = _buildWavHeader(pcmSamples);
      final Float32List floatAudio = WhisperAudio.decodeWav(wavBytes);

      final task = _engine!.transcribe(
        floatAudio,
        options: TranscribeOptions(
          language: recognitionLang,
        ).withPerformanceMode(WhisperPerformanceMode.efficient),
      );

      final result = await task.result;
      if (!mounted) return;

      final rawText = result.text.trim();
      if (rawText.isNotEmpty) {
        String displayText = rawText;
        bool isBanglish = false;

        // Automatically convert to Banglish if Bengali characters are present
        if (enableBanglishConversion && BanglishTranscriber.containsBangla(rawText)) {
          displayText = BanglishTranscriber.convert(rawText);
          isBanglish = true;
        }

        setState(() {
          transcripts.insert(
            0,
            TranscriptItem(
              text: displayText,
              language: isBanglish ? 'Banglish' : 'English',
              timestamp: DateTime.now(),
              isBanglish: isBanglish,
            ),
          );
        });
      }

      setState(() {
        statusMessage = isListening ? 'Listening...' : 'Transcribe completed';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          statusMessage = 'Recognition Error: $e';
        });
      }
    } finally {
      isProcessing = false;
    }
  }

  // --------------------------------------------------------------------------
  // UI HELPERS & DIALOGS
  // --------------------------------------------------------------------------
  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _openWifiSettingsSheet() {
    final ipController = TextEditingController(text: espIp);
    final portController = TextEditingController(text: espPort.toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          left: 20,
          right: 20,
          top: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi_tethering, color: Colors.blueAccent),
                const SizedBox(width: 10),
                Text(
                  'Wi-Fi WebSocket Settings',
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'ESP32 IP Address',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.network_check),
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                labelText: 'Port Number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.numbers),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('VoiceBox AP (192.168.4.1:81)'),
                  onPressed: () {
                    ipController.text = '192.168.4.1';
                    portController.text = '81';
                  },
                ),
                ActionChip(
                  label: const Text('Local Router Preset'),
                  onPressed: () {
                    ipController.text = '192.168.1.100';
                    portController.text = '81';
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  espIp = ipController.text.trim();
                  espPort = int.tryParse(portController.text.trim()) ?? 81;
                });
                Navigator.pop(ctx);
                _connectWifi();
              },
              icon: const Icon(Icons.save),
              label: const Text('Save & Connect'),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // BUILD METHOD & INTERFACE
  // --------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bool anyConnected = isWifiConnected || isBleConnected;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'VoiceBox Edge-AI',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              anyConnected
                  ? (isWifiConnected ? 'Active: Wi-Fi WebSocket' : 'Active: Bluetooth BLE')
                  : 'Hardware Disconnected',
              style: TextStyle(
                fontSize: 12,
                color: anyConnected ? Colors.greenAccent : Colors.grey,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_ethernet),
            tooltip: 'Wi-Fi IP Settings',
            onPressed: _openWifiSettingsSheet,
          ),
          PopupMenuButton<String>(
            tooltip: 'Language Mode',
            initialValue: recognitionLang,
            onSelected: (val) => setState(() => recognitionLang = val),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'auto',
                child: Text('Auto Detect (English + Bangla)'),
              ),
              const PopupMenuItem(
                value: 'en',
                child: Text('English Only'),
              ),
              const PopupMenuItem(
                value: 'bn',
                child: Text('Bangla ➔ Banglish Mode'),
              ),
            ],
            icon: const Icon(Icons.translate),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Android No-Internet Advisory Banner
            if (showMobileDataNotice)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Tip: If connecting to "VoiceBox" Wi-Fi, turn off Mobile Data so Android doesn\'t block local traffic.',
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => setState(() => showMobileDataNotice = false),
                    ),
                  ],
                ),
              ),

            // Live Hardware Status Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Card(
                elevation: 0,
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : Colors.grey.withOpacity(0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isListening
                                  ? Colors.red.withOpacity(0.15)
                                  : theme.colorScheme.primary.withOpacity(0.1),
                            ),
                            child: Icon(
                              isListening ? Icons.graphic_eq : Icons.mic_none,
                              color: isListening
                                  ? Colors.redAccent
                                  : theme.colorScheme.primary,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isListening ? 'Streaming & Listening' : 'Device Idle',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  statusMessage,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      // Audio Energy Meter (VU level)
                      if (isListening) ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Text('MIC LEVEL',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: (currentAudioRms / 1500).clamp(0.0, 1.0),
                                  minHeight: 8,
                                  backgroundColor: isDark
                                      ? Colors.grey.shade800
                                      : Colors.grey.shade200,
                                  valueColor: AlwaysStoppedAnimation(
                                    currentAudioRms > _vadThreshold
                                        ? Colors.greenAccent
                                        : Colors.blueAccent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],

                      const Divider(height: 24),

                      // Transport badges
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildChipBadge(
                            label: 'Wi-Fi Socket',
                            active: isWifiConnected,
                            icon: Icons.wifi,
                          ),
                          _buildChipBadge(
                            label: 'Bluetooth',
                            active: isBleConnected,
                            icon: Icons.bluetooth,
                          ),
                          _buildChipBadge(
                            label: 'Whisper AI',
                            active: isModelReady,
                            icon: Icons.smart_toy_outlined,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Transport Control Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: isWifiConnected ? _disconnectWifi : _connectWifi,
                      icon: Icon(
                        isWifiConnected ? Icons.wifi_off : Icons.wifi,
                        color: isWifiConnected ? Colors.red : Colors.blue,
                      ),
                      label: Text(
                        isWifiConnecting
                            ? 'Connecting...'
                            : (isWifiConnected ? 'Disconnect Wi-Fi' : 'Connect Wi-Fi'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: isBleConnected ? _disconnectBle : _connectBle,
                      icon: Icon(
                        isBleConnected ? Icons.bluetooth_disabled : Icons.bluetooth,
                        color: isBleConnected ? Colors.red : Colors.blue,
                      ),
                      label: Text(
                        isBleScanning
                            ? 'Scanning...'
                            : (isBleConnected ? 'Disconnect BLE' : 'Connect BLE'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Model Download if not ready
            if (!isModelReady)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: isModelDownloading ? null : _downloadModel,
                  icon: const Icon(Icons.download_for_offline),
                  label: Text(
                    isModelDownloading
                        ? 'Downloading (${(modelDownloadProgress * 100).toStringAsFixed(0)}%)'
                        : 'Download AI Model (Offline Engine)',
                  ),
                ),
              ),

            // Start / Stop Microphone Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: isListening
                        ? Colors.redAccent
                        : (anyConnected
                            ? const Color(0xFF0D6EFD)
                            : Colors.grey.shade400),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: anyConnected && isModelReady
                      ? (isListening ? _stopListening : _startListening)
                      : null,
                  icon: Icon(isListening ? Icons.stop_circle : Icons.play_circle_fill),
                  label: Text(
                    isListening
                        ? 'STOP STREAMING / RECORDING'
                        : (anyConnected
                            ? 'START LISTENING (ESP32 MIC)'
                            : 'CONNECT WI-FI OR BLE TO START'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),

            // Transcripts Header & Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 16, 4),
              child: Row(
                children: [
                  const Text(
                    'Transcriptions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      enableBanglishConversion ? 'Banglish Auto-Convert' : 'Bangla Script',
                      style: const TextStyle(fontSize: 11, color: Colors.blueAccent),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Clear Transcripts',
                    onPressed: transcripts.isEmpty
                        ? null
                        : () => setState(() => transcripts.clear()),
                  ),
                ],
              ),
            ),

            // Transcripts List View
            Expanded(
              child: transcripts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.speaker_notes_outlined,
                              size: 48, color: Colors.grey.shade400),
                          const SizedBox(height: 10),
                          Text(
                            'No voice transcriptions yet',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Speak into ESP32 mic. English will print in English,\nBangla will automatically convert to Banglish!',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      itemCount: transcripts.length,
                      itemBuilder: (ctx, index) {
                        final item = transcripts[index];
                        final timeStr =
                            '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}:${item.timestamp.second.toString().padLeft(2, '0')}';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF334155)
                                  : Colors.grey.withOpacity(0.2),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: item.isBanglish
                                          ? Colors.orange.withOpacity(0.15)
                                          : Colors.green.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      item.language,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: item.isBanglish
                                            ? Colors.orange
                                            : Colors.green,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    timeStr,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    tooltip: 'Copy Text',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(text: item.text),
                                      );
                                      _showToast('Copied to clipboard');
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              SelectableText(
                                item.text,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChipBadge({
    required String label,
    required bool active,
    required IconData icon,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? Colors.greenAccent : Colors.grey,
          ),
        ),
        const SizedBox(width: 6),
        Icon(icon, size: 14, color: active ? Colors.green : Colors.grey),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? null : Colors.grey,
          ),
        ),
      ],
    );
  }
}
