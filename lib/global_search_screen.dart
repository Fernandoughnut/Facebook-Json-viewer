// Search across every loaded conversation and jump straight to a match.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'store.dart';
import 'util.dart';

class GlobalSearchScreen extends StatefulWidget {
  final Store store;
  const GlobalSearchScreen({super.key, required this.store});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final qc = TextEditingController();
  Timer? _timer;
  String query = '';
  String? sender;
  bool mediaOnly = false;
  List<GlobalHit> hits = [];
  bool truncated = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    _search();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _timer?.cancel();
    qc.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(_search);
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        query = qc.text.trim();
        _search();
      });
    });
  }

  void _search() {
    if (query.isEmpty) {
      hits = const <GlobalHit>[];
      truncated = false;
      return;
    }
    final result = widget.store.searchAll(
      query,
      sender: sender,
      mediaOnly: mediaOnly,
    );
    hits = result.hits;
    truncated = result.truncated;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void onChanged(String _) => _changed();
    final senders = <String>{};
    for (final c in widget.store.chats.values) {
      senders.addAll(c.participants);
    }
    final names = senders.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Search all conversations')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: theme.useMaterial3
                ? SearchBar(
                    controller: qc,
                    autoFocus: true,
                    hintText: 'Search every conversation',
                    leading: const Icon(Icons.search),
                    onChanged: onChanged,
                  )
                : TextField(
                    controller: qc,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search every conversation',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: onChanged,
                  ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                if (theme.useMaterial3)
                  DropdownMenu<String?>(
                    initialSelection: sender,
                    hintText: 'Everyone',
                    dropdownMenuEntries: [
                      const DropdownMenuEntry<String?>(
                        value: null,
                        label: 'Everyone',
                      ),
                      for (final n in names)
                        DropdownMenuEntry<String?>(
                          value: n,
                          label: displayName(n),
                        ),
                    ],
                    onSelected: (v) => setState(() {
                      sender = v;
                      _search();
                    }),
                  )
                else
                  DropdownButton<String?>(
                    value: sender,
                    hint: const Text('Everyone'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Everyone'),
                      ),
                      for (final n in names)
                        DropdownMenuItem<String?>(
                          value: n,
                          child: Text(displayName(n)),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      sender = v;
                      _search();
                    }),
                  ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Media only'),
                  selected: mediaOnly,
                  onSelected: (v) => setState(() {
                    mediaOnly = v;
                    _search();
                  }),
                ),
                const SizedBox(width: 12),
                Text(
                  query.isEmpty
                      ? 'Type to search all conversations'
                      : truncated
                      ? '${formatCount(hits.length)}+ matches'
                      : '${formatCount(hits.length)} match${hits.length == 1 ? '' : 'es'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: hits.isEmpty
                ? Center(
                    child: Text(
                      query.isEmpty
                          ? 'Type to search all conversations.'
                          : 'No matches.',
                    ),
                  )
                : ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (context, i) {
                      final h = hits[i];
                      final m = h.msg;
                      return ListTile(
                        dense: true,
                        title: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${displayName(m.sender)}: ',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ...highlightSpans(
                                snippet(m.text, query).replaceAll('\n', ' '),
                                query,
                                null,
                                kHighlightColor,
                              ),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${h.chat.title} · ${fmtDate(m.t)} ${fmtTime(m.t)}'
                          '${m.media.isNotEmpty ? ' · ${m.media.length} media' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.of(context).pop(h),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
