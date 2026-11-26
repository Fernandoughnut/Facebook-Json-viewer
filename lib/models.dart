// Plain data classes shared by the parser, the store and the UI.

/// Splits a path at either kind of slash (exports can contain Windows or Linux paths).
final RegExp pathSep = RegExp(r'[\\/]');

/// The ways a conversation can be sorted.
enum SortMode {
  oldest('Date: oldest first'),
  newest('Date: newest first'),
  sender('Sender (A–Z)'),
  longest('Longest messages first'),
  reactions('Most reactions first'),
  media('Messages with media first'),
  threaded('Threads (replies grouped)');

  final String label;
  const SortMode(this.label);
}

class Media {
  final String kind; // photos, videos, audio_files, files, gifs, sticker...
  final String
  uri; // path as written in the export JSON (file names are random IDs)
  const Media(this.kind, this.uri);

  String get name => uri.split(pathSep).last;
}

class Reaction {
  final String emoji;
  final String actor;
  const Reaction(this.emoji, this.actor);
}

/// What a message says it replied to, exactly as written in the export.
class Reply {
  final String id; // ID of the original message, '' if the export gives none
  final String sender; // original sender, if the export includes it
  final String text; // original text, if the export includes it
  final int? t; // original time, if the export includes it
  const Reply({this.id = '', this.sender = '', this.text = '', this.t});
}

class Msg {
  final String id;
  final String sender;
  final int? t; // milliseconds since epoch
  final String text;
  final List<Media> media;
  final List<Reaction> reactions;
  final String share;
  final String type;
  final bool unsent;
  final Reply? reply;
  final Map raw; // original JSON object, shown in "Message details"

  /// The message this one replies to, once found in the conversation (set after loading).
  Msg? replyTarget;

  /// Lower-case search fields, made on first use so a 20k-message export does
  /// not allocate several extra strings while parsing.
  late final String lower = text.toLowerCase();
  late final String lowerSender = sender.toLowerCase();
  late final String lowerShare = share.toLowerCase();
  late final List<String> lowerMediaNames = [
    for (final x in media) x.name.toLowerCase(),
  ];

  Msg({
    required this.id,
    required this.sender,
    required this.t,
    required this.text,
    required this.media,
    required this.reactions,
    required this.share,
    required this.type,
    required this.unsent,
    required this.reply,
    required this.raw,
  });
}

/// What the parser returns for one conversation found in one file.
class ParsedThread {
  final String key;
  final String title;
  final List<String> participants;
  final List<Msg> messages;
  const ParsedThread(this.key, this.title, this.participants, this.messages);
}

/// One opened media folder with an index of the files inside it.
class MediaDir {
  final String path;
  final Map<String, String> files; // lowercase file name -> full path

  /// Lowercase relative path (for example `photos/a.jpg`) -> full path. This
  /// keeps two different files with the same file name distinguishable.
  final Map<String, String> paths;

  MediaDir(this.path, this.files, [Map<String, String>? paths])
    : paths = paths ?? const <String, String>{};

  Map<String, List<String>>? _suffixes;

  /// Relative-path tails -> candidate paths, built once per folder.
  ///
  /// A URI from an exported conversation can carry extra leading folders (for
  /// example `media/photos/a.jpg` after unpacking a media pack). Looking up
  /// the tail in a prebuilt index avoids scanning every indexed file for every
  /// media reference. Candidates keep the old shortest-key-first ordering so
  /// a vanished file can still fall through to the next match.
  Map<String, List<String>> get suffixes {
    final existing = _suffixes;
    if (existing != null) return existing;
    final entries = paths.entries.toList()
      ..sort((a, b) {
        final byLength = a.key.length.compareTo(b.key.length);
        return byLength != 0 ? byLength : a.key.compareTo(b.key);
      });
    final built = <String, List<String>>{};
    for (final entry in entries) {
      final parts = entry.key.split('/');
      for (var i = 0; i < parts.length; i++) {
        built
            .putIfAbsent(parts.sublist(i).join('/'), () => <String>[])
            .add(entry.value);
      }
    }
    return _suffixes = built;
  }

  int get count => files.length;
}

/// A conversation after merging every file that belongs to it.
class Chat {
  final String key;
  final String title;
  final Set<String> participants = {};
  final List<Msg> messages = [];

  /// Media folders opened just for this conversation (checked before the shared ones).
  final List<MediaDir> dirs = [];
  Chat(this.key, this.title);

  int get lastT => messages.isEmpty ? 0 : (messages.last.t ?? 0);
}
