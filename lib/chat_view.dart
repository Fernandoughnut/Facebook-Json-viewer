// One open conversation: search, filters, sorting, results panel, gallery.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'exporter.dart';
import 'media_pack.dart';
import 'models.dart';
import 'settings.dart';
import 'store.dart';
import 'util.dart';
import 'widgets.dart';

enum _ExportScope { whole, view, selected }

class _ExportRequest {
  final _ExportScope scope;
  final ExportFormat format;
  final ExportOptions options;
  const _ExportRequest(this.scope, this.format, this.options);
}

String _exportScopeLabel(_ExportScope scope) => switch (scope) {
  _ExportScope.whole => 'Whole conversation',
  _ExportScope.view => 'Current view / search results',
  _ExportScope.selected => 'Selected messages',
};

String _exportFormatLabel(ExportFormat format) => switch (format) {
  ExportFormat.json => 'JSON',
  ExportFormat.csv => 'CSV',
  ExportFormat.text => 'Text',
};

enum _ChatMenuAction {
  focusSearch,
  panel,
  regex,
  caseSensitive,
  mediaOnly,
  clearFilters,
  peopleFilters,
  savedSearches,
  gallery,
  mediaInfo,
  miniMap,
  indexBar,
  immersive,
  jumpToDate,
  select,
  export,
  packMedia,
}

class ActivityBucket {
  final int t;
  final int count;
  final String label; // YYYY-MM
  const ActivityBucket(this.t, this.count, this.label);
}

class _BucketBuilder {
  final int t;
  final String label;
  int count = 0;
  _BucketBuilder(this.t, this.label);
}

/// Flutter adds a pixel-based scrollbar to every scrollable on Linux. That is
/// dangerous for a conversation with tens of thousands of variable-height
/// bubbles: dragging the thumb makes the sliver lay out every earlier message
/// just to find the offset, which can freeze or abort the process. The chat
/// uses [_IndexScrollbar] and the activity rail, both of which jump by index.
class _NoDesktopScrollbar extends ScrollBehavior {
  const _NoDesktopScrollbar();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// A scrollbar that maps dragging to message *indices*, not pixel offsets.
/// The chat list has variable-height bubbles, so a pixel scrollbar would make
/// the sliver lay out every earlier message to find the offset. This one jumps
/// straight to an index and lets the list rebuild around that item only.
class _IndexScrollbar extends StatefulWidget {
  const _IndexScrollbar({
    required this.itemCount,
    required this.topIndex,
    required this.visibleCount,
    required this.onJump,
    this.immersive = false,
  });

  final int itemCount;
  final ValueListenable<int> topIndex;
  final ValueListenable<int> visibleCount;
  final ValueChanged<int> onJump;
  final bool immersive;

  @override
  State<_IndexScrollbar> createState() => _IndexScrollbarState();
}

class _IndexScrollbarState extends State<_IndexScrollbar> {
  /// Rebuilding the 80k-item list on every pointer event is what makes a drag
  /// feel frozen. The thumb follows the pointer locally; actual jumps are
  /// throttled and a final jump is issued when the drag ends.
  static const _jumpInterval = Duration(milliseconds: 180);

  /// Fixed track used only to convert a pointer's global Y into an index. The
  /// gesture target itself is just the pill, so touching the empty track never
  /// jumps or consumes a navigation gesture.
  final GlobalKey _trackKey = GlobalKey();

  int? _preview;
  int? _pending;
  int? _lastJumped;
  DateTime? _lastJump;
  Timer? _timer;
  Timer? _settleTimer;
  bool _clearScheduled = false;

  @override
  void dispose() {
    _timer?.cancel();
    _settleTimer?.cancel();
    super.dispose();
  }

