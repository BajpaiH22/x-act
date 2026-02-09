# BLE Scanner & Surveyor App (Flutter)

**Description:**
A Flutter application that scans BLE devices, connects to a specific sensor device, reads live gas sensor data (Methane, Ethane), tracks GPS location, logs data to local CSV files with TTL (Time-to-Live), and allows users to manage and share recorded sessions.
The app also supports alarms, map visualization, and a pending files management UI.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Dependencies](#dependencies)
3. [Folder/File Structure](#folderfile-structure)
4. [Core Components](#core-components)
5. [BLE Data Flow](#ble-data-flow)
6. [Local Cache & CSV Logging](#local-cache--csv-logging)
7. [UI Overview](#ui-overview)
8. [Maps & GPS Integration](#maps--gps-integration)
9. [Pending Files Management](#pending-files-management)
10. [Alarm System](#alarm-system)
11. [Extending / Modifying the App](#extending--modifying-the-app)

## Architecture Overview

This app follows a **stateful Flutter architecture** with emphasis on:

* **BLE scanning & device connection:** Managed by `FlutterBluePlus`.
* **Data logging:** Using a custom TTL-based CSV file cache (`TTLFileCache`).
* **GPS & mapping:** Using `Geolocator` for live location and `FlutterMap` for map rendering.
* **UI:** Flutter widgets with `StatefulWidgets` for dynamic updates.
* **Audio & vibration alerts:** For threshold-based alarms.
* **Pending file management:** For viewing, previewing, sharing, or deleting cached CSV files.

### Architecture Diagram

[BLE Device] ---> [FlutterBluePlus] ---> [BLEScanner / SerialDataPage] ---> [TTLFileCache CSV]
                        |
                        v
                  [UI Update & Alarm]
                        |
                        v
                 [Map + GPS Integration]
                        |
                        v
                 [Pending Files UI]


The diagram illustrates the data flow:

* BLE device → FlutterBluePlus → SerialDataPage → TTLFileCache → PendingFilesPage
* GPS location feeds into map display and logs
* UI updates and alarm triggers in SerialDataPage

## Dependencies

| Package                    | Purpose                                                   |
| -------------------------- | --------------------------------------------------------- |
| `flutter_blue_plus`        | BLE scanning, connecting, reading/writing characteristics |
| `permission_handler`       | Requesting Bluetooth & location permissions               |
| `geolocator`               | GPS positioning and live location updates                 |
| `flutter_map` + `latlong2` | Map display and markers                                   |
| `audioplayers`             | Playing audio alarms                                      |
| `vibration`                | Device vibration for alerts                               |
| `share_plus`               | Sharing CSV files with other apps                         |
| `path_provider`            | File system directories for caching CSVs                  |

## Folder/File Structure

* **main.dart** – Contains the entire application logic.
* **assets/** – `logo.png`, `alert.mp3` for UI branding and alarms.
* **Cache Directory:** `surveyor_cache/`

  * `.index.json` – Index of cached CSV files
  * `.session_counter` – Incremental session number tracking

## Core Components

### TTLFileCache

* Persistent local cache for CSV files with TTL.
* Automatic cleanup of expired files.
* Incremental session numbering.
* Max storage enforcement (e.g., 200 MB).
* Provides methods like `appendLine`, `ensureHeader`, `listActive`, `markUploaded`.

### BLEScanner

* Main screen to scan nearby BLE devices.
* Requests Bluetooth and location permissions.
* Tap device → connect → open `SerialDataPage`.
* Access to pending files.

### SerialDataPage

* Connected device view and live data stream.
* BLE characteristic subscription.
* Parses CSV packets into `Methane` and `Ethane` readings.
* Logs readings to CSV via TTLFileCache.
* Live GPS tracking and map display.
* Alarm logic based on thresholds.
* Pause/resume stream.
* Compact/full view toggle.

### PendingFilesPage

* Lists active cached CSV files.
* Metadata: size, record count, last modified.
* Actions: preview, share, delete, purge expired files.

## BLE Data Flow

1. Scan devices with `FlutterBluePlus.startScan()`.
2. Connect to a device, discover services.
3. Subscribe to characteristic (UUID defined in `SerialDataPage`).
4. On BLE notification:

   * Parse CSV string.
   * Append to CSV file via TTLFileCache.
   * Update UI.
   * Trigger alarm if threshold exceeded.

## Local Cache & CSV Logging

* **Session file naming:** `survey_{device_name}_{last6_deviceID}_session_{counter}_{UTCtimestamp}.csv`
* **Header:** `GPS UTC,Error Code,Methane (ppm),Ethane (ppm),Phone Latitude,Phone Longitude`
* **Cache rules:** TTL 14 days, Max size 200MB, Automatic purge.

## UI Overview

* **BLEScanner Page:** AppBar with logo, list of scanned devices, pending files button.
* **SerialDataPage:** AppBar with device name, pause/play, compact/full toggle; Map; Methane/Ethane card; Threshold slider; Alarm toggle.
* **PendingFilesPage:** Summary bar, list of files, preview/share/delete actions, purge expired files.

## Maps & GPS Integration

* Library: flutter_map + latlong2
* Live tracking using `Geolocator.getPositionStream()`.
* Map markers for current Phone location marker i.e. GPS location and custom markers via map tap.
* Map auto-centers and zooms on GPS updates.

## Alarm System

* Triggers when Methane exceeds threshold.
* Audio alert via `audioplayers`.
* Vibration alert via `vibration`.
* 10-second cooldown between alarms.

## Pending Files Management

* Lists all active CSV files in TTLFileCache.
* Shows metadata: size, record count, last modified.
* Actions:
  * Preview (DataTable view)
  * Share (via share_plus)
  * Delete local copy
  * Purge expired files

## Extending / Modifying the App

* **Adjust BLE UUIDs:** Change `serviceUUID` and `charUUID`.
* **Add sensors:** Update `parseCSV()` and CSV header.
* **Map customization:** Modify TileLayer or markers.
* **UI improvements:** Split widgets into separate files.
* **Data export:** Add cloud upload logic in `_saveReadingToCache()`.

---

**Code:** Aryan/Harshita
**Author:** Harshita
**License:** MIT
