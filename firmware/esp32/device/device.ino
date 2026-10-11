#include <WiFi.h>
#include <PubSubClient.h>
#include <math.h>
#include <esp_system.h>
#include <Preferences.h>
#include "time.h"
#include "secrets.h"

// --- NTP & Timezone Configuration ---
const char* NTP_SERVER = "pool.ntp.org";
const long GMT_OFFSET_SEC = 19800;      // UTC+5:30 (IST)
const int DAYLIGHT_OFFSET_SEC = 0;

// --- Pin Definitions ---
const int TRIG_PIN = 13;
const int ECHO_PIN = 12;
// Flame Sensor (Analog Pin)
const int FLAME_ANALOG_PIN = 32;
const int FLAME_THRESHOLD = 600;
// MQ-135 Gas Sensor Pin
const int GAS_ANALOG_PIN = 33;

// Currently powered through USB and has no battery-voltage sensor AS OF NOW - Will add later

// --- Bin Configuration ---
float initialBinDistance = 30.0; // Fallback default height
const float MIN_VALID_BIN_HEIGHT = 2.0;
const float FULL_THRESHOLD_CM = 5.0;

// --- Timing Variables ---
unsigned long previousMillis = 0;
const unsigned long INTERVAL = 120000; // 2 mins
unsigned long lastMqttAttempt = 0;
unsigned long lastConnectionHeartbeat = 0;
const unsigned long MQTT_RETRY_INTERVAL = 5000;
const unsigned long CONNECTION_HEARTBEAT_INTERVAL = 2000;
unsigned long lastWifiAttempt = 0;
const unsigned long WIFI_RETRY_INTERVAL = 10000;
unsigned long lastPendingRetry = 0;
bool telemetryPending = false;
uint32_t bootSessionId = 0;
uint32_t sampleSequence = 0;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
String hardwareDeviceId;
Preferences devicePreferences;
char binHeightPreferenceKey[12];

float readFilteredDistanceCm(bool &valid) {
  const int sampleCount = 5;
  const int minimumValidSamples = 3;
  float distances[sampleCount];
  int validCount = 0;

  for (int i = 0; i < sampleCount; i++) {
    digitalWrite(TRIG_PIN, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);

    const unsigned long duration = pulseIn(ECHO_PIN, HIGH, 30000);
    if (duration != 0) {
      distances[validCount++] = duration * 0.0343f / 2.0f;
    }
    // Give the echo time to clear before starting the next measurement.
    delay(60);
  }

  if (validCount < minimumValidSamples) {
    valid = false;
    return 0.0f;
  }

  // Sort the successful pings and use the median to ignore isolated echoes.
  for (int i = 1; i < validCount; i++) {
    const float value = distances[i];
    int j = i - 1;
    while (j >= 0 && distances[j] > value) {
      distances[j + 1] = distances[j];
      j--;
    }
    distances[j + 1] = value;
  }

  valid = true;
  if (validCount % 2 == 1) {
    return distances[validCount / 2];
  }
  return (distances[validCount / 2 - 1] + distances[validCount / 2]) / 2.0f;
}

void connectWifiIfNeeded() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  const unsigned long now = millis();
  if (now - lastWifiAttempt < WIFI_RETRY_INTERVAL) {
    return;
  }
  lastWifiAttempt = now;
  Serial.println("[Wi-Fi] Disconnected; retrying connection...");
  WiFi.begin(SSID, PASSWORD);
}

void connectMqttIfNeeded() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  if (mqttClient.connected()) {
    if (!mqttClient.loop()) {
      telemetryPending = true;
      Serial.println("[MQTT] Connection lost; a fresh sample will be sent after reconnect.");
    }
    return;
  }

  const unsigned long now = millis();
  if (now - lastMqttAttempt < MQTT_RETRY_INTERVAL) {
    return;
  }
  lastMqttAttempt = now;

  char clientId[64];
  char statusTopic[96];
  snprintf(clientId, sizeof(clientId), "binsight-%s", hardwareDeviceId.c_str());
  snprintf(statusTopic, sizeof(statusTopic), "binsight/devices/%s/status", hardwareDeviceId.c_str());
  Serial.printf("[MQTT] Connecting to %s:%u...\n", MQTT_HOST, MQTT_PORT);
  if (mqttClient.connect(clientId, MQTT_USERNAME, MQTT_PASSWORD,
                         statusTopic, 1, true, "offline")) {
    telemetryPending = true;
    lastPendingRetry = 0;
    lastConnectionHeartbeat = millis();
    mqttClient.publish(statusTopic, "online", true);
    Serial.println("[MQTT] Connected; requesting a fresh sensor sample.");
  } else {
    Serial.printf("[MQTT] Connection failed, state=%d\n", mqttClient.state());
  }
}

