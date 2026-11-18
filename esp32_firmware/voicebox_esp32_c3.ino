/*
 * VoiceBox ESP32-C3 Super Mini Dual Transport Firmware
 * Supports:
 *   1. Wi-Fi WebSocket Streaming (ws://192.168.4.1:81/)
 *   2. Bluetooth Low Energy (BLE) Streaming & Control
 *   3. Either Wi-Fi only, Bluetooth only, or Both!
 *
 * Board: ESP32C3 Dev Module
 * Pin: Pin 0 (ADC1_CH0) for Microphone OUT
 */

#include <WiFi.h>
#include <WebSocketsServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "esp_timer.h"

// ESP32-C3 ADC1 Pin (Safe to use alongside Wi-Fi)
#define MIC_PIN 0

#define SAMPLE_RATE 16000
#define FRAME_SIZE 320 // 320 samples @ 16-bit = 640 bytes (20ms)

const char* WIFI_NAME = "VoiceBox";
const char* WIFI_PASS = "voice1234";

// BLE UUID Definitions
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789000"
#define COMMAND_UUID        "12345678-1234-1234-1234-123456789001"
#define STATUS_UUID         "12345678-1234-1234-1234-123456789002"
#define AUDIO_DATA_UUID     "12345678-1234-1234-1234-123456789003" // BLE Audio Stream

WebSocketsServer webSocket(81);

BLECharacteristic* statusCharacteristic = nullptr;
BLECharacteristic* audioCharacteristic = nullptr;

volatile bool micEnabled = false;
volatile bool bleConnected = false;
volatile bool audioClient = false;

int16_t pcmBuffer[FRAME_SIZE];
int dcOffset = 0;

// BLE Server Callbacks
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    bleConnected = true;
    Serial.println("[BLE] Client Connected");
  }

  void onDisconnect(BLEServer* server) override {
    bleConnected = false;
    Serial.println("[BLE] Client Disconnected");
    BLEDevice::startAdvertising();
  }
};

// BLE Command Callbacks
class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String command = String(characteristic->getValue().c_str());
    command.trim();

    if (command == "START") {
      micEnabled = true;
      Serial.println("[BLE CMD] START");
    } else if (command == "STOP") {
      micEnabled = false;
      Serial.println("[BLE CMD] STOP");
    } else if (command == "STATUS") {
      if (statusCharacteristic != nullptr) {
        statusCharacteristic->setValue(micEnabled ? "RECORDING" : "IDLE");
        statusCharacteristic->notify();
      }
    }
  }
};

void setupBLE() {
  BLEDevice::init("VoiceBox-CTRL");
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);

  // Command Characteristic (Write)
  BLECharacteristic* commandCharacteristic = service->createCharacteristic(
    COMMAND_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  commandCharacteristic->setCallbacks(new CommandCallbacks());

  // Status Characteristic (Read/Notify)
  statusCharacteristic = service->createCharacteristic(
    STATUS_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  statusCharacteristic->addDescriptor(new BLE2902());
  statusCharacteristic->setValue("READY");

  // Audio Data Characteristic (Notify) - For Bluetooth Audio Stream
  audioCharacteristic = service->createCharacteristic(
    AUDIO_DATA_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  audioCharacteristic->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Advertising Started");
}

void setupWiFi() {
  WiFi.mode(WIFI_AP);
  WiFi.softAP(WIFI_NAME, WIFI_PASS, 1, false, 4);

  Serial.print("[WiFi] SoftAP IP: ");
  Serial.println(WiFi.softAPIP());

  webSocket.begin();
  Serial.println("[WebSocket] Started on port 81");
}

void calibrateMic() {
  long total = 0;
  for (int i = 0; i < 1000; i++) {
    total += analogRead(MIC_PIN);
    delayMicroseconds(200);
  }
  dcOffset = total / 1000;
  Serial.print("[Mic] DC Offset Calibrated: ");
  Serial.println(dcOffset);
}

// WebSocket Event Handler (Handles Wi-Fi Commands & Connects)
void webSocketEvent(uint8_t number, WStype_t type, uint8_t* payload, size_t length) {
  if (type == WStype_CONNECTED) {
    audioClient = true;
    Serial.println("[WiFi WS] Audio Client Connected");
    webSocket.sendTXT(number, "READY");
  } else if (type == WStype_DISCONNECTED) {
    audioClient = false;
    Serial.println("[WiFi WS] Audio Client Disconnected");
  } else if (type == WStype_TEXT) {
    // Allows Wi-Fi only users to control START/STOP without Bluetooth!
    String cmd = String((char*)payload);
    cmd.trim();
    if (cmd == "START") {
      micEnabled = true;
      Serial.println("[WiFi CMD] START");
    } else if (cmd == "STOP") {
      micEnabled = false;
      Serial.println("[WiFi CMD] STOP");
    }
  }
}

// Audio Sampling & Multi-Transport Broadcast with Resync Protection
void sendAudioFrame() {
  static int64_t nextSample = 0;
  static int fraction = 0;

  int64_t now = esp_timer_get_time();
  // Timing Resync Guard: Prevents catch-up acceleration after idle/stop
  if (nextSample == 0 || (now - nextSample) > 100000 || (nextSample - now) > 100000) {
    nextSample = now;
    fraction = 0;
  }

  // 16kHz Precise Sampling Loop
  for (int i = 0; i < FRAME_SIZE; i++) {
    while (esp_timer_get_time() < nextSample) {
      taskYIELD();
    }

    int raw = analogRead(MIC_PIN);
    int sample = (raw - dcOffset) * 16;
    sample = constrain(sample, -32768, 32767);
    pcmBuffer[i] = (int16_t)sample;

    nextSample += 62;
    fraction += 8;
    if (fraction >= 16) {
      nextSample++;
      fraction -= 16;
    }
  }

  // 1. Send via Wi-Fi WebSocket (if Wi-Fi client is connected)
  if (audioClient) {
    webSocket.broadcastBIN((uint8_t*)pcmBuffer, sizeof(pcmBuffer));
  }

  // 2. Send via Bluetooth BLE (if BLE client is connected)
  // Split 640 bytes into two 320-byte notifications for BLE MTU compatibility
  if (bleConnected && audioCharacteristic != nullptr) {
    audioCharacteristic->setValue((uint8_t*)pcmBuffer, 320);
    audioCharacteristic->notify();

    audioCharacteristic->setValue((uint8_t*)pcmBuffer + 320, 320);
    audioCharacteristic->notify();
  }

  webSocket.loop();
}

void setup() {
  Serial.begin(115200);

  analogReadResolution(12);

  // Compatible with both Arduino ESP32 Core 2.x and 3.x
  #if defined(ADC_ATTEN_DB_12)
    analogSetPinAttenuation(MIC_PIN, ADC_ATTEN_DB_12);
  #elif defined(ADC_ATTEN_DB_11)
    analogSetPinAttenuation(MIC_PIN, ADC_ATTEN_DB_11);
  #else
    analogSetPinAttenuation(MIC_PIN, ADC_11db);
  #endif

  calibrateMic();
  setupWiFi();
  webSocket.onEvent(webSocketEvent);
  setupBLE();

  Serial.println("VOICEBOX (DUAL-TRANSPORT) READY");
}

void loop() {
  webSocket.loop();

  // Streams audio whenever mic is enabled and EITHER Wi-Fi or BLE is connected!
  if (micEnabled && (audioClient || bleConnected)) {
    sendAudioFrame();
  } else {
    delay(1);
  }
}