  /// The thumb stays under the finger until the list reports that it caught
  /// up. Clearing it on release makes it visibly snap back before the jump.
  void _schedulePreviewClear(int idx) {
    if (_clearScheduled) return;
    _clearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clearScheduled = false;
      if (mounted && _preview == idx) setState(() => _preview = null);
    });
  }

  void _settlePreview(int idx) {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _preview == idx) setState(() => _preview = null);
    });
  }

  int _indexFor(double dy, double height, double thumbHeight) {
    if (height <= 0 || widget.itemCount <= 0) return 0;
    final travel = math.max(1.0, height - thumbHeight);
    final fraction = ((dy - thumbHeight / 2) / travel).clamp(0.0, 1.0);
    return (fraction * (widget.itemCount - 1)).round().clamp(
      0,
      widget.itemCount - 1,
    );
  }

  /// Convert a pointer position to a Y inside the fixed track. The pill moves
  /// while dragging, so using its own local coordinates would drift.
  double? _trackDy(Offset global) {
    final context = _trackKey.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.globalToLocal(global).dy;
  }

  void _drag(double dy, double height, double thumbHeight) {
    final idx = _indexFor(dy, height, thumbHeight);
    if (_preview == idx) return;
    _settleTimer?.cancel();
    setState(() => _preview = idx);

    final now = DateTime.now();
    final last = _lastJump;
    if (last == null || now.difference(last) >= _jumpInterval) {
      _lastJump = now;
      _lastJumped = idx;
      widget.onJump(idx);
      return;
    }
    _pending = idx;
    _timer ??= Timer(_jumpInterval - now.difference(last), () {
      _timer = null;
      final target = _pending;
      _pending = null;
      if (target == null || !mounted) return;
      _lastJump = DateTime.now();
      _lastJumped = target;
      widget.onJump(target);
    });
  }

  void _endDrag() {
    _timer?.cancel();
    _timer = null;
    final idx = _preview;
    _pending = null;
    if (idx != null) {
      if (idx != _lastJumped) {
        _lastJump = DateTime.now();
        _lastJumped = idx;
        widget.onJump(idx);
      }
      _settlePreview(idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: widget.topIndex,
      builder: (context, top, _) => ValueListenableBuilder<int>(
        valueListenable: widget.visibleCount,
        builder: (context, visible, _) {
          return LayoutBuilder(
            builder: (context, box) {
              final height = box.maxHeight;
              // A long pill is easier to catch than a hairline thumb. Keep it
              // proportional for short chats, but never shrink it to a speck on
              // huge variable-height conversations.
              final minThumb = widget.immersive ? 64.0 : 48.0;
              final proportional =
                  height * visible / math.max(1, widget.itemCount);
              final thumbHeight = math.min(
                height * 0.6,
                math.max(minThumb, proportional),
              );
              final maxTop = math.max(0, widget.itemCount - visible);
              if (_preview != null &&
                  (top - _preview!).abs() <=
                      math.max(2, (visible * 0.5).round())) {
                _schedulePreviewClear(_preview!);
              }
              final position = _preview ?? top;
              final progress = maxTop == 0
                  ? 0.0
                  : (position / maxTop).clamp(0.0, 1.0);
              final thumbTop = progress * math.max(0.0, height - thumbHeight);
              // Keep the hit box the same narrow width as the visible pill.
              // The empty track and the parent's edge inset pass straight
              // through to Android gesture navigation.
              final pill = widget.immersive ? 7.0 : 6.0;
              return SizedBox(
                key: _trackKey,
                width: 18,
                child: Stack(
                  children: [
                    Positioned(
                      top: thumbTop,
                      height: thumbHeight,
                      left: (18.0 - pill) / 2,
                      width: pill,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) {
                          final dy = _trackDy(d.globalPosition);
                          if (dy == null) return;
                          _drag(dy, height, thumbHeight);
                          _endDrag();
                        },
                        onVerticalDragStart: (d) {
                          final dy = _trackDy(d.globalPosition);
                          if (dy != null) _drag(dy, height, thumbHeight);
                        },
                        onVerticalDragUpdate: (d) {
                          final dy = _trackDy(d.globalPosition);
                          if (dy != null) _drag(dy, height, thumbHeight);
                        },
                        onVerticalDragEnd: (_) => _endDrag(),
                        onVerticalDragCancel: _endDrag,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: pill,
                          height: thumbHeight,
                          decoration: BoxDecoration(
                            color: cs.onSurface.withValues(
                              alpha: widget.immersive ? 0.48 : 0.32,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ChatView extends StatefulWidget {
  final Store store;
  final Chat chat;

  /// When opened from global search, scroll to this message once after layout.
  final Msg? initialTarget;
  const ChatView({
    super.key,
    required this.store,
    required this.chat,
    this.initialTarget,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final qc = TextEditingController();
  final searchFocus = FocusNode();
  final MenuController _menuController = MenuController();
  final ScrollController _resultsController = ScrollController();

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
  bool resultsOpen =
      false; // narrow screens only: the panel replaces the chat while true
  bool selecting = false; // multi-select mode: tapping a message toggles it
  final Set<Msg> selection = {};
  bool useRegex = false;
  bool caseSensitive = false;

  List<Msg> view = []; // what the chat list shows, top to bottom
  List<int> results =
      []; // indices into [view] that match the search (panel mode only)
  List<Pic>? _pics;
  int _picsFor = -1;
  int _msgCount = -1;
  int _listGen = 0;
  String _viewSig = '';
  int? _lastSavedPosT; // avoid repeated settings writes while scrolling
  int? _restoreIndex; // the same position as an index into [view]
  int? highlight; // index into [view] of the message we just jumped to
  int?
  _pendingJump; // target from global search, applied after the list is laid out
  bool _jumpScheduled = false;
  int? _queuedJump; // coalesced index jump (rail / search results)
  bool _queuedJumpScheduled = false;
  Timer? _hlTimer;
  Timer? _searchTimer;
  RegExp? _compiledRegex;
  bool _wide = false;
  late int _settingsRevision;
  late String _aliasSignature;
  List<ActivityBucket> _activity = const [];
  String _activitySig = '';
  Map<String, int> _monthIndex = const {};
  String _monthSig = '';
  final ValueNotifier<int> _railBucket = ValueNotifier(-1);
  int? _railScrubIdx;
  bool _railDragging = false;
  final ValueNotifier<int> _scrollTop = ValueNotifier(0);
  final ValueNotifier<int> _visibleCount = ValueNotifier(10);

  /// Date of the message in the middle of the viewport, for the floating pill.
  final ValueNotifier<int?> _centerTime = ValueNotifier(null);

  /// Whether the search/filter header is collapsed into its slim strip.
  final ValueNotifier<bool> _topBarHidden = ValueNotifier(false);

  /// Immersive mode keeps the overlay position bar hidden until a sustained
  /// fast scroll, and detaches the search controls from the layout entirely.
  final ValueNotifier<bool> _immersiveBarVisible = ValueNotifier(false);
  final ValueNotifier<bool> _immersiveControlsVisible = ValueNotifier(true);
  bool _immersiveSearchExpanded = false;
  Timer? _immersiveBarTimer;
  Timer? _immersiveControlsTimer;
  bool _immersiveMenuOpen = false;
  final FastScrollTracker _fastScroll = FastScrollTracker();

  double? _lastScrollPixels;
  int _ignoreScrollUntil = 0;

  AppSettings get settings => widget.store.settings;
  String get query => qc.text.trim();
  String get _findHint =>
      Theme.of(context).platform == TargetPlatform.macOS ? '⌘F' : 'Ctrl+F';

  bool get hasActiveFilters =>
      query.isNotEmpty ||
      sender != null ||
      mediaOnly ||
      useRegex ||
      caseSensitive ||
      sort != SortMode.oldest ||
      selecting;

  /// Messages are in date order (either direction), so day separators make sense.
  bool get dateSort => sort == SortMode.oldest || sort == SortMode.newest;

  StartAt get _start {
    final s = settings.startAt;
    if (s == StartAt.leftOff && _restoreIndex == null) {
      return StartAt.newest; // nothing saved yet
    }
    return s;
  }

  /// Newest-at-the-bottom is done with a reversed list (index 0 = bottom).
  bool get _reversed => sort == SortMode.oldest && _start == StartAt.newest;

  @override
  void initState() {
    super.initState();
    _settingsRevision = settings.revision;
    _aliasSignature = _aliasesForMatching();
    _lastSavedPosT = settings.chatPos[widget.chat.key];
    recompute();
    _msgCount = widget.chat.messages.length;
    if (widget.initialTarget != null) _pendingJump = _findTargetIndex();
  }

  int _findTargetIndex() {
    final t = widget.initialTarget;
    if (t == null) return -1;
    var i = view.indexOf(t);
    if (i >= 0) return i;
    if (t.id.isNotEmpty) {
      i = view.indexWhere((m) => m.id == t.id);
      if (i >= 0) return i;
    }
    return view.indexWhere(
      (m) => m.t == t.t && m.sender == t.sender && m.text == t.text,
    );
  }

  String _aliasesForMatching() {
    final entries = settings.aliases.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key}\u0000${e.value}').join('\u0001');
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_msgCount != widget.chat.messages.length) {
      _msgCount = widget.chat.messages.length;
      recompute(); // more JSON files were added to this chat
    }
    if (_settingsRevision != settings.revision) {
      _settingsRevision = settings.revision;
      // Only aliases can change which messages match. Other setting changes
      // (theme, sliders, rail visibility) must not re-sort a 20k-message view.
      final aliases = _aliasesForMatching();
      if (aliases != _aliasSignature) {
        _aliasSignature = aliases;
        if (query.isNotEmpty) recompute();
      }
      _pics = null; // captions use display names, even without a query
    }
    if (oldWidget.initialTarget != widget.initialTarget) {
      // Two hits can share a timestamp, so the widget is reused and only its
      // target changes. Schedule the new jump explicitly.
      _pendingJump = _findTargetIndex();
      _jumpScheduled = false;
    }
  }

  @override
  void dispose() {
    positions.itemPositions.removeListener(_onPositions);
    _hlTimer?.cancel();
    _searchTimer?.cancel();
    _immersiveBarTimer?.cancel();
    _immersiveControlsTimer?.cancel();
    _immersiveBarVisible.dispose();
    _immersiveControlsVisible.dispose();
    qc.dispose();
    searchFocus.dispose();
    _resultsController.dispose();
    _railBucket.dispose();
    _scrollTop.dispose();
    _visibleCount.dispose();
    _centerTime.dispose();
    _topBarHidden.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    // Searching 80,000+ messages on every key is wasteful.
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        recompute();
        if (panelMode) resultsOpen = true;
      });
    });
  }

  Widget _searchToolbar(
    Widget panelToggle,
    Widget overflowMenu, {
    List<Widget> extraTrailing = const [],
  }) {
    if (!Theme.of(context).useMaterial3) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: qc,
              focusNode: searchFocus,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search messages',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          const SizedBox(width: 4),
          panelToggle,
          overflowMenu,
          ...extraTrailing,
        ],
      );
    }
    return SearchBar(
      controller: qc,
      focusNode: searchFocus,
      hintText: 'Search messages',
      leading: const Icon(Icons.search),
      trailing: [panelToggle, overflowMenu, ...extraTrailing],
      onChanged: _onSearchChanged,
    );
  }

  // ---------- what is shown ----------

  bool _hit(Msg m, String q) {
    if (useRegex) {
      final re = _compiledRegex;
      if (re == null) return false; // invalid or empty regex matches nothing
      return re.hasMatch(m.text) ||
          re.hasMatch(m.sender) ||
          re.hasMatch(displayName(m.sender)) ||
          re.hasMatch(m.share) ||
          m.media.any((x) => re.hasMatch(x.name));
    }
    if (caseSensitive) {
      return m.text.contains(q) ||
          m.sender.contains(q) ||
          displayName(m.sender).contains(q) ||
          m.share.contains(q) ||
          m.media.any((x) => x.name.contains(q));
    }
    return messageMatches(m, q);
  }

  /// Literal queries highlight as typed; regex queries highlight only the
  /// substring that matched this message's text (never a sender/file match).
  String _highlightFor(Msg m) {
    if (!useRegex) return query;
    return _compiledRegex?.firstMatch(m.text)?.group(0) ?? '';
  }

  bool get _highlightExact => useRegex || caseSensitive;

  void recompute() {
    final q = query;
    _compiledRegex = null;
    if (useRegex && q.isNotEmpty) {
      try {
        _compiledRegex = RegExp(q, caseSensitive: caseSensitive);
      } catch (_) {
        // An incomplete regex simply matches nothing while typing.
      }
    }
    final inPlace = !panelMode && q.isNotEmpty;
    final sig =
        '$sender|$mediaOnly|${sort.index}|$useRegex|$caseSensitive|${inPlace ? q : ''}|${widget.chat.messages.length}|$_aliasSignature';
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
      _restoreIndex = settings.startAt == StartAt.leftOff
          ? _findRestore()
          : null;
      _railBucket.value = -1;
      // A reversed list shows the newest message first, so its chronological
      // top index is the last item until positions are reported.
      _scrollTop.value = _restoreIndex ?? (_reversed ? view.length - 1 : 0);
      _visibleCount.value = 10;
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
      case SortMode.threaded:
        return _threaded(l);
    }
  }

  /// Put each reply directly after the message it answers. Replies to replies
  /// are included recursively; broken reply links leave the message in place.
  List<Msg> _threaded(List<Msg> l) {
    final inList = l.toSet();
    final out = <Msg>[];
    final used = <Msg>{};
    void add(Msg m) {
      if (!used.add(m)) return;
      out.add(m);
      for (final r in widget.store.repliesTo(m)) {
        if (inList.contains(r)) add(r);
      }
    }

    for (final m in l) {
      final parent = m.replyTarget;
      if (parent == null || !inList.contains(parent)) add(m);
    }
    for (final m in l) {
      add(m); // anything left (cycles, etc.)
    }
    return out;
  }

  /// The saved reading position as an index into [view].
  int? _findRestore() {
    // Read the saved position every time: filters/search can rebuild the view
    // after the chat opened, and scrolling may have saved a newer position.
    final t = settings.chatPos[widget.chat.key];
    if (t == null || !dateSort || view.isEmpty) return null;
    final descending = sort == SortMode.newest;
    return firstIndexAtOrAfter(
      view,
      t,
      (m) => m.t ?? 0,
      descending: descending,
    ).clamp(0, view.length - 1);
  }

  void _newList() {
    positions.itemPositions.removeListener(_onPositions);
    scroll = ItemScrollController();
    positions = ItemPositionsListener.create();
    positions.itemPositions.addListener(_onPositions);
    _railScrubIdx = null;
    _railDragging = false;
    _centerTime.value = null;
    _lastScrollPixels = null;
    _listGen++;
  }

  /// Remember the message at the top of the screen, for "where I left off".
  void _onPositions() {
    if (view.isEmpty) return;
    int? top;
    int? bottom;
    for (final p in positions.itemPositions.value) {
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) {
        continue; // not on screen
      }
      final idx = _reversed ? view.length - 1 - p.index : p.index;
      if (top == null || idx < top) top = idx;
      if (bottom == null || idx > bottom) bottom = idx;
    }
    if (top == null || top >= view.length) return;
    if (_scrollTop.value != top) _scrollTop.value = top;
    final visible = (bottom ?? top) - top + 1;
    if (_visibleCount.value != visible) _visibleCount.value = visible;
    // Middle of the visible range: the date the reader is actually looking at.
    final mid = view[(top + (bottom ?? top)) ~/ 2].t;
    if (_centerTime.value != mid) _centerTime.value = mid;
    // _scrollTop is the oldest visible index (used by the index scrollbar),
    // but the message at the visual top is the newest one in a reversed or
    // newest-first view. That is the timestamp worth highlighting/restoring.
    final visualTop = (_reversed || sort == SortMode.newest) ? bottom : top;
    final t = view[visualTop ?? top].t;
    if (t == null) return;
    // Keep the activity rail's highlight in step with ordinary scrolling, but
    // do not fight the thumb while the user is scrubbing the rail itself.
    if (settings.showActivityRail && !_railDragging) {
      final label = _monthKey(t);
      final bucket = _activityBuckets().indexWhere((b) => b.label == label);
      if (bucket >= 0 && bucket != _railBucket.value) {
        _railBucket.value = bucket;
      }
    }
    // Only date-sorted views have a chronological position worth restoring;
    // sorting by sender/length can put any timestamp at the top.
    if (!dateSort) return;
    if (_lastSavedPosT == t || settings.chatPos[widget.chat.key] == t) {
      _lastSavedPosT = t;
      return;
    }
    settings.chatPos[widget.chat.key] = t;
    _lastSavedPosT = t;
    settings.save();
  }

  // ---------- header that follows the scroll ----------

  /// Briefly reveal the overlay position bar after a sustained fast scroll.
  void _flashImmersiveBar() {
    if (!settings.immersiveMode) return;
    _immersiveBarVisible.value = true;
    _immersiveBarTimer?.cancel();
    _immersiveBarTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) _immersiveBarVisible.value = false;
    });
  }

  /// The bar appears only after fast scrolling has lasted a while, so quick
  /// flicks no longer flash it.
  void _trackFastScroll(int now, double pixels) {
    if (!settings.immersiveMode) {
      _fastScroll.reset();
      return;
    }
    if (_fastScroll.update(now, pixels)) _flashImmersiveBar();
  }

  /// Keep the floating controls on screen while the reader is actively using
  /// them, otherwise hide them after [delay].
  void _scheduleImmersiveControlsHide([
    Duration delay = const Duration(seconds: 3),
  ]) {
    _immersiveControlsTimer?.cancel();
    _immersiveControlsTimer = Timer(delay, () {
      if (!mounted || !settings.immersiveMode) return;
      if (_immersiveMenuOpen ||
          query.isNotEmpty ||
          searchFocus.hasFocus ||
          selecting) {
        _scheduleImmersiveControlsHide();
        return;
      }
      _hideImmersiveControls();
    });
  }

  /// A scroll inside the overflow menu must never remove the widget that owns
  /// that menu. Keep the controls pinned while it is open.
  void _immersiveMenuOpened() {
    _immersiveMenuOpen = true;
    _immersiveControlsTimer?.cancel();
  }

  void _immersiveMenuClosed() {
    _immersiveMenuOpen = false;
    if (mounted && settings.immersiveMode) {
      _scheduleImmersiveControlsHide(const Duration(seconds: 2));
    }
  }

  void revealImmersiveControls() {
    if (!settings.immersiveMode) return;
    _immersiveControlsVisible.value = true;
    _scheduleImmersiveControlsHide();
  }

  /// Brings search into view from a shortcut or menu action. In immersive mode
  /// the field is not built until the floating controls are revealed.
  void focusSearch() {
    if (settings.immersiveMode) {
      setState(() {
        _immersiveControlsVisible.value = true;
        _immersiveSearchExpanded = true;
      });
      _scheduleImmersiveControlsHide();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) searchFocus.requestFocus();
      });
      return;
    }
    _topBarHidden.value = false;
    searchFocus.requestFocus();
  }

  void _hideImmersiveControls() {
    _immersiveControlsTimer?.cancel();
    // This is an explicit hide, so it must work even while the search field is
    // focused. Auto-hide paths already guard against active input.
    searchFocus.unfocus();
    _immersiveControlsVisible.value = false;
    _immersiveSearchExpanded = false;
  }

  Widget _hideImmersiveControlsButton() {
    return IconButton(
      tooltip: 'Hide immersive controls',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.expand_less, size: 18),
      onPressed: _hideImmersiveControls,
    );
  }

  void toggleImmersive() {
    settings.update(() => settings.immersiveMode = !settings.immersiveMode);
    _immersiveSearchExpanded = false;
    _immersiveMenuOpen = false;
    _fastScroll.reset();
    _immersiveBarTimer?.cancel();
    _immersiveBarVisible.value = false;
    _immersiveControlsTimer?.cancel();
    if (settings.immersiveMode) {
      _immersiveControlsVisible.value = true;
      _scheduleImmersiveControlsHide(const Duration(seconds: 2));
    } else {
      _immersiveControlsVisible.value = false;
    }
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is! ScrollUpdateNotification && n is! ScrollEndNotification) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final pixels = n.metrics.pixels;

    if (n is ScrollUpdateNotification) {
      _trackFastScroll(now, pixels);
      if (shouldAutoHideImmersiveControls(
        enabled: settings.immersiveMode,
        menuOpen: _immersiveMenuOpen,
        visible: _immersiveControlsVisible.value,
        queryActive: query.isNotEmpty,
        searchFocused: searchFocus.hasFocus,
        selecting: selecting,
      )) {
        _hideImmersiveControls();
      }
    } else {
      _fastScroll.reset();
    }

    // Immersive detaches the header completely, so the auto-hide bookkeeping
    // is unnecessary while it is active.
    if (settings.immersiveMode) return false;

    if (!settings.autoHideTopBar) return false;
    // The query and selection controls live in the header. Never collapse it
    // while the reader is using them.
    if (query.isNotEmpty || searchFocus.hasFocus || selecting) return false;
    final prev = _lastScrollPixels;
    _lastScrollPixels = pixels;
    if (now < _ignoreScrollUntil || prev == null) return false;
    final delta = pixels - prev;
    if (pixels <= 96) {
      if (_topBarHidden.value) _topBarHidden.value = false;
    } else if (delta > 2) {
      if (!_topBarHidden.value) _topBarHidden.value = true;
    } else if (delta < -2) {
      if (_topBarHidden.value) _topBarHidden.value = false;
    } else {
      return false;
    }
    // Collapsing changes the viewport height, which moves the scroll position
    // again. Ignore that echo so the header cannot oscillate.
    _ignoreScrollUntil = now + 250;
    _lastScrollPixels = null;
    return false;
  }

  /// Slim replacement for the search/filter header. The people-filter eye
  /// stays here so it is never hidden while scrolling.
  Widget _compactTopBar() {
    final cs = Theme.of(context).colorScheme;
    final m3 = Theme.of(context).useMaterial3;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: m3 ? cs.surfaceContainerHigh : cs.surface,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: focusSearch,
                child: SizedBox(
                  height: 38,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Search messages',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ),
                        if (hasActiveFilters)
                          Icon(Icons.filter_list, size: 16, color: cs.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          _peopleFilterToggle(),
          IconButton(
            tooltip: 'Show search and filters',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.expand_more, size: 18),
            onPressed: () => _topBarHidden.value = false,
          ),
        ],
      ),
    );
  }

  /// Date of the message under the reader's eye, as a floating chip.
  Widget _datePill() {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int?>(
      valueListenable: _centerTime,
      builder: (context, t, _) {
        if (t == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.16),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            fmtDate(t),
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
          ),
        );
      },
    );
  }

  /// Translucent surface used by the floating immersive controls.
  Widget _immersiveSurface({required Widget child, double radius = 24}) {
    final cs = Theme.of(context).colorScheme;
    final m3 = Theme.of(context).useMaterial3;
    return Container(
      decoration: BoxDecoration(
        color: (m3 ? cs.surfaceContainerHigh : cs.surface).withValues(
          alpha: 0.94,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(color: Colors.transparent, child: child),
    );
  }

  Widget _immersiveMiniIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: _immersiveSurface(
        radius: 999,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 18, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// Immersive controls float above the conversation instead of reserving
  /// header space. They fade away while reading and return via the small
  /// immersive button at the top-left.
  Widget _immersiveOverlay({
    required Widget panelToggle,
    required Widget overflowMenu,
    required SearchPreset? activePreset,
    required bool panelVisible,
  }) {
    return Positioned.fill(
      child: ValueListenableBuilder<bool>(
        valueListenable: _immersiveControlsVisible,
        builder: (context, visible, _) {
          final child = visible
              ? KeyedSubtree(
                  key: const ValueKey('immersive-controls'),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final expanded = _immersiveSearchExpanded;
                      final available = math.max(0.0, box.maxWidth - 24);
                      final width = expanded
                          ? math.min(560.0, available)
                          : math.min(460.0, available);
                      return Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: SizedBox(
                            width: width,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: expanded ? 360 : double.infinity,
                              ),
                              child: _immersiveSurface(
                                radius: expanded ? 20 : 24,
                                child: expanded
                                    ? SingleChildScrollView(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    14,
                                                    8,
                                                    6,
                                                    0,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Text(
                                                    'Search and filters',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelLarge,
                                                  ),
                                                  const Spacer(),
                                                  _hideImmersiveControlsButton(),
                                                ],
                                              ),
                                            ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    8,
                                                    4,
                                                    8,
                                                    0,
                                                  ),
                                              child: _searchToolbar(
                                                panelToggle,
                                                overflowMenu,
                                              ),
                                            ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    8,
                                                    0,
                                                    8,
                                                    8,
                                                  ),
                                              child: _filterFooter(
                                                activePreset,
                                                panelVisible,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : Row(
                                        children: [
                                          Expanded(
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(24),
                                              onTap: focusSearch,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 8,
                                                    ),
                                                child: Row(
                                                  children: [
                                                    const Icon(
                                                      Icons.search,
                                                      size: 18,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        query.isEmpty
                                                            ? 'Search messages'
                                                            : query,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                    if (hasActiveFilters) ...[
                                                      const SizedBox(width: 8),
                                                      Icon(
                                                        Icons.filter_list,
                                                        size: 16,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .primary,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          _peopleFilterToggle(),
                                          panelToggle,
                                          overflowMenu,
                                          _hideImmersiveControlsButton(),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                )
              : KeyedSubtree(
                  key: const ValueKey('immersive-mini'),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8, left: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _immersiveMiniIcon(
                            icon: Icons.fullscreen,
                            tooltip: 'Show immersive controls',
                            onTap: revealImmersiveControls,
                          ),
                          const SizedBox(width: 6),
                          _immersiveMiniIcon(
                            icon: Icons.visibility_outlined,
                            tooltip: 'People filters',
                            onTap: openPeopleFilters,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (widget, animation) =>
                FadeTransition(opacity: animation, child: widget),
            child: child,
          );
        },
      ),
    );
  }

  // ---------- photos ----------

  List<Pic> getPics() {
    final s = widget.store;
    if (_pics != null && _picsFor == s.mediaVersion) return _pics!;
    final out = <Pic>[];
    final Iterable<Msg> src = (panelMode && query.isNotEmpty)
        ? results.map((i) => view[i])
        : view;
    for (final m in src) {
      for (final x in m.media) {
        final p = s.findMedia(x.uri, widget.chat);
        if (p == null || !isImagePath(p)) continue;
        final cap =
            '${displayName(m.sender)} · ${fmtDate(m.t)} ${fmtTime(m.t)}'
            '${m.text.isNotEmpty ? '\n${m.text}' : ''}\n${p.split(pathSep).last}';
        out.add(Pic(p, cap));
      }
    }
    _pics = out;
    _picsFor = s.mediaVersion;
    return out;
  }

  void openPager(List<Pic> pics, int start) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PicPager(pics: pics, start: start),
      ),
    );
  }

  void openPicByPath(String path) {
    final pics = getPics();
    final i = pics.indexWhere((p) => p.path == path);
    if (i >= 0) openPager(pics, i);
  }

  // ---------- selection and dates ----------

  void toggleSelect(Msg m) => setState(() {
    if (!selection.remove(m)) selection.add(m);
  });

  Future<void> jumpToDate() async {
    if (sort != SortMode.oldest || view.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Switch sorting to "Date: oldest first" to jump by date.',
          ),
        ),
      );
      return;
    }
    final first = DateTime.fromMillisecondsSinceEpoch(view.first.t ?? 0);
    final last = DateTime.fromMillisecondsSinceEpoch(view.last.t ?? 0);
    final picked = await showDatePicker(
      context: context,
      initialDate: last,
      firstDate: DateTime(first.year, first.month, first.day),
      lastDate: DateTime(last.year, last.month, last.day),
    );
    if (picked == null || !mounted) return;
    // showDatePicker returns midnight, so the first message at/after midnight
    // is the first message on the chosen day. Adding a day skipped it.
    final target = picked.millisecondsSinceEpoch;
    final idx = firstIndexAtOrAfter(view, target, (m) => m.t ?? 0);
    jumpToMessage(idx.clamp(0, view.length - 1).toInt());
  }

  // ---------- export ----------

  Iterable<Msg> _exportMessages(_ExportScope scope) => switch (scope) {
    _ExportScope.whole => widget.chat.messages,
    _ExportScope.selected => selection,
    _ExportScope.view =>
      (panelMode && query.isNotEmpty) ? results.map((i) => view[i]) : view,
  };

  Future<void> export(_ExportRequest request) async {
    final Iterable<Msg> msgs = _exportMessages(request.scope);
    final ext = switch (request.format) {
      ExportFormat.json => 'json',
      ExportFormat.csv => 'csv',
      ExportFormat.text => 'txt',
    };
    final mime = switch (request.format) {
      ExportFormat.json => 'application/json',
      ExportFormat.csv => 'text/csv',
      ExportFormat.text => 'text/plain',
    };
    final content = encodeExport(
      widget.chat,
      msgs,
      settings: settings,
      format: request.format,
      options: request.options,
    );
    final suffix = switch (request.scope) {
      _ExportScope.whole => '_all',
      _ExportScope.selected => '_selected',
      _ExportScope.view => '_view',
    };
    final name =
        '${safeFileName(widget.chat.title)}${suffix}_${fmtDate(DateTime.now().millisecondsSinceEpoch)}.$ext';
    final rawMissing =
        request.options.includeRaw && !msgs.any((m) => m.raw.isNotEmpty);
    final ok = await saveExport(name, content, mimeType: mime);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? 'Export cancelled or failed.'
              : rawMissing
              ? 'Saved $name (no original JSON was kept; normalized fields only)'
              : 'Saved $name',
        ),
      ),
    );
  }

  // ---------- toolbar menu ----------

  Future<void> chooseExport() async {
    var scope = _ExportScope.view;
    var format = ExportFormat.json;
    var includeRaw = false;
    var includeMedia = true;
    var includeReactions = true;
    var useDisplayNames = true;
    final scopes = <_ExportScope>[
      _ExportScope.whole,
      _ExportScope.view,
      if (selection.isNotEmpty) _ExportScope.selected,
    ];

    final request = await showDialog<_ExportRequest>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Export messages'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What to export',
                  style: Theme.of(ctx).textTheme.labelLarge,
                ),
                RadioGroup<_ExportScope>(
                  groupValue: scope,
                  onChanged: (v) => setDialog(() => scope = v ?? scope),
                  child: Column(
                    children: [
                      for (final option in scopes)
                        RadioListTile<_ExportScope>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: option,
                          title: Text(_exportScopeLabel(option)),
                          subtitle:
                              option == _ExportScope.selected &&
                                  selection.isNotEmpty
                              ? Text('${selection.length} messages')
                              : null,
                        ),
                    ],
                  ),
                ),
                const Divider(height: 16),
                Text('Format', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in ExportFormat.values)
                      FilterChip(
                        label: Text(_exportFormatLabel(option)),
                        selected: format == option,
                        onSelected: (_) => setDialog(() => format = option),
                      ),
                  ],
                ),
                const Divider(height: 16),
                Text('Include', style: Theme.of(ctx).textTheme.labelLarge),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: includeRaw,
                  title: const Text('Original JSON'),
                  subtitle: const Text(
                    'JSON only. Makes the file much larger.',
                  ),
                  onChanged: format == ExportFormat.json
                      ? (v) => setDialog(() => includeRaw = v ?? false)
                      : null,
                ),
                if (format == ExportFormat.json &&
                    includeRaw &&
                    !_exportMessages(scope).any((m) => m.raw.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Original JSON was not kept in memory for this scope. '
                      'Reopen the export with "Keep original JSON" enabled if you need it; '
                      'this file will contain only normalized fields.',
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: includeMedia,
                  title: const Text('Media'),
                  subtitle: const Text(
                    'JSON and text. CSV always lists media.',
                  ),
                  onChanged: (v) => setDialog(() => includeMedia = v ?? false),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: includeReactions,
                  title: const Text('Reactions'),
                  subtitle: const Text(
                    'JSON and text. CSV always lists reactions.',
                  ),
                  onChanged: (v) =>
                      setDialog(() => includeReactions = v ?? false),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: useDisplayNames,
                  title: const Text('Use display names'),
                  subtitle: const Text(
                    'Aliases are used; originals are kept in JSON and CSV.',
                  ),
                  onChanged: (v) =>
                      setDialog(() => useDisplayNames = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                _ExportRequest(
                  scope,
                  format,
                  ExportOptions(
                    includeRaw: format == ExportFormat.json && includeRaw,
                    includeMedia: includeMedia,
                    includeReactions: includeReactions,
                    useDisplayNames: useDisplayNames,
                  ),
                ),
              ),
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
    if (request != null && mounted) export(request);
  }

  void handleMenu(Object? value) {
    if (value is SortMode) {
      setState(() {
        sort = value;
        recompute();
        if (!_wide) resultsOpen = panelMode && query.isNotEmpty;
      });
      return;
    }
    if (value is! _ChatMenuAction) return;
    switch (value) {
      case _ChatMenuAction.focusSearch:
        focusSearch();
      case _ChatMenuAction.panel:
        setState(() {
          panelMode = !panelMode;
          recompute();
          resultsOpen = panelMode;
        });
      case _ChatMenuAction.regex:
        setState(() {
          useRegex = !useRegex;
          recompute();
        });
      case _ChatMenuAction.caseSensitive:
        setState(() {
          caseSensitive = !caseSensitive;
          recompute();
        });
      case _ChatMenuAction.mediaOnly:
        setState(() {
          mediaOnly = !mediaOnly;
          recompute();
        });
      case _ChatMenuAction.clearFilters:
        _searchTimer?.cancel();
        setState(() {
          qc.clear();
          sender = null;
          mediaOnly = false;
          useRegex = false;
          caseSensitive = false;
          sort = SortMode.oldest;
          selecting = false;
          selection.clear();
          resultsOpen = false;
          recompute();
        });
      case _ChatMenuAction.peopleFilters:
        openPeopleFilters();
      case _ChatMenuAction.savedSearches:
        showSavedSearches();
      case _ChatMenuAction.miniMap:
        settings.update(
          () => settings.showActivityRail = !settings.showActivityRail,
        );
      case _ChatMenuAction.indexBar:
        settings.update(
          () => settings.showIndexScrollbar = !settings.showIndexScrollbar,
        );
      case _ChatMenuAction.immersive:
        toggleImmersive();
      case _ChatMenuAction.gallery:
        setState(() => gallery = !gallery);
      case _ChatMenuAction.mediaInfo:
        showMediaInfo(context, widget.store, widget.chat);
      case _ChatMenuAction.jumpToDate:
        jumpToDate();
      case _ChatMenuAction.select:
        setState(() {
          selecting = !selecting;
          if (!selecting) selection.clear();
        });
      case _ChatMenuAction.export:
        chooseExport();
      case _ChatMenuAction.packMedia:
        unawaited(packConversationMedia(context, widget.store, widget.chat));
    }
  }

  TextStyle? get _menuSectionStyle => Theme.of(context).textTheme.labelSmall
      ?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      );

  PopupMenuEntry<Object> _menuSection(String label) => PopupMenuItem<Object>(
    enabled: false,
    child: Text(label, style: _menuSectionStyle),
  );

  // ---------- controls ----------

  MenuStyle _roundedMenuStyle({
    AlignmentGeometry? alignment,
    double? maxHeight,
  }) {
    final cs = Theme.of(context).colorScheme;
    return MenuStyle(
      alignment: alignment,
      backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
      elevation: const WidgetStatePropertyAll(3),
      side: WidgetStatePropertyAll(BorderSide(color: cs.outlineVariant)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      maximumSize: maxHeight == null
          ? null
          : WidgetStatePropertyAll(Size(double.infinity, maxHeight)),
    );
  }

  ButtonStyle get _roundedMenuItemStyle => ButtonStyle(
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  Widget _menuHeader(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(label, style: _menuSectionStyle),
  );

  Widget _menuAction(
    IconData icon,
    String label,
    VoidCallback run, {
    String? hint,
  }) => MenuItemButton(
    style: _roundedMenuItemStyle,
    leadingIcon: Icon(icon, size: 20),
    onPressed: run,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (hint != null) ...[
          const SizedBox(width: 24),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );

  Widget materialOverflowMenu() {
    final cs = Theme.of(context).colorScheme;
    final active =
        sort != SortMode.oldest ||
        mediaOnly ||
        useRegex ||
        caseSensitive ||
        selecting ||
        gallery;
    return MenuAnchor(
      controller: _menuController,
      onOpen: _immersiveMenuOpened,
      onClose: _immersiveMenuClosed,
      alignmentOffset: const Offset(0, 8),
      style: _roundedMenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        maxHeight: math.max(
          200.0,
          math.min(420.0, MediaQuery.sizeOf(context).height - 96),
        ),
      ),
      menuChildren: [
        _menuHeader('SEARCH'),
        _menuAction(
          Icons.search,
          'Find in chat',
          () => handleMenu(_ChatMenuAction.focusSearch),
          hint: _findHint,
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: panelMode,
          onChanged: (_) => handleMenu(_ChatMenuAction.panel),
          child: const Text('Separate results panel'),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: useRegex,
          onChanged: (_) => handleMenu(_ChatMenuAction.regex),
          child: const Text('Regular expression'),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: caseSensitive,
          onChanged: (_) => handleMenu(_ChatMenuAction.caseSensitive),
          child: const Text('Case-sensitive (Aa)'),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: mediaOnly,
          onChanged: (_) => handleMenu(_ChatMenuAction.mediaOnly),
          child: const Text('Media only'),
        ),
        _menuAction(
          Icons.visibility_outlined,
          'People filters…',
          () => handleMenu(_ChatMenuAction.peopleFilters),
        ),
        if (hasActiveFilters)
          _menuAction(
            Icons.filter_alt_off_outlined,
            'Clear filters',
            () => handleMenu(_ChatMenuAction.clearFilters),
          ),
        _menuAction(
          Icons.bookmarks_outlined,
          'Saved searches…',
          () => handleMenu(_ChatMenuAction.savedSearches),
        ),
        _menuHeader('VIEW'),
        _menuAction(
          gallery ? Icons.chat : Icons.photo_library_outlined,
          gallery ? 'Back to messages' : 'Gallery',
          () => handleMenu(_ChatMenuAction.gallery),
        ),
        _menuAction(
          Icons.perm_media_outlined,
          'Media info and folders',
          () => handleMenu(_ChatMenuAction.mediaInfo),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: settings.immersiveMode,
          onChanged: (_) => handleMenu(_ChatMenuAction.immersive),
          child: const Text('Immersive mode'),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: settings.showActivityRail,
          onChanged: (_) => handleMenu(_ChatMenuAction.miniMap),
          child: const Text('Activity rail'),
        ),
        CheckboxMenuButton(
          style: _roundedMenuItemStyle,
          value: settings.showIndexScrollbar,
          onChanged: (_) => handleMenu(_ChatMenuAction.indexBar),
          child: const Text('Position bar'),
        ),
        _menuAction(
          Icons.event_available_outlined,
          'Jump to a date',
          () => handleMenu(_ChatMenuAction.jumpToDate),
        ),
        _menuHeader('SORT'),
        for (final v in SortMode.values)
          RadioMenuButton<SortMode>(
            style: _roundedMenuItemStyle,
            value: v,
            groupValue: sort,
            onChanged: (value) {
              if (value != null) handleMenu(value);
            },
            child: Text(v.label),
          ),
        _menuHeader('ACTIONS'),
        _menuAction(
          selecting ? Icons.checklist : Icons.checklist_outlined,
          selecting ? 'Finish selecting' : 'Select messages',
          () => handleMenu(_ChatMenuAction.select),
        ),
        _menuAction(
          Icons.file_download_outlined,
          'Export…',
          () => handleMenu(_ChatMenuAction.export),
        ),
        _menuAction(
          Icons.folder_zip_outlined,
          'Pack media (ZIP)…',
          () => handleMenu(_ChatMenuAction.packMedia),
        ),
      ],
      child: IconButton(
        tooltip: 'Search, view, sort and export',
        icon: Icon(Icons.more_vert, color: active ? cs.primary : null),
        onPressed: () {
          if (_menuController.isOpen) {
            _menuController.close();
          } else {
            _menuController.open();
          }
        },
      ),
    );
  }

  List<Widget> activeFilterChips(SearchPreset? activePreset) {
    final chips = <Widget>[];
    void add(Widget chip) => chips.add(chip);

    if (sender != null) {
      add(
        Tooltip(
          message: displayName(sender!),
          child: InputChip(
            avatar: _personAvatar(sender!),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                displayName(sender!),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            onDeleted: () => setState(() {
              sender = null;
              recompute();
            }),
          ),
        ),
      );
    }
    if (mediaOnly) {
      add(
        FilterChip(
          avatar: const Icon(Icons.image_outlined, size: 16),
          label: const Text('Media'),
          selected: true,
          onSelected: (_) => handleMenu(_ChatMenuAction.mediaOnly),
        ),
      );
    }
    if (useRegex) {
      add(
        FilterChip(
          label: const Text('Regex'),
          selected: true,
          onSelected: (_) => handleMenu(_ChatMenuAction.regex),
        ),
      );
    }
    if (caseSensitive) {
      add(
        FilterChip(
          label: const Text('Aa'),
          selected: true,
          onSelected: (_) => handleMenu(_ChatMenuAction.caseSensitive),
        ),
      );
    }
    if (sort != SortMode.oldest) {
      add(
        InputChip(
          avatar: const Icon(Icons.sort, size: 16),
          label: Text(sort.label),
          onDeleted: () => handleMenu(SortMode.oldest),
        ),
      );
    }
    if (activePreset != null) {
      add(
        InputChip(
          avatar: const Icon(Icons.bookmark, size: 16),
          label: Text(activePreset.name),
          onPressed: () => showSavedSearches(),
        ),
      );
    }
    if (hasActiveFilters) {
      add(
        ActionChip(
          avatar: const Icon(Icons.filter_alt_off_outlined, size: 16),
          label: const Text('Clear'),
          onPressed: () => handleMenu(_ChatMenuAction.clearFilters),
        ),
      );
    }
    if (selecting) {
      add(
        Text(
          selection.isEmpty
              ? 'Tap messages to select'
              : '${selection.length} selected',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return chips;
  }

  Widget _personAvatar(String value, {IconData? fallback}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = value.isEmpty ? '' : displayName(value);
    return CircleAvatar(
      radius: 12,
      backgroundColor: cs.primaryContainer,
      foregroundColor: cs.onPrimaryContainer,
      child: fallback != null
          ? Icon(fallback, size: 14)
          : Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: theme.textTheme.labelSmall,
            ),
    );
  }

  Widget _personFieldLabel(IconData icon, String label) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }

  List<DropdownMenuEntry<String>> senderMenuEntries(List<String> senders) => [
    DropdownMenuEntry<String>(
      value: '',
      label: 'Everyone',
      leadingIcon: _personAvatar('', fallback: Icons.groups_outlined),
    ),
    for (final n in senders)
      DropdownMenuEntry<String>(
        value: n,
        label: displayName(n),
        leadingIcon: _personAvatar(n),
      ),
  ];

  List<DropdownMenuEntry<String>> meMenuEntries(List<String> senders) => [
    DropdownMenuEntry<String>(
      value: '',
      label: '(not set)',
      leadingIcon: _personAvatar('', fallback: Icons.person_off_outlined),
    ),
    for (final n in senders)
      DropdownMenuEntry<String>(
        value: n,
        label: displayName(n),
        leadingIcon: _personAvatar(n),
      ),
  ];

  Widget _materialPersonField({
    required String fieldKey,
    required String label,
    required IconData icon,
    required String value,
    required String initialValue,
    required bool searchable,
    required List<DropdownMenuEntry<String>> entries,
    required ValueChanged<String?> onSelected,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Tooltip(
      message: value,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _personFieldLabel(icon, label),
          const SizedBox(height: 6),
          DropdownMenu<String>(
            key: ValueKey(fieldKey),
            initialSelection: initialValue,
            expandedInsets: EdgeInsets.zero,
            menuHeight: 320,
            menuStyle: _roundedMenuStyle(),
            enableSearch: searchable,
            maxLines: 1,
            textStyle: theme.textTheme.bodyMedium,
            leadingIcon: Icon(icon, size: 18, color: cs.onSurfaceVariant),
            trailingIcon: const Icon(Icons.keyboard_arrow_down, size: 20),
            selectedTrailingIcon: const Icon(Icons.keyboard_arrow_up, size: 20),
            dropdownMenuEntries: entries,
            onSelected: onSelected,
            // Use the theme's InputDecorationTheme so M3 and Classic stay in sync.
          ),
        ],
      ),
    );
  }

  Widget _classicPersonItem(String value, String label, {IconData? fallback}) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _personAvatar(value, fallback: fallback),
          const SizedBox(width: 10),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      );

  Widget _classicPersonField<T>({
    required String label,
    required IconData icon,
    required String value,
    required T? initialValue,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Tooltip(
      message: value,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _personFieldLabel(icon, label),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: theme.useMaterial3 ? cs.surfaceContainerLow : cs.surface,
              borderRadius: BorderRadius.circular(theme.useMaterial3 ? 12 : 4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: DropdownButton<T>(
              value: initialValue,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: theme.textTheme.bodyMedium,
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _peopleFilterToggle() {
    return IconButton(
      tooltip: 'People filters',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.visibility_outlined, size: 18),
      onPressed: openPeopleFilters,
    );
  }

  Widget _filterFooter(SearchPreset? activePreset, bool panelVisible) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _peopleFilterToggle(),
          ...activeFilterChips(activePreset),
          if (panelVisible && !_wide && !resultsOpen)
            ActionChip(
              avatar: const Icon(Icons.list, size: 18),
              label: Text('Show ${results.length} results'),
              onPressed: () => setState(() => resultsOpen = true),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                panelVisible
                    ? '${results.length} matches in ${view.length}'
                    : '${view.length} shown',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterBarFrame({
    required List<Widget> fields,
    required Widget footer,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 520;
        final fieldWidth = stacked
            ? constraints.maxWidth
            : (constraints.maxWidth - 8) / 2;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final field in fields)
                    SizedBox(width: fieldWidth, child: field),
                ],
              ),
              footer,
            ],
          ),
        );
      },
    );
  }

  /// The two people selectors. They now live in their own window instead of
  /// under the search box, so the chat header stays short on small screens.
  List<Widget> _personFields(
    Store s,
    List<String> senders, {
    VoidCallback? onPicked,
  }) {
    final meSelection = senders.contains(s.me) ? s.me : '';
    final meValue = meSelection.isEmpty
        ? '(not set)'
        : displayName(meSelection);
    if (Theme.of(context).useMaterial3) {
      return [
        _materialPersonField(
          fieldKey: 'from-${sender ?? ''}-${senders.join('|')}',
          label: 'Show messages from',
          icon: Icons.person_search_outlined,
          value: sender == null ? 'Everyone' : displayName(sender!),
          initialValue: sender ?? '',
          searchable: senders.length > 12,
          entries: senderMenuEntries(senders),
          onSelected: (v) {
            if (mounted) {
              setState(() {
                sender = (v == null || v.isEmpty) ? null : v;
                recompute();
              });
            }
            onPicked?.call();
          },
        ),
        _materialPersonField(
          fieldKey: 'me-${s.me}-${senders.join('|')}',
          label: 'I am',
          icon: Icons.person_outline,
          value: meValue,
          initialValue: meSelection,
          searchable: senders.length > 12,
          entries: meMenuEntries(senders),
          onSelected: (v) {
            s.setMe(v ?? '');
            onPicked?.call();
          },
        ),
      ];
    }
    return [
      _classicPersonField<String?>(
        label: 'Show messages from',
        icon: Icons.person_search_outlined,
        value: sender == null ? 'Everyone' : displayName(sender!),
        initialValue: sender,
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: _classicPersonItem(
              '',
              'Everyone',
              fallback: Icons.groups_outlined,
            ),
          ),
          for (final n in senders)
            DropdownMenuItem<String?>(
              value: n,
              child: _classicPersonItem(n, displayName(n)),
            ),
        ],
        onChanged: (v) {
          if (mounted) {
            setState(() {
              sender = v;
              recompute();
            });
          }
          onPicked?.call();
        },
      ),
      _classicPersonField<String>(
        label: 'I am',
        icon: Icons.person_outline,
        value: meValue,
        initialValue: meSelection,
        items: [
          DropdownMenuItem<String>(
            value: '',
            child: _classicPersonItem(
              '',
              '(not set)',
              fallback: Icons.person_off_outlined,
            ),
          ),
          for (final n in senders)
            DropdownMenuItem<String>(
              value: n,
              child: _classicPersonItem(n, displayName(n)),
            ),
        ],
        onChanged: (v) {
          s.setMe(v ?? '');
          onPicked?.call();
        },
      ),
    ];
  }

  /// Open the people filters in a separate dialog. The eye icon that opens it
  /// is always present in the chat header, even while it is auto-hidden.
  Future<void> openPeopleFilters() async {
    if (!mounted) return;
    _menuController.close();
    final s = widget.store;
    final senders = widget.chat.participants.toList()..sort();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // Rebuild the selectors after a pick: the classic DropdownButton only
          // shows its new value when its parent rebuilds it.
          final fields = _personFields(
            s,
            senders,
            onPicked: () => setDialogState(() {}),
          );
          return AlertDialog(
            title: const Text('People filters'),
            content: SizedBox(
              width: math.min(560.0, MediaQuery.sizeOf(ctx).width - 48),
              child: SingleChildScrollView(
                child: _filterBarFrame(
                  fields: fields,
                  footer: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Filters apply as soon as you choose a name.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------- saved searches ----------

  bool presetMatches(SearchPreset p) =>
      p.query == query &&
      (p.sender.isEmpty ? sender == null : p.sender == sender) &&
      p.mediaOnly == mediaOnly &&
      p.regex == useRegex &&
      p.caseSensitive == caseSensitive &&
      p.sort == sort.name;

  SearchPreset currentPreset(String name) => SearchPreset(
    name: name,
    query: query,
    sender: sender ?? '',
    mediaOnly: mediaOnly,
    regex: useRegex,
    caseSensitive: caseSensitive,
    sort: sort.name,
  );

  void applyPreset(SearchPreset p) {
    _searchTimer?.cancel();
    setState(() {
      qc.text = p.query;
      sender = p.sender.isEmpty || !widget.chat.participants.contains(p.sender)
          ? null
          : p.sender;
      mediaOnly = p.mediaOnly;
      useRegex = p.regex;
      caseSensitive = p.caseSensitive;
      sort = SortMode.values.firstWhere(
        (s) => s.name == p.sort,
        orElse: () => SortMode.oldest,
      );
      resultsOpen = false;
      recompute();
      if (panelMode) resultsOpen = query.isNotEmpty;
    });
  }

  Future<void> showSavedSearches() async {
    final name = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialog) => AlertDialog(
            title: const Text('Saved searches'),
            content: SizedBox(
              width: math.min(520.0, MediaQuery.sizeOf(ctx).width - 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Name for the current search',
                      hintText: 'e.g. photos from Ana',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('Save current filters'),
                      onPressed: () {
                        final n = name.text.trim();
                        if (n.isEmpty) return;
                        settings.savePreset(currentPreset(n));
                        name.clear();
                        setDialog(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (settings.presets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('No saved searches yet.'),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: settings.presets.length,
                        itemBuilder: (context, i) {
                          final p = settings.presets[i];
                          return ListTile(
                            dense: true,
                            title: Text(p.name),
                            subtitle: Text(
                              p.summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              applyPreset(p);
                            },
                            trailing: IconButton(
                              tooltip: 'Delete ${p.name}',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () {
                                settings.deletePreset(p.name);
                                setDialog(() {});
                              },
                            ),
                          );
                        },
                      ),
                    ),
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
        ),
      );
    } finally {
      name.dispose();
    }
  }

  // ---------- activity rail ----------

  String _monthKey(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}';
  }

  Map<String, int> _monthIndexForView() {
    if (_monthSig == _viewSig && _monthIndex.isNotEmpty) {
      return _monthIndex;
    }
    final index = <String, int>{};
    for (var i = 0; i < view.length; i++) {
      final t = view[i].t;
      if (t == null) continue;
      index.putIfAbsent(_monthKey(t), () => i);
    }
    _monthIndex = index;
    _monthSig = _viewSig;
    return _monthIndex;
  }

  List<ActivityBucket> _activityBuckets() {
    final messages = widget.chat.messages;
    final sig =
        '${widget.chat.key}|${messages.length}|${messages.firstOrNull?.t}|${messages.lastOrNull?.t}';
    if (_activitySig == sig && _activity.isNotEmpty) return _activity;
    final builders = <String, _BucketBuilder>{};
    for (final m in messages) {
      final t = m.t;
      if (t == null) continue;
      final key = _monthKey(t);
      final d = DateTime.fromMillisecondsSinceEpoch(t);
      final b = builders.putIfAbsent(
        key,
        () => _BucketBuilder(
          DateTime(d.year, d.month).millisecondsSinceEpoch,
          key,
        ),
      );
      b.count++;
    }
    final buckets =
        builders.values
            .map((b) => ActivityBucket(b.t, b.count, b.label))
            .toList()
          ..sort((a, b) => a.t.compareTo(b.t));
    _activity = buckets;
    _activitySig = sig;
    return _activity;
  }

  void _scrubRail(
    double dy,
    double height,
    List<ActivityBucket> buckets, {
    bool finish = false,
  }) {
    if (height <= 0 || buckets.isEmpty) return;
    final i = (dy / height * buckets.length)
        .clamp(0, buckets.length - 1)
        .toInt();
    if (i == _railBucket.value && !finish) return;
    _railBucket.value = i;
    _railDragging = !finish;
    final label = buckets[i].label;
    final idx = _monthIndexForView()[label];
    if (idx == null || idx < 0) {
      _railScrubIdx = null;
      if (finish) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No visible messages from $label. Clear filters to jump there.',
            ),
          ),
        );
      }
      return;
    }
    _railScrubIdx = idx;
    if (finish) {
      // One full jump on release; dragging uses the lightweight scrub so it
      // does not rebuild toolbars and restart the highlight timer per frame.
      jumpToMessage(idx);
      _railScrubIdx = null;
      _railDragging = false;
    } else {
      scrubTo(idx);
    }
  }

  void _finishRailScrub() {
    _railDragging = false;
    final idx = _railScrubIdx;
    _railScrubIdx = null;
    if (idx != null) jumpToMessage(idx);
  }

  Widget activityRail() {
    final buckets = _activityBuckets();
    if (buckets.isEmpty) return const SizedBox.shrink();
    final max = buckets.map((b) => b.count).reduce(math.max);
    return Container(
      width: 26,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(right: Divider.createBorderSide(context, width: 1)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final slot = math.max(2.0, box.maxHeight / buckets.length);
          final cs = Theme.of(context).colorScheme;
          final m3 = Theme.of(context).useMaterial3;
          final activeColor = m3 ? cs.primaryContainer : cs.primary;
          final idleColor = m3
              ? cs.primaryContainer.withValues(alpha: 0.45)
              : cs.primary.withValues(alpha: 0.25);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                _scrubRail(d.localPosition.dy, box.maxHeight, buckets),
            onTapUp: (d) => _scrubRail(
              d.localPosition.dy,
              box.maxHeight,
              buckets,
              finish: true,
            ),
            onPanStart: (d) =>
                _scrubRail(d.localPosition.dy, box.maxHeight, buckets),
            onPanUpdate: (d) =>
                _scrubRail(d.localPosition.dy, box.maxHeight, buckets),
            onPanEnd: (_) => _finishRailScrub(),
            onPanCancel: _finishRailScrub,
            child: ValueListenableBuilder<int>(
              valueListenable: _railBucket,
              builder: (context, activeBucket, _) => Column(
                children: [
                  for (var i = 0; i < buckets.length; i++)
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Tooltip(
                          message:
                              '${buckets[i].label} · ${buckets[i].count} message${buckets[i].count == 1 ? '' : 's'}',
                          child: Container(
                            width: 14,
                            height: math.max(
                              1.0,
                              (slot - 2) * buckets[i].count / max,
                            ),
                            decoration: BoxDecoration(
                              color: i == activeBucket
                                  ? activeColor
                                  : idleColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- jumping around ----------

  /// Step through search hits. In panel mode [results] holds the matching view
  /// indices; in-place mode [view] already contains only matches. [delta] is
  /// in visible order, so reversed layouts still move down on F3.
  void stepMatch(int delta) {
    if (query.isEmpty) return;
    final visibleDelta = panelMode
        ? (dateSort &&
                  ((sort == SortMode.oldest) == settings.resultsNewestFirst)
              ? -delta
              : delta)
        : (_reversed ? -delta : delta);
    if (panelMode) {
      if (results.isEmpty) return;
      final pos = nextMatchPosition(highlight, results, visibleDelta);
      if (pos >= 0) jumpToMessage(results[pos]);
      return;
    }
    // In-place search uses the view itself as the match list; wrapping can be
    // done arithmetically instead of allocating an identity list of all rows.
    final n = view.length;
    if (n == 0) return;
    var current = highlight;
    if (current == null || current < 0 || current >= n) {
      current = visibleDelta > 0 ? -1 : 0;
    }
    jumpToMessage((current + visibleDelta + n) % n);
  }

  /// Esc: close the narrow results panel first, then clear the search.
  void clearSearchOrResults() {
    if (resultsOpen && !_wide) {
      setState(() => resultsOpen = false);
      return;
    }
    if (query.isEmpty) return;
    _searchTimer?.cancel();
    setState(() {
      qc.clear();
      recompute();
      if (panelMode) resultsOpen = false;
    });
  }

  /// Queue an index-based jump. Rapid rail scrubs overwrite the previous
  /// target, so at most one list rebuild happens per frame.
  void _queueJump(int idx) {
    _queuedJump = idx;
    if (_queuedJumpScheduled) return;
    _queuedJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queuedJumpScheduled = false;
      final target = _queuedJump;
      _queuedJump = null;
      if (target == null || !mounted || !scroll.isAttached || view.isEmpty) {
        return;
      }
      scroll.jumpTo(
        index: (_reversed ? view.length - 1 - target : target)
            .clamp(0, view.length - 1)
            .toInt(),
        alignment: 0.35,
      );
    });
  }

  /// Lightweight scrub used by the scrollbar: move the list without rebuilding
  /// toolbars or restarting the highlight timer on every drag update.
  void scrubTo(int idx) => _queueJump(idx);

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
    _queueJump(idx);
  }

  /// Show every message that replied to this one, then jump to the chosen one.
  Future<void> showReplies(Msg original) async {
    final replies = widget.store.repliesTo(original);
    if (replies.isEmpty) return;
    final chosen = await showDialog<Msg>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${replies.length} repl${replies.length == 1 ? 'y' : 'ies'}',
        ),
        content: SizedBox(
          width: math.min(500.0, MediaQuery.sizeOf(ctx).width - 48),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: replies.length,
            itemBuilder: (context, i) {
              final r = replies[i];
              return ListTile(
                dense: true,
                title: Text(
                  '${displayName(r.sender)}: ${r.text.isEmpty ? '[media]' : r.text}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${fmtDate(r.t)} ${fmtTime(r.t)}'),
                onTap: () => Navigator.pop(ctx, r),
              );
            },
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
    if (chosen == null || !mounted) return;
    final idx = view.indexOf(chosen);
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That reply is hidden by the current search or filters.',
          ),
        ),
      );
      return;
    }
    jumpToMessage(idx);
  }

  /// Tap on a quoted reply: go to the original message.
  void openReply(Msg target) {
    final idx = view.indexOf(target);
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The original message is hidden by the current search or filters.',
          ),
        ),
      );
      return;
    }
    jumpToMessage(idx);
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    SearchPreset? activePreset;
    for (final p in settings.presets) {
      if (presetMatches(p)) {
        activePreset = p;
        break;
      }
    }

    if (_pendingJump != null && !_jumpScheduled) {
      _jumpScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpScheduled = false;
        final i = _pendingJump;
        _pendingJump = null;
        if (i != null && i >= 0 && mounted) jumpToMessage(i);
      });
    }

    final panelToggle = IconButton(
      tooltip: panelMode
          ? 'Results panel: ON — click to filter the chat in place instead'
          : 'Results panel: OFF — click to list matches separately',
      isSelected: panelMode,
      icon: const Icon(Icons.manage_search_outlined),
      selectedIcon: const Icon(Icons.manage_search),
      onPressed: () => handleMenu(_ChatMenuAction.panel),
    );

    final legacyMoreMenu = PopupMenuButton<Object>(
      tooltip: 'Search, view, sort and export',
      icon: Icon(
        Icons.more_vert,
        color:
            (sort != SortMode.oldest ||
                mediaOnly ||
                useRegex ||
                caseSensitive ||
                selecting ||
                gallery)
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
      onOpened: _immersiveMenuOpened,
      onCanceled: _immersiveMenuClosed,
      onSelected: (value) {
        _immersiveMenuClosed();
        handleMenu(value);
      },
      itemBuilder: (_) => [
        _menuSection('SEARCH'),
        PopupMenuItem<Object>(
          value: _ChatMenuAction.focusSearch,
          child: Row(
            children: [
              const Icon(Icons.search, size: 18),
              const SizedBox(width: 12),
              const Expanded(child: Text('Find in chat')),
              Text(_findHint, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.panel,
          checked: panelMode,
          child: const Text('Separate results panel'),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.regex,
          checked: useRegex,
          child: const Text('Regular expression'),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.caseSensitive,
          checked: caseSensitive,
          child: const Text('Case-sensitive (Aa)'),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.mediaOnly,
          checked: mediaOnly,
          child: const Text('Media only'),
        ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.peopleFilters,
          child: Row(
            children: [
              Icon(Icons.visibility_outlined, size: 18),
              SizedBox(width: 12),
              Text('People filters…'),
            ],
          ),
        ),
        if (hasActiveFilters)
          const PopupMenuItem<Object>(
            value: _ChatMenuAction.clearFilters,
            child: Row(
              children: [
                Icon(Icons.filter_alt_off_outlined, size: 18),
                SizedBox(width: 12),
                Text('Clear filters'),
              ],
            ),
          ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.savedSearches,
          child: Row(
            children: [
              Icon(Icons.bookmarks_outlined, size: 18),
              SizedBox(width: 12),
              Text('Saved searches…'),
            ],
          ),
        ),
        _menuSection('VIEW'),
        PopupMenuItem<Object>(
          value: _ChatMenuAction.gallery,
          child: Row(
            children: [
              Icon(gallery ? Icons.chat : Icons.photo_library, size: 18),
              const SizedBox(width: 12),
              Text(gallery ? 'Back to messages' : 'Gallery'),
            ],
          ),
        ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.mediaInfo,
          child: Row(
            children: [
              Icon(Icons.perm_media, size: 18),
              SizedBox(width: 12),
              Text('Media info and folders'),
            ],
          ),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.miniMap,
          checked: settings.showActivityRail,
          child: const Text('Activity rail'),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.indexBar,
          checked: settings.showIndexScrollbar,
          child: const Text('Position bar'),
        ),
        CheckedPopupMenuItem<Object>(
          value: _ChatMenuAction.immersive,
          checked: settings.immersiveMode,
          child: const Text('Immersive mode'),
        ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.jumpToDate,
          child: Row(
            children: [
              Icon(Icons.event_available_outlined, size: 18),
              SizedBox(width: 12),
              Text('Jump to a date'),
            ],
          ),
        ),
        _menuSection('SORT'),
        for (final v in SortMode.values)
          CheckedPopupMenuItem<Object>(
            value: v,
            checked: sort == v,
            child: Text(v.label),
          ),
        _menuSection('ACTIONS'),
        PopupMenuItem<Object>(
          value: _ChatMenuAction.select,
          child: Row(
            children: [
              Icon(
                selecting ? Icons.checklist : Icons.checklist_outlined,
                size: 18,
              ),
              const SizedBox(width: 12),
              Text(selecting ? 'Finish selecting' : 'Select messages'),
            ],
          ),
        ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.export,
          child: Row(
            children: [
              Icon(Icons.file_download_outlined, size: 18),
              SizedBox(width: 12),
              Text('Export…'),
            ],
          ),
        ),
        const PopupMenuItem<Object>(
          value: _ChatMenuAction.packMedia,
          child: Row(
            children: [
              Icon(Icons.folder_zip_outlined, size: 18),
              SizedBox(width: 12),
              Text('Pack media (ZIP)…'),
            ],
          ),
        ),
      ],
    );
    final overflowMenu = settings.material3
        ? materialOverflowMenu()
        : legacyMoreMenu;
    final immersive = settings.immersiveMode;

    return LayoutBuilder(
      builder: (context, box) {
        _wide = box.maxWidth >= 900;
        final panelVisible = panelMode && query.isNotEmpty;
        final panelSide = panelVisible && _wide;
        final panelFull = panelVisible && !_wide && resultsOpen;
        // Gallery and the full results panel have their own controls, so only
        // the normal conversation view detaches its header into a float.
        final immersiveOverlay =
            immersive && !gallery && !panelFull && view.isNotEmpty;
        final showPositionBar =
            !gallery &&
            !panelFull &&
            view.isNotEmpty &&
            settings.showIndexScrollbar;
        final Widget body = gallery
            ? galleryView()
            : (panelFull ? resultsPanel() : listView());

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                focusSearch,
            const SingleActivator(LogicalKeyboardKey.f3): () => stepMatch(1),
            const SingleActivator(LogicalKeyboardKey.f3, shift: true): () =>
                stepMatch(-1),
            const SingleActivator(LogicalKeyboardKey.escape):
                clearSearchOrResults,
          },
          child: Focus(
            autofocus: true,
            child: Column(
              children: [
                // Immersive mode removes the header from the layout entirely;
                // its controls are a floating overlay inside the chat area.
                if (!immersiveOverlay)
                  ValueListenableBuilder<bool>(
                    valueListenable: _topBarHidden,
                    builder: (context, hidden, _) {
                      final full = !settings.autoHideTopBar || !hidden;
                      return AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: full
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      8,
                                      8,
                                      0,
                                    ),
                                    child: _searchToolbar(
                                      panelToggle,
                                      overflowMenu,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      0,
                                      8,
                                      8,
                                    ),
                                    child: _filterFooter(
                                      activePreset,
                                      panelVisible,
                                    ),
                                  ),
                                  const Divider(height: 1),
                                ],
                              )
                            : _compactTopBar(),
                      );
                    },
                  ),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScrollNotification,
                    // The same Row is always used, so the message list is never torn down just
                    // because the results panel appears next to it. The position bar is an
                    // overlay and never takes width from the conversation.
                    child: Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (settings.showActivityRail &&
                                !immersive &&
                                !gallery &&
                                view.isNotEmpty)
                              activityRail(),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(child: body),
                                  if (!gallery &&
                                      !panelFull &&
                                      dateSort &&
                                      settings.showDatePill)
                                    Positioned(
                                      top: 8,
                                      left: 0,
                                      right: 0,
                                      child: IgnorePointer(
                                        child: Center(child: _datePill()),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (panelSide) ...[
                              const VerticalDivider(width: 1),
                              SizedBox(width: 360, child: resultsPanel()),
                            ],
                          ],
                        ),
                        if (immersiveOverlay)
                          _immersiveOverlay(
                            panelToggle: panelToggle,
                            overflowMenu: overflowMenu,
                            activePreset: activePreset,
                            panelVisible: panelVisible,
                          ),
                        if (showPositionBar)
                          Positioned(
                            right: panelSide ? 373 : 12,
                            top: 12,
                            bottom: 12,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _immersiveBarVisible,
                              builder: (context, flashed, _) {
                                final visible = !immersive || flashed;
                                return AnimatedOpacity(
                                  opacity: visible ? 1 : 0,
                                  duration: const Duration(milliseconds: 180),
                                  child: IgnorePointer(
                                    ignoring: !visible,
                                    child: _IndexScrollbar(
                                      itemCount: view.length,
                                      topIndex: _scrollTop,
                                      visibleCount: _visibleCount,
                                      onJump: scrubTo,
                                      immersive: immersive,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- search results panel ----------

  Widget resultsPanel() {
    final q = query;
    final compact = settings.resultsLayout == ResultsLayout.compact;
    final newestFirst = settings.resultsNewestFirst;
    // `results` follows the order of the chat; map the index instead of
    // copying and reversing tens of thousands of entries on every rebuild.
    final reverse = dateSort && ((sort == SortMode.oldest) == newestFirst);
    final cs = Theme.of(context).colorScheme;
    final muted = cs.outline;

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
                  tooltip: newestFirst
                      ? 'Newest matches first (click to flip)'
                      : 'Oldest matches first (click to flip)',
                  icon: Icon(
                    newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
                  ),
                  onPressed: () => settings.update(
                    () => settings.resultsNewestFirst = !newestFirst,
                  ),
                ),
              IconButton(
                tooltip: compact
                    ? 'Showing one line per result (click for detailed)'
                    : 'Showing detailed results (click for compact)',
                icon: Icon(
                  compact ? Icons.view_headline : Icons.view_agenda_outlined,
                ),
                onPressed: () => settings.update(
                  () => settings.resultsLayout = compact
                      ? ResultsLayout.detailed
                      : ResultsLayout.compact,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('No matches'))
              : RawScrollbar(
                  controller: _resultsController,
                  thumbVisibility: true,
                  thickness: 6,
                  radius: const Radius.circular(8),
                  mainAxisMargin: 4,
                  crossAxisMargin: 2,
                  thumbColor: cs.onSurface.withValues(alpha: 0.24),
                  child: ListView.separated(
                    controller: _resultsController,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final idx = results[reverse ? results.length - 1 - i : i];
                      final m = view[idx];
                      final when = '${fmtDate(m.t)} ${fmtTime(m.t)}';
                      final hq = _highlightFor(m);
                      final shape = RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      );
                      if (compact) {
                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          selected: highlight == idx,
                          selectedTileColor: cs.secondaryContainer,
                          shape: shape,
                          title: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$when  ${displayName(m.sender)}: ',
                                  style: TextStyle(color: muted, fontSize: 12),
                                ),
                                ...highlightSpans(
                                  snippet(
                                    m.text,
                                    hq,
                                    caseSensitive: _highlightExact,
                                  ).replaceAll('\n', ' '),
                                  hq,
                                  null,
                                  kHighlightColor,
                                  caseSensitive: _highlightExact,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => jumpToMessage(idx),
                        );
                      }
                      return ListTile(
                        dense: true,
                        selected: highlight == idx,
                        selectedTileColor: cs.secondaryContainer,
                        shape: shape,
                        title: Text.rich(
                          TextSpan(
                            children: highlightSpans(
                              snippet(
                                m.text,
                                hq,
                                caseSensitive: _highlightExact,
                              ),
                              hq,
                              null,
                              kHighlightColor,
                              caseSensitive: _highlightExact,
                            ),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${displayName(m.sender)} · $when'),
                        onTap: () => jumpToMessage(idx),
                      );
                    },
                  ),
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
    return ScrollConfiguration(
      behavior: const _NoDesktopScrollbar(),
      child: ScrollablePositionedList.builder(
        key: ValueKey('$_listGen-$rev'),
        itemScrollController: scroll,
        itemPositionsListener: positions,
        reverse: rev,
        initialScrollIndex: initial,
        padding: const EdgeInsets.all(8),
        // Bubbles hold no state worth keeping. Let the sliver recycle them as
        // soon as they leave the cache extent instead of retaining every item
        // visited during a long scroll.
        addAutomaticKeepAlives: false,
        itemCount: n,
        itemBuilder: (context, i) {
          final idx = rev ? n - 1 - i : i;
          final m = view[idx];
          final prev = idx > 0 ? view[idx - 1] : null;
          final newDay = dateSort && (prev == null || !sameDay(prev.t, m.t));
          final showName =
              !dateSort || prev == null || prev.sender != m.sender || newDay;
          final tight =
              dateSort && prev != null && !newDay && prev.sender == m.sender;
          // Only the last message in a run from the same minute carries a
          // timestamp. `view` stays chronological even when displayed in
          // reverse, so the right message keeps its time either way.
          final showTime =
              !settings.groupTimesByMinute ||
              !dateSort ||
              idx + 1 >= n ||
              !sameMinute(m.t, view[idx + 1].t);
          final mine =
              widget.store.me.isNotEmpty && m.sender == widget.store.me;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (newDay)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      fmtDate(m.t),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              Bubble(
                m: m,
                mine: mine,
                showName: showName,
                showDate: !dateSort,
                showTime: showTime,
                tight: tight,
                store: widget.store,
                chat: widget.chat,
                query: query,
                regex: useRegex,
                caseSensitive: caseSensitive,
                compiledRegex: _compiledRegex,
                highlighted: highlight == idx,
                selected: selection.contains(m),
                onSelect: selecting ? () => toggleSelect(m) : null,
                replyCount: widget.store.replyCount(m),
                onShowReplies: () => showReplies(m),
                onPic: openPicByPath,
                onOpenReply: openReply,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget galleryView() {
    final pics = getPics();
    if (pics.isEmpty) {
      return Center(
        child: Text(
          widget.store.hasMedia(widget.chat)
              ? 'No photos match the current filters.'
              : 'Open a media folder first (media info button above).',
        ),
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
      itemBuilder: (context, i) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => openPager(pics, i),
          child: Image.file(
            File(pics[i].path),
            fit: BoxFit.cover,
            cacheWidth: (tile * MediaQuery.devicePixelRatioOf(context)).round(),
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
          ),
        ),
      ),
    );
  }
}