void publishTelemetry(float fillLevel, int gasPpm, bool flameDetected, bool fillValid) {
  connectMqttIfNeeded();
  if (!mqttClient.connected()) {
    telemetryPending = true;
    Serial.println("[MQTT] Offline; keeping a pending reading for retry.");
    return;
  }

  char topic[96];
  snprintf(
      topic,
      sizeof(topic),
      "binsight/devices/%s/telemetry",
      hardwareDeviceId.c_str());
  char sampleId[32];
  snprintf(sampleId, sizeof(sampleId), "%08lx-%lu",
           (unsigned long)bootSessionId, (unsigned long)++sampleSequence);
  char payload[180];
  if (fillValid) {
    snprintf(payload, sizeof(payload),
             "{\"sample_id\":\"%s\",\"fill_level\":%.1f,\"fill_valid\":true,\"gas_level\":%d,\"flame\":%s}",
             sampleId, fillLevel, gasPpm, flameDetected ? "true" : "false");
  } else {
    // Send heartbeat and the working sensors even when ultrasonic echo is missing - Retains bin's last valid fill measurement
    snprintf(payload, sizeof(payload),
             "{\"sample_id\":\"%s\",\"fill_valid\":false,\"gas_level\":%d,\"flame\":%s}",
             sampleId, gasPpm, flameDetected ? "true" : "false");
  }

  // Retain the newest sample so FastAPI can recover it if its MQTT listener restarts
  if (mqttClient.publish(topic, payload, true)) {
    telemetryPending = false;
    Serial.printf("[MQTT] Published %s %s\n", topic, payload);
  } else {
    telemetryPending = true;
    Serial.println("[MQTT] Publish failed; keeping a pending reading for retry.");
  }
}

void setup() {
  Serial.begin(115200);

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  pinMode(FLAME_ANALOG_PIN, INPUT);

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(false);
  bootSessionId = esp_random();
  // MQTT uses the registered MongoDB bin_id so telemetry updates that bin
  hardwareDeviceId = DEVICE_ID;
  Serial.printf("Registered bin ID: %s\n", hardwareDeviceId.c_str());
  if (hardwareDeviceId.isEmpty() || hardwareDeviceId == "YOUR_REGISTERED_BIN_ID") {
    Serial.println("[CONFIG] Set DEVICE_ID in secrets.h to this device's registered bin_id.");
  }

  // Store each registered bin's empty-height baseline separately in ESP32 NVS
  uint32_t deviceIdHash = 2166136261UL;
  for (size_t i = 0; i < hardwareDeviceId.length(); i++) {
    deviceIdHash ^= static_cast<uint8_t>(hardwareDeviceId[i]);
    deviceIdHash *= 16777619UL;
  }
  snprintf(binHeightPreferenceKey, sizeof(binHeightPreferenceKey), "h%08lx",
           (unsigned long)deviceIdHash);
  devicePreferences.begin("binsight", false);

  // Connect to Wi-Fi
  Serial.print("Connecting to Wi-Fi");
  lastWifiAttempt = millis();
  WiFi.begin(SSID, PASSWORD);

  int wifiTimeout = 0;
  while (WiFi.status() != WL_CONNECTED && wifiTimeout < 20) {
    delay(500);
    Serial.print(".");
    wifiTimeout++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[Wi-Fi] Connected successfully!");
    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
  } else {
    Serial.println("\n[Wi-Fi] Failed to connect. Running offline.");
  }

  mqttClient.setServer(MQTT_HOST, MQTT_PORT);
  mqttClient.setSocketTimeout(3);
  mqttClient.setKeepAlive(5);
  connectMqttIfNeeded();

  Serial.println("\n--- ESP32 Multi-Sensor System Initialized ---");

  // Reuse the first baseline for this registered bin across reconnects/reboots
  const float savedBinHeight = devicePreferences.getFloat(binHeightPreferenceKey, 0.0f);
  if (savedBinHeight >= MIN_VALID_BIN_HEIGHT && isfinite(savedBinHeight)) {
    initialBinDistance = savedBinHeight;
    Serial.print("[Calibration] Restored saved bin height: ");
    Serial.print(initialBinDistance);
    Serial.println(" cm\n");
  } else {
    Serial.println("[Calibration] Measuring empty bin initial distance...");
    delay(1000);

    bool initialDistanceValid = false;
    float initDistance = readFilteredDistanceCm(initialDistanceValid);

    // Use the median valid echo as a one-time empty-bin baseline
    if (initialDistanceValid && initDistance >= MIN_VALID_BIN_HEIGHT) {
      initialBinDistance = initDistance;
      Serial.print("[Calibration] Initial Bin Distance set to: ");
      Serial.print(initialBinDistance);
      Serial.println(" cm\n");
    } else {
      Serial.print("[Calibration] Warning: Read ");
      Serial.print(initDistance);
      Serial.println(" cm. Falling back to default: 30.0 cm\n");
      initialBinDistance = 30.0f;
    }

    devicePreferences.putFloat(binHeightPreferenceKey, initialBinDistance);
    Serial.println("[Calibration] Saved bin height baseline in ESP32 NVS.");
  }

  readAllSensors();
  previousMillis = millis();
}

