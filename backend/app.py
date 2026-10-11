import asyncio
import json
import logging
import os
import re
import threading
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from statsmodels.tsa.arima.model import ARIMA

import paho.mqtt.client as mqtt
from bson import Binary
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pymongo import MongoClient, ReturnDocument
from pymongo.collation import Collation
from pymongo.errors import DuplicateKeyError, PyMongoError

load_dotenv(Path(__file__).with_name('.env'))

logging.basicConfig(level=os.getenv('LOG_LEVEL', 'INFO'))
logger = logging.getLogger('binsight')

MONGODB_URI = os.getenv('MONGODB_URI', '')
MONGODB_DB = os.getenv('MONGODB_DB', 'binsight')
PORT = int(os.getenv('PORT', '5000'))
APP_BASE_URL = os.getenv('APP_BASE_URL', f'http://localhost:{PORT}')
CORS_ORIGINS = [origin.strip() for origin in os.getenv('CORS_ORIGINS', '').split(',') if origin.strip()]
MQTT_URL = os.getenv('MQTT_URL', '')
MQTT_USERNAME = os.getenv('MQTT_USERNAME', '')
MQTT_PASSWORD = os.getenv('MQTT_PASSWORD', '')
FILL_LEVEL_FULL_THRESHOLD = float(os.getenv('FILL_LEVEL_FULL_THRESHOLD', '90'))
FILL_LEVEL_MODERATE_THRESHOLD = float(os.getenv('FILL_LEVEL_MODERATE_THRESHOLD', '50'))
FILL_LEVEL_ALMOST_FULL_THRESHOLD = float(os.getenv('FILL_LEVEL_ALMOST_FULL_THRESHOLD', '70'))
GAS_LEVEL_CRITICAL_THRESHOLD = float(os.getenv('GAS_LEVEL_CRITICAL_THRESHOLD', '601'))
GAS_LEVEL_MODERATE_THRESHOLD = float(os.getenv('GAS_LEVEL_MODERATE_THRESHOLD', '401'))
DEVICE_OFFLINE_TIMEOUT_SECONDS = int(os.getenv('DEVICE_OFFLINE_TIMEOUT_SECONDS', '5'))
CRITICAL_ESCALATION_MINUTES = int(os.getenv('CRITICAL_ESCALATION_MINUTES', '60'))
CRITICAL_REMINDERS_ENABLED = os.getenv('CRITICAL_REMINDERS_ENABLED', 'true').lower() == 'true'
SENSOR_ERROR_REPEAT_COUNT = int(os.getenv('SENSOR_ERROR_REPEAT_COUNT', '3'))
MAX_INLINE_IMAGE_BYTES = 14 * 1024 * 1024
ADMIN_NOTIFICATION_TYPES = (
    'report_submitted',
    'unresolved_critical_alert',
    'task_acknowledged',
    'task_completed',
    'device_offline',
    'device_online',
    'sensor_issue',
)
ADMIN_NOTIFICATION_DEFAULTS = {notification_type: True for notification_type in ADMIN_NOTIFICATION_TYPES}
WORKER_NOTIFICATION_TYPES = (
    'task_updates', 'critical_reminders', 'bin_alerts', 'report_updates',
)
_admin_connectivity_events: dict[str, list[dict[str, Any]]] = {}
_admin_connectivity_events_lock = threading.Lock()


def queue_admin_connectivity_event(
    db: Any, message: str, event_key: str, created_at: datetime, notification_type: str,
) -> None:
    # One-time in-memory banner; online notices are not persisted.
    with _admin_connectivity_events_lock:
        for admin in db.admins.find({}):
            admin_id = str(admin.get('admin_id') or admin.get('_id') or '')
            if not admin_id or not admin_notification_preferences(admin).get(notification_type, True):
                continue
            events = _admin_connectivity_events.setdefault(admin_id, [])
            events.append({
                'notification_id': f'ephemeral:{event_key}:{admin_id}',
                'message': message,
                'notification_type': notification_type,
                'created_at': created_at,
            })
            del events[:-50]


def worker_notification_category(notification_type: str, has_report: bool = False) -> str | None:
    if has_report or notification_type in {'report_resolved', 'report_update'}:
        return 'report_updates'
    if notification_type in {'task_assigned', 'task_reassigned', 'task_acknowledged', 'task_completed'}:
        return 'task_updates'
    if notification_type in {'critical_alert_reminder', 'reminder'}:
        return 'critical_reminders'
    if notification_type == 'bin_almost_full':
        return 'bin_alerts'
    return None


def worker_notification_preferences(worker: dict[str, Any]) -> dict[str, bool]:
    configured = worker.get('notification_preferences')
    configured = configured if isinstance(configured, dict) else {}
    return {
        category: configured.get(category, True) is True
        for category in WORKER_NOTIFICATION_TYPES
    }


def admin_notification_preferences(admin: dict[str, Any]) -> dict[str, bool]:
    configured = admin.get('notification_preferences')
    configured = configured if isinstance(configured, dict) else {}
    return {
        notification_type: configured.get(notification_type, True) is True
        for notification_type in ADMIN_NOTIFICATION_TYPES
    }


