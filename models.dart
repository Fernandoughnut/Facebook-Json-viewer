// Plain data classes shared by the parser, the store and the UI.

class Media {
  final String kind; // photos, videos, audio_files, files, gifs, sticker...
  final String uri; // path as written in the export JSON (file names are random IDs)
  const Media(this.kind, this.uri);

  String get name => uri.split(RegExp(r'[\\/]')).last;
}

class Reaction {
  final String emoji;
  final String actor;
  const Reaction(this.emoji, this.actor);
}

class Msg {
  final String sender;
  final int? t; // milliseconds since epoch
  final String text;
  final List<Media> media;
  final List<Reaction> reactions;
  final String share;
  final String type;
  final bool unsent;
  final Map raw; // original JSON object, handy for debugging

  const Msg({
    required this.sender,
    required this.t,
    required this.text,
    required this.media,
    required this.reactions,
    required this.share,
    required this.type,
    required this.unsent,
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
  MediaDir(this.path, this.files);

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