void loop() {
  connectWifiIfNeeded();
  connectMqttIfNeeded();

  unsigned long currentMillis = millis();
  if (mqttClient.connected() &&
      currentMillis - lastConnectionHeartbeat >= CONNECTION_HEARTBEAT_INTERVAL) {
    char statusTopic[96];
    snprintf(statusTopic, sizeof(statusTopic), "binsight/devices/%s/status", hardwareDeviceId.c_str());
    if (mqttClient.publish(statusTopic, "online", true)) {
      lastConnectionHeartbeat = currentMillis;
    }
  }

  // Take and publish a fresh sensor reading as soon as MQTT has returned
  if (mqttClient.connected() && telemetryPending &&
      currentMillis - lastPendingRetry >= MQTT_RETRY_INTERVAL) {
    lastPendingRetry = currentMillis;
    readAllSensors();
  }

  if (currentMillis - previousMillis >= INTERVAL) {
    previousMillis = currentMillis;
    readAllSensors();
  }
}

void printFormattedTime() {
  struct tm timeinfo;
  if (getLocalTime(&timeinfo)) {
    Serial.print("Timestamp: ");
    Serial.println(&timeinfo, "%I:%M:%S %p");
  } else {
    Serial.print("Uptime: ");
    Serial.print(millis() / 1000);
    Serial.println(" seconds since boot");
  }
}

void readAllSensors() {
  Serial.println("==========================================");
  printFormattedTime();

  Serial.println("[Power] USB 5V input | Battery percentage unavailable (no battery monitor)");
  Serial.println("==========================================");

  // --- 1. Ultrasonic Sensor Logic
  bool ultrasonicValid = false;
  float distanceCm = readFilteredDistanceCm(ultrasonicValid);
  float fillPercentage = 0.0;

  if (!ultrasonicValid) {
    // When the sensor times out at 85-95% full, it's inside the blind zone (<2cm) - Treat it as completely full (100%) instead of throwing hardware error
    fillPercentage = 100.0;
    distanceCm = 0.0;
    ultrasonicValid = true;

    Serial.print("[Bin Status]  Fill Level: 100.0% | Distance: ~0 cm | Status: ");
    Serial.println("Bin Full (Blind Zone Reached)");
  } else {
    if (distanceCm > initialBinDistance) distanceCm = initialBinDistance;

    fillPercentage = ((initialBinDistance - distanceCm) / initialBinDistance) * 100.0;
    if (fillPercentage < 0) fillPercentage = 0;
    if (fillPercentage > 100) fillPercentage = 100;

    Serial.print("[Bin Status]  Fill Level: ");
    Serial.print(fillPercentage);
    Serial.print("% | Distance: ");
    Serial.print(distanceCm);
    Serial.print(" cm | Status: ");

    if (distanceCm <= FULL_THRESHOLD_CM || fillPercentage >= 70.0) {
      Serial.println("Almost Full");
    } else if (fillPercentage >= 50.0) {
      Serial.println("Moderate");
    } else {
      Serial.println("Normal");
    }
  }

  // --- 2. Flame Sensor Logic
  int flameAnalogVal = analogRead(FLAME_ANALOG_PIN);
  bool flameDetected = flameAnalogVal < FLAME_THRESHOLD;
  Serial.print("[Flame Sensor] Analog Val: ");
  Serial.print(flameAnalogVal);
  Serial.print(" | Status: ");

  if (flameDetected) {
    Serial.println("FIRE DETECTED!");
  } else {
    Serial.println("Normal (No Fire)");
  }

  // --- 3. MQ-135 Gas Sensor Logic (Proper ESP32 3.3V / 12-bit ADC Native Math)
  int rawGasVal = analogRead(GAS_ANALOG_PIN);
  if (rawGasVal == 0) rawGasVal = 1;
  // Convert ESP32 12-bit ADC reading (0-4095) to Voltage (3.3V max)
  float vRl = (float)rawGasVal * (3.3 / 4095.0);

  // Calculate sensor resistance Rs assuming a 10kΩ load resistor (RL)
  float rS = ((3.3 * 10.0) / vRl) - 10.0;
  if (rS < 0.1) rS = 0.1;

  // Calculate PPM using standard curve parameters for MQ-135 (CO2 calibration)
  float r0 = 12.5; // Clean air baseline resistance
  float ratio = rS / r0;
  float ppm = 116.6020682 * pow(ratio, -2.76903487);
  // Send the same calculated PPM value printed below. Bound extreme readings so the integer telemetry field remains valid and useful to the app
  int gasPpm = (int)roundf(fminf(fmaxf(ppm, 0.0f), 100000.0f));

  Serial.print("[Gas Sensor]   Raw: ");
  Serial.print(rawGasVal);
  Serial.print(" | PPM: ");
  Serial.print(ppm);
  Serial.print(" | Status: ");

  if (ppm > 700.0) {
    Serial.println("Severe / Hazardous");
  } else if (ppm > 600.0) {
    Serial.println("Very Poor");
  } else if (ppm > 500.0) {
    Serial.println("Poor");
  } else if (ppm > 400.0) {
    Serial.println("Moderate");
  } else {
    Serial.println("Normal");
  }

  Serial.println("------------------------------------------\n");

  publishTelemetry(fillPercentage, gasPpm, flameDetected, ultrasonicValid);
}
