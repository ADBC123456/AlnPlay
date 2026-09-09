import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/library_models.dart';

/// Compact settings row for a library root's recursive scan depth.
class ScanDepthSetting extends StatelessWidget {
  const ScanDepthSetting({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(
      LibraryRoot.minimumMaxScanDepth,
      LibraryRoot.maximumMaxScanDepth,
    );
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const AppText('Scan depth'),
      subtitle: const AppText('Maximum folder levels below each library root'),
      trailing: DropdownButton<int>(
        value: normalized,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
        items: [
          for (
            var depth = LibraryRoot.minimumMaxScanDepth;
            depth <= LibraryRoot.maximumMaxScanDepth;
            depth++
          )
            DropdownMenuItem(value: depth, child: Text('$depth')),
        ],
      ),
    );
  }
}
