<div align="center">
  
  # BinSight
  
  **BinSight** is an IoT-based smart waste monitoring system combining ESP32 sensor devices, an MQTT message broker, a FastAPI backend, MongoDB storage, and a Flutter application. It helps administrators and waste collection teams monitor bin fill levels, air-quality readings, fire indicators, device connectivity, and collection operations.

</div>

----

## Problem Statement / Objective

Shared waste collection areas in apartments, campuses, institutions, and other public spaces often face garbage overflow, delayed disposal, and safety risks such as gas buildup or fire hazards due to a lack of real-time monitoring.

There is no integrated system that combines real-time garbage-level monitoring, air-quality and fire-hazard detection, bin and waste-zone location tracking, and alerts in a single platform. BinSight addresses this need by monitoring registered waste bins and notifying users through the application when readings or operational conditions need attention.

Its objectives are to:

- Monitor bin fill level, estimated gas concentration, and fire indicators.
- Help admin and worker teams identify bins and areas needing attention using maps and zone summaries.
- Provide operational views for administrators and workers.
- Record telemetry and alerts for historical review and analytics.
- Reduce reliance on manual inspection and support timely waste collection.

----

## Key Features

### Sensor monitoring

- ESP32 firmware reads ultrasonic fill-level, MQ-135 air-quality, and flame-sensor measurements.
- Devices publish telemetry over MQTT, including fill level, estimated gas concentration in PPM, and flame status.
- A device heartbeat and MQTT last-will status help identify whether devices are online or offline.
- The backend validates incoming measurements, stores accepted telemetry, and updates the current bin status.
- When an ultrasonic reading is invalid, gas and fire readings can still be reported while the backend retains the last valid fill reading.

### Alerts and notifications

- The backend evaluates readings against configurable thresholds and records sensor alert transitions.
- Open alerts can be reviewed and resolved in the application.
- The application also supports operational notifications for reports, task updates, connectivity events, and critical reminders.
- Dashboards periodically refresh device data; notifications are application-level, not a guarantee of SMS or push delivery.

### Administration and worker operations

- Role-based application experiences for administrators and workers.
- Initial organization setup for an administrator, workers, bins, and zones.
- Bin and zone registration, including QR-based device registration.
- Worker profiles, assignments, and task status updates.
- Issue reporting with optional photos and administrator report resolution.
- Configurable notification preferences and profile pictures.

### Maps and location

- Map views can show bins, zones, and worker locations when location information is available.
- Bin records can include coordinates and location descriptions.
- Map tiles are provided by OpenStreetMap; map display requires network access.

### Analytics

- Historical fill-level data can be reviewed by bin and zone.
- The backend groups valid fill measurements into hourly history.
- Overflow forecasts use an ARIMA model when enough history is available, with a recent-rate fallback for sparse data.
- Gas-spike and fire-risk indicators are estimated from recent telemetry. Predictions are indicative and should not replace sensor validation or safety procedures.

----

## Scope

BinSight is designed to be adaptable to apartments, educational institutions, offices, hotels, malls, industrial areas, event venues, and other shared or public waste-management environments.

The system can help:

- Reduce garbage overflow, foul odors, and prolonged exposure to harmful gases through monitoring and timely response.
- Identify abnormal air-quality readings and potential fire hazards around monitored bins.
- Reduce manual inspection effort and help operators prioritize work.
- Monitor individual bins and group registered bins into zones for aggregate views.
- Scale from a small installation to deployments with multiple bins and locations.

**Current implementation note:** zones are logical groups that aggregate information from registered bins. Independent sensors for waste rooms, shafts, or dumping areas are not currently implemented as a separate device type.

----

## System Architecture

```text
ESP32 sensors
    │
    │ MQTT telemetry and status heartbeat
    ▼
Mosquitto MQTT broker
    │
    ▼
FastAPI backend ───── MongoDB
    │                    ├── bins and zones
    │                    ├── telemetry history
    │                    ├── alerts and reports
    │                    └── worker and administrator data
    │
    ▼
Flutter application
    ├── Administrator dashboard
    ├── Worker dashboard
    ├── Maps and zone views
    └── Analytics, alerts, tasks, and reports
```

The ESP32 publishes a telemetry sample at startup and approximately every two minutes while connected. It sends a retained connection heartbeat every two seconds. The backend considers a device offline when no heartbeat has been seen within the configured timeout, five seconds by default.

----

## Technologies & Tools

