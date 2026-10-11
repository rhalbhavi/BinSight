# ESP32 MQTT Sensor Ingestion

The ESP32 publishes sensor readings to Mosquitto every two minutes and a separate retained connection heartbeat every two seconds. FastAPI stores sensor messages as telemetry and uses the connection heartbeat, with a five-second timeout, to track online status. The mobile and web dashboards refresh device status every five seconds.

## Configure the broker and API

Copy `backend/.env.example` to `backend/.env`. The Compose stack starts MongoDB, Mosquitto, and FastAPI together with persistent MongoDB storage. For a MongoDB Atlas deployment, replace `MONGODB_URI` with the Atlas connection string and allow the server's egress IP in Atlas. Choose an MQTT username and long random password; the same MQTT username/password must be set in the ESP32's `secrets.h`. Keep all credentials private.

Start the broker from the workspace root:

```sh
docker compose --env-file backend/.env -f backend/docker-compose.yml up -d --build
```

The API is available on port `5000`; the local MongoDB service is persisted in the `mongodb_data` volume. To run FastAPI outside Compose for development, change `MONGODB_URI` to `mongodb://localhost:27017/binsight` and `MQTT_URL` to `mqtt://localhost:1884`, then run:

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
.venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port 5000
```

The broker is available to FastAPI at `mosquitto:1883` inside Compose. Host ports bind to loopback by default. For an ESP32 on another network, first set `MQTT_BIND_ADDRESS` in `backend/.env` to the server's VPN interface address, connect the device's Wi-Fi network to that VPN, and use the server's VPN address with port `1884` in `secrets.h`. Do not bind this plain-MQTT port to a public interface. For a publicly hosted app, put FastAPI behind HTTPS and set `API_BIND_ADDRESS` to loopback for the reverse proxy; allow the hosted web origin in `CORS_ORIGINS`.

## Register and configure a device

1. Add a bin in the app so MongoDB has a registered `bin_id` (for example, `bin1`).
2. Copy `firmware/esp32/device/secrets.example.h` to `firmware/esp32/device/secrets.h`.
3. Set the Wi-Fi name and password, broker host and port, MQTT credentials, and `DEVICE_ID` to the exact registered `bin_id`. The sketch uses this ID as its topic identity; the ESP32 MAC address is not used to identify the bin.
4. Flash `firmware/esp32/device/device.ino`. Install the Arduino `PubSubClient` library and use an ESP32 board.

The sketch publishes telemetry to `binsight/devices/{DEVICE_ID}/telemetry` at startup and then every 120 seconds while connected. It publishes retained `online` heartbeats to `binsight/devices/{DEVICE_ID}/status` every two seconds and configures a retained MQTT last will of `offline`. FastAPI marks a device offline if no heartbeat arrives for five seconds. It retries Wi-Fi and MQTT after interruptions and retains a uniquely identified latest telemetry sample so FastAPI can recover it after a subscriber restart; retained telemetry replays are deduplicated in MongoDB. It publishes a heartbeat and available gas/fire values even when the ultrasonic sensor misses an echo; the backend retains that bin's last valid fill reading until a new valid measurement arrives. The JSON fields are `fill_level` (0-100%), `gas_level` (calculated MQ-135 PPM value, capped at 100000), and `flame` (boolean). Battery percentage is optional. FastAPI validates and stores it when a device has a real battery monitor and publishes `battery_percent` from 0 to 100. A USB power bank’s 5 V output does not reveal its remaining charge, so the current USB-powered firmware omits that field until a monitor/protocol is available. FastAPI validates and stores the three bin metrics.

## Data and alerts

Each accepted message is first written to MongoDB's `telemetry` collection with an acknowledged insert, then updates the matching document in `bins`, including `fill_level`, `gas_level`, `flame`, derived `status`, and `last_updated`. The app reads current bin and zone data through `GET /devices`; history is available from `GET /devices/{binId}/telemetry?limit=50`. Open alerts are available from `GET /alerts?status=open`.

Overall bin status is Critical for detected fire, air readings at 601 PPM or higher (Very Poor or Severe/Hazardous), or fill at the configured Full threshold (90% by default) continuously for at least one hour. Full for less than one hour is Moderate. Fill at 50% or above and air at 401 PPM or above are Moderate; air from 501 through 600 PPM is Poor and remains Moderate. Configure `FILL_LEVEL_FULL_THRESHOLD`, `FILL_LEVEL_MODERATE_THRESHOLD`, `FILL_LEVEL_ALMOST_FULL_THRESHOLD`, `GAS_LEVEL_CRITICAL_THRESHOLD`, and `GAS_LEVEL_MODERATE_THRESHOLD` in `backend/.env`. The firmware calculates PPM using its MQ-135 resistance curve and the configured clean-air baseline; calibrate `r0`, load resistance, and the sensor for your actual module and environment before relying on the PPM value. Each new telemetry sample is written to `telemetry` and `bins`; alert transitions upsert moderate/critical state and mark condition-resolved alerts as cleared while preserving manually resolved alerts in `alerts`; the Flutter dashboards poll `GET /devices` every five seconds. Sensor transitions are stored in `alerts` and shown in the operational Alerts section. The Notifications section is reserved for report events, task lifecycle events, worker critical reminders, and admin unresolved-critical escalations; routine sensor transitions do not appear there. Critical reminders are enabled by default and repeat every 30 minutes while unresolved; set `CRITICAL_REMINDERS_ENABLED=false` to disable recurring reminders.

Telemetry for an ID that is not registered as a bin is intentionally ignored and logged by FastAPI. Check that `DEVICE_ID` exactly matches `bin_id` and that the app, API, broker, and ESP32 are using the intended database and network.
