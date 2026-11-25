// The settings screen.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'settings.dart';
import 'store.dart';
import 'util.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Store store;
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.store,
  });

  static const accents = [
    0xFF0B7CFF,
    0xFF2E7D32,
    0xFF8E24AA,
    0xFFE65100,
    0xFFC62828,
    0xFF00838F,
  ];

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingSectionMarker extends StatelessWidget {
  final String title;
  final String keywords;
  const _SettingSectionMarker(this.title, this.keywords);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _SettingSection {
  final String title;
  final String keywords;
  final List<Widget> children = [];
  _SettingSection(this.title, this.keywords);
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  final Set<String> _collapsed = {};
  Set<String>? _collapsedBeforeSearch;

  AppSettings get settings => widget.settings;
  Store get store => widget.store;
  List<int> get accents => SettingsScreen.accents;

  @override
  void initState() {
    super.initState();
    settings.addListener(_refresh);
    settings.appearance.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    settings.removeListener(_refresh);
    settings.appearance.removeListener(_refresh);
    _search.dispose();
    super.dispose();
  }

  Widget section(BuildContext context, String title, [String keywords = '']) =>
      _SettingSectionMarker(title, '$title $keywords');

  List<_SettingSection> _groupSections(List<Widget> children) {
    final sections = <_SettingSection>[];
    _SettingSection? current;
    for (final child in children) {
      if (child is _SettingSectionMarker) {
        current = _SettingSection(child.title, child.keywords);
        sections.add(current);
      } else if (current != null) {
        current.children.add(child);
      } else {
        final loose = _SettingSection('Other', '');
        loose.children.add(child);
        sections.add(loose);
      }
    }
    return sections;
  }

  bool _matches(_SettingSection s, String q) =>
      '${s.title} ${s.keywords}'.toLowerCase().contains(q);

  void _onSearchChanged(String value) {
    setState(() {
      final searching = value.trim().isNotEmpty;
      if (searching && _collapsedBeforeSearch == null) {
        _collapsedBeforeSearch = Set<String>.from(_collapsed);
        _collapsed.clear();
      } else if (!searching && _collapsedBeforeSearch != null) {
        _collapsed
          ..clear()
          ..addAll(_collapsedBeforeSearch!);
        _collapsedBeforeSearch = null;
      }
    });
  }

  Widget _searchField(ThemeData theme) {
    if (!theme.useMaterial3) {
      return TextField(
        controller: _search,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Search settings (theme, cache, PIN, media…)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: _onSearchChanged,
      );
    }
    return SearchBar(
      controller: _search,
      hintText: 'Search settings (theme, cache, PIN, media…)',
      leading: const Icon(Icons.search),
      trailing: [
        if (_search.text.isNotEmpty)
          IconButton(
            tooltip: 'Clear search',
            icon: const Icon(Icons.close),
            onPressed: () {
              _search.clear();
              _onSearchChanged('');
            },
          ),
      ],
      onChanged: _onSearchChanged,
    );
  }

  Widget _sectionCard(_SettingSection s) {
    final expanded = !_collapsed.contains(s.title);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('${s.title}-$expanded'),
        initiallyExpanded: expanded,
        onExpansionChanged: (v) => setState(() {
          if (v) {
            _collapsed.remove(s.title);
          } else {
            _collapsed.add(s.title);
          }
        }),
        title: Text(s.title),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: s.children,
      ),
    );
  }

  Widget hint(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) show,
    required void Function(double) onChanged,
  }) => DeferredSlider(
    label: label,
    value: value,
    min: min,
    max: max,
    divisions: divisions,
    show: show,
    onCommit: onChanged,
  );

  /// A row of choices that can scroll sideways on a narrow screen.
  Widget choice<T>({
    required Set<T> selected,
    required List<ButtonSegment<T>> segments,
    required void Function(T) onChanged,
  }) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SegmentedButton<T>(
      showSelectedIcon: false,
      segments: segments,
      selected: selected,
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );

  List<String> _participants(Store store) {
    final names = <String>{};
    for (final c in store.chats.values) {
      names.addAll(c.participants);
    }
    return names.toList()..sort();
  }

  Widget aliasEditor(BuildContext context, String original) {
    final alias = settings.aliases[original] ?? '';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(original),
      subtitle: Text(
        alias.isEmpty ? 'Tap to set a display name' : 'Shown as: $alias',
      ),
      trailing: IconButton(
        tooltip: alias.isEmpty
            ? 'Set display name'
            : 'Edit or clear display name',
        icon: Icon(
          alias.isEmpty ? Icons.person_add_outlined : Icons.edit_outlined,
        ),
        onPressed: () async {
          final ctrl = TextEditingController(text: alias);
          final saved = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Display name for $original'),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Leave empty to use the export name',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          );
          if (saved == true && context.mounted) {
            settings.setAlias(original, ctrl.text);
          }
          ctrl.dispose();
        },
      ),
    );
  }

  Future<void> setPin(BuildContext context) async {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(settings.lockEnabled ? 'Change PIN' : 'Set a PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'PIN'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Confirm PIN'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      if (pin.text.trim().length < 4) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Use at least 4 digits.')),
          );
        }
      } else if (pin.text.trim() != confirm.text.trim()) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('PINs do not match.')));
        }
      } else {
        settings.setPin(pin.text.trim());
      }
    }
    pin.dispose();
    confirm.dispose();
  }

  Future<void> confirmResetPin(BuildContext context) async {
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
    await settings.resetPin();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Local PIN removed.')));
    }
  }

  Future<void> showErrorLog(BuildContext context) async {
    final log = settings.readLog();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Error log'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              log.isEmpty ? '(no errors logged)' : log,
              style: monoStyle(context),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              settings.clearLog();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Error log cleared.')),
              );
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final participants = _participants(store);
    final raw = <Widget>[
      // ---------------- appearance ----------------
      section(
        context,
        'Appearance',
        'theme dark light color accent text size amoled animation material m3 classic design style',
      ),
      const Text('Design style'),
      const SizedBox(height: 8),
      choice<bool>(
        selected: {settings.material3},
        segments: const [
          ButtonSegment(
            value: true,
            label: Text('Material 3'),
            icon: Icon(Icons.auto_awesome),
          ),
          ButtonSegment(
            value: false,
            label: Text('Classic'),
            icon: Icon(Icons.widgets_outlined),
          ),
        ],
        onChanged: (v) =>
            settings.update(() => settings.material3 = v, appearanceOnly: true),
      ),
      hint(
        context,
        'Material 3 uses tonal surfaces, rounded dialogs and the navigation rail. Classic keeps the older widget shapes.',
      ),
      const SizedBox(height: 8),
      const Text('Color mode'),
      const SizedBox(height: 8),
      choice<ThemeMode>(
        selected: {settings.themeMode},
        segments: const [
          ButtonSegment(
            value: ThemeMode.system,
            label: Text('System'),
            icon: Icon(Icons.brightness_auto),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            label: Text('Light'),
            icon: Icon(Icons.light_mode),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text('Dark'),
            icon: Icon(Icons.dark_mode),
          ),
        ],
        onChanged: (v) =>
            settings.update(() => settings.themeMode = v, appearanceOnly: true),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Pure black background in dark mode'),
        subtitle: const Text('Looks best on OLED screens.'),
        value: settings.amoled,
        onChanged: (v) =>
            settings.update(() => settings.amoled = v, appearanceOnly: true),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Animate theme changes'),
        subtitle: const Text(
          'Smooth color transition. Leave off if a large conversation stutters.',
        ),
        value: settings.animateTheme,
        onChanged: (v) => settings.update(
          () => settings.animateTheme = v,
          appearanceOnly: true,
        ),
      ),
      const SizedBox(height: 8),
      const Text('Accent color'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 10,
        children: [
          for (final c in accents)
            Tooltip(
              message: settings.accent == c
                  ? 'Current accent'
                  : 'Use this accent',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => settings.update(
                    () => settings.accent = c,
                    appearanceOnly: true,
                  ),
                  child: CircleAvatar(
                    backgroundColor: Color(c),
                    radius: 16,
                    child: settings.accent == c
                        ? Icon(
                            Icons.check,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            size: 18,
                          )
                        : null,
                  ),
                ),
              ),
            ),
        ],
      ),
      slider(
        label: 'Text size',
        value: settings.textScale,
        min: 0.8,
        max: 1.6,
        divisions: 8,
        show: (v) => '${(v * 100).round()}%',
        onChanged: (v) =>
            settings.update(() => settings.textScale = v, appearanceOnly: true),
      ),

      // ---------------- reading ----------------
      section(
        context,
        'Reading',
        'layout bubbles compact plain time clock replies photo gallery image',
      ),
      const Text('Open conversations at'),
      const SizedBox(height: 8),
      choice<StartAt>(
        selected: {settings.startAt},
        segments: const [
          ButtonSegment(value: StartAt.newest, label: Text('Newest message')),
          ButtonSegment(value: StartAt.oldest, label: Text('Oldest message')),
          ButtonSegment(
            value: StartAt.leftOff,
            label: Text('Where I left off'),
          ),
        ],
        onChanged: (v) => settings.update(() => settings.startAt = v),
      ),
      hint(
        context,
        'Applies when messages are sorted by date (oldest first). '
        '"Where I left off" remembers the message you were reading in each conversation.',
      ),
      const SizedBox(height: 8),
      const Text('Message layout'),
      const SizedBox(height: 8),
      choice<ChatLayout>(
        selected: {settings.layout},
        segments: const [
          ButtonSegment(
            value: ChatLayout.bubbles,
            label: Text('Bubbles'),
            icon: Icon(Icons.chat_bubble_outline),
          ),
          ButtonSegment(
            value: ChatLayout.compact,
            label: Text('Compact'),
            icon: Icon(Icons.density_small),
          ),
          ButtonSegment(
            value: ChatLayout.plain,
            label: Text('Plain log'),
            icon: Icon(Icons.notes),
          ),
        ],
        onChanged: (v) => settings.update(() => settings.layout = v),
      ),
      hint(
        context,
        'Plain log shows one line per message ("14:22  Name: text"), which is the easiest to read through a long history.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Show what a message replied to'),
        subtitle: const Text(
          'A quoted block above the reply. Click it to jump to the original message.',
        ),
        value: settings.showReplies,
        onChanged: (v) => settings.update(() => settings.showReplies = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('24-hour clock'),
        value: settings.use24h,
        onChanged: (v) => settings.update(() => settings.use24h = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Show time with each message'),
        value: settings.showTimes,
        onChanged: (v) => settings.update(() => settings.showTimes = v),
      ),
      slider(
        label: 'Photo width in chat',
        value: settings.chatImageWidth,
        min: 160,
        max: 420,
        divisions: 13,
        show: (v) => '${v.round()} px',
        onChanged: (v) => settings.update(() => settings.chatImageWidth = v),
      ),
      slider(
        label: 'Gallery tile size',
        value: settings.galleryTileSize,
        min: 90,
        max: 240,
        divisions: 15,
        show: (v) => '${v.round()} px',
        onChanged: (v) => settings.update(() => settings.galleryTileSize = v),
      ),

      // ---------------- search ----------------
      section(
        context,
        'Search results panel',
        'search results layout compact detailed newest activity rail minimap',
      ),
      const Text('Layout'),
      const SizedBox(height: 8),
      choice<ResultsLayout>(
        selected: {settings.resultsLayout},
        segments: const [
          ButtonSegment(
            value: ResultsLayout.detailed,
            label: Text('Detailed'),
            icon: Icon(Icons.view_agenda_outlined),
          ),
          ButtonSegment(
            value: ResultsLayout.compact,
            label: Text('Compact'),
            icon: Icon(Icons.view_headline),
          ),
        ],
        onChanged: (v) => settings.update(() => settings.resultsLayout = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Newest matches first'),
        value: settings.resultsNewestFirst,
        onChanged: (v) =>
            settings.update(() => settings.resultsNewestFirst = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Show activity rail in chats'),
        subtitle: const Text(
          'A small density bar for jumping between months. Can also be toggled in the chat menu.',
        ),
        value: settings.showActivityRail,
        onChanged: (v) => settings.update(() => settings.showActivityRail = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Floating date in chats'),
        subtitle: const Text(
          'A small pill at the top of the message list shows the date of the messages you are scrolling through.',
        ),
        value: settings.showDatePill,
        onChanged: (v) => settings.update(() => settings.showDatePill = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-hide chat header'),
        subtitle: const Text(
          'Scrolling down collapses the search and filter row to a slim strip. The people-filter eye stays available, and scrolling up brings it back.',
        ),
        value: settings.autoHideTopBar,
        onChanged: (v) => settings.update(() => settings.autoHideTopBar = v),
      ),

      // ---------------- performance ----------------
      section(
        context,
        'Performance',
        'cache raw memory dedupe parse speed large export',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Use parse cache'),
        subtitle: const Text(
          'Reuse normalized messages on the next launch instead of parsing the export again. Applies to files opened after this change.',
        ),
        value: settings.useParseCache,
        onChanged: (v) => settings.update(() => settings.useParseCache = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Keep original JSON in memory'),
        subtitle: const Text(
          'Needed for "Message details" and raw export. Turn off to save RAM on huge exports; large files also offer to turn it off when opened. Applies to files opened after this change.',
        ),
        value: settings.keepRaw,
        onChanged: (v) => settings.update(() => settings.keepRaw = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Skip duplicate messages'),
        subtitle: const Text(
          'Overlapping exports often repeat the same messages; keep only one copy.',
        ),
        value: settings.dedupeImports,
        onChanged: (v) => settings.update(() => settings.dedupeImports = v),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.cleaning_services_outlined),
          label: const Text('Clear parse cache'),
          onPressed: () {
            settings.clearParseCache();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Parse cache cleared.')),
            );
          },
        ),
      ),

      // ---------------- privacy ----------------
      section(context, 'Privacy', 'pin lock password reset privacy security'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Ask for a PIN on start'),
        subtitle: const Text(
          'A local gate for shared devices. It does not encrypt your files.',
        ),
        value: settings.lockEnabled,
        onChanged: (v) async {
          if (!v) {
            settings.disableLock();
            return;
          }
          if (settings.lockHash.isEmpty) {
            await setPin(context);
          } else {
            settings.update(() => settings.lockEnabled = true);
          }
        },
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.lock_outline),
          label: Text(settings.lockHash.isEmpty ? 'Set PIN' : 'Change PIN'),
          onPressed: () => setPin(context),
        ),
      ),
      if (settings.lockHash.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('Reset local PIN'),
            onPressed: () => confirmResetPin(context),
          ),
        ),

      // ---------------- names ----------------
      section(context, 'Names', 'alias display name participant sender'),
      hint(
        context,
        'Display names affect reading and search only. The original names in the exported JSON stay untouched.',
      ),
      if (participants.isEmpty)
        const Text('Open a conversation to see its participants.')
      else
        for (final n in participants) aliasEditor(context, n),

      // ---------------- session ----------------
      section(
        context,
        'Session',
        'reopen files folders reading position clear forget',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Reopen last files and media folders on start'),
        subtitle: const Text('Large exports take a moment to load again.'),
        value: settings.reopenLast,
        onChanged: (v) => settings.update(() => settings.reopenLast = v),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.delete_outline),
          label: const Text(
            'Forget saved files, folders and reading positions',
          ),
          onPressed: () {
            store.forgetSession();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Saved session forgotten. Open files stay loaded until you close the app.',
                ),
              ),
            );
          },
        ),
      ),

      // ---------------- about ----------------
      section(context, 'Files', 'config error log path about'),
      SelectableText(
        'Settings file: ${settings.filePath}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 4),
      SelectableText(
        'Error log: ${settings.logPath}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.article_outlined),
          label: const Text('View error log'),
          onPressed: () => showErrorLog(context),
        ),
      ),
    ];

    final sections = _groupSections(raw);
    final visible = sections
        .where((s) => query.isEmpty || _matches(s, query))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _searchField(Theme.of(context)),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.unfold_less, size: 18),
                    label: const Text('Collapse all'),
                    onPressed: () => setState(() {
                      _search.clear();
                      _collapsedBeforeSearch = null;
                      _collapsed.addAll(sections.map((s) => s.title));
                    }),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.unfold_more, size: 18),
                    label: const Text('Expand all'),
                    onPressed: () => setState(() {
                      _search.clear();
                      _collapsedBeforeSearch = null;
                      _collapsed.clear();
                    }),
                  ),
                ],
              ),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('No settings match that search.')),
                )
              else
                for (final s in visible) _sectionCard(s),
            ],
          ),
        ),
      ),
    );
  }
}

