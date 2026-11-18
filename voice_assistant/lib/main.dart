import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

const String serviceId = '12345678-1234-1234-1234-123456789000';
const String commandId = '12345678-1234-1234-1234-123456789001';
const String statusId = '12345678-1234-1234-1234-123456789002';
const String audioId = '12345678-1234-1234-1234-123456789003'; // BLE Audio Stream
const String deviceTargetName = 'VoiceBox-CTRL';
const String webSocketUrl = 'ws://192.168.4.1:81/';
const String whisperModelName = 'ggml-base.bin';
const String whisperModelUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceApp());
}

class VoiceApp extends StatelessWidget {
  const VoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Voice Assistant (Dual Transport)',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const VoiceHome(),
    );
  }
}

class VoiceHome extends StatefulWidget {
  const VoiceHome({super.key});

  @override
  State<VoiceHome> createState() => _VoiceHomeState();
}

class _VoiceHomeState extends State<VoiceHome> {
  // BLE Handles
  BluetoothDevice? device;
  BluetoothCharacteristic? command;
  BluetoothCharacteristic? statusChar;
  BluetoothCharacteristic? audioChar;

  StreamSubscription? bleSubscription;
  StreamSubscription? bleAudioSubscription;
  StreamSubscription? bleConnectionSubscription;
  StreamSubscription? wifiSubscription;

  WebSocket? socket;

  final WhisperModelManager modelManager = WhisperModelManager();
  WhisperEngine? engine;

  bool bleConnected = false;
  bool wifiConnected = false;
  bool modelReady = false;
  bool listening = false;
  bool processing = false;

  double downloadProgress = 0;
  String selectedLanguage = 'auto'; // 'auto', 'bn', or 'en'

  String status = 'Download AI Model to begin';
  String recognizedText = '';

  // Incoming chunk assembly buffer (handles both Wi-Fi and BLE packet sizes)
  final List<int> incomingBuffer = [];
  final List<int> audioBuffer = [];
  final Queue<Uint8List> preRoll = Queue();

  bool speechStarted = false;
  int silentFrames = 0;

  // 16kHz, 16-bit mono PCM = 32,000 bytes/sec
  // 640 bytes = 320 samples = 20ms per frame
  static const int frameBytes = 640;
  static const int silenceLimit = 45; // ~900ms silence ends utterance
  static const double threshold = 550; // RMS energy threshold for speech

  @override
  void initState() {
    super.initState();
    _checkExistingModel();
  }

  // ---------------------------------
  // MODEL MANAGEMENT
  // ---------------------------------

  Future<void> _checkExistingModel() async {
    try {
      final existing = await modelManager.find(whisperModelName);
      if (existing != null && mounted) {
        final loadedEngine = await WhisperEngine.load(existing.path);
        if (!mounted) {
          loadedEngine.dispose();
          return;
        }
        setState(() {
          engine = loadedEngine;
          modelReady = true;
          status = 'Whisper Ready (Offline)';
        });
      }
    } catch (_) {
      // Model not yet downloaded; wait for user to click download
    }
  }

  Future<void> downloadModel() async {
    try {
      setState(() {
        status = 'Checking Whisper Base model...';
        downloadProgress = 0.01;
      });

      final existing = await modelManager.find(whisperModelName);

      if (existing != null) {
        final loadedEngine = await WhisperEngine.load(existing.path);
        if (!mounted) {
          loadedEngine.dispose();
          return;
        }
        engine = loadedEngine;
      } else {
        setState(() {
          status = 'Downloading multilingual Whisper model...';
        });

        await for (final progress in modelManager.download(
          Uri.parse(whisperModelUrl),
          whisperModelName,
        )) {
          if (!mounted) return;
          setState(() {
            downloadProgress = progress.fraction;
            status =
                'Downloading model: ${(progress.fraction * 100).toStringAsFixed(1)}%';
          });
        }

        final model = await modelManager.find(whisperModelName);
        if (model == null) {
          throw Exception('Model file verification failed after download');
        }

        final loadedEngine = await WhisperEngine.load(model.path);
        if (!mounted) {
          loadedEngine.dispose();
          return;
        }
        engine = loadedEngine;
      }

      if (!mounted) return;
      setState(() {
        modelReady = true;
        downloadProgress = 1.0;
        status = 'Whisper Ready (Bengali + English)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Model Error: $e';
        downloadProgress = 0;
      });
    }
  }

  // ---------------------------------
  // BLE PERMISSIONS, SCAN AND CONNECT
  // ---------------------------------

