# BinSight

IoT-based smart waste monitoring system with a Flutter app, ESP32 firmware, FastAPI backend, MongoDB storage, and Mosquitto MQTT ingestion.

## Run the backend

From the workspace root, install the backend dependencies and start FastAPI:

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
.venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port 5000
```

The backend reads MongoDB, MQTT, and alert threshold settings from `backend/.env`. Keep credentials out of source control. The API remains on port `5000`, matching the Flutter app's configured development URL. FastAPI's interactive docs are available at `http://localhost:5000/docs` while the service is running.

See [backend/MQTT_SETUP.md](backend/MQTT_SETUP.md) for starting Mosquitto and the sensor topic/payload contract. ESP32 firmware is in `firmware/esp32/device/device.ino`.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
