// One open conversation: search, filters, sorting, results panel, gallery.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'models.dart';
import 'settings.dart';
import 'store.dart';
import 'util.dart';
import 'widgets.dart';

class ChatView extends StatefulWidget {
  final Store store;
  final Chat chat;
  const ChatView({super.key, required this.store, required this.chat});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final qc = TextEditingController();
  final searchFocus = FocusNode();

  // A fresh controller is made every time the list is rebuilt from scratch: a scroll
  // controller can only belong to one list at a time.
  ItemScrollController scroll = ItemScrollController();
  ItemPositionsListener positions = ItemPositionsListener.create();

  String? sender;
  bool mediaOnly = false;
  bool gallery = false;
  SortMode sort = SortMode.oldest;

  /// Results panel mode (optional). Off: typing in the search box filters the chat in place.
  /// On: the chat stays complete, matches are listed in a panel, and clicking one jumps to it.
  bool panelMode = false;
  bool resultsOpen = false; // narrow screens only: the panel replaces the chat while true

  List<Msg> view = []; // what the chat list shows, top to bottom
  List<int> results = []; // indices into [view] that match the search (panel mode only)
  List<Pic>? _pics;
  int _picsFor = -1;
  int _msgCount = -1;
  int _listGen = 0;
  String _viewSig = '';
  int? _restoreT; // saved reading position (message time), used once when the chat opens
  int? _restoreIndex; // the same position as an index into [view]
  int? highlight; // index into [view] of the message we just jumped to
  Timer? _hlTimer;
  Timer? _searchTimer;
  bool _wide = false;

  AppSettings get settings => widget.store.settings;
  String get query => qc.text.trim();

  /// Messages are in date order (either direction), so day separators make sense.
  bool get dateSort => sort == SortMode.oldest || sort == SortMode.newest;

  StartAt get _start {
    final s = settings.startAt;
    if (s == StartAt.leftOff && _restoreIndex == null) return StartAt.newest; // nothing saved yet
    return s;
  }

  /// Newest-at-the-bottom is done with a reversed list (index 0 = bottom).
  bool get _reversed => sort == SortMode.oldest && _start == StartAt.newest;

