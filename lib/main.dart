// Indexed: opens exported Facebook / Messenger JSON and shows it as chats.
// Linux first; the same code is meant to run on Android.

import 'dart:async' show unawaited;
import 'dart:io' show File;
import 'dart:ui' show PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_view.dart';
import 'command_palette.dart';
import 'global_search_screen.dart';
import 'models.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'shortcuts.dart';
import 'store.dart';
import 'tools_screen.dart';
import 'util.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  await settings.load();
  gSettings = settings;

  // Write errors to a log file, so a crash can be looked at afterwards.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    settings.logError('${details.exceptionAsString()}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    settings.logError('$error\n$stack');
    return false; // still let Flutter print it in the terminal
  };
  settings.logBreadcrumb('Indexed started');

  // Keep decoded photos around, but do not let the cache dominate RAM in debug
  // builds that already hold tens of thousands of messages.
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSizeBytes = 160 << 20;
  cache.maximumSize = 1200;

  runApp(ViewerApp(settings: settings));
}

enum _ChatContextAction {
  archive,
  details,
  copyName,
  copyParticipants,
  clearPosition,
  remove,
}

class ViewerApp extends StatefulWidget {
  final AppSettings settings;
  const ViewerApp({super.key, required this.settings});

  @override
  State<ViewerApp> createState() => _ViewerAppState();
}

class _ViewerAppState extends State<ViewerApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A debounced save must not be lost when the app is swiped away or closed.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(widget.settings.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.settings.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: settings.appearance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Indexed',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: settings.themeFor(Brightness.light),
          darkTheme: settings.themeFor(Brightness.dark),
          themeAnimationStyle: settings.animateTheme
              ? null
              : AnimationStyle.noAnimation,
          // "Text size" in settings scales all text in the app.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(settings.textScale)),
            child: child!,
          ),
          home: HomeScreen(settings: settings),
        );
      },
    );
  }
}

// ---------- optional local PIN gate ----------

