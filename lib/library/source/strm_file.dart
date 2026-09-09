import 'dart:convert';

class StrmFormatException implements Exception {
  const StrmFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses a single HTTP(S) target without ever requesting the target stream.
///
/// Version 1 deliberately accepts only HTTP(S). The STRM file itself remains
/// the stable library identity; its target is re-read immediately before play.
Uri parseExternalStrm(String text) {
  if (utf8.encode(text).length > 64 * 1024) {
    throw const StrmFormatException('STRM exceeds 64 KiB');
  }
  final normalized = text.startsWith('\uFEFF') ? text.substring(1) : text;
  Uri? target;
  for (final rawLine in normalized.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    if (target != null) {
      throw const StrmFormatException('STRM must contain exactly one URL');
    }
    final uri = Uri.tryParse(line);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(line) ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https')) {
      throw const StrmFormatException('STRM only supports HTTP(S) URLs');
    }
    if (uri.path.toLowerCase().endsWith('.strm')) {
      throw const StrmFormatException('Nested STRM targets are not supported');
    }
    target = uri;
  }
  if (target != null) return target;
  throw const StrmFormatException('STRM does not contain a playable URL');
}

bool isStrmFileName(String name) => name.toLowerCase().trim().endsWith('.strm');
