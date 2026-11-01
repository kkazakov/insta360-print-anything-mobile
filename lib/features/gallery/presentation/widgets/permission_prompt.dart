import 'package:flutter/material.dart';

import '../../../../core/ui/status_message.dart';

/// Shown when the gallery permission was declined or blocked.
///
/// "Allow access" re-runs the system prompt, which is what the user asked for
/// when pressing the button; "Open settings" is the way out when Android no
/// longer shows the prompt (permanent denial) or the state is restricted.
class PermissionPrompt extends StatelessWidget {
  const PermissionPrompt({
    super.key,
    required this.restricted,
    required this.onRequestAccess,
    required this.onOpenSettings,
  });

  final bool restricted;
  final VoidCallback onRequestAccess;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (restricted) {
      return StatusMessage(
        icon: Icons.lock_outline_rounded,
        title: 'Photo access is blocked',
        message:
            'Photo access for this app is restricted by the system, so your '
            'gallery cannot be shown. Changing it needs the app settings.',
        actions: [
          FilledButton(
            onPressed: onOpenSettings,
            child: const Text('Open settings'),
          ),
        ],
        footnote: 'Settings → Apps → Insta360 Print → Permissions → Photos.',
      );
    }

    return StatusMessage(
      icon: Icons.photo_library_outlined,
      title: 'Photo access needed',
      message:
          'To copy a photo onto your Insta360 camera, the app needs to see '
          'your photos. Nothing leaves the phone except the photo you choose.',
      actions: [
        FilledButton(
          onPressed: onRequestAccess,
          child: const Text('Allow access'),
        ),
        OutlinedButton(
          onPressed: onOpenSettings,
          child: const Text('Open settings'),
        ),
      ],
      footnote:
          'If Android no longer shows the prompt, enable Photos access in '
          'Settings → Apps → Insta360 Print → Permissions.',
    );
  }
}