class LockScreen extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback onUnlock;
  const LockScreen({super.key, required this.settings, required this.onUnlock});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final pin = TextEditingController();
  String error = '';

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  void submit() {
    if (widget.settings.pinMatches(pin.text.trim())) {
      widget.onUnlock();
    } else {
      setState(() => error = 'Incorrect PIN.');
    }
  }

  Future<void> resetPin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset the local PIN?'),
        content: const Text(
          'This removes the ask-on-start gate only. Your JSON files and media are not encrypted or changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset PIN'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.settings.resetPin();
    if (context.mounted) widget.onUnlock();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 48, color: cs.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Enter PIN',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      errorText: error.isEmpty ? null : error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: submit,
                    icon: const Icon(Icons.login),
                    label: const Text('Unlock'),
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: resetPin,
                    icon: const Icon(Icons.lock_reset_outlined),
                    label: const Text('Forgot PIN? Reset local lock'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- home: conversation list + chat ----------

class HomeScreen extends StatefulWidget {
  final AppSettings settings;
  const HomeScreen({super.key, required this.settings});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final Store store = Store(widget.settings);
  late final Listenable _changes = Listenable.merge([store, widget.settings]);
  Chat? selected;
  String filter = '';
  bool _showArchived = false;
  final filterController = TextEditingController();
  bool _wide = false;
  Msg? _jumpTarget;
  bool unlocked = false;
  bool _largeFileWarningShown = false;
  final ScrollController _chatListController = ScrollController();

  @override
  void initState() {
    super.initState();
    unlocked = !widget.settings.lockEnabled;
    if (unlocked && widget.settings.reopenLast) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restore());
      });
    }
  }

  void unlock() {
    setState(() => unlocked = true);
    if (widget.settings.reopenLast && store.chats.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restore());
      });
    }
  }

  Future<void> _restore() async {
    await _offerLighterMemoryForLargeFiles(widget.settings.jsonPaths);
    await store.restoreSession();
    final last = widget.settings.lastChat;
    if (mounted && last.isNotEmpty && store.chats.containsKey(last)) {
      setState(() => selected = store.chats[last]);
    }
  }

  @override
  void dispose() {
    filterController.dispose();
    _chatListController.dispose();
    store.dispose();
    super.dispose();
  }

  void openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(settings: widget.settings, store: store),
      ),
    );
  }

  void clearSession() {
    setState(() => selected = null);
    store.clear();
  }

  Future<void> _copyText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _showConversationDetails(Chat c) {
    final cs = Theme.of(context).colorScheme;
    final participants =
        c.participants.map((p) => widget.settings.aliasFor(p)).toList()..sort();
    final mediaCount = c.messages.fold<int>(
      0,
      (sum, m) => sum + m.media.length,
    );
    final archived = widget.settings.archivedChats.contains(c.key);

    Widget row(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              row(Icons.forum_outlined, '${c.messages.length} messages'),
              row(
                Icons.calendar_month_outlined,
                'Last message ${fmtDate(c.lastT == 0 ? null : c.lastT)}',
              ),
              row(Icons.image_outlined, '$mediaCount media items'),
              row(
                Icons.folder_outlined,
                '${c.dirs.length} conversation media folder(s)',
              ),
              row(
                Icons.archive_outlined,
                archived ? 'Archived' : 'Active conversation',
              ),
              const SizedBox(height: 12),
              Text(
                'Participants',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Text(participants.join(', ')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemoveChat(Chat c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${c.title}"?'),
        content: const Text(
          'The conversation is hidden from this app and its saved session. The original JSON file on disk is not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      if (selected?.key == c.key) selected = null;
    });
    store.removeChat(c);
  }

  Future<void> _showConversationMenu(
    BuildContext context,
    Offset position,
    Chat c,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final rect = overlay == null
        ? RelativeRect.fromLTRB(
            position.dx,
            position.dy,
            position.dx,
            position.dy,
          )
        : RelativeRect.fromRect(
            Rect.fromPoints(position, position),
            Offset.zero & overlay.size,
          );
    final archived = widget.settings.archivedChats.contains(c.key);

    PopupMenuItem<_ChatContextAction> item(
      IconData icon,
      String label,
      _ChatContextAction value,
    ) => PopupMenuItem<_ChatContextAction>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    );

    final action = await showMenu<_ChatContextAction>(
      context: context,
      position: rect,
      items: [
        item(
          archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          archived ? 'Unarchive' : 'Archive',
          _ChatContextAction.archive,
        ),
        item(Icons.info_outline, 'Details', _ChatContextAction.details),
        const PopupMenuDivider(),
        item(Icons.copy_outlined, 'Copy name', _ChatContextAction.copyName),
        item(
          Icons.people_outline,
          'Copy participant names',
          _ChatContextAction.copyParticipants,
        ),
        item(
          Icons.mark_chat_unread_outlined,
          'Clear reading position',
          _ChatContextAction.clearPosition,
        ),
        const PopupMenuDivider(),
        item(
          Icons.delete_outline,
          'Remove from app',
          _ChatContextAction.remove,
        ),
      ],
    );
    if (action == null || !mounted || !context.mounted) return;
    switch (action) {
      case _ChatContextAction.archive:
        store.toggleArchive(c);
        if (widget.settings.archivedChats.isEmpty && _showArchived) {
          setState(() => _showArchived = false);
        }
      case _ChatContextAction.details:
        _showConversationDetails(c);
      case _ChatContextAction.copyName:
        await _copyText(c.title, 'Conversation name copied.');
      case _ChatContextAction.copyParticipants:
        final names =
            c.participants.map((p) => widget.settings.aliasFor(p)).toList()
              ..sort();
        await _copyText(names.join(', '), 'Participant names copied.');
      case _ChatContextAction.clearPosition:
        widget.settings.update(() => widget.settings.chatPos.remove(c.key));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reading position cleared.')),
        );
      case _ChatContextAction.remove:
        await _confirmRemoveChat(c);
    }
  }

  // A 20 MB export can grow to well over a GB in debug mode when raw JSON is
  // retained for every message. Ask before that happens, not after the VM has
  // exhausted its heap.
  static const int _largeExportBytes = 8 * 1024 * 1024;

  Future<void> _offerLighterMemoryForLargeFiles(List<String> paths) async {
    if (_largeFileWarningShown || !widget.settings.keepRaw || !mounted) return;
    final large = paths.any((p) {
      final f = File(p);
      return f.existsSync() && f.lengthSync() > _largeExportBytes;
    });
    if (!large) return;
    _largeFileWarningShown = true;
    final turnOff =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Large export detected'),
            content: const Text(
              'Keeping the original JSON in memory makes big exports use much more RAM. '
              'Turn off raw retention for lighter parsing? You can change it later in Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep raw JSON'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Turn off for big files'),
              ),
            ],
          ),
        ) ??
        false;
    if (turnOff && mounted) {
      widget.settings.logBreadcrumb('Large export: raw retention disabled');
      widget.settings.update(() => widget.settings.keepRaw = false);
    }
  }

  void toggleDarkMode() {
    final next = widget.settings.themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    widget.settings.update(
      () => widget.settings.themeMode = next,
      appearanceOnly: true,
    );
  }

  void showShortcutSheet() {
    showDialog<void>(context: context, builder: (_) => const ShortcutSheet());
  }

  List<CommandAction> commandActions() => [
    CommandAction(
      label: 'Open JSON files',
      subtitle: 'Add one or more exported .json files',
      icon: Icons.description,
      run: pickJson,
    ),
    CommandAction(
      label: 'Import folder of JSON files',
      subtitle: 'Recursively import every .json file in a folder',
      icon: Icons.folder_open_outlined,
      run: importJsonFolder,
    ),
    CommandAction(
      label: 'Search every conversation',
      subtitle: 'Global search with jump-to-message',
      icon: Icons.travel_explore,
      run: searchAll,
    ),
    CommandAction(
      label: 'Open Tools',
      subtitle: 'Saved messages, insights, links and media',
      icon: Icons.dashboard_customize_outlined,
      run: openTools,
    ),
    CommandAction(
      label: 'Open Settings',
      icon: Icons.settings_outlined,
      run: openSettings,
    ),
    CommandAction(
      label: 'Toggle dark / light theme',
      icon: Icons.brightness_6_outlined,
      run: toggleDarkMode,
    ),
    CommandAction(
      label: 'Choose shared media folder',
      icon: Icons.folder_shared_outlined,
      run: pickSharedMedia,
    ),
    CommandAction(
      label: 'Clear loaded session',
      subtitle: 'Close the open files without deleting them',
      icon: Icons.delete_outline,
      run: clearSession,
    ),
    CommandAction(
      label: 'Keyboard shortcuts',
      icon: Icons.keyboard_outlined,
      run: showShortcutSheet,
    ),
    for (final c in store.sortedChats)
      CommandAction(
        label: 'Open ${c.title}',
        subtitle: '${c.messages.length} messages',
        icon: Icons.chat_bubble_outline,
        run: () => openChat(c, _wide),
      ),
  ];

  Future<void> openCommandPalette() async {
    await showDialog<void>(
      context: context,
      builder: (_) => CommandPalette(commands: commandActions()),
    );
  }

  Future<void> pickJson() async {
    // file_picker 13+: static call, returns an empty list when cancelled.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return;
    final paths = files.map((f) => f.path).whereType<String>().toList();
    widget.settings.logBreadcrumb(
      'Open JSON: ${paths.length} file(s), keepRaw=${widget.settings.keepRaw}',
    );
    await _offerLighterMemoryForLargeFiles(paths);
    await store.addJsonFiles(paths);
    if (mounted && selected == null && store.chats.length == 1) {
      setState(() => selected = store.chats.values.first);
    }
  }

  Future<void> importJsonFolder() async {
    final uri = await FilePicker.pickDirectory();
    if (uri == null || uri.scheme != 'file') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a local folder to import its .json files.'),
          ),
        );
      }
      return;
    }
    final files = jsonFilesIn(uri.toFilePath());
    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No .json files found in that folder.')),
        );
      }
      return;
    }
    widget.settings.logBreadcrumb(
      'Import folder: ${files.length} file(s), keepRaw=${widget.settings.keepRaw}',
    );
    await _offerLighterMemoryForLargeFiles(files);
    await store.addJsonFiles(files);
    if (mounted && selected == null && store.chats.length == 1) {
      setState(() => selected = store.chats.values.first);
    }
  }

  Future<void> pickSharedMedia() async {
    final dir = await pickFolder(store);
    if (dir != null) await store.addMediaDir(dir);
  }

  void openChat(Chat c, bool wide, {Msg? target}) {
    widget.settings.logBreadcrumb(
      'Open conversation: ${c.title} (${c.messages.length} messages)',
    );
    widget.settings.lastChat = c.key;
    widget.settings.save();
    if (wide) {
      setState(() {
        selected = c;
        _jumpTarget = target;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(c.title)),
            // this route sits outside the home screen, so it listens for changes itself
            body: ListenableBuilder(
              listenable: Listenable.merge([store, widget.settings]),
              builder: (context, _) =>
                  ChatView(store: store, chat: c, initialTarget: target),
            ),
          ),
        ),
      );
    }
  }

  Future<void> searchAll() async {
    widget.settings.logBreadcrumb('Open global search');
    final hit = await Navigator.of(context).push<GlobalHit>(
      MaterialPageRoute(builder: (_) => GlobalSearchScreen(store: store)),
    );
    if (hit == null || !mounted) return;
    openChat(hit.chat, _wide, target: hit.msg);
  }

  Future<void> openTools() async {
    widget.settings.logBreadcrumb('Open tools');
    final hit = await Navigator.of(context).push<GlobalHit>(
      MaterialPageRoute(builder: (_) => ToolsScreen(store: store)),
    );
    if (hit == null || !mounted) return;
    openChat(hit.chat, _wide, target: hit.msg);
  }

  Widget _emptyState({required bool filtered}) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.search_off : Icons.chat_bubble_outline,
              size: 48,
              color: cs.primary,
            ),
            const SizedBox(height: 12),
            Text(
              filtered ? 'No matching conversations' : 'No conversations yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              filtered
                  ? 'Try a different name in the filter above.'
                  : 'Open a Messenger JSON export to start reading.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (filtered)
              OutlinedButton.icon(
                onPressed: () {
                  filterController.clear();
                  setState(() => filter = '');
                },
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Clear filter'),
              )
            else
              FilledButton.icon(
                onPressed: pickJson,
                icon: const Icon(Icons.description_outlined),
                label: const Text('Open JSON'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chatPlaceholder() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: cs.primary),
            const SizedBox(height: 14),
            Text(
              'Choose a conversation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Open a JSON file, then pick a chat from the list.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: pickJson,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Open JSON'),
            ),
          ],
        ),
      ),
    );
  }

  Widget sidebar(bool wide, {bool rail = false}) {
    final q = filter.toLowerCase();
    bool archived(Chat c) => widget.settings.archivedChats.contains(c.key);
    final base = store.sortedChats
        .where((c) => q.isEmpty || c.title.toLowerCase().contains(q))
        .toList();
    final order = {for (final e in base.asMap().entries) e.value.key: e.key};
    final chats = base.where((c) => _showArchived || !archived(c)).toList()
      ..sort((a, b) {
        final aa = archived(a);
        final ab = archived(b);
        if (aa != ab) return aa ? 1 : -1;
        return order[a.key]!.compareTo(order[b.key]!);
      });
    final m3 = widget.settings.material3;
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (store.busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: const LinearProgressIndicator(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Container(
            decoration: m3
                ? BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: pickJson,
                    icon: const Icon(Icons.description),
                    label: const Text('Open JSON'),
                  ),
                  IconButton(
                    tooltip: 'Import every .json file in a folder',
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: importJsonFolder,
                  ),
                  if (!rail) ...[
                    IconButton(
                      tooltip: 'Search every conversation',
                      icon: const Icon(Icons.travel_explore),
                      onPressed: searchAll,
                    ),
                    IconButton(
                      tooltip: 'Saved messages, insights, links and media',
                      icon: const Icon(Icons.dashboard_customize_outlined),
                      onPressed: openTools,
                    ),
                  ],
                  if (widget.settings.archivedChats.isNotEmpty)
                    IconButton(
                      tooltip: _showArchived
                          ? 'Hide archived conversations'
                          : 'Show archived conversations',
                      isSelected: _showArchived,
                      icon: const Icon(Icons.archive_outlined),
                      selectedIcon: const Icon(Icons.archive),
                      onPressed: () =>
                          setState(() => _showArchived = !_showArchived),
                    ),
                  Tooltip(
                    message: 'A media folder used by every conversation. Per-conversation folders are in the chat\'s media info.',
                    child: OutlinedButton.icon(
                      onPressed: pickSharedMedia,
                      icon: const Icon(Icons.folder_shared),
                      label: const Text('Shared media'),
                    ),
                  ),
                  TextButton(
                    onPressed: clearSession,
                    child: const Text('Clear'),
                  ),
                  if (!rail) ...[
                    IconButton(
                      tooltip: 'Command palette (Ctrl/⌘ K)',
                      icon: const Icon(Icons.bolt_outlined),
                      onPressed: openCommandPalette,
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings),
                      onPressed: openSettings,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: m3
              ? SearchBar(
                  controller: filterController,
                  hintText: 'Filter conversations',
                  leading: const Icon(Icons.search),
                  trailing: [
                    if (filter.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear filter',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          filterController.clear();
                          setState(() => filter = '');
                        },
                      ),
                  ],
                  onChanged: (v) => setState(() => filter = v),
                )
              : TextField(
                  controller: filterController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Filter conversations',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => filter = v),
                ),
        ),
        Expanded(
          child: chats.isEmpty
              ? _emptyState(filtered: q.isNotEmpty)
              : RawScrollbar(
                  controller: _chatListController,
                  thumbVisibility: true,
                  thickness: 6,
                  radius: const Radius.circular(8),
                  mainAxisMargin: 4,
                  crossAxisMargin: 2,
                  thumbColor: cs.onSurface.withValues(alpha: 0.24),
                  child: ListView.separated(
                    controller: _chatListController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    itemCount: chats.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final c = chats[i];
                      final initial = c.title.isEmpty
                          ? '?'
                          : c.title[0].toUpperCase();
                      final isArchived = archived(c);
                      return Builder(
                        builder: (tileContext) => GestureDetector(
                          onSecondaryTapDown: (d) => unawaited(
                            _showConversationMenu(
                              tileContext,
                              d.globalPosition,
                              c,
                            ),
                          ),
                          child: ListTile(
                            selected: wide && selected?.key == c.key,
                            selectedTileColor: cs.secondaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            leading: CircleAvatar(
                              backgroundColor: isArchived
                                  ? cs.surfaceContainerHighest
                                  : cs.primaryContainer,
                              foregroundColor: isArchived
                                  ? cs.onSurfaceVariant
                                  : cs.onPrimaryContainer,
                              child: Text(initial),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isArchived)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Icon(
                                      Icons.archive_outlined,
                                      size: 14,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              '${c.messages.length} messages · ${fmtDate(c.lastT == 0 ? null : c.lastT)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: c.dirs.isEmpty
                                ? null
                                : Tooltip(
                                    message: 'Has media folders',
                                    child: Icon(
                                      Icons.folder,
                                      size: 16,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                            onTap: () => openChat(c, wide),
                            onLongPress: () {
                              final box =
                                  tileContext.findRenderObject() as RenderBox?;
                              unawaited(
                                _showConversationMenu(
                                  tileContext,
                                  box?.localToGlobal(Offset.zero) ??
                                      Offset.zero,
                                  c,
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (store.status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Container(
              decoration: m3
                  ? BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    )
                  : null,
              padding: const EdgeInsets.all(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      store.status,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!unlocked) {
      return LockScreen(settings: widget.settings, onUnlock: unlock);
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            openCommandPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            openCommandPalette,
        const SingleActivator(LogicalKeyboardKey.slash, shift: true):
            showShortcutSheet,
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: _changes,
          builder: (context, _) => LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 800;
              _wide = wide;
              return Scaffold(
                appBar: wide ? null : AppBar(title: const Text('Indexed')),
                body: SafeArea(
                  child: wide
                      ? Row(
                          children: [
                            if (widget.settings.material3) ...[
                              NavigationRail(
                                selectedIndex: 0,
                                groupAlignment: -0.85,
                                labelType: NavigationRailLabelType.all,
                                leading: Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Icon(
                                    Icons.forum_outlined,
                                    size: 28,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                ),
                                onDestinationSelected: (i) {
                                  switch (i) {
                                    case 1:
                                      unawaited(openCommandPalette());
                                    case 2:
                                      unawaited(searchAll());
                                    case 3:
                                      unawaited(openTools());
                                    case 4:
                                      openSettings();
                                  }
                                },
                                destinations: const [
                                  NavigationRailDestination(
                                    icon: Icon(Icons.chat_bubble_outline),
                                    selectedIcon: Icon(Icons.chat_bubble),
                                    label: Text('Chats'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(Icons.bolt_outlined),
                                    label: Text('Commands'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(Icons.travel_explore),
                                    label: Text('Search'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(
                                      Icons.dashboard_customize_outlined,
                                    ),
                                    label: Text('Tools'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(Icons.settings_outlined),
                                    label: Text('Settings'),
                                  ),
                                ],
                              ),
                              const VerticalDivider(width: 1),
                            ],
                            SizedBox(
                              width: 340,
                              child: sidebar(
                                true,
                                rail: widget.settings.material3,
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: selected == null
                                  ? _chatPlaceholder()
                                  : ChatView(
                                      key: ValueKey(
                                        _jumpTarget == null
                                            ? selected!.key
                                            : '${selected!.key}|${Store.messageKey(_jumpTarget!)}',
                                      ),
                                      store: store,
                                      chat: selected!,
                                      initialTarget: _jumpTarget,
                                    ),
                            ),
                          ],
                        )
                      : sidebar(false),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
