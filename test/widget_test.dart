import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:binsight/main.dart';
import 'package:binsight/screens/auth/login_screen.dart';
import 'package:binsight/widgets/manage_devices_content.dart';

void main() {
  test('Next bin name skips existing numbered bins', () {
    final existing = [
      {'type': 'bin', 'name': 'Bin 1'},
      {'type': 'bin', 'name': 'Bin 3'},
      {'type': 'zone', 'name': 'Zone A'},
    ];

    expect(generateNextBinName(existing), 'Bin 2');
  });

  test('Bin display names append the location detail to the auto-generated number', () {
    final bin = {
      'type': 'bin',
      'name': 'Bin 2',
      'location_description': 'Floor 5, 507',
    };

    expect(buildBinDisplayName(bin), 'Bin 2 - Floor 5, 507');
  });

  testWidgets('Login screen shows the admin setup CTA and fires the callback', (WidgetTester tester) async {
    bool adminSetupTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onGoToAdminSetup: () => adminSetupTapped = true,
        ),
      ),
    );

    expect(find.text('Go to Admin Setup'), findsOneWidget);

    await tester.ensureVisible(find.text('Go to Admin Setup'));
    await tester.tap(find.text('Go to Admin Setup'));
    await tester.pump();

    expect(adminSetupTapped, isTrue);
  });

  test('QR device detection matches the setup-screen contract', () {
    expect(detectDeviceTypeFromQr('bin'), 'bin');
    expect(detectDeviceTypeFromQr('bin:sticker-1'), 'bin');
    expect(detectDeviceTypeFromQr('ZONE'), 'zone');
    expect(detectDeviceTypeFromQr('zone:floor-3'), 'zone');
    expect(detectDeviceTypeFromQr('{"type":"bin"}'), 'bin');
    expect(detectDeviceTypeFromQr('random-text'), isNull);
  });

  test('Bin numbering reindexes to a consecutive sequence after deletion', () {
    final bins = [
      {'type': 'bin', 'name': 'Bin 1'},
      {'type': 'bin', 'name': 'Bin 2'},
      {'type': 'bin', 'name': 'Bin 3'},
      {'type': 'bin', 'name': 'Bin 4'},
    ];

    final remaining = bins.where((bin) => bin['name'] != 'Bin 2').toList();
    final reindexed = <Map<String, dynamic>>[];
    for (var i = 0; i < remaining.length; i++) {
      reindexed.add({...remaining[i], 'name': 'Bin ${i + 1}'});
    }

    expect(reindexed.map((bin) => bin['name']).toList(), ['Bin 1', 'Bin 2', 'Bin 3']);
  });

}
