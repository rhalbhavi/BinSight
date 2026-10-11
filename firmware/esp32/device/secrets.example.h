#pragma once

#include <stdint.h>

// Copy this file to secrets.h and fill in the per-device values.
const char* SSID = "YOUR_WIFI_SSID";
const char* PASSWORD = "YOUR_WIFI_PASSWORD";

// Development: use the computer's LAN IP and port 1884.
// Remote devices: use the server VPN IP and broker port 1884. The current
// client is plain MQTT; do not point it at a public TLS-only broker.
const char* MQTT_HOST = "YOUR_COMPUTER_LAN_IP";
const uint16_t MQTT_PORT = 1884;
const char* MQTT_USERNAME = "binsight";
const char* MQTT_PASSWORD = "YOUR_MQTT_PASSWORD";

// Must match the registered bin's bin_id in MongoDB.
const char* DEVICE_ID = "YOUR_REGISTERED_BIN_ID";