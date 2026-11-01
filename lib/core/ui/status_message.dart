import 'package:flutter/material.dart';

/// Full-screen or full-sheet message: icon badge, headline, body and actions.
///
/// Used for every "the normal content cannot be shown" state (permission
/// denied, no cameras found, load failure) so those screens stay consistent.
///
/// The layout adapts to the available height: on a phone in landscape (or a
/// short bottom sheet) the icon/title shrink, the footnote is dropped and
/// multiple actions go side by side, so the primary button is visible without
/// scrolling.
class StatusMessage extends StatelessWidget {
  const StatusMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const <Widget>[],
    this.footnote,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;
  final String? footnote;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        // 430 logical px is below every phone landscape body and some small
        // split-screen layouts; portrait phones (~800) and tablets stay roomy.
        final short = height.isFinite && height < 430;
        final tight = compact || short;
        final iconExtent = compact ? 52.0 : (short ? 56.0 : 72.0);
        final actionsSideBySide = actions.length > 1 && short && !compact;

        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 24 : 32,
              vertical: compact ? 20 : (short ? 16 : 40),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: iconExtent,
                    height: iconExtent,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: iconExtent * (compact ? 0.5 : 0.44),
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: compact ? 16 : (short ? 12 : 22)),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style:
                        (tight
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.headlineSmall)
                            ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: compact ? 6 : (short ? 8 : 10)),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    SizedBox(height: compact ? 16 : (short ? 16 : 26)),
                    if (actionsSideBySide)
                      Row(
                        children: [
                          for (var i = 0; i < actions.length; i++) ...[
                            if (i > 0) const SizedBox(width: 10),
                            Expanded(child: actions[i]),
                          ],
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < actions.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            actions[i],
                          ],
                        ],
                      ),
                  ],
                  // The footnote is supporting detail; on a short screen the
                  // action button matters more.
                  if (footnote != null && !short) ...[
                    const SizedBox(height: 18),
                    Text(
                      footnote!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
