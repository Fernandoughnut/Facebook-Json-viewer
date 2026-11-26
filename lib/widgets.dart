// Message widgets and dialogs: bubbles, reply quotes, message details, media info, photo viewer.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'media_pack.dart';
import 'models.dart';
import 'settings.dart';
import 'store.dart';
import 'util.dart';

/// A stable color for a person's name (used by the plain layout).
Color nameColor(String name, Brightness b) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(
    1,
    (h % 360).toDouble(),
    0.55,
    b == Brightness.dark ? 0.72 : 0.36,
  ).toColor();
}

// ---------- message details (raw JSON, reply info) ----------

Future<void> showMsgDetails(
  BuildContext context,
  Msg m,
  Chat chat, {
  Store? store,
}) {
  String json;
  try {
    json = m.raw.isEmpty
        ? '(original JSON was not kept in memory; turn on "Keep original JSON" in Settings to see it)'
        : const JsonEncoder.withIndent('  ').convert(m.raw);
  } catch (e) {
    json = '(cannot show: $e)';
  }
  final r = m.reply;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final note = store?.noteFor(chat, m) ?? '';
        final bookmarked = store?.isBookmarked(chat, m) ?? false;
        final lines = <String>[
          'From: ${displayName(m.sender)} (export name: ${m.sender})',
          'Time: ${fmtDate(m.t)} ${fmtTime(m.t)}   (${m.t})',
          'Message ID: ${m.id.isEmpty ? '(none found)' : m.id}',
          if (m.text.isNotEmpty) 'Text: ${m.text}',
          if (note.isNotEmpty) 'Note: $note',
          if (r == null)
            'Reply info: none found in this message (its fields: ${m.raw.keys.join(', ')})'
          else
            'Replies to: ${m.replyTarget != null ? 'found in this conversation (${m.replyTarget!.sender})' : 'not found in this conversation'}'
                '${r.id.isNotEmpty ? ', id ${r.id}' : ''}',
        ];
        final dialogWidth = math.max(
          240.0,
          math.min(620.0, MediaQuery.sizeOf(ctx).width - 48),
        );
        return AlertDialog(
          title: const Text('Message details'),
          content: SizedBox(
            width: dialogWidth,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(lines.join('\n')),
                  const SizedBox(height: 12),
                  Text(
                    'Original data from the export',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(json, style: monoStyle(ctx)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            // Five actions do not fit in one row on a phone, so let them wrap.
            SizedBox(
              width: dialogWidth,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  if (store != null)
                    TextButton(
                      onPressed: () async {
                        final ctrl = TextEditingController(text: note);
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (nctx) => AlertDialog(
                            title: const Text('Note for this message'),
                            content: TextField(
                              controller: ctrl,
                              maxLines: 4,
                              autofocus: true,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(nctx, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(nctx, true),
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true && ctx.mounted) {
                          store.setNote(chat, m, ctrl.text);
                          setDialogState(() {});
                        }
                        ctrl.dispose();
                      },
                      child: Text(note.isEmpty ? 'Add note' : 'Edit note'),
                    ),
                  if (store != null)
                    TextButton.icon(
                      icon: Icon(
                        bookmarked ? Icons.bookmark : Icons.bookmark_border,
                        size: 18,
                      ),
                      label: Text(bookmarked ? 'Remove bookmark' : 'Bookmark'),
                      onPressed: () {
                        store.toggleBookmark(chat, m);
                        setDialogState(() {});
                      },
                    ),
                  if (m.text.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: m.text));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Message text copied'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                      child: const Text('Copy text'),
                    ),
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: json));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('Message JSON copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    child: const Text('Copy JSON'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

// ---------- media info dialog ----------

Future<void> showMediaInfo(BuildContext context, Store store, Chat chat) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final st = store.statsFor(chat);

        Widget dirTile(MediaDir d, Chat? owner) => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder),
          title: SelectableText(d.path),
          subtitle: Text('${d.count} files'),
          trailing: IconButton(
            tooltip: 'Remove this folder',
            icon: const Icon(Icons.close),
            onPressed: () => store.removeMediaDir(d, chat: owner),
          ),
        );

        Future<void> add(Chat? owner) async {
          final dir = await pickFolder(
            store,
            navigator: Navigator.of(ctx, rootNavigator: true),
          );
          if (dir != null) await store.addMediaDir(dir, chat: owner);
        }

        final heading = Theme.of(ctx).textTheme.titleSmall;
        return AlertDialog(
          title: Text(
            'Media: ${chat.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: math.max(
              240.0,
              math.min(560.0, MediaQuery.sizeOf(ctx).width - 48),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (store.busy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: LinearProgressIndicator(),
                    ),
                  Text(
                    'Photos, videos and files referenced by this conversation: ${st.total}',
                  ),
                  Text(
                    'Found: ${st.fromChat + st.fromShared} '
                    '(${st.fromChat} in this conversation\'s folders, ${st.fromShared} in shared folders)',
                  ),
                  Text('Missing: ${st.missing}'),
                  if (st.missing > 0)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Show missing file names'),
                      children: [
                        for (final n in st.missingSample)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(n),
                          ),
                        if (st.missing > st.missingSample.length)
                          Text(
                            '… and ${st.missing - st.missingSample.length} more',
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Text('Folders for this conversation only', style: heading),
                  if (chat.dirs.isEmpty) const Text('None yet.'),
                  for (final d in chat.dirs) dirTile(d, chat),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => add(chat),
                      icon: const Icon(Icons.create_new_folder),
                      label: const Text('Add folder for this conversation'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Shared folders (used by every conversation)',
                    style: heading,
                  ),
                  if (store.sharedDirs.isEmpty) const Text('None yet.'),
                  for (final d in store.sharedDirs) dirTile(d, null),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => add(null),
                      icon: const Icon(Icons.folder_shared),
                      label: const Text('Add shared folder'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lookup order: this conversation\'s folders first, then the shared ones. '
                    'Files are matched by the file name written in the JSON.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton.icon(
              onPressed: (st.fromChat + st.fromShared) == 0
                  ? null
                  : () => packConversationMedia(ctx, store, chat),
              icon: const Icon(Icons.folder_zip_outlined, size: 18),
              label: const Text('Pack media (ZIP)'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

// ---------- quoted reply ----------

/// The small block shown above a message that replies to another one.
class ReplyQuote extends StatelessWidget {
  final Msg m;
  final Color fg;
  final void Function(Msg target) onOpen;
  const ReplyQuote({
    super.key,
    required this.m,
    required this.fg,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final r = m.reply!;
    final target = m.replyTarget;
    final rawWho = target?.sender ?? r.sender;
    final who = rawWho.isEmpty ? 'a message' : displayName(rawWho);
    var text = target != null ? target.text : r.text;
    if (text.isEmpty && target != null && target.media.isNotEmpty) {
      text = '📎 ${target.media.first.kind.replaceAll('_', ' ')}';
    }
    if (text.isEmpty) {
      text = target == null
          ? 'Original message is not in this export'
          : '(no text)';
    }

    final soft = fg.withValues(alpha: 0.85);
    final textTheme = Theme.of(context).textTheme;
    final box = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        border: Border(
          left: BorderSide(color: fg.withValues(alpha: 0.6), width: 3),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '↩ Replying to $who',
            style: textTheme.labelSmall?.copyWith(
              color: soft,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: soft),
          ),
        ],
      ),
    );
    if (target == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => onOpen(target), child: box),
    );
  }
}

// ---------- one message ----------

class Bubble extends StatelessWidget {
  final Msg m;
  final bool mine;
  final bool showName;
  final bool showDate; // put the date next to the time (used when messages are not in date order)
  final bool showTime; // false for earlier messages in the same minute
  final bool tight; // consecutive message from the same sender
  final Store store;
  final Chat chat;
  final String query;
  final bool regex;
  final bool caseSensitive;
  final RegExp? compiledRegex;
  final bool highlighted;
  final void Function(String path) onPic;
  final void Function(Msg target) onOpenReply;
  final bool selected;
  final VoidCallback? onSelect;
  final int replyCount;
  final VoidCallback? onShowReplies;

  const Bubble({
    super.key,
    required this.m,
    required this.mine,
    required this.showName,
    required this.showDate,
    this.showTime = true,
    this.tight = false,
    required this.store,
    required this.chat,
    required this.query,
    required this.highlighted,
    this.regex = false,
    this.caseSensitive = false,
    this.compiledRegex,
    required this.onPic,
    required this.onOpenReply,
    this.selected = false,
    this.onSelect,
    this.replyCount = 0,
    this.onShowReplies,
  });

  AppSettings get st => store.settings;

  String get stamp =>
      showDate ? '${fmtDate(m.t)} ${fmtTime(m.t)}' : fmtTime(m.t);

  void details(BuildContext context) =>
      showMsgDetails(context, m, chat, store: store);

  Widget mediaWidget(BuildContext context, Media x, Color fg) {
    final label = x.kind.replaceAll('_', ' ');
    final p = store.findMedia(x.uri, chat);
    if (p == null) {
      final miss = store.hasMedia(chat) && x.uri.isNotEmpty
          ? ' (not found in media folders)'
          : '';
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '📎 $label${x.uri.isEmpty ? '' : ': ${x.name}'}$miss',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: fg.withValues(alpha: 0.8)),
        ),
      );
    }
    if (isImagePath(p)) {
      final w = st.chatImageWidth;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => onPic(p),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: w * 1.5),
                child: Image.file(
                  File(p),
                  width: w,
                  // Decode at the screen's real pixel density. A fixed 2x
                  // made photos visibly soft on 3x/4x phones.
                  cacheWidth: (w * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  // a fixed-size placeholder until the picture is ready, so the list does not jump around
                  frameBuilder: (context, child, frame, sync) {
                    if (sync || frame != null) return child;
                    return Container(
                      width: w,
                      height: w * 0.75,
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    );
                  },
                  errorBuilder: (_, _, _) => Text(
                    '⚠ cannot show ${x.name}',
                    style: TextStyle(color: fg),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ActionChip(
        avatar: const Icon(Icons.play_arrow, size: 18),
        label: Text('$label: ${x.name}', overflow: TextOverflow.ellipsis),
        onPressed: () => openExternal(p, context),
      ),
    );
  }

  /// Text, photos and links of the message (used by the bubble layouts).
  List<Widget> body(BuildContext context, TextStyle base, Color fg) {
    final out = <Widget>[];
    if (m.text.isNotEmpty) {
      // Regex matches can come from the sender or a file name, so highlight
      // only the exact substring that actually matched the message text.
      final hq = regex
          ? (compiledRegex?.firstMatch(m.text)?.group(0) ?? '')
          : query;
      // Plain Text is much cheaper than SelectableText when a jump rebuilds
      // a screenful of bubbles. Full selectable text stays available in
      // Message details.
      out.add(
        Text.rich(
          TextSpan(
            children: highlightSpans(
              m.text,
              hq,
              base,
              kHighlightColor,
              caseSensitive: regex || caseSensitive,
            ),
          ),
        ),
      );
    } else if (m.unsent) {
      out.add(Text('This message was unsent', style: base));
    }
    for (final x in m.media) {
      out.add(mediaWidget(context, x, fg));
    }
    if (m.share.isNotEmpty) {
      out.add(Text('🔗 ${m.share}', style: base));
    }
    if (out.isEmpty) {
      out.add(
        Text(
          '[${m.type.isEmpty ? 'empty message' : m.type}]',
          style: base.copyWith(color: fg.withValues(alpha: 0.7)),
        ),
      );
    }
    return out;
  }

  Widget metaRow(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final wantsStamp = st.showTimes || showDate;
    final showStamp = showTime && wantsStamp;
    // Hidden-by-grouping is different from "showTimes is off": don't replace
    // the suppressed time with an info icon, or the row stays just as cluttered.
    final groupedAway = !showTime && wantsStamp;
    final hasReplies = replyCount > 0 && onShowReplies != null;
    if (groupedAway && !hasReplies) return const SizedBox.shrink();
    final children = <Widget>[
      if (!groupedAway)
        Tooltip(
          message: 'Message details',
          child: InkWell(
            onTap: () => details(context),
            onLongPress: () => details(context),
            child: showStamp
                ? Text(stamp, style: style)
                : Icon(Icons.info_outline, size: 12, color: style?.color),
          ),
        ),
      if (hasReplies)
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          iconSize: 14,
          tooltip: 'Show $replyCount repl${replyCount == 1 ? 'y' : 'ies'}',
          icon: Icon(Icons.reply_all, color: style?.color),
          onPressed: onShowReplies,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = switch (st.layout) {
      ChatLayout.plain => plain(context),
      ChatLayout.compact => bubble(context, compact: true),
      ChatLayout.bubbles => bubble(context, compact: false),
    };
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTap: () => details(context),
      // Android has no right click: long press opens the same message details.
      onLongPress: () => details(context),
      onTap: onSelect,
      child: child,
    );
  }

  Widget bubble(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.useMaterial3;
    final bg = mine
        ? (m3 ? cs.primaryContainer : cs.primary)
        : (m3 ? cs.surfaceContainerHigh : cs.surfaceContainerHighest);
    final fg = mine
        ? (m3 ? cs.onPrimaryContainer : cs.onPrimary)
        : cs.onSurface;
    final maxW = math.min(560.0, MediaQuery.of(context).size.width * 0.8);
    final base = TextStyle(
      color: fg,
      fontSize: compact ? 13 : null,
      fontStyle: m.unsent ? FontStyle.italic : FontStyle.normal,
    );

    final content = <Widget>[
      if (st.showReplies && m.reply != null)
        ReplyQuote(m: m, fg: fg, onOpen: onOpenReply),
      ...body(context, base, fg),
    ];

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        // Consecutive messages from one sender sit closer together; a new
        // sender (or a new day) keeps the roomier gap so groups stay readable.
        padding: EdgeInsets.symmetric(
          vertical: tight ? (compact ? 0.5 : 1.5) : (compact ? 2 : 4),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (showName && !mine)
              Padding(
                padding: EdgeInsets.fromLTRB(8, compact ? 3 : 6, 8, 1),
                child: Text(
                  displayName(m.sender),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            Container(
              constraints: BoxConstraints(maxWidth: maxW),
              padding: compact
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
                  : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(compact ? 12 : 16),
                border: selected
                    ? Border.all(color: cs.tertiary, width: 3)
                    : highlighted
                    ? Border.all(color: kHighlightColor, width: 3)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: content,
              ),
            ),
            if (m.reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(
                  m.reactions
                      .map(
                        (r) => r.actor.isEmpty
                            ? r.emoji
                            : '${r.emoji} ${displayName(r.actor)}',
                      )
                      .join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            metaRow(context),
          ],
        ),
      ),
    );
  }

  /// One dense line per message: "14:22  Name: text", like a chat log.
  Widget plain(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final base = theme.textTheme.bodyMedium;
    final nameCol = mine
        ? cs.primary
        : nameColor(displayName(m.sender), theme.brightness);

    final spans = <InlineSpan>[
      if (showTime && (st.showTimes || showDate))
        TextSpan(
          text: '$stamp  ',
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
      TextSpan(
        text: displayName(m.sender),
        style: TextStyle(color: nameCol, fontWeight: FontWeight.w600),
      ),
      const TextSpan(text: ':  '),
    ];
    if (m.text.isNotEmpty) {
      spans.addAll(highlightSpans(m.text, query, null, kHighlightColor));
    } else if (m.unsent) {
      spans.add(
        const TextSpan(
          text: 'This message was unsent',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else if (m.media.isEmpty && m.share.isEmpty) {
      spans.add(
        TextSpan(
          text: '[${m.type.isEmpty ? 'empty message' : m.type}]',
          style: TextStyle(color: cs.outline),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.symmetric(vertical: tight ? 0 : 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: selected
          ? BoxDecoration(
              color: cs.tertiaryContainer,
              border: Border.all(color: cs.tertiary, width: 2),
              borderRadius: BorderRadius.circular(6),
            )
          : highlighted
          ? BoxDecoration(
              color: kHighlightColor.withValues(alpha: 0.25),
              border: Border.all(color: kHighlightColor, width: 2),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (st.showReplies && m.reply != null)
            ReplyQuote(m: m, fg: cs.onSurface, onOpen: onOpenReply),
          Text.rich(TextSpan(style: base, children: spans)),
          for (final x in m.media) mediaWidget(context, x, cs.onSurface),
          if (m.share.isNotEmpty) Text('🔗 ${m.share}', style: base),
          if (m.reactions.isNotEmpty)
            Text(
              m.reactions
                  .map(
                    (r) => r.actor.isEmpty
                        ? r.emoji
                        : '${r.emoji} ${displayName(r.actor)}',
                  )
                  .join(' · '),
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

// ---------- full-screen photo viewer ----------

class PicPager extends StatefulWidget {
  final List<Pic> pics;
  final int start;
  const PicPager({super.key, required this.pics, required this.start});

  @override
  State<PicPager> createState() => _PicPagerState();
}

class _PicPagerState extends State<PicPager> {
  late final PageController ctrl = PageController(initialPage: widget.start);
  late int index = widget.start;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  void go(int delta) {
    ctrl.animateToPage(
      (index + delta).clamp(0, widget.pics.length - 1).toInt(),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: cs.surfaceContainerLowest,
          appBar: AppBar(
            backgroundColor: cs.surfaceContainerLowest,
            foregroundColor: cs.onSurface,
            title: Text('${index + 1} / ${widget.pics.length}'),
          ),
          body: PageView.builder(
            controller: ctrl,
            itemCount: widget.pics.length,
            onPageChanged: (i) => setState(() => index = i),
            itemBuilder: (context, i) {
              final p = widget.pics[i];
              return Column(
                children: [
                  Expanded(
                    child: InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        // Decode the original: this is the view where a user
                        // checks photo quality and zooms in, so a logical-pixel
                        // cacheWidth made every imported image look compressed.
                        child: Image.file(
                          File(p.path),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      p.caption,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
