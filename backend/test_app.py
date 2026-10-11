import unittest

from fastapi import HTTPException
from pymongo.errors import ServerSelectionTimeoutError

from app import (
    assess_telemetry,
    device_type_from_qr,
    get_db,
    parse_location,
    validate_telemetry,
    zone_name_exists,
    zone_summary,
)


class TelemetryTests(unittest.TestCase):
    def test_accepts_expected_sensor_values(self):
        self.assertEqual(
            validate_telemetry({'fill_level': 72.5, 'gas_level': 300, 'flame': False}),
            {'fill_level': 72.5, 'gas_level': 300, 'flame': False},
        )

    def test_rejects_out_of_range_and_invalid_values(self):
        invalid_payloads = [
            {'fill_level': -1, 'gas_level': 0, 'flame': False},
            {'fill_level': 20, 'gas_level': 100001, 'flame': False},
            {'fill_level': 20, 'gas_level': 100, 'flame': 0},
            None,
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                validate_telemetry(payload)

    def test_derives_threshold_status(self):
        self.assertEqual(
            assess_telemetry({'fill_level': 25, 'gas_level': 90, 'flame': False}),
            {'fill_alert': False, 'gas_alert': True, 'fire_alert': False, 'status': 'critical'},
        )


class ZoneTests(unittest.TestCase):
    def test_computes_members_and_strips_old_stored_aggregates(self):
        summary = zone_summary(
            {
                '_id': 'zone1',
                'zone_id': 'zone1',
                'name': 'Lobby',
                'avg_fill_level': 44,
                'status': 'normal',
            },
            [
                {'bin_id': 'bin1', 'zone_id': 'zone1', 'fill_level': 30},
                {'bin_id': 'bin2', 'zone_id': 'zone1', 'fill_level': 50},
                {'bin_id': 'bin3', 'zone_id': None},
            ],
        )
        self.assertEqual(summary['bin_count'], 2)
        self.assertEqual([bin_doc['bin_id'] for bin_doc in summary['bins']], ['bin1', 'bin2'])
        self.assertNotIn('avg_fill_level', summary)
        self.assertNotIn('status', summary)

    def test_parses_qr_device_type(self):
        self.assertEqual(device_type_from_qr('BIN:sticker-1'), 'bin')
        self.assertEqual(device_type_from_qr('{"type":"zone"}'), 'zone')
        self.assertIsNone(device_type_from_qr('not a device'))

    def test_parses_legacy_string_organization_location(self):
        self.assertEqual(parse_location({'organization_location': 'Downtown'}), (0.0, 0.0))

    def test_zone_name_lookup_is_case_insensitive_and_escaped(self):
        class Zones:
            def find_one(self, query):
                self.query = query
                return {'zone_id': 'zone1'}

        class Database:
            zones = Zones()

        database = Database()
        self.assertTrue(zone_name_exists(database, ' lobby '))
        self.assertEqual(
            database.zones.query,
            {'name': {'$regex': '^lobby$', '$options': 'i'}},
        )


if __name__ == '__main__':
    unittest.main()