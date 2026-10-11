import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Displays registered bins and zones in two clearly separated columns.
/// On narrow screens the columns stack so each device card remains readable.
class RegisteredBinsZonesSection extends StatelessWidget {
  const RegisteredBinsZonesSection({
    super.key,
    required this.bins,
    required this.zones,
    required this.binBuilder,
    required this.zoneBuilder,
    this.binTitle = 'Bins',
    this.zoneTitle = 'Zones',
  });

  final List<Map<String, dynamic>> bins;
  final List<Map<String, dynamic>> zones;
  final Widget Function(Map<String, dynamic>) binBuilder;
  final Widget Function(Map<String, dynamic>) zoneBuilder;
  final String binTitle;
  final String zoneTitle;

  Widget _column(
    String title,
    List<Map<String, dynamic>> devices,
    Widget Function(Map<String, dynamic>) builder,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          title,
          style: GoogleFonts.titilliumWeb(
            fontSize: 19,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF263238),
          ),
        ),
      ),
      if (devices.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            title.startsWith('ASSIGNED ')
                ? 'No ${title.toLowerCase()}.'
                : 'No registered ${title.toLowerCase()}.',
            style: GoogleFonts.titilliumWeb(
              fontSize: 16,
              color: Colors.black54,
            ),
          ),
        )
      else
        ...devices.map(builder),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final binsColumn = _column(binTitle, bins, binBuilder);
      final zonesColumn = _column(zoneTitle, zones, zoneBuilder);
      if (constraints.maxWidth < 720) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            binsColumn,
            const Divider(height: 28, thickness: 1),
            zonesColumn,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: binsColumn),
            const VerticalDivider(width: 32, thickness: 1),
            Expanded(child: zonesColumn),
          ],
        ),
      );
    },
  );
}
