#!/bin/sh
set -eu

: "${MQTT_USERNAME:?MQTT_USERNAME is required}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD is required}"

password_file=/mosquitto/data/passwd
if [ -f "$password_file" ]; then
  mosquitto_passwd -b "$password_file" "$MQTT_USERNAME" "$MQTT_PASSWORD"
else
  mosquitto_passwd -b -c "$password_file" "$MQTT_USERNAME" "$MQTT_PASSWORD"
fi

exec mosquitto -c /mosquitto/config/mosquitto.conf