  Future<void> connectBLE() async {
    try {
      setState(() {
        status = 'Requesting Bluetooth permissions...';
      });

      if (Platform.isAndroid) {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Please turn on Bluetooth first');
      }

      setState(() {
        status = 'Scanning for $deviceTargetName...';
      });

      // Filter by name and Service UUID for Android and iOS compatibility
      await FlutterBluePlus.startScan(
        withNames: [deviceTargetName],
        withServices: [Guid(serviceId)],
        timeout: const Duration(seconds: 10),
      );

      final results = await FlutterBluePlus.scanResults
          .firstWhere(
            (list) => list.any(
              (r) =>
                  r.advertisementData.advName == deviceTargetName ||
                  r.device.platformName == deviceTargetName ||
                  r.advertisementData.serviceUuids.contains(Guid(serviceId)),
            ),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Device "$deviceTargetName" not found. Ensure it is powered on.',
            ),
          );

      await FlutterBluePlus.stopScan();

      final result = results.firstWhere(
        (r) =>
            r.advertisementData.advName == deviceTargetName ||
            r.device.platformName == deviceTargetName ||
            r.advertisementData.serviceUuids.contains(Guid(serviceId)),
      );

      device = result.device;

      setState(() {
        status =
            'Connecting to BLE (${device!.platformName.isNotEmpty ? device!.platformName : deviceTargetName})...';
      });

      await device!.connect(timeout: const Duration(seconds: 15));

      // Request maximum MTU for high-speed BLE audio transfer
      try {
        await device!.requestMtu(512);
      } catch (_) {}

      bleConnectionSubscription?.cancel();
      bleConnectionSubscription = device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            bleConnected = false;
            if (!wifiConnected) {
              listening = false;
            }
            status = 'BLE Disconnected';
          });
        }
      });

      final services = await device!.discoverServices();

      command = null;
      statusChar = null;
      audioChar = null;

      for (final service in services) {
        if (service.uuid == Guid.fromString(serviceId) ||
            service.uuid == Guid(serviceId)) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == Guid.fromString(commandId) ||
                characteristic.uuid == Guid(commandId)) {
              command = characteristic;
            }
            if (characteristic.uuid == Guid.fromString(statusId) ||
                characteristic.uuid == Guid(statusId)) {
              statusChar = characteristic;
            }
            if (characteristic.uuid == Guid.fromString(audioId) ||
                characteristic.uuid == Guid(audioId)) {
              audioChar = characteristic;
            }
          }
        }
      }

      if (command == null) {
        throw Exception('Command characteristic not found on device');
      }

      // Listen for BLE status updates
      if (statusChar != null) {
        await statusChar!.setNotifyValue(true);
        bleSubscription?.cancel();
        bleSubscription = statusChar!.onValueReceived.listen((value) {
          if (value.isNotEmpty && mounted) {
            setState(() {
              status = 'BLE Status: ${String.fromCharCodes(value)}';
            });
          }
        });
      }

      // Listen for BLE audio stream (active if Wi-Fi is not connected)
      if (audioChar != null) {
        await audioChar!.setNotifyValue(true);
        bleAudioSubscription?.cancel();
        bleAudioSubscription = audioChar!.onValueReceived.listen((value) {
          if (!wifiConnected && value.isNotEmpty) {
            receiveAudioChunk(Uint8List.fromList(value));
          }
        });
      }

      if (!mounted) return;
      setState(() {
        bleConnected = true;
        status = 'BLE Connected (Audio & Control Ready)';
      });
    } catch (e) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        status = 'BLE Error: $e';
        bleConnected = false;
      });
    }
  }

  // ---------------------------------
  // WIFI WEBSOCKET AUDIO & CONTROL
  // ---------------------------------

  Future<void> connectWiFi() async {
    try {
      setState(() {
        status = 'Connecting to Wi-Fi ($webSocketUrl)...';
      });

      socket = await WebSocket.connect(webSocketUrl).timeout(
        const Duration(seconds: 7),
        onTimeout: () => throw TimeoutException(
          'Could not reach $webSocketUrl. Please connect your phone to the VoiceBox Wi-Fi network first.',
        ),
      );

      wifiSubscription?.cancel();
      wifiSubscription = socket!.listen(
        (event) {
          if (event is List<int>) {
            // Wi-Fi binary audio stream
            receiveAudioChunk(Uint8List.fromList(event));
          } else if (event is String && mounted) {
            // Wi-Fi text message / status
            setState(() {
              status = 'Wi-Fi Status: $event';
            });
          }
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              wifiConnected = false;
              if (!bleConnected) {
                listening = false;
              }
              status = 'Wi-Fi Socket Error: $e';
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              wifiConnected = false;
              if (!bleConnected) {
                listening = false;
              }
              status = 'Wi-Fi Audio Socket Closed';
            });
          }
        },
      );

      if (!mounted) return;
      setState(() {
        wifiConnected = true;
        status = 'Wi-Fi Connected (Audio & Control Ready)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        wifiConnected = false;
        status = 'Wi-Fi Error: $e';
      });
    }
  }

  // ---------------------------------
  // START / STOP VOICE CONTROL (DUAL TRANSPORT)
  // ---------------------------------

  Future<void> startVoice() async {
    // Either Wi-Fi OR Bluetooth is sufficient!
    if (!modelReady || (!bleConnected && !wifiConnected)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect either Wi-Fi OR Bluetooth first.'),
        ),
      );
      return;
    }

    incomingBuffer.clear();
    audioBuffer.clear();
    preRoll.clear();
    speechStarted = false;
    silentFrames = 0;

    try {
      if (bleConnected && command != null) {
        await command!.write('START'.codeUnits);
      }
      if (wifiConnected && socket != null) {
        socket!.add('START');
      }

      if (!mounted) return;
      setState(() {
        listening = true;
        final channel = (wifiConnected && bleConnected)
            ? 'Dual (Wi-Fi + BLE)'
            : (wifiConnected ? 'Wi-Fi' : 'Bluetooth');
        status = 'Listening via $channel...';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Command Send Error: $e';
      });
    }
  }

  Future<void> stopVoice() async {
    try {
      if (bleConnected && command != null) {
        await command!.write('STOP'.codeUnits);
      }
      if (wifiConnected && socket != null) {
        socket!.add('STOP');
      }
    } catch (_) {}

    listening = false;
    speechStarted = false;

    if (audioBuffer.isNotEmpty) {
      await finishSentence();
    }

    if (mounted) {
      setState(() {
        status = 'Stopped';
      });
    }
  }

  // ---------------------------------
  // AUDIO REASSEMBLY & VAD (VOICE ACTIVITY)
  // ---------------------------------

  void receiveAudioChunk(Uint8List chunk) {
    if (!listening || processing) return;

    incomingBuffer.addAll(chunk);

    // Prevent buffer explosion if processing was delayed
    if (incomingBuffer.length > 64000) {
      incomingBuffer.clear();
      return;
    }

    // Slice continuous stream into exact 640-byte (20ms) frames
    while (incomingBuffer.length >= frameBytes) {
      final frame = Uint8List.fromList(incomingBuffer.sublist(0, frameBytes));
      incomingBuffer.removeRange(0, frameBytes);
      _processFrame(frame);
    }
  }

  void _processFrame(Uint8List frame) {
    final data = ByteData.sublistView(frame);
    double energy = 0;

    for (int i = 0; i < frame.length; i += 2) {
      final sample = data.getInt16(i, Endian.little);
      energy += sample * sample;
    }

    final double rms = sqrt(energy / (frame.length ~/ 2));
    final bool voice = rms > threshold;

    preRoll.add(frame);
    if (preRoll.length > 10) {
      preRoll.removeFirst();
    }

    if (voice) {
      if (!speechStarted) {
        speechStarted = true;
        for (final oldFrame in preRoll) {
          audioBuffer.addAll(oldFrame);
        }
      } else {
        audioBuffer.addAll(frame);
      }

      silentFrames = 0;

      // High-performance guard: avoids 50 rebuilds/sec during speaking
      if (mounted && status != 'Speech detected (Speaking...)') {
        setState(() {
          status = 'Speech detected (Speaking...)';
        });
      }
    } else if (speechStarted) {
      audioBuffer.addAll(frame);
      silentFrames++;

      if (silentFrames >= silenceLimit) {
        speechStarted = false;
        silentFrames = 0;
        preRoll.clear();
        unawaited(finishSentence());
      }
    }
  }

  // ---------------------------------
  // WAV CREATION (HIGH PERFORMANCE BUFFER)
  // ---------------------------------

  Uint8List createWav(List<int> pcm) {
    final header = ByteData(44);

    void writeText(int offset, String text) {
      for (int i = 0; i < text.length; i++) {
        header.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    // RIFF chunk descriptor
    writeText(0, 'RIFF');
    header.setUint32(4, pcm.length + 36, Endian.little);
    writeText(8, 'WAVE');

    // "fmt " sub-chunk
    writeText(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);

    // "data" sub-chunk
    writeText(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    final wavBytes = Uint8List(44 + pcm.length);
    wavBytes.setRange(0, 44, header.buffer.asUint8List());
    wavBytes.setRange(44, 44 + pcm.length, pcm);
    return wavBytes;
  }

  // ---------------------------------
  // WHISPER TRANSCRIPTION (BENGALI + ENGLISH)
  // ---------------------------------

  Future<void> finishSentence() async {
    if (audioBuffer.isEmpty || processing || engine == null) return;

    processing = true;
    final pcm = List<int>.from(audioBuffer);
    audioBuffer.clear();

    // Noise/Click rejection filter: ignore clicks shorter than 300ms (9600 bytes)
    if (pcm.length < 9600) {
      processing = false;
      return;
    }

    if (!mounted) {
      processing = false;
      return;
    }

    setState(() {
      status = 'Recognizing speech (Whisper AI)...';
    });

    try {
      final wavBytes = createWav(pcm);
      final Float32List samples = WhisperAudio.decodeWav(wavBytes);

      final task = engine!.transcribe(
        samples,
        options: TranscribeOptions(
          language: selectedLanguage,
        ).withPerformanceMode(
          WhisperPerformanceMode.efficient,
        ),
      );

      final result = await task.result;

      if (!mounted) return;

      final text = result.text.trim();
      if (text.isNotEmpty) {
        setState(() {
          recognizedText += '$text\n';
        });
      }

      setState(() {
        status = listening ? 'Listening...' : 'Recognition complete';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          status = 'Transcription Error: $e';
        });
      }
    } finally {
      processing = false;
    }
  }

  // ---------------------------------
  // DISCONNECT & CLEANUP
  // ---------------------------------

  Future<void> disconnectAll() async {
    try {
      if (command != null) {
        await command!.write('STOP'.codeUnits);
      }
      socket?.add('STOP');
    } catch (_) {}

    listening = false;
    speechStarted = false;

    await wifiSubscription?.cancel();
    await bleSubscription?.cancel();
    await bleAudioSubscription?.cancel();
    await bleConnectionSubscription?.cancel();

    try {
      await socket?.close();
    } catch (_) {}

    try {
      await device?.disconnect();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      bleConnected = false;
      wifiConnected = false;
      status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    wifiSubscription?.cancel();
    bleSubscription?.cancel();
    bleAudioSubscription?.cancel();
    bleConnectionSubscription?.cancel();

    socket?.close();
    device?.disconnect();

    engine?.dispose();
    modelManager.close();

    super.dispose();
  }

  // ---------------------------------
  // USER INTERFACE
  // ---------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool anyTransportConnected = bleConnected || wifiConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Assistant'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Recognition Language',
            initialValue: selectedLanguage,
            onSelected: (val) {
              setState(() {
                selectedLanguage = val;
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'auto',
                child: Text('Auto Detect (বাংলা + English)'),
              ),
              const PopupMenuItem(
                value: 'bn',
                child: Text('Bengali (বাংলা)'),
              ),
              const PopupMenuItem(
                value: 'en',
                child: Text('English'),
              ),
            ],
            icon: const Icon(Icons.language),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        listening ? Icons.mic : Icons.mic_none,
                        size: 54,
                        color: listening
                            ? Colors.redAccent
                            : theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        status,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (!modelReady && downloadProgress > 0) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(value: downloadProgress),
                      ],
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatusChip(
                            label: 'BLE',
                            connected: bleConnected,
                          ),
                          _buildStatusChip(
                            label: 'Wi-Fi',
                            connected: wifiConnected,
                          ),
                          _buildStatusChip(
                            label: 'Whisper AI',
                            connected: modelReady,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Transport Connection Buttons
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: modelReady ? null : downloadModel,
                    icon: const Icon(Icons.download),
                    label: Text(
                      modelReady ? 'Model Ready' : 'Download Whisper Model',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: bleConnected ? null : connectBLE,
                    icon: const Icon(Icons.bluetooth),
                    label: Text(
                      bleConnected ? 'BLE Connected' : 'Connect Bluetooth',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: wifiConnected ? null : connectWiFi,
                    icon: const Icon(Icons.wifi),
                    label: Text(
                      wifiConnected ? 'Wi-Fi Connected' : 'Connect Wi-Fi',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          !listening && modelReady && anyTransportConnected
                              ? startVoice
                              : null,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        listening
                            ? 'LISTENING...'
                            : (anyTransportConnected
                                ? 'START LISTENING'
                                : 'CONNECT BLE OR WI-FI'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade100,
                        foregroundColor: Colors.red.shade900,
                      ),
                      onPressed: listening ? stopVoice : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('STOP LISTENING'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Recognized Speech (${selectedLanguage.toUpperCase()})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear_all),
                    tooltip: 'Clear Text',
                    onPressed: () {
                      setState(() {
                        recognizedText = '';
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      recognizedText.isEmpty
                          ? 'Your speech will appear here (Supports either Wi-Fi or Bluetooth)...'
                          : recognizedText,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 17,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: disconnectAll,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Disconnect All'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip({required String label, required bool connected}) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: connected ? Colors.green : Colors.grey,
        radius: 6,
      ),
      label: Text('$label: ${connected ? "Connected" : "Disconnected"}'),
      visualDensity: VisualDensity.compact,
    );
  }
}
