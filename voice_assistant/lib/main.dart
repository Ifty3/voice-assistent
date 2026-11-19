import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

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

// Lightweight Vosk Models (~40MB, 1/4 the size of Whisper)
const String voskEnglishAsset = 'assets/models/vosk-model-small-en-us-0.15.zip';
const String voskEnglishUrl =
    'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';

const String voskBanglaAsset = 'assets/models/vosk-model-small-streaming-bn.zip';
const String voskBanglaUrl =
    'https://alphacephei.com/vosk/models/vosk-model-small-streaming-bn.zip';

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

      final cleanWord = word.replaceAll(RegExp(r'[^\u0980-\u09FF]'), '');
      if (_phraseMap.containsKey(cleanWord)) {
        convertedWords.add(word.replaceAll(cleanWord, _phraseMap[cleanWord]!));
        continue;
      }

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

          if (i + 1 < runes.length) {
            final nextChar = String.fromCharCode(runes[i + 1]);
            if (!_vowelSigns.containsKey(nextChar) &&
                nextChar != '্' &&
                _consonants.containsKey(nextChar)) {
              buffer.write('o');
            }
          }
        } else if (char == '্') {
          continue;
        } else {
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
      title: 'VoiceBox Vosk AI',
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

class _VoiceHomeScreenState extends State<VoiceHomeScreen> {
  // Wi-Fi Configuration
  String espIp = defaultEsp32Ip;
  int espPort = defaultEsp32Port;
  WebSocket? _socket;
  StreamSubscription? _wifiSubscription;
  bool isWifiConnecting = false;
  bool isWifiConnected = false;
  int wifiBytesReceived = 0;

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

  // Vosk Engine
  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  Model? _voskModel;
  Recognizer? _recognizer;
  bool isEngineReady = false;
  bool isEngineLoading = false;
  String currentLanguage = 'en'; // 'en' or 'bn'
  String livePartialText = '';

  // Audio Pipeline
  bool isListening = false;
  double currentAudioRms = 0.0;
  final List<TranscriptItem> transcripts = [];
  String statusMessage = 'Vosk Offline Engine Initializing...';
  bool showMobileDataNotice = true;

  @override
  void initState() {
    super.initState();
    _initVoskEngine();
  }

  @override
  void dispose() {
    _disconnectAll();
    _recognizer?.dispose();
    _voskModel?.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // VOSK ENGINE SETUP & MODEL LOADING
  // --------------------------------------------------------------------------
  Future<void> _initVoskEngine() async {
    setState(() {
      isEngineLoading = true;
      statusMessage = 'Loading Vosk Engine ($currentLanguage)...';
    });

    try {
      await _recognizer?.dispose();
      _voskModel?.dispose();
      _recognizer = null;
      _voskModel = null;

      final isBangla = currentLanguage == 'bn';
      final assetPath = isBangla ? voskBanglaAsset : voskEnglishAsset;
      final networkUrl = isBangla ? voskBanglaUrl : voskEnglishUrl;

      String? modelPath;

      // 1. Check if model is bundled in assets, fallback to network
      try {
        modelPath = await ModelLoader().loadFromAssets(assetPath);
      } catch (_) {
        modelPath = await ModelLoader().loadFromNetwork(networkUrl);
      }

      _voskModel = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _voskModel!,
        sampleRate: 16000,
      );

      if (!mounted) return;
      setState(() {
        isEngineReady = true;
        isEngineLoading = false;
        statusMessage =
            'Vosk Engine Ready (${currentLanguage == 'en' ? 'English' : 'Bangla ➔ Banglish'})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isEngineLoading = false;
        isEngineReady = false;
        statusMessage = 'Vosk Load Error: $e';
      });
      _showToast('Vosk Init Error: $e');
    }
  }

  void _switchLanguage(String newLang) {
    if (currentLanguage == newLang) return;
    setState(() {
      currentLanguage = newLang;
    });
    _initVoskEngine();
  }

  void _handleVoskPartialJson(String partialJson) {
    try {
      final Map<String, dynamic> data = jsonDecode(partialJson);
      final partial = (data['partial'] as String? ?? '').trim();
      if (mounted && partial.isNotEmpty) {
        setState(() {
          livePartialText = currentLanguage == 'bn'
              ? BanglishTranscriber.convert(partial)
              : partial;
        });
      }
    } catch (_) {}
  }

  void _handleVoskResultJson(String resultJson) {
    try {
      final Map<String, dynamic> data = jsonDecode(resultJson);
      final text = (data['text'] as String? ?? '').trim();
      if (mounted && text.isNotEmpty) {
        String outputText = text;
        bool isBanglish = false;

        if (currentLanguage == 'bn' || BanglishTranscriber.containsBangla(text)) {
          outputText = BanglishTranscriber.convert(text);
          isBanglish = true;
        }

        setState(() {
          livePartialText = '';
          transcripts.insert(
            0,
            TranscriptItem(
              text: outputText,
              language: isBanglish ? 'Banglish' : 'English',
              timestamp: DateTime.now(),
              isBanglish: isBanglish,
            ),
          );
        });
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // WI-FI WEBSOCKET CLIENT & PRE-FLIGHT PROBE
  // --------------------------------------------------------------------------
  Future<void> _connectWifi() async {
    if (isWifiConnected || isWifiConnecting) return;

    setState(() {
      isWifiConnecting = true;
      statusMessage = 'Checking connection at $espIp:$espPort...';
    });

    try {
      Socket testSocket;
      try {
        testSocket = await Socket.connect(
          espIp,
          espPort,
          timeout: const Duration(seconds: 4),
        );
        testSocket.destroy();
      } catch (_) {
        throw Exception(
          'Cannot reach $espIp:$espPort.\n'
          '1. Ensure phone Wi-Fi is connected to "VoiceBox".\n'
          '2. Turn OFF Mobile Data (cellular) so Android does not route to LTE/5G.',
        );
      }

      setState(() {
        statusMessage = 'Connecting WebSocket...';
      });

      final wsUrl = 'ws://$espIp:$espPort/';
      _socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Handshake timeout at $wsUrl'),
      );

      _socket!.pingInterval = const Duration(seconds: 3);

      _wifiSubscription?.cancel();
      _wifiSubscription = _socket!.listen(
        (data) {
          if (data is List<int>) {
            wifiBytesReceived += data.length;
            _feedAudioChunkToVosk(Uint8List.fromList(data));
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
            statusMessage = 'Wi-Fi Socket Error: $err';
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
        statusMessage = 'Wi-Fi Streaming Active ($espIp:$espPort)';
      });
      _showToast('Wi-Fi Connected successfully!');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isWifiConnecting = false;
        isWifiConnected = false;
        statusMessage = 'Wi-Fi Failed: $e';
      });
      _showErrorDialog('Wi-Fi Connection Notice', e.toString());
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
      statusMessage = 'Scanning for Bluetooth "$bleDeviceName"...';
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
      final matched = scanResult.firstWhere((r) =>
          r.advertisementData.advName == bleDeviceName ||
          r.device.platformName == bleDeviceName ||
          r.advertisementData.serviceUuids.contains(Guid(bleServiceUuid)));

      _bleDevice = matched.device;

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
            _feedAudioChunkToVosk(Uint8List.fromList(bytes));
          }
        });
      }

      if (!mounted) return;
      setState(() {
        isBleConnected = true;
        isBleScanning = false;
        statusMessage = 'Bluetooth Connected & Ready';
      });
      _showToast('Bluetooth Connected!');
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
      statusMessage = 'All Disconnected';
    });
  }

  // --------------------------------------------------------------------------
  // LIVE VOSK AUDIO FEEDING (REAL-TIME STREAMING)
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
    if (!isEngineReady) {
      _showToast('Vosk engine is still initializing...');
      return;
    }
    if (!isWifiConnected && !isBleConnected) {
      _showToast('Connect either Wi-Fi OR Bluetooth first.');
      return;
    }

    await _sendDeviceCommand('START');

    setState(() {
      isListening = true;
      livePartialText = '';
      statusMessage = 'Live streaming mic data into Vosk Engine...';
    });
  }

  Future<void> _stopListening() async {
    await _sendDeviceCommand('STOP');
    setState(() {
      isListening = false;
      currentAudioRms = 0.0;
      livePartialText = '';
      statusMessage = 'Listening stopped';
    });
  }

  Future<void> _feedAudioChunkToVosk(Uint8List pcmChunk) async {
    if (!isListening || _recognizer == null) return;

    // Calculate RMS volume for visual meter
    final byteData = ByteData.sublistView(pcmChunk);
    double energy = 0;
    for (int i = 0; i < pcmChunk.length; i += 2) {
      final sample = byteData.getInt16(i, Endian.little);
      energy += sample * sample;
    }
    final double rms = sqrt(energy / (pcmChunk.length ~/ 2));
    if (mounted && (rms - currentAudioRms).abs() > 25) {
      setState(() {
        currentAudioRms = rms;
      });
    }

    // Direct Real-time Streaming into Vosk
    try {
      final bool hasResult = await _recognizer!.acceptWaveformBytes(pcmChunk);
      if (hasResult) {
        final resultJson = await _recognizer!.getResult();
        _handleVoskResultJson(resultJson);
      } else {
        final partialJson = await _recognizer!.getPartialResult();
        _handleVoskPartialJson(partialJson);
      }
    } catch (_) {}
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
                  label: const Text('Home Router Preset'),
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
  // MAIN BUILD
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
              'VoiceBox (Vosk Engine)',
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
            initialValue: currentLanguage,
            onSelected: _switchLanguage,
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'en',
                child: Text('English (Vosk English)'),
              ),
              const PopupMenuItem(
                value: 'bn',
                child: Text('Bangla ➔ Banglish (Vosk Bengali)'),
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
                  color: Colors.amber.withAlpha(38),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withAlpha(100)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Tip: If connecting to "VoiceBox" Wi-Fi, turn off Mobile Data so Android does not block local socket traffic.',
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
                        : Colors.grey.withAlpha(50),
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
                                  ? Colors.red.withAlpha(38)
                                  : theme.colorScheme.primary.withAlpha(25),
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
                                  isListening ? 'Streaming & Live Typing' : 'Device Idle',
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

                      // Audio VU Meter
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
                                    currentAudioRms > 550
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
                            label: 'Vosk Engine',
                            active: isEngineReady,
                            icon: Icons.memory,
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

            // Start / Stop Listening Button
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
                  onPressed: anyConnected && isEngineReady
                      ? (isListening ? _stopListening : _startListening)
                      : null,
                  icon: Icon(isListening ? Icons.stop_circle : Icons.play_circle_fill),
                  label: Text(
                    isListening
                        ? 'STOP STREAMING / RECORDING'
                        : (anyConnected
                            ? 'START VOSK LISTENING'
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

            // Live Partial Typing Bubble
            if (livePartialText.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.withAlpha(75)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.record_voice_over,
                        color: Colors.blueAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        livePartialText,
                        style: const TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ),
                  ],
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
                      color: Colors.blue.withAlpha(38),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      currentLanguage == 'bn' ? 'Banglish Output' : 'English Output',
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
                            'Powered by Vosk Offline Engine.\nAudio from ESP32 is processed in real time!',
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
                                  : Colors.grey.withAlpha(50),
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
                                          ? Colors.orange.withAlpha(38)
                                          : Colors.green.withAlpha(38),
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
