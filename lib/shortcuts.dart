// Discoverable keyboard shortcuts.

import 'package:material_ui/material_ui.dart';

class ShortcutSheet extends StatelessWidget {
  static const entries = <({String action, String keys})>[
    (action: 'Open command palette', keys: 'Ctrl/⌘ K'),
    (action: 'Search messages', keys: 'Ctrl/⌘ F'),
    (action: 'Next search match', keys: 'F3'),
    (action: 'Previous search match', keys: 'Shift F3'),
    (action: 'Clear search / close results', keys: 'Esc'),
    (action: 'Show this help', keys: '?'),
    (action: 'Choose in command palette', keys: '↑ / ↓ then Enter'),
    (action: 'Jump by time', keys: 'Click or drag the activity rail'),
  ];

  const ShortcutSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.keyboard_outlined, color: cs.primary),
          const SizedBox(width: 12),
          const Expanded(child: Text('Keyboard shortcuts')),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in entries)
              ListTile(
                dense: true,
                title: Text(e.action),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    e.keys,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