def validate_telemetry(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError('Telemetry payload must be a JSON object')
    fill_level = payload.get('fill_level')
    fill_valid = payload.get('fill_valid', True)
    gas_level = payload.get('gas_level')
    flame = payload.get('flame')
    if not isinstance(fill_valid, bool):
        raise ValueError('fill_valid must be a boolean')
    if fill_valid and (isinstance(fill_level, bool) or not isinstance(fill_level, (int, float)) or not 0 <= fill_level <= 100):
        raise ValueError('fill_level must be a number from 0 to 100 when fill_valid is true')
    if isinstance(gas_level, bool) or not isinstance(gas_level, (int, float)) or not 0 <= gas_level <= 100000:
        raise ValueError('gas_level must be a PPM value from 0 to 100000')
    if not isinstance(flame, bool):
        raise ValueError('flame must be a boolean')
    readings = {'gas_level': gas_level, 'flame': flame, 'fill_valid': fill_valid}
    if fill_valid:
        readings['fill_level'] = fill_level
    if 'battery_percent' in payload:
        battery_percent = payload['battery_percent']
        if (isinstance(battery_percent, bool)
                or not isinstance(battery_percent, (int, float))
                or not 0 <= battery_percent <= 100):
            raise ValueError('battery_percent must be a number from 0 to 100 when provided')
        readings['battery_percent'] = battery_percent
    return readings


def assess_telemetry(
    readings: dict[str, Any],
    fill_threshold: float = FILL_LEVEL_FULL_THRESHOLD,
    gas_threshold: float = GAS_LEVEL_CRITICAL_THRESHOLD,
    full_duration_seconds: int = 0,
) -> dict[str, Any]:
    fill_level = readings['fill_level']
    gas_level = readings['gas_level']
    bin_full = fill_level >= fill_threshold
    fill_critical = bin_full and full_duration_seconds >= 3600
    gas_critical = gas_level >= gas_threshold
    fire_alert = readings['flame']
    fill_moderate = fill_level >= FILL_LEVEL_MODERATE_THRESHOLD
    gas_moderate = gas_level >= GAS_LEVEL_MODERATE_THRESHOLD
    critical = fill_critical or gas_critical or fire_alert
    moderate = fill_moderate or gas_moderate
    return {
        'bin_full': bin_full,
        'full_duration_seconds': max(0, int(full_duration_seconds)),
        'fill_alert': fill_critical,
        'gas_alert': gas_critical,
        'fire_alert': fire_alert,
        'fill_moderate': fill_moderate,
        'fill_almost_full': fill_level >= FILL_LEVEL_ALMOST_FULL_THRESHOLD,
        'gas_moderate': gas_moderate and not gas_critical,
        'status': 'critical' if critical else ('moderate' if moderate else 'normal'),
    }


def _overflow_forecast(fill_history: list[dict[str, Any]]) -> dict[str, Any]:
    """Forecast the first 100% crossing with hourly ARIMA, with a sparse-data fallback."""
    empty = {
        'next_overflow_hours': None,
        'next_overflow_time': 'Insufficient hourly history for forecast',
        'overflow_forecast_method': 'Insufficient data',
    }
    if not fill_history:
        return empty

    fill_frame = pd.DataFrame(fill_history)
    if 'received_at' not in fill_frame or 'fill_level' not in fill_frame:
        return empty
    fill_frame['received_at'] = pd.to_datetime(fill_frame['received_at'], utc=True, errors='coerce')
    fill_frame['fill_level'] = pd.to_numeric(fill_frame['fill_level'], errors='coerce')
    fill_frame = fill_frame.dropna(subset=['received_at', 'fill_level'])
    fill_frame = fill_frame[(fill_frame['fill_level'] >= 0) & (fill_frame['fill_level'] <= 100)]
    if fill_frame.empty:
        return empty

    hourly = (fill_frame.set_index('received_at')['fill_level']
              .resample('1h').mean()
              .interpolate(method='time', limit=3)
              .dropna()
              .tail(168))
    if hourly.empty:
        return empty
    current_fill = float(hourly.iloc[-1])
    if current_fill >= 100:
        return {
            'next_overflow_hours': 0.0,
            'next_overflow_time': 'Now (at or above 100%)',
            'overflow_forecast_method': 'Current fill level',
        }

    forecast_values = None
    method = 'ARIMA(1,1,1)'
    if len(hourly) >= 24:
        try:
            fitted = ARIMA(
                hourly.to_numpy(dtype=float),
                order=(1, 1, 1),
                enforce_stationarity=False,
                enforce_invertibility=False,
            ).fit()
            forecast_values = np.asarray(fitted.forecast(steps=168), dtype=float)
            if not np.isfinite(forecast_values).all():
                forecast_values = None
        except Exception:
            logger.exception('ARIMA overflow forecast failed; using recent-rate fallback')
            forecast_values = None
            method = 'Recent-rate fallback (ARIMA fit failed)'
    else:
        method = 'Recent-rate fallback (need 24 hourly points for ARIMA)'

    if forecast_values is not None:
        previous = current_fill
        for step, raw_value in enumerate(forecast_values, start=1):
            value = float(np.clip(raw_value, 0, 100))
            if value >= 100:
                fraction = (100 - previous) / (value - previous) if value > previous else 1.0
                hours = max(0.0, (step - 1) + min(1.0, max(0.0, fraction)))
                return {
                    'next_overflow_hours': round(hours, 1),
                    'next_overflow_time': f'~{hours:.1f} hrs',
                    'overflow_forecast_method': method,
                }
            previous = value
        return {
            'next_overflow_hours': None,
            'next_overflow_time': 'No overflow predicted in the next 7 days',
            'overflow_forecast_method': method,
        }

    # Keep a useful estimate for short histories or model convergence failures.
    rates = hourly.diff().dropna()
    rising_rates = rates[rates > 0].tail(12)
    if len(rising_rates):
        weights = np.arange(1, len(rising_rates) + 1, dtype=float)
        rate_per_hour = float(np.average(rising_rates.to_numpy(dtype=float), weights=weights))
        hours = max(0.0, (100 - current_fill) / rate_per_hour)
        return {
            'next_overflow_hours': round(hours, 1),
            'next_overflow_time': f'~{hours:.1f} hrs',
            'overflow_forecast_method': method,
        }
    return {
        'next_overflow_hours': None,
        'next_overflow_time': 'Insufficient rising fill trend',
        'overflow_forecast_method': method,
    }


def predict_sensor_metrics(
    history: list[dict[str, Any]],
    fill_history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Forecast overflow with hourly ARIMA; use z-scores for gas and fire indicators."""
    if not history and not fill_history:
        return {
            **_overflow_forecast([]),
            'gas_z_score': None,
            'gas_spike': False,
            'fire_risk': False,
        }
    frame = pd.DataFrame(history)
    if not frame.empty and 'received_at' in frame:
        frame['received_at'] = pd.to_datetime(frame['received_at'], utc=True, errors='coerce')
        frame = frame.dropna(subset=['received_at']).sort_values('received_at')
    gas_z = None
    gas_spike = False
    fire_risk = bool(frame.iloc[-1].get('flame', False)) if not frame.empty else False
    if 'gas_level' in frame:
        gas = pd.to_numeric(frame['gas_level'], errors='coerce').dropna()
        if len(gas) >= 5:
            baseline = gas.iloc[:-1].tail(30).to_numpy(dtype=float)
            deviation = float(np.std(baseline)) if len(baseline) else 0.0
            if deviation > 0:
                gas_z = float((float(gas.iloc[-1]) - float(np.mean(baseline))) / deviation)
            elif len(baseline) and float(gas.iloc[-1]) > float(np.mean(baseline)):
                gas_z = 99.0
            gas_spike = gas_z is not None and gas_z >= 3.0
    if 'flame' in frame:
        flame = pd.to_numeric(frame['flame'].astype(int), errors='coerce').dropna()
        if len(flame) >= 5:
            baseline = flame.iloc[:-1].tail(30).to_numpy(dtype=float)
            deviation = float(np.std(baseline)) if len(baseline) else 0.0
            if deviation > 0:
                fire_risk = fire_risk or float((float(flame.iloc[-1]) - float(np.mean(baseline))) / deviation) >= 3.0
            elif len(baseline) and float(flame.iloc[-1]) > float(np.mean(baseline)):
                fire_risk = True
    return {
        **_overflow_forecast(fill_history if fill_history is not None else history),
        'gas_z_score': round(gas_z, 2) if gas_z is not None else None,
        'gas_spike': gas_spike,
        'fire_risk': fire_risk,
    }


def zone_summary(zone: dict[str, Any], bins: list[dict[str, Any]]) -> dict[str, Any]:
    assigned = [bin_doc for bin_doc in bins if bin_doc.get('zone_id') == zone.get('zone_id')]
    readings = [
        {
            'bin_id': bin_doc.get('bin_id'),
            'name': bin_doc.get('name'),
            'status': bin_doc.get('status', 'normal'),
            'fill_level': bin_doc.get('fill_level', 0),
            'gas_level': bin_doc.get('gas_level', 0),
            'fill_alert': bin_doc.get('fill_alert', False),
            'gas_alert': bin_doc.get('gas_alert', False),
            'fire_alert': bin_doc.get('fire_alert', bin_doc.get('flame', False)),
            'flame': bin_doc.get('flame', False),
            'last_updated': bin_doc.get('last_updated'),
        }
        for bin_doc in assigned
    ]
    clean_zone = {key: value for key, value in zone.items() if key != '_id'}
    for field in ('avg_fill_level', 'gas_alert', 'fire_alert', 'status'):
        clean_zone.pop(field, None)
    return {**clean_zone, 'bin_count': len(assigned), 'bins': readings}


def split_name(name: str = '') -> tuple[str, str]:
    parts = name.strip().split()
    return (parts[0], ' '.join(parts[1:])) if parts else ('', '')


def device_type_from_qr(raw_value: str = '') -> str | None:
    normalized = raw_value.strip().lower()
    if normalized == 'bin' or normalized.startswith('bin:'):
        return 'bin'
    if normalized == 'zone' or normalized.startswith('zone:'):
        return 'zone'
    try:
        value = json.loads(raw_value)
    except (TypeError, json.JSONDecodeError):
        return None
    return value.get('type') if isinstance(value, dict) and value.get('type') in {'bin', 'zone'} else None


def reindex_bin_names(db: Any) -> None:
    bins = list(db.bins.find({}).sort('created_at', 1))
    for index, bin_doc in enumerate(bins, start=1):
        new_name = f'Bin {index}'
        if bin_doc.get('name') == new_name:
            continue
        db.bins.update_one(
            {'_id': bin_doc['_id']},
            {'$set': {'name': new_name, 'updated_at': datetime.now(timezone.utc)}},
        )


def worker_query(worker_id: str) -> dict[str, Any]:
    return {'$or': [{'_id': worker_id}, {'worker_id': worker_id}]}


def next_sequence(db: Any, name: str) -> int:
    result = db.counters.find_one_and_update(
        {'_id': name},
        {'$inc': {'sequence_value': 1}},
        upsert=True,
        return_document=ReturnDocument.AFTER,
    )
    return result['sequence_value']


def zone_name_exists(db: Any, name: str) -> bool:
    return db.zones.find_one({
        'name': {'$regex': f'^{re.escape(name.strip())}$', '$options': 'i'},
    }) is not None


def normalize_base_url(url: str) -> str:
    return (
        url.replace('http://localhost:50005000', 'http://localhost:5000')
        .replace('http://127.0.0.1:50005000', 'http://127.0.0.1:5000')
        .replace('http://localhost:5000', 'http://localhost:5000')
    )


def get_image_url(collection_name: str, owner_id: str) -> str:
    return f"{normalize_base_url(APP_BASE_URL)}/images/{collection_name.removesuffix('_images')}/{owner_id}"


def ensure_profile_image_url(db: Any, doc: dict[str, Any], collection_name: str, owner_field: str) -> dict[str, Any]:
    next_doc = dict(doc)
    owner_id = str(next_doc.get(owner_field) or next_doc.get('_id') or '').strip()
    if not owner_id:
        return next_doc

    current_url = str(next_doc.get('profile_image_url') or '').strip()
    if current_url:
        return next_doc

    stored = db[collection_name].find_one({owner_field: owner_id})
    if stored:
        next_doc['profile_image_url'] = get_image_url(collection_name, owner_id)
    return next_doc


async def upsert_image(
    db: Any,
    collection_name: str,
    owner_field: str,
    owner_id: str,
    upload: UploadFile | None,
) -> str | None:
    if upload is None:
        return None
    data = await upload.read(MAX_INLINE_IMAGE_BYTES + 1)
    if len(data) > MAX_INLINE_IMAGE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f'Image for {owner_id} is too large to store inline in MongoDB. Please use an image smaller than 14 MB.',
        )
    now = datetime.now(timezone.utc)
    db[collection_name].update_one(
        {owner_field: owner_id},
        {
            '$set': {
                owner_field: owner_id,
                'filename': upload.filename or '',
                'content_type': upload.content_type or 'application/octet-stream',
                'size': len(data),
                'updated_at': now,
                'data': Binary(data),
            },
            '$setOnInsert': {'created_at': now},
        },
        upsert=True,
    )
    return get_image_url(collection_name, owner_id)


def parse_location(config: dict[str, Any]) -> tuple[float, float]:
    organization = config.get('organization_location') or config.get('location') or {}
    if not isinstance(organization, dict):
        organization = {}
    coordinates = organization.get('coordinates') or (organization.get('location') or {}).get('coordinates')

    def valid_pair(latitude: Any, longitude: Any) -> tuple[float, float] | None:
        try:
            latitude = float(latitude)
            longitude = float(longitude)
        except (TypeError, ValueError):
            return None
        if abs(latitude) > 90 or abs(longitude) > 180 or (latitude == 0 and longitude == 0):
            return None
        return latitude, longitude

    pairs = [
        (organization.get('latitude'), organization.get('longitude')),
        (organization.get('lat'), organization.get('lng', organization.get('lon'))),
        (coordinates[1], coordinates[0]) if isinstance(coordinates, list) and len(coordinates) >= 2 else (None, None),
        (config.get('latitude'), config.get('longitude')),
        (config.get('location_lat'), config.get('location_lon')),
    ]
    for pair in pairs:
        result = valid_pair(*pair)
        if result is not None:
            return result
    return 0.0, 0.0


def full_device_name(device_doc: dict[str, Any], fallback: str = 'Bin') -> str:
    name = str(device_doc.get('name') or fallback).strip()
    location = str(device_doc.get('location_description') or '').strip()
    picker_separator = location.rfind(' (')
    if location.endswith(')') and picker_separator > 0:
        location = location[:picker_separator].strip()
    return f'{name} - {location}' if location else name


def notify_recipients(db: Any, bin_doc: dict[str, Any], message: str, event_key: str, created_at: datetime, admins: bool = False) -> None:
    device_id = str(bin_doc.get('bin_id') or bin_doc.get('_id') or '')
    device_name = full_device_name(bin_doc, device_id or 'Bin')
    if device_name and device_name not in message:
        message = f'{device_name}: {message}'
    recipients: set[tuple[str, str]] = set()
    if admins:
        notification_type = event_key.split(':', 1)[0]
        for account in db.admins.find({}):
            account_id = str(account.get('admin_id') or account.get('_id') or '')
            if account_id and admin_notification_preferences(account).get(notification_type, False):
                recipients.add(('admin_id', account_id))
    else:
        query: dict[str, Any] = {'assigned_bins': device_id}
        if bin_doc.get('zone_id'):
            query = {'$or': [{'assigned_bins': device_id}, {'assigned_zones': bin_doc['zone_id']}]}
        notification_type = event_key.split(':', 1)[0]
        category = worker_notification_category(notification_type)
        for account in db.workers.find(query):
            account_id = str(account.get('worker_id') or account.get('_id') or '')
            if account_id and (category is None or worker_notification_preferences(account).get(category, True)):
                recipients.add(('worker_id', account_id))
    for field, account_id in sorted(recipients):
        notification_id = f'{event_key}:{account_id}'
        db.notifications.update_one({'_id': notification_id}, {'$setOnInsert': {
            '_id': notification_id, 'notification_id': notification_id, field: account_id,
            'device_id': device_id, 'message': message,
            'report_name': bin_doc.get('name') or device_id,
            'notification_type': event_key.split(':', 1)[0], 'created_at': created_at,
        }}, upsert=True)


def clear_device_offline_notifications(db: Any, device_id: str) -> None:
    # Also match IDs from notifications created before device_id was stored.
    escaped_id = re.escape(device_id)
    db.notifications.delete_many({
        'notification_type': {'$in': ['device_offline', 'offline']},
        '$or': [
            {'device_id': device_id},
            {'notification_id': {'$regex': f'^(device_offline|offline):{escaped_id}:'}},
        ],
    })
    # Remove any old persisted online notices too; reconnect banners are now transient.
    db.notifications.delete_many({
        'notification_type': {'$in': ['device_online', 'online']},
        '$or': [
            {'device_id': device_id},
            {'notification_id': {'$regex': f'^(device_online|online):{escaped_id}:'}},
        ],
    })
    db.alerts.delete_many({
        'device_id': device_id,
        'alert_type': {'$in': ['device_offline', 'offline']},
    })


def record_device_connectivity(db: Any, bin_doc: dict[str, Any], device_id: str, online: bool, at: datetime, force: bool = False) -> None:
    update: dict[str, Any] = {'$set': {'is_online': online}}
    if online:
        update['$set']['last_connection_seen'] = at
        update['$unset'] = {'offline_since': ''}
    else:
        update['$set']['offline_since'] = at
    query: dict[str, Any] = {'_id': bin_doc['_id']}
    if not online and not force:
        cutoff = at - timedelta(seconds=DEVICE_OFFLINE_TIMEOUT_SECONDS)
        query.update({
            'is_online': {'$ne': False},
            '$or': [
                {'last_connection_seen': {'$lt': cutoff}},
                {'last_connection_seen': {'$exists': False}, 'last_updated': {'$lt': cutoff}},
                {'last_connection_seen': {'$exists': False}, 'last_updated': {'$exists': False}},
            ],
        })
    previous = db.bins.find_one_and_update(
        query, update, return_document=ReturnDocument.BEFORE,
    )
    if previous is None:
        return
    was_online = previous.get('is_online', True) is not False
    bin_name = full_device_name(bin_doc, device_id).strip() or device_id
    if online and not was_online:
        event_key = f'device_online:{device_id}:{int(at.timestamp())}'
        message = f'🟢 {bin_name} is online.'
        queue_admin_connectivity_event(db, message, event_key, at, 'device_online')
        # Resolving online clears both the offline notification and operational alert.
        clear_device_offline_notifications(db, device_id)
    elif not online and was_online:
        event_key = f'device_offline:{device_id}:{int(at.timestamp())}'
        message = f'⚠️ {bin_name} is offline.'
        notify_recipients(db, bin_doc, message, event_key, at, admins=True)


def mqtt_message(client: mqtt.Client, userdata: Any, message: mqtt.MQTTMessage) -> None:
    db = userdata['db']
    status_match = re.fullmatch(r'binsight/devices/([^/]+)/status', message.topic)
    if status_match is not None:
        device_id = status_match.group(1)
        try:
            bin_doc = db.bins.find_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]})
            if bin_doc is None:
                logger.warning('Ignoring connection status for unregistered device %s', device_id)
                return
            status = message.payload.decode('utf-8', errors='replace').strip().lower()
            if status in {'online', 'offline'}:
                record_device_connectivity(
                    db, bin_doc, device_id, status == 'online', datetime.now(timezone.utc),
                    force=status == 'offline',
                )
        except Exception:
            # A temporary database outage must not terminate Paho's network
            # thread; otherwise all later heartbeats are lost until API restart.
            logger.exception('Failed to persist connection status for device %s', device_id)
        return

    match = re.fullmatch(r'binsight/devices/([^/]+)/telemetry', message.topic)
    if match is None:
        return
    device_id = match.group(1)
    try:
        payload = json.loads(message.payload.decode('utf-8'))
        readings = validate_telemetry(payload)
        sample_id = str(payload.get('sample_id') or '').strip()
        bin_doc = db.bins.find_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]})
        if bin_doc is None:
            logger.warning('Ignoring telemetry for unregistered device %s', device_id)
            return
        # Keep telemetry flowing if the ultrasonic sensor misses an echo. Gas and
        # flame still update; fill stays at its last known value until valid again.
        if 'fill_level' not in readings:
            # The bin snapshot can be empty/stale (for example after a legacy
            # invalid sample wrote its default 0). Recover fill from the latest
            # valid sensor sample before falling back to the snapshot.
            device_aliases = {device_id, str(bin_doc.get('_id', ''))}
            if bin_doc.get('bin_id'):
                device_aliases.add(str(bin_doc['bin_id']))
            last_valid_fill = db.telemetry.find_one(
                {
                    'device_id': {'$in': list(device_aliases)},
                    'fill_valid': {'$ne': False},
                    'fill_level': {'$type': 'number', '$gte': 0, '$lte': 100},
                },
                sort=[('received_at', -1)],
            )
            preserved_fill = (last_valid_fill or {}).get(
                'fill_level', bin_doc.get('fill_level', 0)
            )
            readings['fill_level'] = preserved_fill
        # Older firmware publishes retained samples without a sample_id. When
        # FastAPI subscribes/restarts, ignore an identical retained replay so
        # the history count does not grow from the same stale reading.
        if message.retain and not sample_id:
            latest_record = db.telemetry.find_one(
                {'device_id': device_id}, sort=[('received_at', -1)]
            )
            compared_fields = ('fill_level', 'gas_level', 'flame')
            if latest_record and all(
                latest_record.get(field) == readings.get(field)
                for field in compared_fields
            ):
                logger.info(
                    'Ignored duplicate retained legacy telemetry for device %s',
                    device_id,
                )
                return
        received_at = datetime.now(timezone.utc)
        previous_status = str(bin_doc.get('status', 'normal')).lower()
        full_since = bin_doc.get('full_since')
        full_duration_seconds = 0
        if readings['fill_level'] >= FILL_LEVEL_FULL_THRESHOLD:
            if isinstance(full_since, str):
                try:
                    full_since = datetime.fromisoformat(full_since.replace('Z', '+00:00'))
                except ValueError:
                    full_since = None
            if full_since is None:
                full_since = received_at
            elif full_since.tzinfo is None:
                full_since = full_since.replace(tzinfo=timezone.utc)
            full_duration_seconds = max(0, int((received_at - full_since).total_seconds()))
        else:
            full_since = None
        assessment = assess_telemetry(readings, FILL_LEVEL_FULL_THRESHOLD, GAS_LEVEL_CRITICAL_THRESHOLD, full_duration_seconds)
        # Persist the history record first. The bin snapshot drives the live UI,
        # so advancing it before this insert could make a failed history write
        # look like successful telemetry ingestion.
        telemetry_record = {
            'device_id': device_id,
            **({'sample_id': sample_id} if sample_id else {}),
            **readings,
            **assessment,
            **({'full_since': full_since} if full_since is not None else {}),
            'topic': message.topic,
            'received_at': received_at,
        }
        if sample_id:
            telemetry_record['_id'] = f'{device_id}:{sample_id}'
        try:
            telemetry_result = db.telemetry.insert_one(telemetry_record)
            if not telemetry_result.acknowledged:
                raise PyMongoError(f'Telemetry insert was not acknowledged for {device_id}')
            logged_record = {**telemetry_record, '_id': str(telemetry_result.inserted_id)}
            logger.info(
                'Stored telemetry JSON: %s',
                json.dumps(logged_record, default=str, separators=(',', ':')),
            )
        except DuplicateKeyError:
            if not sample_id:
                raise
            # A retained sample replay after FastAPI restarts is already in history.
            # Do not refresh last_updated or emit events from an old sample.
            logger.info('Retained telemetry sample %s for %s was already stored', sample_id, device_id)
            return
        record_device_connectivity(db, bin_doc, device_id, True, received_at)
        bin_update = {
            '$set': {
                **readings, **assessment, 'last_updated': received_at,
                'last_connection_seen': received_at, 'is_online': True,
                'sensor_error_count': 0, 'sensor_issue_active': False,
            },
            '$unset': {'offline_since': ''},
        }
        if full_since is not None:
            bin_update['$set']['full_since'] = full_since
        else:
            bin_update['$unset']['full_since'] = ''
        db.bins.update_one({'_id': bin_doc['_id']}, bin_update)
        rules = [
            ('fill_level', assessment['fill_moderate'],
             'is full' if assessment['fill_alert'] else ('is nearly full' if assessment['fill_almost_full'] else 'fill level is moderate'),
             'critical' if assessment['fill_alert'] else 'moderate'),
            ('air_quality', assessment['gas_moderate'] or assessment['gas_alert'],
             'air quality is hazardous' if assessment['gas_alert'] else ('air quality is poor' if readings['gas_level'] > 500 else 'air quality is moderate'),
             'critical' if assessment['gas_alert'] else 'moderate'),
            ('flame', assessment['fire_alert'], 'fire sensor detected a fire risk', 'critical'),
        ]
        muted_alert_types = set(bin_doc.get('muted_alert_types', []))
        for alert_type, active, alert_message, severity in rules:
            alert_id = f'{device_id}:{alert_type}'
            prior_alert = db.alerts.find_one({'alert_id': alert_id})
            if not active and alert_type in muted_alert_types:
                db.bins.update_one({'_id': bin_doc['_id']}, {'$pull': {'muted_alert_types': alert_type}})
                muted_alert_types.discard(alert_type)
            if active and alert_type in muted_alert_types:
                continue
            if active:
                new_event = prior_alert is None or prior_alert.get('status') != 'open'
                promoted = prior_alert is not None and prior_alert.get('status') == 'open' and prior_alert.get('severity') != severity
                update = {
                    'alert_id': alert_id,
                    'device_id': device_id,
                    'device_name': full_device_name(bin_doc, device_id),
                    'alert_type': alert_type,
                    'message': f"{full_device_name(bin_doc, device_id)}: {alert_message}",
                    'severity': severity,
                    'status': 'open',
                    'last_updated': received_at,
                }
                update_ops = {'$set': update}
                if new_event or promoted:
                    update['created_at'] = received_at
                    update['escalation_sent'] = False
                    update['almost_full_notified'] = False
                    update_ops['$unset'] = {'reminder_sent_at': '', 'resolved_at': '', 'resolved_by': ''}
                else:
                    update_ops['$setOnInsert'] = {'created_at': received_at}
                db.alerts.update_one({'alert_id': alert_id}, update_ops, upsert=True)
                if (
                    alert_type == 'fill_level'
                    and assessment['fill_almost_full']
                    and (new_event or not prior_alert.get('almost_full_notified', False))
                ):
                    notify_recipients(
                        db, bin_doc,
                        '⚠️ Bin is almost full. Please arrange collection soon.',
                        f'bin_almost_full:{device_id}:{int(received_at.timestamp())}',
                        received_at,
                    )
                    db.alerts.update_one(
                        {'alert_id': alert_id, 'status': 'open'},
                        {'$set': {'almost_full_notified': True}},
                    )
            elif prior_alert is not None and prior_alert.get('status') == 'open':
                db.alerts.update_one({'alert_id': alert_id, 'status': 'open'}, {'$set': {
                    'status': 'cleared', 'last_updated': received_at, 'resolved_at': received_at,
                }})
        # Sensor transitions are stored in bins/alerts; almost-full transitions also notify assigned workers.
        db.bins.update_one({'_id': bin_doc['_id']}, {'$set': {'is_online': True}, '$unset': {'offline_since': ''}})
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        logger.warning('Rejected telemetry on %s: %s', message.topic, error)
        bin_doc = db.bins.find_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]})
        if bin_doc:
            count = int(bin_doc.get('sensor_error_count', 0)) + 1
            db.bins.update_one({'_id': bin_doc['_id']}, {'$set': {'sensor_error_count': count}})
            if count >= SENSOR_ERROR_REPEAT_COUNT and not bin_doc.get('sensor_issue_active', False):
                at = datetime.now(timezone.utc)
                db.bins.update_one({'_id': bin_doc['_id']}, {'$set': {'sensor_issue_active': True}})
                notify_recipients(
                    db, bin_doc,
                    '⚠️ Sensor issue detected. Please inspect the device.',
                    f'sensor_issue:{device_id}:{int(at.timestamp())}', at, admins=True,
                )
    except Exception:
        logger.exception('Failed to persist telemetry for device %s on %s', device_id, message.topic)


async def monitor_devices(db: Any) -> None:
    """Emit one offline/escalation event per transition, independent of dashboard polling."""
    while True:
        try:
            now = datetime.now(timezone.utc)
            for bin_doc in db.bins.find({}):
                device_id = str(bin_doc.get('bin_id') or bin_doc.get('_id') or '')
                # Use the same freshest heartbeat/telemetry timestamp that the
                # devices API uses, so an older connection field cannot keep a
                # bin marked offline after newer telemetry has arrived.
                online_now = _device_is_online(bin_doc, bin_doc.get('last_updated'))
                stale = not online_now
                if stale and bin_doc.get('is_online', True):
                    record_device_connectivity(db, bin_doc, device_id, False, now)
                elif not stale and bin_doc.get('is_online') is False:
                    record_device_connectivity(db, bin_doc, device_id, True, now)
            for alert in db.alerts.find({'status': 'open', 'severity': 'critical'}):
                created = alert.get('created_at')
                if not created:
                    continue
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                elapsed = (now - created).total_seconds()
                device_id = str(alert.get('device_id') or '')
                bin_doc = db.bins.find_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]}) or {'bin_id': device_id, 'name': alert.get('device_name')}
                if elapsed >= CRITICAL_ESCALATION_MINUTES * 60 and not alert.get('escalation_sent'):
                    notify_recipients(db, bin_doc, '🚨 Unresolved critical alert. The issue has not been addressed. Please assign or escalate the task.', f'unresolved_critical_alert:{alert.get("alert_id")}', now, admins=True)
                    db.alerts.update_one({'_id': alert['_id']}, {'$set': {'escalation_sent': True, 'escalated_at': now}})
                reminder_at = alert.get('reminder_sent_at')
                if CRITICAL_REMINDERS_ENABLED and elapsed >= 1800 and (not reminder_at or (now - reminder_at).total_seconds() >= 1800):
                    notify_recipients(db, bin_doc, '⏰ Reminder: A bin still requires attention. The critical condition remains unresolved.', f'critical_alert_reminder:{alert.get("alert_id")}:{int(now.timestamp() // 1800)}', now)
                    db.alerts.update_one({'_id': alert['_id']}, {'$set': {'reminder_sent_at': now}})
        except Exception:
            logger.exception('Device/alert monitor failed')
        await asyncio.sleep(1)


def create_mqtt_client(db: Any) -> mqtt.Client | None:
    if not (MQTT_URL and MQTT_USERNAME and MQTT_PASSWORD):
        logger.warning('MQTT disabled; configure MQTT_URL, MQTT_USERNAME, and MQTT_PASSWORD to enable ingestion.')
        return None
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id='binsight-fastapi')
    client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    client.user_data_set({'db': db})
    client.on_message = mqtt_message

    def on_connect(
        mqtt_client: mqtt.Client,
        userdata: Any,
        flags: dict[str, Any],
        reason_code: mqtt.ReasonCode,
        properties: Any,
    ) -> None:
        if reason_code.is_failure:
            logger.error('MQTT connection rejected: %s', reason_code)
            return
        mqtt_client.subscribe('binsight/devices/+/telemetry', qos=1)
        mqtt_client.subscribe('binsight/devices/+/status', qos=1)
        logger.info('Subscribed to BinSight device telemetry')

    client.on_connect = on_connect
    scheme, separator, address = MQTT_URL.partition('://')
    if scheme not in {'mqtt', 'tcp'} or not separator or not address:
        raise ValueError('MQTT_URL must use mqtt://host[:port]')
    host, port_separator, port_text = address.partition(':')
    # Connect asynchronously so FastAPI can start while the broker is offline;
    # Paho retries in its network loop and subscribes again in on_connect.
    client.connect_async(host, int(port_text) if port_separator else 1883, keepalive=60)
    client.loop_start()
    return client


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not MONGODB_URI:
        raise RuntimeError('MONGODB_URI is required')
    mongo_client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=10000, tz_aware=True)
    try:
        await asyncio.to_thread(mongo_client.admin.command, 'ping')
    except Exception:
        mongo_client.close()
        logger.exception('Failed to connect to MongoDB')
        raise
    db = mongo_client[MONGODB_DB]
    # Remove legacy persisted online notices. Reconnect notices now exist only
    # as short-lived in-memory banners, never as Mongo notification records.
    db.notifications.delete_many({
        '$or': [
            {'notification_type': {'$in': ['device_online', 'online']}},
            {'notification_id': {'$regex': '^(device_online|online):'}},
        ],
    })
    db.telemetry.create_index(
        [('device_id', 1), ('received_at', 1)],
        name='telemetry_device_received_at',
    )
    db.zones.create_index(
        [('name', 1)],
        unique=True,
        collation=Collation(locale='en', strength=2),
        name='zone_name_unique_case_insensitive',
    )
    app.state.mongo_client = mongo_client
    app.state.db = db
    mqtt_client = create_mqtt_client(db)
    app.state.mqtt_client = mqtt_client
    monitor_task = asyncio.create_task(monitor_devices(db))
    logger.info('Connected to MongoDB database %s; telemetry writes target %s', MONGODB_DB, db.telemetry.full_name)
    try:
        yield
    finally:
        monitor_task.cancel()
        try:
            await monitor_task
        except asyncio.CancelledError:
            pass
        if mqtt_client is not None:
            mqtt_client.loop_stop()
            mqtt_client.disconnect()
        mongo_client.close()


app = FastAPI(title='BinSight API', version='1.0.0', lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_origin_regex=r'^https?://(localhost|127\.0\.0\.1)(:\d+)?$',
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)


@app.exception_handler(HTTPException)
async def http_error_handler(request: Request, error: HTTPException) -> JSONResponse:
    detail = error.detail
    return JSONResponse(
        status_code=error.status_code,
        content={'error': detail} if isinstance(detail, str) else detail,
        headers=error.headers,
    )


def require_db_ready(db: Any) -> Any:
    try:
        db.command('ping')
    except PyMongoError as exc:
        raise HTTPException(
            status_code=503,
            detail='Database unavailable. Check MongoDB connectivity, Atlas access, and TLS/network settings.',
        ) from exc
    return db


def get_db(request: Request) -> Any:
    return require_db_ready(request.app.state.db)


@app.exception_handler(PyMongoError)
async def mongo_error_handler(request: Request, exc: PyMongoError) -> JSONResponse:
    logger.exception('MongoDB operation failed for %s %s', request.method, request.url.path)
    return JSONResponse(
        status_code=503,
        content={'error': 'Database unavailable. Check MongoDB connectivity, Atlas access, and TLS/network settings.'},
    )


@app.get('/health')
def health() -> dict[str, bool]:
    return {'ok': True}


@app.get('/setup/status')
def setup_status(request: Request) -> dict[str, bool]:
    config = get_db(request).app_config.find_one({'_id': 'main'})
    return {'is_setup_complete': bool(config and config.get('is_setup_complete', False))}


@app.get('/contact-admin')
def contact_admin(request: Request) -> dict[str, str]:
    db = get_db(request)
    config = db.app_config.find_one({'_id': 'main'})
    if not config or not config.get('admin_uid'):
        raise HTTPException(status_code=404, detail='Contact admin not configured.')
    admin = db.admins.find_one({'admin_id': config['admin_uid']})
    if not admin:
        raise HTTPException(status_code=404, detail='Contact admin not found.')
    return {'name': admin.get('name') or 'N/A', 'email': admin.get('email') or 'N/A', 'phone': admin.get('phone') or 'N/A'}


@app.get('/config')
def app_config(request: Request) -> dict[str, Any]:
    config = get_db(request).app_config.find_one({'$or': [{'_id': 'main'}, {'config_id': 'main'}]})
    if not config:
        raise HTTPException(status_code=404, detail='App config not found.')
    latitude, longitude = parse_location(config)
    return {'organization_location': config.get('organization_location'), 'latitude': latitude, 'longitude': longitude}


@app.get('/users/{uid}/role')
def user_role(uid: str, request: Request, email: str = '') -> dict[str, Any]:
    db = get_db(request)
    if db.admins.find_one({'admin_id': uid}):
        return {'role': 'admin'}
    if db.workers.find_one({'worker_id': uid}):
        return {'role': 'worker'}
    if email.strip():
        query = {'email': {'$regex': f'^{re.escape(email.strip())}$', '$options': 'i'}}
        admin = db.admins.find_one(query)
        if admin:
            db.admins.update_one({'_id': admin['_id']}, {'$set': {'admin_id': uid, 'updated_at': datetime.now(timezone.utc)}})
            return {'role': 'admin'}
        worker = db.workers.find_one(query)
        if worker:
            db.workers.update_one({'_id': worker['_id']}, {'$set': {'worker_id': uid, 'updated_at': datetime.now(timezone.utc)}})
            return {'role': 'worker'}
    raise HTTPException(status_code=404, detail={'role': None})


@app.get('/admins/{admin_id}')
def get_admin(admin_id: str, request: Request) -> dict[str, Any]:
    db = get_db(request)
    admin = db.admins.find_one({'admin_id': admin_id})
    if not admin:
        raise HTTPException(status_code=404, detail='Admin not found')
    admin.pop('_id', None)
    admin['notification_preferences'] = admin_notification_preferences(admin)
    admin = ensure_profile_image_url(db, admin, 'admin_images', 'admin_id')
    return {'admin': admin}


@app.patch('/admins/{admin_id}')
def update_admin(admin_id: str, updates: dict[str, Any], request: Request) -> dict[str, bool]:
    db = get_db(request)
    existing = db.admins.find_one({'admin_id': admin_id})
    if not existing:
        raise HTTPException(status_code=404, detail='Admin not found')
    name = str(updates.get('name', existing.get('name', ''))).strip()
    first_name, last_name = split_name(name)
    fields_to_update: dict[str, Any] = {
        'name': name,
        'first_name': updates.get('first_name', first_name),
        'last_name': updates.get('last_name', last_name),
        'email': str(updates.get('email', existing.get('email', ''))).strip(),
        'phone': updates.get('phone', existing.get('phone', '')),
        'date_of_birth': updates.get('date_of_birth', existing.get('date_of_birth', '')),
        'updated_at': datetime.now(timezone.utc),
    }
    if 'notification_preferences' in updates:
        preferences = updates['notification_preferences']
        if not isinstance(preferences, dict):
            raise HTTPException(status_code=400, detail='notification_preferences must be an object.')
        if any(key not in ADMIN_NOTIFICATION_TYPES or not isinstance(value, bool) for key, value in preferences.items()):
            raise HTTPException(status_code=400, detail='Notification preferences contain an invalid category or value.')
        fields_to_update['notification_preferences'] = {
            notification_type: preferences.get(notification_type, True)
            for notification_type in ADMIN_NOTIFICATION_TYPES
        }
    db.admins.update_one({'admin_id': admin_id}, {'$set': fields_to_update})
    return {'ok': True}


@app.get('/workers')
def list_workers(request: Request) -> dict[str, Any]:
    db = get_db(request)
    tasks_by_worker: dict[str, list[dict[str, Any]]] = {}
    for task in db.tasks.find({}).sort('assigned_at', -1):
        tasks_by_worker.setdefault(task.get('worker_id'), []).append({
            'task_id': task.get('task_id'),
            'description': task.get('description') or '',
            'status': task.get('status') or 'pending',
            'priority': task.get('priority') or 'medium',
            'bin_id': task.get('bin_id'),
            'zone_id': task.get('zone_id'),
        })
    workers = []
    for worker in db.workers.find({}).sort('created_at', -1):
        worker.pop('_id', None)
        worker = ensure_profile_image_url(db, worker, 'worker_images', 'worker_id')
        worker['tasks'] = tasks_by_worker.get(worker.get('worker_id'), [])
        workers.append(worker)
    return {'workers': workers}


@app.get('/workers/{worker_id}/notifications')
def list_worker_notifications(worker_id: str, request: Request) -> dict[str, Any]:
    db = get_db(request)
    notifications = list(
        db.notifications.find({
            'worker_id': worker_id,
            'notification_type': {'$nin': ['report_submitted', 'sensor_issue']},
            '$or': [
                {'notification_type': {'$in': [
                    'critical_alert_reminder', 'reminder', 'bin_almost_full',
                    'task_assigned', 'task_reassigned', 'task_acknowledged', 'task_completed',
                ]}},
                {'report_id': {'$exists': True}},
            ],
        }).sort('created_at', -1).limit(100)
    )
    for notification in notifications:
        notification.pop('_id', None)
    return {'notifications': notifications}


@app.patch('/tasks/{task_id}/status')
def update_task_status(task_id: str, payload: dict[str, Any], request: Request) -> dict[str, bool]:
    """Persist task acknowledgement/completion and notify admins on transitions."""
    db = get_db(request)
    task = db.tasks.find_one({'$or': [{'task_id': task_id}, {'_id': task_id}]})
    if task is None:
        raise HTTPException(status_code=404, detail='Task not found.')
    status = str(payload.get('status') or '').strip().lower()
    if status not in {'acknowledged', 'completed'}:
        raise HTTPException(status_code=400, detail='Task status must be acknowledged or completed.')
    if str(task.get('status') or '').lower() == status:
        return {'ok': True}

    now = datetime.now(timezone.utc)
    db.tasks.update_one({'_id': task['_id']}, {'$set': {
        'status': status,
        'updated_at': now,
        'acknowledged_at': now if status == 'acknowledged' else task.get('acknowledged_at'),
        'completed_at': now if status == 'completed' else task.get('completed_at'),
    }})
    worker_id = str(task.get('worker_id') or payload.get('worker_id') or '')
    worker = db.workers.find_one(worker_query(worker_id)) if worker_id else None
    worker_name = str((worker or {}).get('name') or 'Worker')
    bin_id = str(task.get('bin_id') or '')
    bin_doc = db.bins.find_one({'$or': [{'bin_id': bin_id}, {'_id': bin_id}]}) if bin_id else None
    bin_name = full_device_name(bin_doc or {}, bin_id or 'assigned task')
    if status == 'acknowledged':
        message = f'✅ Task acknowledged: {worker_name} has accepted the task for {bin_name}.'
    else:
        message = f'✅ Task completed: {worker_name} has completed the task for {bin_name}.'
    notify_recipients(db, bin_doc or {'bin_id': bin_id, 'name': bin_name}, message,
                      f'task_{status}:{task_id}:{int(now.timestamp())}', now, admins=True)
    return {'ok': True}


@app.get('/admins/{admin_id}/notifications')
def list_admin_notifications(admin_id: str, request: Request) -> dict[str, Any]:
    db = get_db(request)
    admin = db.admins.find_one({'admin_id': admin_id}) or {}
    preferences = admin_notification_preferences(admin)
    notifications = list(
        db.notifications.find({'admin_id': admin_id, '$or': [
            {'notification_type': {'$in': ['unresolved_critical_alert', 'escalation', 'task_acknowledged', 'task_completed', 'report_submitted', 'device_offline', 'offline', 'sensor_issue']}},
            {'report_id': {'$exists': True}},
        ]}).sort('created_at', -1).limit(100)
    )
    # Older records used `offline` / `online`; preferences use stable UI keys.
    preference_aliases = {
        'escalation': 'unresolved_critical_alert',
        'offline': 'device_offline',
        'online': 'device_online',
    }
    notifications = [
        notification for notification in notifications
        if preferences.get(
            preference_aliases.get(notification.get('notification_type'), notification.get('notification_type')),
            True,
        )
    ]
    for notification in notifications:
        notification.pop('_id', None)
    return {'notifications': notifications}


@app.get('/admins/{admin_id}/connectivity-events')
def drain_admin_connectivity_events(admin_id: str, request: Request) -> dict[str, Any]:
    with _admin_connectivity_events_lock:
        events = _admin_connectivity_events.get(admin_id, [])
        next_event = events.pop(0) if events else None
        if not events:
            _admin_connectivity_events.pop(admin_id, None)
    return {'events': [next_event] if next_event is not None else []}


@app.post('/notifications/{notification_id}/claim-banner')
def claim_notification_banner(notification_id: str, request: Request) -> dict[str, bool]:
    result = get_db(request).notifications.update_one(
        {'notification_id': notification_id, 'banner_shown_at': {'$exists': False}},
        {'$set': {'banner_shown_at': datetime.now(timezone.utc)}},
    )
    return {'show': result.modified_count == 1}


@app.delete('/notifications/{notification_id}')
def delete_notification(notification_id: str, request: Request) -> dict[str, bool]:
    result = get_db(request).notifications.delete_one({'notification_id': notification_id})
    if not result.deleted_count:
        raise HTTPException(status_code=404, detail='Notification not found.')
    return {'ok': True}


@app.get('/workers/{worker_id}')
def get_worker(worker_id: str, request: Request) -> dict[str, Any]:
    db = get_db(request)
    worker = db.workers.find_one(worker_query(worker_id))
    if not worker:
        raise HTTPException(status_code=404, detail='Worker not found')
    worker.pop('_id', None)
    worker = ensure_profile_image_url(db, worker, 'worker_images', 'worker_id')
    worker['tasks'] = list(db.tasks.find({'worker_id': worker.get('worker_id')}).sort('assigned_at', -1))
    for task in worker['tasks']:
        task.pop('_id', None)
    return {'worker': worker}


@app.post('/workers')
def upsert_worker(payload: dict[str, Any], request: Request) -> dict[str, bool]:
    worker_id, email = payload.get('worker_id'), payload.get('email')
    if not worker_id or not email:
        raise HTTPException(status_code=400, detail='worker_id and email are required')
    fallback_first, fallback_last = split_name(str(payload.get('name', '')))
    first_name = str(payload.get('first_name') or fallback_first).strip()
    last_name = str(payload.get('last_name') or fallback_last).strip()
    name = str(payload.get('name', '')).strip() or f'{first_name} {last_name}'.strip() or email.split('@')[0]
    now = datetime.now(timezone.utc)
    get_db(request).workers.update_one(
        {'_id': worker_id},
        {
            '$set': {
                'worker_id': worker_id,
                'first_name': first_name,
                'last_name': last_name,
                'date_of_birth': str(payload.get('date_of_birth', '')).strip(),
                'name': name,
                'email': email,
                'phone': payload.get('phone', ''),
                'role': 'worker',
                'profile_image_url': payload.get('profile_image_url', ''),
                'assigned_zones': payload.get('assigned_zones', []),
                'assigned_bins': payload.get('assigned_bins', []),
                'status': 'active',
                'current_location': {'lat': 0.0, 'lng': 0.0},
                'last_active': now,
                'updated_at': now,
            },
            '$setOnInsert': {'_id': worker_id, 'created_at': now},
        },
        upsert=True,
    )
    return {'ok': True}


@app.patch('/workers/{worker_id}')
def update_worker(worker_id: str, updates: dict[str, Any], request: Request) -> dict[str, bool]:
    db = get_db(request)
    existing = db.workers.find_one(worker_query(worker_id))
    if not existing:
        raise HTTPException(status_code=404, detail='Worker not found')
    name = updates.get('name', existing.get('name', ''))
    first_name, last_name = split_name(str(name))
    email = str(updates.get('email', existing.get('email', ''))).strip()
    next_update: dict[str, Any] = {
        'name': name,
        'first_name': first_name,
        'last_name': last_name,
        'email': email,
        'date_of_birth': updates.get('date_of_birth', existing.get('date_of_birth', '')),
        'phone': updates.get('phone', existing.get('phone', '')),
        'profile_image_url': updates.get('profile_image_url', existing.get('profile_image_url', '')),
        'assigned_zones': updates.get('assigned_zones', existing.get('assigned_zones', [])),
        'assigned_bins': updates.get('assigned_bins', existing.get('assigned_bins', [])),
        'updated_at': datetime.now(timezone.utc),
    }
    preferences = updates.get('notification_preferences')
    if isinstance(preferences, dict):
        current_preferences = worker_notification_preferences(existing)
        for category in WORKER_NOTIFICATION_TYPES:
            if isinstance(preferences.get(category), bool):
                current_preferences[category] = preferences[category]
        next_update['notification_preferences'] = current_preferences
    location = updates.get('current_location')
    if isinstance(location, dict) and isinstance(location.get('lat'), (int, float)) and isinstance(location.get('lng'), (int, float)):
        next_update['current_location'] = location
        next_update['last_active'] = datetime.now(timezone.utc)
    prior_bins = set(str(item) for item in existing.get('assigned_bins', []))
    next_bins = set(str(item) for item in next_update['assigned_bins'])
    db.workers.update_one(worker_query(worker_id), {'$set': next_update})
    worker_id_value = str(existing.get('worker_id') or existing.get('_id') or worker_id)
    for bin_id in sorted(next_bins - prior_bins):
        bin_doc = db.bins.find_one({'$or': [{'bin_id': bin_id}, {'_id': bin_id}]}) or {'bin_id': bin_id, 'name': bin_id}
        at = datetime.now(timezone.utc)
        open_task = db.tasks.find_one({
            'bin_id': bin_id,
            'status': {'$nin': ['completed', 'cancelled']},
        })
        reassigned = bool(open_task and str(open_task.get('worker_id') or '') != worker_id_value)
        if reassigned:
            task_id = str(open_task.get('task_id') or open_task.get('_id'))
            db.tasks.update_one({'_id': open_task['_id']}, {'$set': {
                'worker_id': worker_id_value, 'status': 'pending', 'assigned_at': at,
                'updated_at': at,
            }})
            notification_type = 'task_reassigned'
            task_message = f"📋 Task reassigned to you: Please attend to {full_device_name(bin_doc, bin_id)}."
        else:
            task_id = f'task_{uuid.uuid4().hex}'
            db.tasks.insert_one({
                '_id': task_id, 'task_id': task_id, 'worker_id': worker_id_value,
                'bin_id': bin_id, 'description': f"Collect waste from {full_device_name(bin_doc, bin_id)}.",
                'status': 'pending', 'priority': 'medium', 'assigned_at': at,
            })
            notification_type = 'task_assigned'
            task_message = f"📋 New task assigned: Collect waste from {full_device_name(bin_doc, bin_id)}."
        notification_id = f'{notification_type}:{task_id}:{worker_id_value}:{int(at.timestamp())}'
        db.notifications.update_one({'_id': notification_id}, {'$setOnInsert': {
            '_id': notification_id, 'notification_id': notification_id,
            'worker_id': worker_id_value, 'notification_type': notification_type,
            'task_id': task_id, 'bin_id': bin_id,
            'report_name': bin_doc.get('name') or bin_id,
            'message': task_message, 'created_at': at,
        }}, upsert=True)
    return {'ok': True}


@app.delete('/workers/{worker_id}')
def delete_worker(worker_id: str, request: Request) -> dict[str, bool]:
    db = get_db(request)
    existing = db.workers.find_one(worker_query(worker_id))
    db.workers.delete_one(worker_query(worker_id))
    db.worker_images.delete_one({'worker_id': (existing or {}).get('worker_id', worker_id)})
    return {'ok': True}


@app.get('/zones')
def list_zones(request: Request) -> dict[str, Any]:
    db = get_db(request)
    bins = list(db.bins.find({'zone_id': {'$ne': None}}))
    return {'zones': [zone_summary(zone, bins) for zone in db.zones.find({}).sort('created_at', -1)]}


def _device_is_online(bin_doc: dict[str, Any], last_updated: Any) -> bool:
    # Prefer the freshest heartbeat or telemetry timestamp. Older saved
    # connection state must not mask newer telemetry from a recovered device.
    timestamps = []
    for value in (bin_doc.get('last_connection_seen'), last_updated, bin_doc.get('last_updated')):
        if isinstance(value, str):
            try:
                value = datetime.fromisoformat(value.replace('Z', '+00:00'))
            except ValueError:
                continue
        if isinstance(value, datetime):
            if value.tzinfo is None:
                value = value.replace(tzinfo=timezone.utc)
            timestamps.append(value)
    if not timestamps:
        return False
    last_seen = max(timestamps)
    age_seconds = (datetime.now(timezone.utc) - last_seen).total_seconds()
    return 0 <= age_seconds < DEVICE_OFFLINE_TIMEOUT_SECONDS


@app.get('/devices')
def list_devices(request: Request) -> dict[str, Any]:
    db = get_db(request)
    bins = list(db.bins.find({}).sort('created_at', -1))
    zones = list(db.zones.find({}).sort('created_at', -1))
    # The telemetry collection is the live sensor source; fall back to the bin
    # snapshot for devices that have not published since they were registered.
    latest_by_device = {}
    latest_valid_fill_by_device = {}
    fill_history_by_device = {}
    historical_fill_by_device = {}
    predictions_by_device = {}
    if bins:
        # Telemetry can use either the registered bin_id or the Mongo _id as
        # its device_id. Include both so historical averages survive ID aliases.
        aliases_by_device = {}
        device_ids = set()
        for item in bins:
            canonical_id = str(item.get('bin_id') or item.get('_id'))
            aliases = {canonical_id, str(item.get('_id'))}
            if item.get('bin_id'):
                aliases.add(str(item['bin_id']))
            aliases_by_device[canonical_id] = aliases
            device_ids.update(aliases)
        canonical_by_alias = {
            alias: canonical_id
            for canonical_id, aliases in aliases_by_device.items()
            for alias in aliases
        }
        telemetry_groups = list(db.telemetry.aggregate([
            {'$match': {'device_id': {'$in': list(device_ids)}}},
            {'$sort': {'received_at': -1}},
            {'$group': {'_id': '$device_id', 'readings': {'$push': '$$ROOT'}}},
            {'$project': {'readings': {'$slice': ['$readings', 50]}}},
        ]))
        readings_by_device = {}
        for group in telemetry_groups:
            canonical_id = canonical_by_alias.get(str(group['_id']))
            if canonical_id:
                readings_by_device.setdefault(canonical_id, []).extend(group.get('readings', []))
        for canonical_id, readings in readings_by_device.items():
            readings.sort(key=lambda reading: reading.get('received_at') or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
            latest_by_device[canonical_id] = readings[0]

        # Build a regular hourly history from all valid fill samples in the last
        # two weeks; the forecast helper uses the most recent 168 hourly points.
        forecast_cutoff = datetime.now(timezone.utc) - timedelta(days=14)
        hourly_fill_groups = list(db.telemetry.aggregate([
            {'$match': {
                'device_id': {'$in': list(device_ids)},
                'received_at': {'$gte': forecast_cutoff},
                'fill_level': {'$type': 'number', '$gte': 0, '$lte': 100},
                'fill_valid': {'$ne': False},
            }},
            {'$group': {
                '_id': {
                    'device_id': '$device_id',
                    'hour': {'$dateTrunc': {'date': '$received_at', 'unit': 'hour', 'timezone': 'UTC'}},
                },
                'fill_level': {'$avg': '$fill_level'},
            }},
            {'$sort': {'_id.hour': 1}},
        ]))
        for group in hourly_fill_groups:
            canonical_id = canonical_by_alias.get(str(group['_id']['device_id']))
            if canonical_id:
                fill_history_by_device.setdefault(canonical_id, []).append({
                    'received_at': group['_id']['hour'],
                    'fill_level': group['fill_level'],
                })
        for canonical_id, readings in readings_by_device.items():
            predictions_by_device[canonical_id] = predict_sensor_metrics(
                readings[:50], fill_history_by_device.get(canonical_id, [])
            )

        # Invalid ultrasonic heartbeats can still be latest for gas/flame, but
        # must not replace the last valid fill measurement shown on bin cards.
        latest_valid_fill_groups = list(db.telemetry.aggregate([
            {'$match': {
                'device_id': {'$in': list(device_ids)},
                'fill_level': {'$type': 'number', '$gte': 0, '$lte': 100},
                'fill_valid': {'$ne': False},
            }},
            {'$sort': {'received_at': -1}},
            {'$group': {'_id': '$device_id', 'reading': {'$first': '$$ROOT'}}},
        ]))
        for group in latest_valid_fill_groups:
            canonical_id = canonical_by_alias.get(str(group['_id']))
            if canonical_id:
                candidate = group.get('reading', {})
                current = latest_valid_fill_by_device.get(canonical_id)
                candidate_time = candidate.get('received_at') or datetime.min.replace(tzinfo=timezone.utc)
                current_time = (current or {}).get('received_at') or datetime.min.replace(tzinfo=timezone.utc)
                if current is None or candidate_time > current_time:
                    latest_valid_fill_by_device[canonical_id] = candidate

        historical_fill_groups = list(db.telemetry.aggregate([
            {'$match': {
                'device_id': {'$in': list(device_ids)},
                'fill_level': {'$type': 'number', '$gte': 0, '$lte': 100},
                'fill_valid': {'$ne': False},
            }},
            {'$group': {
                '_id': '$device_id',
                'average_fill': {'$avg': '$fill_level'},
                'sample_count': {'$sum': 1},
            }},
        ]))
        for group in historical_fill_groups:
            canonical_id = canonical_by_alias.get(str(group['_id']))
            if not canonical_id:
                continue
            current = historical_fill_by_device.setdefault(canonical_id, {'weighted_fill': 0.0, 'sample_count': 0})
            count = int(group.get('sample_count', 0))
            current['weighted_fill'] += float(group.get('average_fill', 0)) * count
            current['sample_count'] += count
        for sample in historical_fill_by_device.values():
            sample['average_fill'] = sample['weighted_fill'] / sample['sample_count'] if sample['sample_count'] else 0
    zone_names = {zone.get('zone_id'): zone.get('name') for zone in zones}
    bin_devices = [{
        'id': bin_doc.get('bin_id'),
        'name': bin_doc.get('name'),
        'type': 'bin',
        'zone_id': bin_doc.get('zone_id'),
        'zone_name': zone_names.get(bin_doc.get('zone_id')),
        'location': bin_doc.get('location'),
        'location_description': bin_doc.get('location_description', ''),
        'status': (latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('status', bin_doc.get('status', 'normal'))),
        'fill_level': latest_valid_fill_by_device.get(
            str(bin_doc.get('bin_id') or bin_doc.get('_id')),
            latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc),
        ).get('fill_level', bin_doc.get('fill_level', 0)),
        'gas_level': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('gas_level', bin_doc.get('gas_level', 0)),
        'fill_alert': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('fill_alert', bin_doc.get('fill_alert', False)),
        'gas_alert': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('gas_alert', bin_doc.get('gas_alert', False)),
        'flame': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('flame', bin_doc.get('flame', False)),
        'fire_alert': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('fire_alert', bin_doc.get('fire_alert', bin_doc.get('flame', False))),
        'fill_moderate': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('fill_moderate', False),
        'gas_moderate': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('gas_moderate', False),
        **predictions_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), {'next_overflow_hours': None, 'next_overflow_time': 'Insufficient trend', 'gas_z_score': None, 'gas_spike': False, 'fire_risk': False}),
        'is_online': _device_is_online(
            bin_doc,
            latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('received_at', bin_doc.get('last_updated')),
        ),
        'created_at': bin_doc.get('created_at'),
        'last_updated': latest_by_device.get(str(bin_doc.get('bin_id') or bin_doc.get('_id')), bin_doc).get('received_at', bin_doc.get('last_updated')),
    } for bin_doc in bins]
    zone_devices = []
    for zone in zones:
        assigned = [bin_doc for bin_doc in bin_devices if bin_doc.get('zone_id') == zone.get('zone_id')]
        historical_samples = [
            historical_fill_by_device.get(str(bin_doc.get('id') or ''), {})
            for bin_doc in assigned
        ]
        historical_count = sum(int(sample.get('sample_count', 0)) for sample in historical_samples)
        if historical_count:
            weighted_fill = sum(
                float(sample.get('average_fill', 0)) * int(sample.get('sample_count', 0))
                for sample in historical_samples
            )
            average_fill = round(weighted_fill / historical_count)
        else:
            average_fill = round(sum(bin_doc['fill_level'] for bin_doc in assigned) / len(assigned)) if assigned else 0
        latest = [bin_doc.get('last_updated') for bin_doc in assigned if bin_doc.get('last_updated')]
        zone_devices.append({
            'id': zone.get('zone_id'),
            'name': zone.get('name'),
            'type': 'zone',
            'location': zone.get('location'),
            'location_description': zone.get('location_description', ''),
            'status': 'critical' if any(bin_doc['status'] == 'critical' for bin_doc in assigned) else ('moderate' if any(bin_doc['status'] == 'moderate' for bin_doc in assigned) else 'normal'),
            'fill_level': average_fill,
            'historical_fill_sample_count': historical_count,
            'gas_level': max((bin_doc['gas_level'] for bin_doc in assigned), default=0),
            'flame': any(bin_doc['flame'] for bin_doc in assigned),
            'bin_count': len(assigned),
            'critical_bin_count': sum(bin_doc['status'] == 'critical' for bin_doc in assigned),
            'bins': assigned,
            'created_at': zone.get('created_at'),
            'last_updated': max(latest, default=zone.get('last_updated')),
        })
    floor = datetime.min.replace(tzinfo=timezone.utc)
    return {'devices': sorted(bin_devices + zone_devices, key=lambda item: item.get('last_updated') or item.get('created_at') or floor, reverse=True)}


@app.get('/devices/{device_id}/telemetry')
def get_telemetry(device_id: str, request: Request, limit: int = 50) -> dict[str, Any]:
    readings = get_db(request).telemetry.find({'device_id': device_id}).sort('received_at', -1).limit(min(max(limit, 1), 500))
    result = []
    for reading in readings:
        reading.pop('_id', None)
        result.append(reading)
    return {'telemetry': result}


@app.get('/analytics/fill-history')
def get_analytics_fill_history(request: Request) -> dict[str, Any]:
    db = get_db(request)
    bins = list(db.bins.find({}).sort('created_at', 1))
    zones = list(db.zones.find({}))
    zone_names = {
        str(zone.get('zone_id') or zone.get('_id') or ''): str(zone.get('name') or 'Zone')
        for zone in zones
    }
    alias_to_bin: dict[str, dict[str, str]] = {}
    telemetry_ids: set[str] = set()
    registered_bins = []
    for bin_doc in bins:
        canonical_id = str(bin_doc.get('bin_id') or bin_doc.get('_id') or '')
        if not canonical_id:
            continue
        zone_id = str(bin_doc.get('zone_id') or '')
        entry = {
            'device_id': canonical_id,
            'name': str(bin_doc.get('name') or canonical_id),
            'zone_id': zone_id,
            'zone_name': zone_names.get(zone_id, zone_id),
        }
        registered_bins.append(entry)
        for alias in {canonical_id, str(bin_doc.get('_id') or '')}:
            if alias:
                alias_to_bin[alias] = entry
                telemetry_ids.add(alias)
    if not telemetry_ids:
        return {'bins': registered_bins, 'history': []}

    history = list(db.telemetry.aggregate([
        {'$match': {
            'device_id': {'$in': list(telemetry_ids)},
            'received_at': {'$type': 'date'},
            'fill_level': {'$type': 'number', '$gte': 0, '$lte': 100},
            'fill_valid': {'$ne': False},
        }},
        {'$group': {
            '_id': {
                'device_id': '$device_id',
                'hour': {'$dateTrunc': {'date': '$received_at', 'unit': 'hour', 'timezone': 'UTC'}},
            },
            'fill_level': {'$avg': '$fill_level'},
            'sample_count': {'$sum': 1},
        }},
        {'$sort': {'_id.hour': 1, '_id.device_id': 1}},
        {'$project': {
            '_id': 0,
            'device_id': '$_id.device_id',
            'timestamp': '$_id.hour',
            'fill_level': 1,
            'sample_count': 1,
        }},
    ]))
    for point in history:
        bin_info = alias_to_bin.get(str(point.get('device_id') or ''))
        point['device_id'] = bin_info['device_id'] if bin_info else str(point.get('device_id') or '')
    return {'bins': registered_bins, 'history': history}


@app.get('/alerts')
def list_alerts(request: Request, status: str = 'open') -> dict[str, Any]:
    alerts = get_db(request).alerts.find({'status': status}).sort('last_updated', -1)
    result = []
    for alert in alerts:
        alert.pop('_id', None)
        result.append(alert)
    return {'alerts': result}


@app.delete('/alerts/device/{device_id}/resolve')
def resolve_device_alerts(device_id: str, request: Request) -> dict[str, bool]:
    db = get_db(request)
    active = list(db.alerts.find({'device_id': device_id, 'status': 'open'}))
    types = [item['alert_type'] for item in active if item.get('alert_type')]
    if types:
        now = datetime.now(timezone.utc)
        db.bins.update_one(
            {'$or': [{'bin_id': device_id}, {'_id': device_id}]},
            {'$addToSet': {'muted_alert_types': {'$each': types}}},
        )
        db.alerts.update_many(
            {'device_id': device_id, 'status': 'open'},
            {'$set': {
                'status': 'resolved',
                'resolved_at': now,
                'resolved_by': 'manual',
                'last_updated': now,
            }},
        )
    return {'ok': True}


@app.patch('/alerts/{alert_id}/resolve')
def resolve_alert(alert_id: str, payload: dict[str, Any], request: Request) -> dict[str, bool]:
    db = get_db(request)
    alert = db.alerts.find_one({'alert_id': alert_id, 'status': 'open'})
    if not alert:
        raise HTTPException(status_code=404, detail='Open alert not found.')
    db.bins.update_one(
        {'$or': [{'bin_id': alert.get('device_id')}, {'_id': alert.get('device_id')}]},
        {'$addToSet': {'muted_alert_types': alert.get('alert_type')}},
    )
    now = datetime.now(timezone.utc)
    db.alerts.update_one({'alert_id': alert_id, 'status': 'open'}, {'$set': {
        'status': 'resolved', 'resolved_at': now,
        'resolved_by': str(payload.get('resolved_by') or 'manual'), 'last_updated': now,
    }})
    return {'ok': True}


@app.get('/reports')
def list_reports(request: Request) -> dict[str, Any]:
    reports = list(get_db(request).reports.find({}).sort('created_at', -1))
    for report in reports:
        report.pop('_id', None)
    return {'reports': reports}


@app.post('/devices')
def create_device(payload: dict[str, Any], request: Request) -> dict[str, Any]:
    db = get_db(request)
    qr_value = str(payload.get('qr_value') or '')
    device_type = device_type_from_qr(qr_value)
    if not device_type:
        raise HTTPException(status_code=400, detail='QR value must identify a bin or zone')
    name = str(payload.get('name') or '').strip()
    if not name:
        raise HTTPException(status_code=400, detail='name is required')
    if device_type == 'zone' and zone_name_exists(db, name):
        raise HTTPException(
            status_code=409,
            detail='This name already belongs to an existing zone.',
        )
    zone_id = payload.get('zone_id') if device_type == 'bin' else None
    if zone_id and not db.zones.find_one({'zone_id': zone_id}):
        raise HTTPException(status_code=400, detail='Selected zone does not exist.')
    collection = 'bins' if device_type == 'bin' else 'zones'
    generated_id = f'{device_type}{next_sequence(db, collection)}'
    now = datetime.now(timezone.utc)
    location = {'type': 'Point', 'coordinates': [payload.get('longitude', 0), payload.get('latitude', 0)]}
    if device_type == 'bin':
        db.bins.update_one(
            {'_id': generated_id},
            {
                '$set': {
                    'id': generated_id, 'bin_id': generated_id, 'type': 'bin', 'name': name,
                    'location_description': str(payload.get('location_description') or '').strip(),
                    'location': location, 'zone_id': zone_id, 'fill_level': 0, 'gas_level': 0,
                    'flame': False, 'status': 'normal', 'qr_payload': qr_value.strip(), 'last_updated': now,
                },
                '$setOnInsert': {'_id': generated_id, 'created_at': now},
            },
            upsert=True,
        )
    else:
        try:
            db.zones.update_one(
                {'_id': generated_id},
                {
                    '$set': {
                        'id': generated_id, 'zone_id': generated_id, 'type': 'zone', 'name': name,
                        'location_description': str(payload.get('location_description') or '').strip(),
                        'location': location, 'qr_payload': qr_value.strip(), 'last_updated': now,
                    },
                    '$setOnInsert': {'_id': generated_id, 'created_at': now},
                },
                upsert=True,
            )
        except DuplicateKeyError as error:
            raise HTTPException(
                status_code=409,
                detail='This name already belongs to an existing zone.',
            ) from error
    return {'device': {
        'id': generated_id, 'name': name, 'type': device_type,
        'location_description': str(payload.get('location_description') or '').strip(),
        'status': 'normal', 'created_at': now, 'last_updated': now, 'zone_id': zone_id,
    }}


@app.patch('/bins/{bin_id}/zone')
def assign_bin_zone(bin_id: str, payload: dict[str, Any], request: Request) -> dict[str, Any]:
    db = get_db(request)
    zone_id = str(payload.get('zone_id') or '').strip() or None
    if zone_id and not db.zones.find_one({'zone_id': zone_id}):
        raise HTTPException(status_code=400, detail='Selected zone does not exist.')
    result = db.bins.update_one(
        {'$or': [{'bin_id': bin_id}, {'_id': bin_id}]},
        {'$set': {'zone_id': zone_id, 'updated_at': datetime.now(timezone.utc)}},
    )
    if not result.matched_count:
        raise HTTPException(status_code=404, detail='Bin not found.')
    return {'ok': True, 'zone_id': zone_id}


@app.patch('/bins/{bin_id}')
def update_bin(bin_id: str, payload: dict[str, Any], request: Request) -> dict[str, Any]:
    db = get_db(request)
    existing = db.bins.find_one({'$or': [{'bin_id': bin_id}, {'_id': bin_id}]})
    if existing is None:
        raise HTTPException(status_code=404, detail='Bin not found.')

    update_values: dict[str, Any] = {}
    if 'name' in payload:
        name = str(payload.get('name') or '').strip()
        if name:
            update_values['name'] = name

    if 'location_description' in payload:
        update_values['location_description'] = str(payload.get('location_description') or '').strip()

    if 'latitude' in payload or 'longitude' in payload:
        latitude = payload.get('latitude')
        longitude = payload.get('longitude')
        if latitude is not None and longitude is not None:
            try:
                latitude = float(latitude)
                longitude = float(longitude)
            except (TypeError, ValueError) as error:
                raise HTTPException(status_code=400, detail='Latitude and longitude must be valid numbers.') from error
            update_values['location'] = {'type': 'Point', 'coordinates': [longitude, latitude]}

    if 'zone_id' in payload:
        zone_id = str(payload.get('zone_id') or '').strip() or None
        if zone_id and not db.zones.find_one({'zone_id': zone_id}):
            raise HTTPException(status_code=400, detail='Selected zone does not exist.')
        update_values['zone_id'] = zone_id

    if not update_values:
        return {'ok': True, 'updated': {}}

    update_values['updated_at'] = datetime.now(timezone.utc)
    db.bins.update_one({'$or': [{'bin_id': bin_id}, {'_id': bin_id}]}, {'$set': update_values})
    return {'ok': True, 'updated': update_values}


@app.delete('/bins/{bin_id}')
def delete_bin(bin_id: str, request: Request) -> dict[str, bool]:
    db = get_db(request)
    result = db.bins.delete_one({'$or': [{'bin_id': bin_id}, {'_id': bin_id}]})
    if not result.deleted_count:
        raise HTTPException(status_code=404, detail='Bin not found.')

    reindex_bin_names(db)

    db.alerts.update_many(
        {'device_id': bin_id, 'status': 'open'},
        {'$set': {'status': 'cleared', 'last_updated': datetime.now(timezone.utc)}},
    )
    return {'ok': True}


@app.delete('/devices/{device_id}')
def delete_device(device_id: str, request: Request) -> dict[str, bool]:
    db = get_db(request)

    by_bin = db.bins.find_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]})
    if by_bin is not None:
        db.bins.delete_one({'$or': [{'bin_id': device_id}, {'_id': device_id}]})
        db.alerts.update_many(
            {'device_id': device_id, 'status': 'open'},
            {'$set': {'status': 'cleared', 'last_updated': datetime.now(timezone.utc)}},
        )
        return {'ok': True}

    by_zone = db.zones.find_one({'$or': [{'zone_id': device_id}, {'_id': device_id}]})
    if by_zone is not None:
        db.zones.delete_one({'$or': [{'zone_id': device_id}, {'_id': device_id}]})
        db.bins.update_many({'zone_id': device_id}, {'$set': {'zone_id': None, 'updated_at': datetime.now(timezone.utc)}})
        return {'ok': True}

    raise HTTPException(status_code=404, detail='Device not found.')


def image_response(db: Any, collection_name: str, owner_field: str, owner_id: str, missing_message: str) -> Response:
    image = db[collection_name].find_one({owner_field: owner_id})
    if not image or not image.get('data'):
        return Response(content=missing_message, status_code=404)
    return Response(content=bytes(image['data']), media_type=image.get('content_type') or 'image/jpeg')


@app.get('/images/admin/{admin_id}')
def admin_image(admin_id: str, request: Request) -> Response:
    return image_response(get_db(request), 'admin_images', 'admin_id', admin_id, 'Not found')


@app.get('/images/worker/{worker_id}')
def worker_image(worker_id: str, request: Request) -> Response:
    return image_response(get_db(request), 'worker_images', 'worker_id', worker_id, 'Not found')


@app.get('/images/report/{report_id}/{photo_id}')
def report_photo(report_id: str, photo_id: str, request: Request) -> Response:
    image = get_db(request).report_photos.find_one(
        {'report_id': report_id, 'photo_id': photo_id}
    )
    if not image or not image.get('data'):
        return Response(content='Report photo not found', status_code=404)
    return Response(
        content=bytes(image['data']),
        media_type=image.get('content_type') or 'image/jpeg',
    )


@app.get('/images/report/{report_id}')
def report_image(report_id: str, request: Request) -> Response:
    return image_response(get_db(request), 'report_images', 'report_id', report_id, 'Report image not found')


@app.post('/upload/profile_picture')
async def upload_profile_picture(
    request: Request,
    owner_id: str = Form(alias='ownerId'),
    owner_type: str = Form(alias='ownerType'),
    profile_picture: UploadFile = File(alias='profilePicture'),
) -> dict[str, str]:
    if owner_type not in {'admin', 'worker'}:
        raise HTTPException(status_code=400, detail='ownerType must be admin or worker')
    collection = f'{owner_type}_images'
    await upsert_image(get_db(request), collection, f'{owner_type}_id', owner_id, profile_picture)
    return {'profile_image_url': get_image_url(collection, owner_id)}


@app.post('/upload/report_picture')
async def upload_report_picture(
    request: Request,
    report_id: str = Form(alias='reportId'),
    report_picture: UploadFile = File(alias='reportPicture'),
) -> dict[str, str]:
    await upsert_image(get_db(request), 'report_images', 'report_id', report_id, report_picture)
    return {'image_url': get_image_url('report_images', report_id)}


@app.post('/reports')
async def create_report(request: Request) -> dict[str, Any]:
    form = await request.form()
    name = str(form.get('name') or '').strip()
    description = str(form.get('description') or '').strip()
    reporter_id = str(form.get('reporter_id') or '').strip()
    if not name:
        raise HTTPException(status_code=400, detail='Report name is required.')
    if not description:
        raise HTTPException(status_code=400, detail='Report description is required.')
    if not reporter_id:
        raise HTTPException(status_code=400, detail='Worker identity is required.')

    db = get_db(request)
    worker = db.workers.find_one(worker_query(reporter_id))
    if worker is None:
        raise HTTPException(status_code=404, detail='Submitting worker was not found.')

    related_device_id = str(form.get('related_device_id') or '').strip()
    related_device_type = str(form.get('related_device_type') or '').strip().lower()
    related_device_name = ''
    if related_device_id:
        if related_device_type == 'bin':
            related_device = db.bins.find_one({
                '$or': [{'bin_id': related_device_id}, {'_id': related_device_id}],
            })
            if related_device is None:
                raise HTTPException(status_code=404, detail='Related bin was not found.')
            related_device_name = full_device_name(related_device, related_device_id)
        elif related_device_type == 'zone':
            related_device = db.zones.find_one({
                '$or': [{'zone_id': related_device_id}, {'_id': related_device_id}],
            })
            if related_device is None:
                raise HTTPException(status_code=404, detail='Related zone was not found.')
            zone_name = str(related_device.get('name') or related_device_id).strip()
            zone_location = str(related_device.get('location_description') or '').strip()
            related_device_name = f'{zone_name} - {zone_location}' if zone_location else zone_name
        else:
            raise HTTPException(status_code=400, detail='Related device type must be bin or zone.')

    report_id = str(form.get('report_id') or f'report_{uuid.uuid4().hex}')
    uploads = form.getlist('reportPictures')
    if not uploads:
        legacy_upload = form.get('reportPicture')
        if legacy_upload is not None:
            uploads = [legacy_upload]

    now = datetime.now(timezone.utc)
    photo_urls: list[str] = []
    for upload in uploads:
        if not hasattr(upload, 'read'):
            continue
        data = await upload.read(MAX_INLINE_IMAGE_BYTES + 1)
        if len(data) > MAX_INLINE_IMAGE_BYTES:
            raise HTTPException(
                status_code=413,
                detail='Each report photo must be smaller than 14 MB.',
            )
        photo_id = uuid.uuid4().hex
        db.report_photos.insert_one({
            'report_id': report_id,
            'photo_id': photo_id,
            'filename': getattr(upload, 'filename', '') or '',
            'content_type': getattr(upload, 'content_type', '') or 'image/jpeg',
            'size': len(data),
            'data': Binary(data),
            'created_at': now,
        })
        photo_urls.append(
            f"{normalize_base_url(APP_BASE_URL)}/images/report/{report_id}/{photo_id}"
        )

    report = {
        'report_id': report_id,
        'name': name,
        'description': description,
        'reporter_id': reporter_id,
        'reporter_name': str(worker.get('name') or '').strip(),
        'reporter_email': str(worker.get('email') or '').strip(),
        'related_device_id': related_device_id or None,
        'related_device_type': related_device_type or None,
        'related_device_name': related_device_name or None,
        'photos': photo_urls,
        'status': 'submitted',
        'submitted_at': now,
        'created_at': now,
        'updated_at': now,
    }
    db.reports.insert_one({'_id': report_id, **report})

    config = db.app_config.find_one({'$or': [{'_id': 'main'}, {'config_id': 'main'}]}) or {}
    admin_id = str(config.get('admin_uid') or config.get('admin_id') or '').strip()
    if not admin_id:
        admin = db.admins.find_one({}) or {}
        admin_id = str(admin.get('admin_id') or admin.get('_id') or '').strip()
    admin = db.admins.find_one({'admin_id': admin_id}) if admin_id else None
    if admin_id and (admin is None or admin_notification_preferences(admin).get('report_submitted', True)):
        notification_id = uuid.uuid4().hex
        worker_name = str(worker.get('name') or 'Worker').strip()
        db.notifications.insert_one({
            '_id': notification_id,
            'notification_id': notification_id,
            'admin_id': admin_id,
            'report_id': report_id,
            'report_name': name,
            'worker_name': worker_name,
            'notification_type': 'report_submitted',
            'message': (
                f'Issue Report submitted by {worker_name} about {related_device_name}.'
                if related_device_name
                else f'Issue Report submitted by {worker_name}.'
            ),
            'created_at': now,
        })
    return {'report': report}


@app.post('/reports/{report_id}/resolve')
def resolve_issue_report(
    report_id: str,
    payload: dict[str, Any],
    request: Request,
) -> dict[str, bool]:
    db = get_db(request)
    report = db.reports.find_one({'$or': [{'_id': report_id}, {'report_id': report_id}]})
    if report is None:
        raise HTTPException(status_code=404, detail='Issue report not found.')

    worker_id = str(report.get('reporter_id') or '').strip()
    if not worker_id:
        raise HTTPException(status_code=400, detail='Report has no submitting worker.')

    now = datetime.now(timezone.utc)
    report_name = str(report.get('name') or 'Issue Report')
    notification_id = uuid.uuid4().hex
    worker = db.workers.find_one(worker_query(worker_id)) or {}
    if worker_notification_preferences(worker).get('report_updates', True):
        db.notifications.insert_one({
            '_id': notification_id,
            'notification_id': notification_id,
            'worker_id': worker_id,
            'report_id': report_id,
            'report_name': report_name,
            'notification_type': 'report_resolved',
            'message': f"Your report '{report_name}' has been resolved by the admin.",
            'remarks': str(payload.get('remarks') or '').strip(),
            'created_at': now,
        })
    db.report_photos.delete_many({'report_id': report_id})
    db.report_images.delete_many({'report_id': report_id})
    db.reports.delete_one({'_id': report.get('_id')})
    return {'ok': True}


@app.post('/setup/complete')
async def complete_setup(request: Request) -> dict[str, bool]:
    form = await request.form()
    files = {
        key: value
        for key, value in form.multi_items()
        if hasattr(value, 'filename') and hasattr(value, 'read')
    }
    try:
        payload = json.loads(str(form.get('payload') or '{}'))
    except json.JSONDecodeError as error:
        raise HTTPException(status_code=400, detail='Invalid setup payload') from error

    db = get_db(request)
    admin = payload.get('admin') or {}
    workers = payload.get('workers') or []
    bins = payload.get('bins') or []
    zones = payload.get('zones') or []
    now = datetime.now(timezone.utc)
    if not admin.get('admin_id') or not admin.get('email'):
        raise HTTPException(status_code=400, detail='Invalid admin payload')

    admin_id = admin['admin_id']
    admin_photo = await upsert_image(db, 'admin_images', 'admin_id', admin_id, files.get('adminPhoto'))
    db.admins.update_one(
        {'_id': admin_id},
        {
            '$set': {
                'admin_id': admin_id, 'name': admin.get('name'),
                'first_name': admin.get('first_name') or '', 'last_name': admin.get('last_name') or '',
                'date_of_birth': admin.get('date_of_birth') or '', 'email': admin['email'],
                'phone': admin.get('phone') or '',
                'profile_image_url': admin_photo or admin.get('profile_image_url') or '',
                'updated_at': now,
            },
            '$setOnInsert': {'_id': admin_id, 'created_at': now},
        },
        upsert=True,
    )
    for worker in workers:
        worker_id = worker['worker_id']
        worker_photo = await upsert_image(
            db, 'worker_images', 'worker_id', worker_id,
            files.get(f"workerPhoto_{worker.get('local_id', '')}"),
        )
        db.workers.update_one(
            {'_id': worker_id},
            {
                '$set': {
                    'worker_id': worker_id, 'first_name': worker.get('first_name') or '',
                    'last_name': worker.get('last_name') or '', 'date_of_birth': worker.get('date_of_birth') or '',
                    'name': worker.get('name'), 'email': worker.get('email'),
                    'phone': worker.get('phone') or '', 'role': 'worker',
                    'profile_image_url': worker_photo or worker.get('profile_image_url') or '',
                    'assigned_zones': worker.get('assigned_zones') or [],
                    'status': worker.get('status') or 'active',
                    'current_location': worker.get('current_location') or {'lat': 0, 'lng': 0},
                    'last_active': now, 'updated_at': now,
                },
                '$setOnInsert': {'_id': worker_id, 'created_at': now},
            },
            upsert=True,
        )
    location_lat = payload.get('location_lat') or 0.0
    location_lon = payload.get('location_lon') or 0.0
    for bin_doc in bins:
        bin_id = bin_doc['bin_id']
        db.bins.update_one(
            {'_id': bin_id},
            {
                '$set': {
                    'id': bin_doc.get('id') or bin_id, 'bin_id': bin_id, 'type': 'bin',
                    'name': bin_doc.get('name'), 'location_description': bin_doc.get('location_description') or '',
                    'location': bin_doc.get('location') or {'type': 'Point', 'coordinates': [location_lon, location_lat]},
                    'zone_id': bin_doc.get('zone_id') or None,
                    'last_updated': now,
                },
                '$setOnInsert': {
                    '_id': bin_id,
                    'created_at': now,
                    'fill_level': 0,
                    'gas_level': 0,
                    'flame': False,
                    'status': 'normal',
                },
            },
            upsert=True,
        )
    for zone in zones:
        zone_id = zone['zone_id']
        db.zones.update_one(
            {'_id': zone_id},
            {
                '$set': {
                    'id': zone.get('id') or zone_id, 'zone_id': zone_id, 'type': 'zone',
                    'name': zone.get('name'), 'location_description': zone.get('location_description') or '',
                    'location': zone.get('location') or {'type': 'Point', 'coordinates': [location_lon, location_lat]},
                    'last_updated': now,
                },
                '$setOnInsert': {'_id': zone_id, 'created_at': now},
            },
            upsert=True,
        )
    organization_location = payload.get('organization_location') or ''
    db.app_config.update_one(
        {'_id': 'main'},
        {
            '$set': {
                'config_id': 'main', 'is_setup_complete': True, 'admin_uid': admin_id,
                'organization_name': payload.get('organization_name') or 'BinSight Deployment',
                'organization_location': {
                    'name': organization_location, 'latitude': location_lat, 'longitude': location_lon,
                },
                'organization_location_name': organization_location, 'location_lat': location_lat,
                'location_lon': location_lon, 'updated_at': now,
            },
            '$setOnInsert': {'created_at': now},
        },
        upsert=True,
    )
    return {'ok': True}


if __name__ == '__main__':
    import uvicorn

    uvicorn.run('app:app', host='0.0.0.0', port=PORT, reload=False)