  @override
  void initState() {
    super.initState();
    _restoreT = settings.chatPos[widget.chat.key];
    recompute();
    _msgCount = widget.chat.messages.length;
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_msgCount != widget.chat.messages.length) {
      _msgCount = widget.chat.messages.length;
      recompute(); // more JSON files were added to this chat
    }
  }

  @override
  void dispose() {
    positions.itemPositions.removeListener(_onPositions);
    _hlTimer?.cancel();
    _searchTimer?.cancel();
    qc.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  // ---------- what is shown ----------

  bool _hit(Msg m, String q) =>
      m.lower.contains(q) ||
      m.sender.toLowerCase().contains(q) ||
      (m.share.isNotEmpty && m.share.toLowerCase().contains(q)) ||
      m.media.any((x) => x.name.toLowerCase().contains(q));

  void recompute() {
    final q = query.toLowerCase();
    final inPlace = !panelMode && q.isNotEmpty;
    final sig = '$sender|$mediaOnly|${sort.index}|${inPlace ? q : ''}|${widget.chat.messages.length}';
    if (sig != _viewSig) {
      // The list itself changed: rebuild it from scratch at its start position.
      _viewSig = sig;
      final list = widget.chat.messages.where((m) {
        if (sender != null && m.sender != sender) return false;
        if (mediaOnly && m.media.isEmpty) return false;
        if (inPlace && !_hit(m, q)) return false;
        return true;
      }).toList();
      view = _sorted(list);
      // A saved position is only used for "Where I left off"; "Oldest" and
      // "Newest" must always open at the corresponding end of the conversation.
      _restoreIndex = settings.startAt == StartAt.leftOff ? _findRestore() : null;
      _restoreT = null;
      _newList();
    }
    results = [];
    if (panelMode && q.isNotEmpty) {
      for (var i = 0; i < view.length; i++) {
        if (_hit(view[i], q)) results.add(i);
      }
    }
    _pics = null;
    highlight = null;
  }

  List<Msg> _sorted(List<Msg> l) {
    int byTime(Msg a, Msg b) => (a.t ?? 0).compareTo(b.t ?? 0);
    switch (sort) {
      case SortMode.oldest:
        return l; // messages are already stored oldest first
      case SortMode.newest:
        return l.reversed.toList();
      case SortMode.sender:
        final lc = <String, String>{};
        String low(String s) => lc.putIfAbsent(s, () => s.toLowerCase());
        l.sort((a, b) {
          final c = low(a.sender).compareTo(low(b.sender));
          return c != 0 ? c : byTime(a, b);
        });
        return l;
      case SortMode.longest:
        l.sort((a, b) {
          final c = b.text.length.compareTo(a.text.length);
          return c != 0 ? c : byTime(a, b);
        });
        return l;
      case SortMode.reactions:
        l.sort((a, b) {
          final c = b.reactions.length.compareTo(a.reactions.length);
          return c != 0 ? c : byTime(a, b);
        });
        return l;
      case SortMode.media:
        l.sort((a, b) {
          final c = b.media.length.compareTo(a.media.length);
          return c != 0 ? c : byTime(a, b);
        });
        return l;
    }
  }

  /// The saved reading position as an index into [view] (first message at or after that time).
  int? _findRestore() {
    final t = _restoreT;
    if (t == null || sort != SortMode.oldest || view.isEmpty) return null;
    var lo = 0, hi = view.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if ((view[mid].t ?? 0) < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo.clamp(0, view.length - 1).toInt();
  }

  void _newList() {
    positions.itemPositions.removeListener(_onPositions);
    scroll = ItemScrollController();
    positions = ItemPositionsListener.create();
    positions.itemPositions.addListener(_onPositions);
    _listGen++;
  }

  /// Remember the message at the top of the screen, for "where I left off".
  void _onPositions() {
    if (view.isEmpty || sort != SortMode.oldest) return;
    int? top;
    for (final p in positions.itemPositions.value) {
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) continue; // not on screen
      final idx = _reversed ? view.length - 1 - p.index : p.index;
      if (top == null || idx < top) top = idx;
    }
    if (top == null || top >= view.length) return;
    final t = view[top].t;
    if (t == null) return;
    settings.chatPos[widget.chat.key] = t;
    settings.save();
  }

  // ---------- photos ----------

  List<Pic> getPics() {
    final s = widget.store;
    if (_pics != null && _picsFor == s.mediaVersion) return _pics!;
    final out = <Pic>[];
    final Iterable<Msg> src = (panelMode && query.isNotEmpty) ? results.map((i) => view[i]) : view;
    for (final m in src) {
      for (final x in m.media) {
        final p = s.findMedia(x.uri, widget.chat);
        if (p == null || !isImagePath(p)) continue;
        final cap = '${m.sender} · ${fmtDate(m.t)} ${fmtTime(m.t)}'
            '${m.text.isNotEmpty ? '\n${m.text}' : ''}\n${p.split(pathSep).last}';
        out.add(Pic(p, cap));
      }
    }
    _pics = out;
    _picsFor = s.mediaVersion;
    return out;
  }

  void openPager(List<Pic> pics, int start) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PicPager(pics: pics, start: start)));
  }

  void openPicByPath(String path) {
    final pics = getPics();
    final i = pics.indexWhere((p) => p.path == path);
    if (i >= 0) openPager(pics, i);
  }

  // ---------- jumping around ----------

  /// Scroll the conversation to message [idx] (an index into [view]) and flash it.
  void jumpToMessage(int idx) {
    setState(() {
      gallery = false;
      if (!_wide) resultsOpen = false;
      highlight = idx;
    });
    _hlTimer?.cancel();
    _hlTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => highlight = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.isAttached || view.isEmpty) return;
      scroll.jumpTo(index: _reversed ? view.length - 1 - idx : idx, alignment: 0.35);
    });
  }

  /// Tap on a quoted reply: go to the original message.
  void openReply(Msg target) {
    final idx = view.indexOf(target);
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The original message is hidden by the current search or filters.')),
      );
      return;
    }
    jumpToMessage(idx);
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final senders = widget.chat.participants.toList()..sort();

    return LayoutBuilder(builder: (context, box) {
      _wide = box.maxWidth >= 900;
      final panelVisible = panelMode && query.isNotEmpty;
      final panelSide = panelVisible && _wide;
      final panelFull = panelVisible && !_wide && resultsOpen;
      final Widget body = gallery ? galleryView() : (panelFull ? resultsPanel() : listView());

      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => searchFocus.requestFocus(),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: qc,
                        focusNode: searchFocus,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search messages',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) {
                          // wait for a short pause in typing: searching 80,000+ messages on every key is wasteful
                          _searchTimer?.cancel();
                          _searchTimer = Timer(const Duration(milliseconds: 250), () {
                            if (!mounted) return;
                            setState(() {
                              recompute();
                              if (panelMode) resultsOpen = true;
                            });
                          });
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: panelMode
                          ? 'Results panel is ON (click to filter the chat in place instead)'
                          : 'Results panel is OFF (click to list matches in a panel and jump to them)',
                      isSelected: panelMode,
                      icon: const Icon(Icons.manage_search_outlined),
                      selectedIcon: const Icon(Icons.manage_search),
                      onPressed: () => setState(() {
                        panelMode = !panelMode;
                        recompute();
                        resultsOpen = panelMode;
                      }),
                    ),
                    PopupMenuButton<SortMode>(
                      tooltip: 'Sort messages (now: ${sort.label})',
                      initialValue: sort,
                      icon: Icon(Icons.sort, color: sort == SortMode.oldest ? null : Theme.of(context).colorScheme.primary),
                      onSelected: (v) => setState(() {
                        sort = v;
                        recompute();
                      }),
                      itemBuilder: (_) => [
                        for (final v in SortMode.values)
                          CheckedPopupMenuItem<SortMode>(value: v, checked: v == sort, child: Text(v.label)),
                      ],
                    ),
                    IconButton(
                      tooltip: gallery ? 'Chat view' : 'Gallery',
                      icon: Icon(gallery ? Icons.chat : Icons.photo_library),
                      onPressed: () => setState(() => gallery = !gallery),
                    ),
                    IconButton(
                      tooltip: 'Media info and folders',
                      icon: const Icon(Icons.perm_media),
                      onPressed: () => showMediaInfo(context, s, widget.chat),
                    ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    DropdownButton<String?>(
                      value: sender,
                      hint: const Text('Everyone'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('Everyone')),
                        for (final n in senders) DropdownMenuItem<String?>(value: n, child: Text(n)),
                      ],
                      onChanged: (v) => setState(() {
                        sender = v;
                        recompute();
                      }),
                    ),
                    const SizedBox(width: 12),
                    const Text('I am '),
                    DropdownButton<String>(
                      value: senders.contains(s.me) ? s.me : '',
                      items: [
                        const DropdownMenuItem<String>(value: '', child: Text('(not set)')),
                        for (final n in senders) DropdownMenuItem<String>(value: n, child: Text(n)),
                      ],
                      onChanged: (v) => s.setMe(v ?? ''),
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('Media only'),
                      selected: mediaOnly,
                      onSelected: (v) => setState(() {
                        mediaOnly = v;
                        recompute();
                      }),
                    ),
                    const SizedBox(width: 12),
                    if (sort != SortMode.oldest) ...[
                      InputChip(
                        avatar: const Icon(Icons.sort, size: 16),
                        label: Text(sort.label),
                        onDeleted: () => setState(() {
                          sort = SortMode.oldest;
                          recompute();
                        }),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (panelVisible && !_wide && !resultsOpen)
                      ActionChip(
                        avatar: const Icon(Icons.list, size: 18),
                        label: Text('Show ${results.length} results'),
                        onPressed: () => setState(() => resultsOpen = true),
                      )
                    else
                      Text(
                        panelVisible ? '${results.length} matches in ${view.length}' : '${view.length} shown',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                // The same Row is always used, so the message list is never torn down just
                // because the results panel appears next to it.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: body),
                    if (panelSide) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(width: 360, child: resultsPanel()),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  // ---------- search results panel ----------

  Widget resultsPanel() {
    final q = query;
    final compact = settings.resultsLayout == ResultsLayout.compact;
    final newestFirst = settings.resultsNewestFirst;
    final order = [...results];
    // `results` follows the order of the chat; flip it so it matches "newest first / oldest first"
    if (dateSort && ((sort == SortMode.oldest) == newestFirst)) {
      order.setRange(0, order.length, order.reversed.toList());
    }
    final muted = Theme.of(context).colorScheme.outline;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${results.length} result${results.length == 1 ? '' : 's'} for "$q"',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dateSort)
                IconButton(
                  tooltip: newestFirst ? 'Newest matches first (click to flip)' : 'Oldest matches first (click to flip)',
                  icon: Icon(newestFirst ? Icons.arrow_downward : Icons.arrow_upward),
                  onPressed: () => settings.update(() => settings.resultsNewestFirst = !newestFirst),
                ),
              IconButton(
                tooltip: compact ? 'Showing one line per result (click for detailed)' : 'Showing detailed results (click for compact)',
                icon: Icon(compact ? Icons.view_headline : Icons.view_agenda_outlined),
                onPressed: () => settings.update(
                  () => settings.resultsLayout = compact ? ResultsLayout.detailed : ResultsLayout.compact,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: order.isEmpty
              ? const Center(child: Text('No matches'))
              : ListView.builder(
                  itemCount: order.length,
                  itemBuilder: (context, i) {
                    final idx = order[i];
                    final m = view[idx];
                    final when = '${fmtDate(m.t)} ${fmtTime(m.t)}';
                    if (compact) {
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        selected: highlight == idx,
                        title: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '$when  ${m.sender}: ', style: TextStyle(color: muted, fontSize: 12)),
                            ...highlightSpans(snippet(m.text, q).replaceAll('\n', ' '), q, null, Colors.amber),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => jumpToMessage(idx),
                      );
                    }
                    return ListTile(
                      dense: true,
                      selected: highlight == idx,
                      title: Text.rich(
                        TextSpan(children: highlightSpans(snippet(m.text, q), q, null, Colors.amber)),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${m.sender} · $when'),
                      onTap: () => jumpToMessage(idx),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------- messages ----------

  Widget listView() {
    if (view.isEmpty) return const Center(child: Text('No messages match.'));
    final rev = _reversed;
    final n = view.length;
    final initial = rev ? 0 : (_restoreIndex ?? 0);
    return ScrollablePositionedList.builder(
      key: ValueKey('$_listGen-$rev'),
      itemScrollController: scroll,
      itemPositionsListener: positions,
      reverse: rev,
      initialScrollIndex: initial,
      padding: const EdgeInsets.all(8),
      itemCount: n,
      itemBuilder: (context, i) {
        final idx = rev ? n - 1 - i : i;
        final m = view[idx];
        final prev = idx > 0 ? view[idx - 1] : null;
        final newDay = dateSort && (prev == null || !sameDay(prev.t, m.t));
        final showName = !dateSort || prev == null || prev.sender != m.sender || newDay;
        final mine = widget.store.me.isNotEmpty && m.sender == widget.store.me;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(child: Text(fmtDate(m.t), style: Theme.of(context).textTheme.bodySmall)),
              ),
            Bubble(
              m: m,
              mine: mine,
              showName: showName,
              showDate: !dateSort,
              store: widget.store,
              chat: widget.chat,
              query: query,
              highlighted: highlight == idx,
              onPic: openPicByPath,
              onOpenReply: openReply,
            ),
          ],
        );
      },
    );
  }

  Widget galleryView() {
    final pics = getPics();
    if (pics.isEmpty) {
      return Center(
        child: Text(widget.store.hasMedia(widget.chat)
            ? 'No photos match the current filters.'
            : 'Open a media folder first (media info button above).'),
      );
    }
    final tile = settings.galleryTileSize;
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: tile,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: pics.length,
      itemBuilder: (context, i) => GestureDetector(
        onTap: () => openPager(pics, i),
        child: Image.file(
          File(pics[i].path),
          fit: BoxFit.cover,
          cacheWidth: (tile * 2).round(), // decode small: light on memory
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        ),
      ),
    );
  }
}
