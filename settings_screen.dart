// The settings screen.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'settings.dart';
import 'store.dart';

class SettingsScreen extends StatelessWidget {
  final AppSettings settings;
  final Store store;
  const SettingsScreen({super.key, required this.settings, required this.store});

  static const accents = [0xFF0B7CFF, 0xFF2E7D32, 0xFF8E24AA, 0xFFE65100, 0xFFC62828, 0xFF00838F];

  Widget section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

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
  }) =>
      DeferredSlider(
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
  }) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          segments: segments,
          selected: selected,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ---------------- appearance ----------------
                section(context, 'Appearance'),
                choice<ThemeMode>(
                  selected: {settings.themeMode},
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                  ],
                  onChanged: (v) => settings.update(() => settings.themeMode = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pure black background in dark mode'),
                  subtitle: const Text('Looks best on OLED screens.'),
                  value: settings.amoled,
                  onChanged: (v) => settings.update(() => settings.amoled = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Animate theme changes'),
                  subtitle: const Text('Smooth color transition. Leave off if a large conversation stutters.'),
                  value: settings.animateTheme,
                  onChanged: (v) => settings.update(() => settings.animateTheme = v),
                ),
                const SizedBox(height: 8),
                const Text('Accent color'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final c in accents)
                      GestureDetector(
                        onTap: () => settings.update(() => settings.accent = c),
                        child: CircleAvatar(
                          backgroundColor: Color(c),
                          radius: 16,
                          child: settings.accent == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
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
                  onChanged: (v) => settings.update(() => settings.textScale = v),
                ),

                // ---------------- reading ----------------
                section(context, 'Reading'),
                const Text('Open conversations at'),
                const SizedBox(height: 8),
                choice<StartAt>(
                  selected: {settings.startAt},
                  segments: const [
                    ButtonSegment(value: StartAt.newest, label: Text('Newest message')),
                    ButtonSegment(value: StartAt.oldest, label: Text('Oldest message')),
                    ButtonSegment(value: StartAt.leftOff, label: Text('Where I left off')),
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
                    ButtonSegment(value: ChatLayout.bubbles, label: Text('Bubbles'), icon: Icon(Icons.chat_bubble_outline)),
                    ButtonSegment(value: ChatLayout.compact, label: Text('Compact'), icon: Icon(Icons.density_small)),
                    ButtonSegment(value: ChatLayout.plain, label: Text('Plain log'), icon: Icon(Icons.notes)),
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
                  subtitle: const Text('A quoted block above the reply. Click it to jump to the original message.'),
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
                section(context, 'Search results panel'),
                const Text('Layout'),
                const SizedBox(height: 8),
                choice<ResultsLayout>(
                  selected: {settings.resultsLayout},
                  segments: const [
                    ButtonSegment(value: ResultsLayout.detailed, label: Text('Detailed'), icon: Icon(Icons.view_agenda_outlined)),
                    ButtonSegment(value: ResultsLayout.compact, label: Text('Compact'), icon: Icon(Icons.view_headline)),
                  ],
                  onChanged: (v) => settings.update(() => settings.resultsLayout = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Newest matches first'),
                  value: settings.resultsNewestFirst,
                  onChanged: (v) => settings.update(() => settings.resultsNewestFirst = v),
                ),

                // ---------------- session ----------------
                section(context, 'Session'),
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
                    label: const Text('Forget saved files, folders and reading positions'),
                    onPressed: () {
                      store.forgetSession();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Saved session forgotten. Open files stay loaded until you close the app.')),
                      );
                    },
                  ),
                ),

                // ---------------- about ----------------
                section(context, 'Files'),
                SelectableText('Settings file: ${settings.filePath}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                SelectableText('Error log: ${settings.logPath}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
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
              _commitTimer = Timer(const Duration(milliseconds: 250), () => _commit(v));
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