/// A slider that moves locally while dragging and commits once on release.
/// Without this, every drag frame notifies all settings listeners and rebuilds
/// the whole app, including an open conversation with thousands of messages.
class DeferredSlider extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) show;
  final ValueChanged<double> onCommit;

  const DeferredSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.show,
    required this.onCommit,
  });

  @override
  State<DeferredSlider> createState() => _DeferredSliderState();
}

class _DeferredSliderState extends State<DeferredSlider> {
  late double value = widget.value;
  bool _dragging = false;
  Timer? _commitTimer;

  @override
  void didUpdateWidget(covariant DeferredSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && widget.value != value) value = widget.value;
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    super.dispose();
  }

  void _commit(double v) {
    _commitTimer?.cancel();
    widget.onCommit(v);
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text('${widget.label}: ${widget.show(value)}'),
    subtitle: Slider(
      value: value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.show(value),
      onChanged: (v) {
        setState(() => value = v);
        // Keyboard changes never fire onChangeEnd, so commit those on a pause.
        if (!_dragging) {
          _commitTimer?.cancel();
          _commitTimer = Timer(
            const Duration(milliseconds: 250),
            () => _commit(v),
          );
        }
      },
      onChangeStart: (_) => _dragging = true,
      onChangeEnd: (v) {
        _dragging = false;
        _commit(v);
      },
    ),
  );
}
