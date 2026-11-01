import 'package:flutter/material.dart';

/// Slim AppBar banner explaining a partial (Android 14 "Select photos")
/// gallery grant, with a way to change the selection.
class LimitedAccessBanner extends StatelessWidget {
  const LimitedAccessBanner({super.key, required this.onManage});

  final VoidCallback onManage;

  static const double height = 46;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: height,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.only(left: 20, right: 8),
      child: Row(
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Only your selected photos are visible',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(onPressed: onManage, child: const Text('Manage')),
        ],
      ),
    );
  }
}
