// A single searchable entry point for actions. Keeps toolbars small.

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class CommandAction {
  final String label;
  final String? subtitle;
  final IconData icon;
  final VoidCallback run;
  const CommandAction({
    required this.label,
    this.subtitle,
    required this.icon,
    required this.run,
  });
}

class CommandPalette extends StatefulWidget {
  final List<CommandAction> commands;
  const CommandPalette({super.key, required this.commands});

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final search = TextEditingController();
  int selected = 0;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<CommandAction> get filtered {
    final q = search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.commands;
    return widget.commands
        .where(
          (c) => '${c.label} ${c.subtitle ?? ''}'.toLowerCase().contains(q),
        )
        .toList();
  }

  void run(CommandAction action) {
    Navigator.of(context).pop();
    action.run();
  }

  void move(int delta) {
    final items = filtered;
    if (items.isEmpty) return;
    setState(() => selected = (selected + delta) % items.length);
  }

  @override
  Widget build(BuildContext context) {
    final items = filtered;
    if (selected >= items.length) selected = 0;
    final index = items.isEmpty ? -1 : selected;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (index >= 0) run(items[index]);
        },
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
          if (index >= 0) run(items[index]);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: theme.useMaterial3
                    ? SearchBar(
                        controller: search,
                        autoFocus: true,
                        hintText: 'Type a command or conversation…',
                        leading: const Icon(Icons.bolt_outlined),
                        trailing: [
                          if (search.text.isNotEmpty)
                            IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                search.clear();
                                setState(() => selected = 0);
                              },
                            ),
                        ],
                        onChanged: (_) => setState(() => selected = 0),
                      )
                    : TextField(
                        controller: search,
                        autofocus: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.bolt_outlined),
                          hintText: 'Type a command or conversation…',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() => selected = 0),
                      ),
              ),
              const Divider(height: 1),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off, size: 40, color: cs.primary),
                      const SizedBox(height: 10),
                      Text(
                        'No matching commands',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Try a different word or conversation name.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final action = items[i];
                      return ListTile(
                        dense: true,
                        selected: i == index,
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: cs.secondaryContainer,
                          foregroundColor: cs.onSecondaryContainer,
                          child: Icon(action.icon, size: 18),
                        ),
                        title: Text(
                          action.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: action.subtitle == null
                            ? null
                            : Text(
                                action.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => run(action),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '↑↓ choose · Enter run · Esc close',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
