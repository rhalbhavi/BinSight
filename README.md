<div align="center">
   
   # 🚮 BinSight: Smart IoT-Powered Waste Monitoring and Analytics System
   ### BinSight is an IoT-based system for real-time waste bin and zone monitoring using multi-sensor integration. It enables data-driven waste collection with alerts, predictive analytics, and scalable deployment models.

</div>

---

## TABLE OF CONTENTS
1. [📝 **Overview**](#overview)

2. [⚠️ **The Problem**](#the-problem)

3. [💡 **Our Solution**](#our-solution)

4. [🧩 **Key Features**](#key-features)

5. [📦 **System Versions**](#system-versions)

6. [⚙️ **Tools and Technologies**](#tools-and-technologies)

7. [💵 **Technical Feasibility**](#technical-feasibility)

8. [🖧 **System Design**](#system-design)
    * [🔄 Flow Diagrams](#flow-diagrams)
      * [1) Single Bin Version - Battery + Solar](#single-bin-version--battery--solar)
      * [2) Single Bin Version - Mains + Backup + Solar](#single-bin-version--mains--backup--solar)
      * [3) Modular Version - Mains](#modular-version---mains)
    * [🧱 Layered Architecture](#layered-architecture)
    * [🔩 Hardware Design](#hardware-design)
    * [🔁 Firmware Flow](#firmware-flow)
    * [📡 MQTT Design](#mqtt-design)
    * [🛢 Database Design](#database-design)
      * [📁 Database Schema](#database-schema)
    * [🔌 API Design](#api-design)
    * [🤖 ML Pipeline](#ml-pipeline)

9. [📱 **Application**](#application)
    * [🧩 **Features**](#features)
    * [👥 **User Interfaces**](#user-interfaces)
      * [🧑‍💼 Admin](#admin-supervisor--facility-manager)
      * [👷 Worker](#worker-sanitation-staff--operator)
    * [📈 **Single Bin and Zone Status Cards**](#single-bin-and-zone-status-cards)
      * [Single Bin Card](#single-bin-card)
      * [Zone Card](#zone-card)
      * [Status Logic](#status-logic)

12. [🔮 **Future Scope**](#future-scope)

13. [🏁 **Conclusion**](#conclusion)

---

## Overview
🗑️ Urban waste management systems rely on manual inspection and fixed schedules, leading to inefficiencies and hygiene risks.
♻️ BinSight introduces a smart, scalable, and data-driven solution using IoT and analytics.

---

## The Problem
* No real-time visibility into bin fill levels
* Dependence on fixed collection schedules
* Overflowing bins and odor complaints
* Lack of gas and fire hazard detection
* No real-time alerts or notifications when bins / waste zones require servicing
* Inefficient manual monitoring
* Poor workforce utilization

<div align="center">
   <img width="600" height=auto alt="image" src="https://github.com/user-attachments/assets/49bce326-565f-4a51-8f75-4aef541eba65" />
</div>

---

## Our Solution
💡 BinSight enables:
* 📊 Real-time fill level tracking
* ☁️ Gas detection for harmful emissions
* 🔥 Flame detection for fire safety and removal of flammable waste
* 📲 Centralized dashboard for tracking with bin / zone & user locations on a live map, bin / zone status cards, and real-time alerts for servicing
* 🔮 Predictive analytics (next overflow time, anomaly detection - gas spike, fire risk) using ML

---

## Key Features
* **Real-time Monitoring:** Continuous tracking of waste levels and environmental hazards.
* **Multi-sensor Integration:** Combines ultrasonic, gas, and flame sensors for 360° safety.
* **Predictive Analytics:** ML-driven forecasts for bin overflow and cleaning schedules.
* **Scalable Design:** From individual apartments to city-wide modular campus deployments.
* **Modular System:** Can be employed for single bins as well as multi-bin waste rooms/shafts.
* **Cost-effective:** Built using low-power, affordable IoT hardware for maximum ROI.

---

## System Versions

| 📦 Version | Power | Architecture | Best For | Components |
| :--- | :--- | :--- | :--- | :--- |
| **Single Bin – Battery + Solar** | 🔋 18650 Battery + ☀️ Solar | Device in single bin | Apartments, Retrofits | - ESP32 ✅<br>- Ultrasonic Sensor ✅<br>- Gas Sensor ✅<br>- Flame Sensor ✅<br>- Battery ✅<br>- Solar Panel ✅ |
| **Single Bin – Mains + Backup + Solar** | 5V + 🔋 Battery (+ ☀️ Optional Solar) | Device in single bin | Larger Residential Complexes, Hospitals, etc. | - ESP32 ✅<br>- Ultrasonic Sensor ✅<br>- Gas Sensor ✅<br>- Flame Sensor ✅<br>- Battery ✅<br>- Solar Panel ⚠️ Optional |
| **Modular System – Mains** | 5V Adapter | Central unit + wired sensors | Campuses, Corporate Parks, Malls, Large Event Venues | - Central ESP32 ✅<br>- Central Gas Sensor ✅<br>- Ultrasonic Sensors (per bin) ✅<br>- Flame Sensors (per bin) ✅<br>- Battery ❌<br>- Solar Panel ❌ |

---

## Tools and Technologies

### Hardware Components
* ESP32-WROOM-32
* Ultrasonic Sensor (HC-SR04)
* Gas Sensor (MQ-135)
* Flame Sensor (KY-026)
* Battery (Samsung INR18650-30Q 3.7V 3000mAh Li-NiMnCoO2) + Charge controller / Mains Power System
* Solar Panels

### Communication
* WiFi
* LoRa (optional)
* MQTT Protocol

### Software Stack
* **Firmware:** Arduino / ESP-IDF
* **Backend:** FastAPI
* **Database:** MongoDB
* **Frontend:** Flutter
* **Maps:** flutter_osm_plugin, flutter_map
* **ML:** NumPy, Pandas
* **Authentication/Login:** Firebase (Email, Google - Gmail)

---

## Technical Feasibility
* **Low-Cost Infrastructure:** Utilizes affordable, mass-produced sensors and microcontrollers (ESP32), significantly lowering entry barriers.
* **Standardized Protocols:** Implementation of MQTT and REST APIs ensures compatibility with existing cloud infrastructures.
* **Energy Efficiency:** Deep-sleep modes in ESP32 allow for long-term battery operation, making the system viable for locations without power mains.
* **Modular Scalability:** The decoupled architecture (Edge to Cloud) allows for easy expansion from 1 bin to 1000s without re-engineering the core logic.

---

## System Design

### Flow Diagrams

##### Single Bin Version – Battery + Solar
<div align="center">
   <img width="800" height=auto alt="Single bin battery and solar" src="https://github.com/user-attachments/assets/09ada5bc-399d-4f44-8f7e-a379541385fe" />
</div>

<br>

##### Single Bin Version – Mains + Backup + Solar
<div align="center">
   <img width="650" height=auto alt="Single bin - mains backup and solar" src="https://github.com/user-attachments/assets/aa79a365-64b8-4ea6-a9e6-a9f98f92a2f1" />
</div>

<br>

##### Modular Version - Mains
<div align="center">
   <img width="1000" height=auto alt="Modular version - mains" src="https://github.com/user-attachments/assets/ac5623be-d369-457e-a4e2-b43634458596" />
</div>

----

### Layered Architecture
<div align="center">
   <img width="800" height=auto alt="3 layer architecture" src="https://github.com/user-attachments/assets/95c23eb0-3ea2-4469-9c4b-50b3e3190983" />
</div>

----

### Hardware Design
* Sensor → ESP32 connections
* GPIO / ADC mapping
* Power regulation

----

### Firmware Flow
1. Initialize sensors
2. Connect WiFi
3. Read data
4. Process
5. Publish via MQTT
6. Repeat

----

### MQTT Design
**Topics:** `bins/{bin_id}/data` | `bins/{bin_id}/alert`  
**Payload Example:** `{ "fill": 78, "gas": 120, "flame": false }`

----

### Database Design

<div align="center">
   <img width="700" height=auto alt="Database schema" src="https://github.com/user-attachments/assets/6ecb9602-9ede-4886-88bc-f84db1609f78" />
</div>

#### Database Schema

##### admins
```
{
  "_id": "firebase_uid_of_admin",
  "admin_id": "firebase_uid_of_admin",
  "first_name": "First",
  "last_name": "Last",
  "name": "First Last",
  "email": "adminmail@email.com",
  "phone": "+1234567890",

  "profile_image_url": "http://localhost:4000/images/admin/firebase_uid_of_admin",

  "created_at": { "$date": "2023-10-26T10:00:00.000Z" },
  "updated_at": { "$date": "2023-10-26T10:00:00.000Z" }
}
```
##### workers
```
{
  "_id": "firebase_uid_of_worker",
  "worker_id": "firebase_uid_of_worker",
  "first_name": "First",
  "last_name": "Last",
  "name": "First Last",
  "email": "workermail@email.com",
  "phone": "+1234567890",
  "role": "worker",

  "profile_image_url": "http://localhost:4000/images/worker/firebase_uid_of_worker",  

"assigned_zones": [ // Optional
    "ZONE_101",
    "ZONE_102"
  ],

  "status": "active",
  "current_location": {
    "lat": 12.9716,
    "lng": 77.5946
  },

  "last_active": { "$date": "2023-10-26T14:30:00.000Z" },
  "created_at": { "$date": "2023-10-20T09:00:00.000Z" },
  "updated_at": { "$date": "2023-10-26T14:30:00.000Z" }
}
```
##### admin_images
```
{
  "_id": "admin_firebase_uid_1_image_id", // MongoDB's default primary key
  "admin_id": "firebase_uid_of_admin", // Reference to the admin document

  // Image data
  "filename": "admin_profile.jpg",
  "content_type": "image/jpeg",
  "size": 123456, // Size in bytes
  "data": { "$binary": { "base64": "...", "subType": "00" } }, // Binary image data

  "created_at": { "$date": "2023-10-26T10:00:00.000Z" }, 
  "updated_at": { "$date": "2023-10-26T10:00:00.000Z" }
}
```
##### worker_images
```
{
  "_id": "worker_firebase_uid_1_image_id", // MongoDB's default primary key
  "worker_id": "firebase_uid_of_worker", // Reference to the worker document

  // Image data
  "filename": "worker_profile.jpg",
  "content_type": "image/jpeg",
  "size": 789012, // Size in bytes
  "data": { "$binary": { "base64": "...", "subType": "00" } }, // Binary image data

  "created_at": { "$date": "2023-10-26T14:30:00.000Z" }, 
  "updated_at": { "$date": "2023-10-26T14:30:00.000Z" }
}
```

##### bins
```
{
  "_id": "bin_generated_unique_id",
  "bin_id": "bin_generated_unique_id", // App-generated unique ID
  "type": "bin",
  "name": "Bin 1", // Auto-generated by the app based on order
  "location_description": "Floor 1 - Panini Building", // User-provided 
  "zone_id": "ZONE_101", // Optional
  "location": { // Coordinates, fixed at setup (e.g., from Leaflet.js)
    "lat": 0.0,
    "lng": 0.0
  },

  "fill_level": 75,
  "gas_level": 120,
  "flame": false,
  "status": "normal/moderate/critical",

  "last_updated": { "$date": "2023-10-26T15:00:00.000Z" },
  "created_at": { "$date": "2023-10-25T08:00:00.000Z" }
}
```
##### zones
```
{
  "_id": "zone_generated_unique_id",
  "zone_id": "zone_generated_unique_id",
  "type": "zone", // Always "zone"
  "name": "Zone 1", // Auto-generated by the app based on order
  "location_description": "Block A - Floor 1", // User-provided
  "location": { 
    "lat": 0.0,
    "lng": 0.0
  },

  "bin_count": 10, // No. of bins in the zone ( maintained by backend logic)
  "avg_fill_level": 65, // Average fill level of bins in the zone
  "gas_alert": false, // Boolean: true if any bin in zone has gas alert
  "fire_alert": false, // Boolean: true if any bin in the zone has fire alert
  "status": "normal/moderate/critical",

  "last_updated": { "$date": "2023-10-26T15:05:00.000Z" },
  "created_at": { "$date": "2023-10-25T09:00:00.000Z" }
}
```

##### tasks
```
{
  "_id": "TASK_001", 
  "task_id": "TASK_001",
  "worker_id": "firebase_uid_of_worker",

  "bin_id": "bin_generated_unique_id", // Optional
  "zone_id": "zone_generated_unique_id", // Optional
  "description": "Empty bin at main lobby", // Details
  "status": "pending/in_progress/completed/cancelled",
  "priority": "low/medium/high/critical",

  "assigned_at": { "$date": "2023-10-26T10:30:00.000Z" },
  "completed_at": ISODate
}
```
##### alerts
```
{
  "_id": "ALERT_001", 
  "alert_id": "ALERT_001",
  "type": "overflow/gas/fire/offline/battery_low",

  "bin_id": "bin_generated_unique_id", // Optional
  "zone_id": "zone_generated_unique_id", // Optional
  "message": "Bin is full",
  "severity": "critical",
  "is_resolved": false,

  "created_at": { "$date": "2023-10-26T11:00:00.000Z" },
  "resolved_by": firebase_uid,
  "resolved_at": ISODate
}
```
##### reports
```
{
  "_id": "REPORT_001",
  "report_id": "REPORT_001", 
  "worker_id": "firebase_uid_of_worker",
  "type": "bin_issue/zone_issue/general_feedback",

  "bin_id": "bin_generated_unique_id", // Optional
  "zone_id": "zone_generated_unique_id", // Optional
  "issue": "Bin lid broken", 
  "image_url": "http://localhost:4000/images/report/REPORT_001",
  "status": "pending/in_progress/resolved/rejected",

  "created_at": { "$date": "2023-10-26T12:00:00.000Z" },
  "resolved_at": ISODate,
  "resolved_by": firebase_uid of admin
}
```
##### app_config
```
{
  "_id": "main",
  "config_id": "main",
  "is_setup_complete": true,
  "admin_uid": "firebase_uid_of_initial_admin",

  "organization_name": "BinSight Deployment", // Can be a default or derived from organization_location
  "organization_location": "displayName", // PickedData.displayName
  "location_lat": 12.9497, // PickedData.lat
  "location_lon": 77.6614, // PickedData.lon

  "created_at": { "$date": "2023-10-26T09:00:00.000Z" },
  "updated_at": { "$date": "2023-10-26T09:00:00.000Z" }
}
```

----

### API Design
* `POST /data`
* `GET /bins`
* `GET /alerts`

----

### ML Pipeline
* **🗑 Fill Level Prediction:** Weighted Moving Average, ARIMA
* **📈 Anomaly Detection:** Z-score

---

## Application

### Features
* Real-time monitoring of bins/zones.
* Location-based tracking via map.
* Alerts for overflow, gas, and fire hazards.
* ML-based prediction for overflow and anomalies.
* Historical data storage for trend analysis.
* Graphical representation of bin metrics.

---

### User Interfaces

#### Admin (Supervisor / Facility Manager)
* **📍 Live Map:** User & Bin/Zone Markers.
* **🗑 Status Monitoring:** Bin/Dumping Zone status.
* **📈 Predictive Analytics:** Overflow time estimates and anomaly detection.
* **⚠️ Alerts:** Real-time notifications when sensor thresholds crossed.
* **👨‍💻 Management:**
    - 📝 Task List
    - 👷 Worker management (View Workers & Tasks Assigned per Worker, Assign Tasks)
    - 🔋 Device management (Locations, Battery Levels)
* **🗂️ Reports:**
    - Weekly bin/zone metrics/analytics, no. of alerts, no. of alerts resolved/pending/rejected
    - Damaged Bins/Zones (With photos taken & uploaded by workers)
* **🔎 Filters:** Filter by Fill, Air Quality, or Flames.

#### Worker (Sanitation Staff / Operator)
* **📍 Live Map:** User & Bin/Zone Markers.
* **🗑 Status Monitoring:** Real-time bin/zone status.
* **📈 Predictive Analytics:** Overflow time estimates and anomaly detection.
* **⚠️ Alerts:** Real-time notifications when sensor thresholds crossed.
* **📝 Task List:** View assigned cleaning duties.
* **✅ Confirmation:** Feature to mark alerts/reports as 'Resolved.'
* **🗂️ Report Issue:** Report damaged bins/zones with photo uploads.
* **🔎 Quick Filters:**
   - Show Critical Only
   - Show Nearby Bins/Zones (Within x radius)
   - Show Assigned Tasks

---

### Single Bin and Zone Status Cards

#### Single Bin Card
* **📊 Fill Level:** %
* **☁️ Air Quality Index**
* **🕒 Next Predicted Overflow:** “In Y hrs”
* **🚦 Status:** Normal / Moderate / Critical

#### Zone Card
* **🗑 Number of Bins**
* **📊 Fill Level**
* **☁️ Air Quality Index**
* **🕒 Next Predicted Overflow  (Bin-specific):** "In Y hrs"
* **🚦 Status:** Normal / Moderate / Critical

---

### Status Logic

| Status    | Threshold | Single Bin Conditions | Zone Conditions |
|----------|----------|----------------------|------------------------------|
| **🟢 Normal** | Fill < 70%<br>Gas: Safe Range<br>Flame: None | - Fill Level < 70%<br>- Gas levels within safe range<br>- No flame detected<br>- No anomalies | - All bins within safe limits<br>- No gas/fire risk in zone<br>- No anomalies |
| **🟠 Moderate** | Fill: 70–90%<br>Overflow < 4 hrs<br>Minor Gas/Fire Risk | - Fill Level between 70–90%<br>- Predicted overflow in < 4 hrs<br>- Slight increase in gas OR minor fire risk<br>- Non-critical anomaly | - Any bin predicted to overflow in < 4 hrs<br>- Moderate gas levels in zone<br>- Minor fire risk in any bin<br>- Non-critical anomaly |
| **🔴 Critical** | Fill ≥ 90%<br>Gas: Unsafe<br>Flame:Detected | - Fill Level ≥ 90% (or full)<br>- Gas exceeds safe limits<br>- Flame detected<br>- High-risk anomaly | - Any bin is full<br>- High gas levels in zone<br>- Flame detected in any bin<br>- Multiple bins in moderate/critical state |

---

## Future Scope
* **VOC & Humidity Sensors:** For precise odor detection and moisture monitoring.
* **Smart Route Optimization:** AI-driven path planning for collection vehicles based on real-time fill levels.
* **Smart City Integration:** Direct API integration with municipal waste management grids.
* **Computer Vision:** Advanced cameras for automated waste segregation at the source.

---

## Conclusion
BinSight delivers a smart, scalable, and efficient waste monitoring solution combining IoT, analytics, and safety systems to modernize urban waste management.