| Category | Technology | Image / Badge |
|---|---|---|
| **IoT Hardware** | ESP32 Development Board | <img width=auto height="100" alt="Screenshot from 2026-10-11 14-03-31" src="https://github.com/user-attachments/assets/70988967-a575-4721-bb1a-ea0ba962be2e"/> |
| | HC-SR04 Ultrasonic Sensor | <img width=auto height="100" alt="Screenshot from 2026-10-11 13-58-34" src="https://github.com/user-attachments/assets/7fc33e09-d042-4484-984c-07d6ff300002"/> |
| | MQ-135 Air Quality Sensor | <img width=auto height="100" alt="Screenshot from 2026-10-11 14-01-13" src="https://github.com/user-attachments/assets/4b9d1e39-e705-4121-8370-5607c96fa375"/> |
| | KY-026 Flame Sensor | <img width=auto height="100" alt="Screenshot from 2026-10-11 14-06-58" src="https://github.com/user-attachments/assets/cf056ac5-7d15-4a05-a023-498a37a51b33"/> |
| **Firmware** | Arduino Framework | ![Arduino](https://img.shields.io/badge/Arduino-00979D?style=flat&logo=arduino&logoColor=white) |
| | PubSubClient | ![PubSubClient](https://img.shields.io/badge/PubSubClient-00979D?style=flat) |
| **Mobile Application** | Flutter | ![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat&logo=flutter&logoColor=white) |
| | Dart | ![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat&logo=dart&logoColor=white) |
| **Authentication** | Firebase Authentication | ![Firebase](https://img.shields.io/badge/Firebase_Auth-DD2C00?style=flat&logo=firebase&logoColor=white) |
| | Google Sign-In | ![Google](https://img.shields.io/badge/Google_Sign--In-4285F4?style=flat&logo=google&logoColor=white) |
| **Backend & APIs** | FastAPI | ![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=flat&logo=fastapi&logoColor=white) |
| | Python | ![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white) |
| **Database** | MongoDB | ![MongoDB](https://img.shields.io/badge/MongoDB-47A248?style=flat&logo=mongodb&logoColor=white) |
| **Messaging & Communication** | MQTT | ![MQTT](https://img.shields.io/badge/MQTT-660066?style=flat&logo=eclipsemosquitto&logoColor=white) |
| | Eclipse Mosquitto | ![Mosquitto](https://img.shields.io/badge/Mosquitto-3C5280?style=flat&logo=eclipsemosquitto&logoColor=white) |
| | Paho MQTT | ![Paho](https://img.shields.io/badge/Paho_MQTT-3C5280?style=flat&logo=eclipseide&logoColor=white) |
| **Maps & Location** | flutter_map | ![Flutter Map](https://img.shields.io/badge/flutter__map-02569B?style=flat&logo=flutter&logoColor=white) |
| | OpenStreetMap | ![OpenStreetMap](https://img.shields.io/badge/OpenStreetMap-7EBC6F?style=flat&logo=openstreetmap&logoColor=white) |
| | Geolocator | ![Geolocator](https://img.shields.io/badge/Geolocator-02569B?style=flat&logo=flutter&logoColor=white) |
| **Analytics & Forecasting** | pandas | ![pandas](https://img.shields.io/badge/pandas-150458?style=flat&logo=pandas&logoColor=white) |
| | NumPy | ![NumPy](https://img.shields.io/badge/NumPy-013243?style=flat&logo=numpy&logoColor=white) |
| | statsmodels (ARIMA) | ![statsmodels](https://img.shields.io/badge/statsmodels-4051B5?style=flat) |
| **Image Handling** | Flutter Image Picker | ![Image Picker](https://img.shields.io/badge/Image_Picker-02569B?style=flat&logo=flutter&logoColor=white) |
| **Containerization** | Docker Compose | ![Docker](https://img.shields.io/badge/Docker_Compose-2496ED?style=flat&logo=docker&logoColor=white) |

----

## Repository Layout

```text
.
├── android/                       # Android application project
├── assets/                        # Application images
├── backend/
│   ├── app.py                     # FastAPI application and MQTT ingestion
│   ├── Dockerfile
│   ├── docker-compose.yml          # MongoDB, Mosquitto, and API services
│   ├── mosquitto/                 # MQTT broker configuration
│   ├── requirements.txt
│   ├── test_app.py
│   └── MQTT_SETUP.md              # Broker, device, and deployment details
├── firmware/
│   ├── README.md
│   └── esp32/device/
│       ├── device.ino             # ESP32 firmware
│       └── secrets.example.h      # Safe device configuration template
├── ios/                           # iOS application project
├── lib/                           # Flutter application source
├── linux/                         # Linux application project
├── macos/                         # macOS application project
├── test/                          # Flutter tests
├── web/                           # Web application project
└── windows/                       # Windows application project
```

----

## Sensor Data and Alert Behavior

Telemetry includes:

- `fill_level`: fill percentage from 0 to 100 when a valid ultrasonic measurement is available.
- `gas_level`: estimated MQ-135 concentration in PPM, accepted from 0 to 100,000.
- `flame`: Boolean fire-sensor indication.
- `battery_percent`: optional percentage for a device with a real battery monitor.

The current USB-powered firmware does not estimate battery percentage because USB input voltage does not indicate the remaining charge of a power bank.

Default backend thresholds include:

- Moderate fill at 50% or higher.
- Almost-full fill at 70% or higher.
- Full fill at 90% or higher.
- Critical fill after the bin remains at or above the full threshold for at least one hour.
- Moderate gas reading at 401 PPM or higher.
- Critical gas reading at 601 PPM or higher.
- A detected flame is critical.

Thresholds and connectivity settings can be configured through backend environment variables; see `backend/docker-compose.yml` and `backend/MQTT_SETUP.md` for the supported settings and defaults.

MQ-135 PPM values depend on the sensor module, load resistance, warm-up, environmental conditions, and calibration. Calibrate the sensor for the deployment environment before using its readings for operational decisions. The ESP32’s GPIO pins are not 5 V tolerant; verify sensor output levels and use appropriate level shifting or voltage conditioning.

----

## API Overview

The FastAPI service provides endpoints for application setup, device data, reports, and operations. Examples include:

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Check API health |
| `GET /setup/status` | Check whether initial organization setup is complete |
| `GET /devices` | List bins with current readings, connectivity, and prediction fields |
| `GET /zones` | List zones with aggregate bin information |
| `GET /devices/{device_id}/telemetry` | Retrieve historical telemetry |
| `GET /analytics/fill-history` | Retrieve hourly fill history for analytics |
| `GET /alerts` | List alerts, optionally filtered by status |
| `GET /reports` | List submitted reports |
| `POST /reports` | Submit an issue report |
| `GET /workers` | List worker records |
| `PATCH /tasks/{task_id}/status` | Update a task’s status |

The complete API schema is available at `/docs` while the backend is running.

----

## Testing

Run backend unit tests from the backend directory after installing its Python dependencies:

```sh
cd backend
python -m unittest
```

Run Flutter tests from the repository root:

```sh
flutter test
```

----

## Scope and Limitations

BinSight is intended to support waste-management operations; it does not replace physical inspection or emergency-response processes. Device connectivity depends on Wi-Fi and a reachable MQTT broker. The current system reports the latest telemetry and stored history; readings missed while a device is powered off cannot be reconstructed.

Predictions depend on the quantity and quality of available telemetry. Sparse or irregular history may produce a fallback estimate or no forecast. Air-quality accuracy depends on sensor calibration and installation conditions.

----

## Future Additions

- **Waste-zone and dumping-room monitoring:** Add dedicated sensing for shared rooms, shafts, and larger dumping areas.
- **Solar integration:** Add solar panels and improve charging and power management for greater device autonomy.
- **More sensor types:** Expand monitoring with additional environmental or equipment sensors.
- **Mobile app expansion:** Add richer mobile workflows and tools for administrators and collection workers.
- **Advanced ML predictions:** Improve fill-level forecasts and anomaly detection using larger, deployment-specific datasets.
- **LoRa communication:** Add long-range communication for large campuses or waste-management zones.
- **Multi-bin deployment:** Improve provisioning and fleet management for deployments across many bins, zones, and sites.
- **Automated waste collection:** Integrate route optimization to help workers plan efficient collection schedules.
- **Advanced analytics:** Add richer historical trends, comparisons, and reports to support planning and operational decisions.

----

## Conclusion

BinSight brings sensor-based waste monitoring and operational tools together in one system. By combining ESP32 telemetry, MQTT, a FastAPI and MongoDB backend, and a Flutter application, it provides a foundation for monitoring bin conditions, identifying risks, organizing collection work, and learning from historical data. Its modular design can be extended toward larger deployments and additional monitoring capabilities as hardware, connectivity, and operational needs grow.
