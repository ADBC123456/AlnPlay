/// Episode info parsed from a file name (+ optional parent-folder context).
///
/// Covers the naming conventions the danmaku PRD requires:
/// - `S01E01`, `S1E1` (season + episode)
/// - `第1集` / `第01话` / `第1話` (Chinese/Japanese counters)
/// - bare `01` (episode-only, needs folder context to be trusted)
/// - specials: `OVA`, `OAD`, `SP`, `Special`, plus their Chinese forms
///   (`OVA1`, `SP02`, `特别篇1`).
///
/// Purity: no imports, no IO — unit-testable and usable from isolates.
library;

import '../model/episode_title_classifier.dart';

/// How the episode number was found.
enum EpisodeSource {
  /// Not an episode (movie, standalone video, unknown).
  none,

  /// `S01E02` / `s1e2` / `1x02`.
  seasonEpisode,

  /// `第3集` / `第03話` / `EP3` / `E3` (episode only).
  episodeOnly,

  /// Bare `01.mkv` / `Show - 05.mkv` (needs folder context).
  bareNumber,

  /// `OVA` / `OAD` / `SP` / `Special` / `NCOP` … (special episode).
  special,
}

/// Kind of special episode for the danmu_api catalog mapping.
enum SpecialKind {
  /// `OVA` — Original Video Animation.
  ova,

  /// `OAD` — Original Animation Disc.
  oad,

  /// `SP` / `Special` / `特别篇` — TV special.
  special,

  /// Other recognized-but-unmapped specials (`NCOP`, `NCED`, `Menu`, `PV`…).
  other,
}

class EpisodeInfo {
  const EpisodeInfo({
    this.source = EpisodeSource.none,
    this.season = 0,
    this.episode = 0,
    this.special,
    this.specialIndex,
    this.seriesName,
  });

  /// How the episode number was found.
  final EpisodeSource source;

  /// Season number (1-based; 0 when absent). `S01E01` → 1.
  final int season;

  /// Episode number within the season (1-based; 0 when absent/special).
  final int episode;

  /// For [EpisodeSource.special]: which kind.
  final SpecialKind? special;

  /// For [EpisodeSource.special]: trailing index (`OVA2` → 2), else null.
  final int? specialIndex;

  /// Series name text before the episode marker, cleaned. Null when unknown.
  final String? seriesName;

  bool get isEpisode => source != EpisodeSource.none;

  /// True when this is a normal numbered episode (not a special).
  bool get isNumbered =>
      source == EpisodeSource.seasonEpisode ||
      source == EpisodeSource.episodeOnly ||
      source == EpisodeSource.bareNumber;

  @override
  String toString() =>
      'EpisodeInfo(${source.name}, S${season}E$episode, special=$special, '
      'series=$seriesName)';
}

class DanmakuEpisodeParser {
  DanmakuEpisodeParser._();

  /// `S01E02`, `s1e2` — season + episode.
  static final RegExp _seasonEpisode = RegExp(
    r'S(\d{1,2})\s*[Eº]\s*(\d{1,4})',
    caseSensitive: false,
  );

  /// `1x02` — season x episode (Jellyfin/Plex style).
  static final RegExp _seasonEpisodeX = RegExp(
    r'\b(\d{1,2})x(\d{1,4})\b',
    caseSensitive: false,
  );

  /// `第03集` / `第3话` / `第03話` — Chinese/Japanese counters.
  static final RegExp _cjkEpisode = RegExp(r'第\s*(\d{1,4})\s*[集话話]');

  /// `EP03`, `E03` — episode-only markers (English fansub style).
  /// The separator alternation is fully grouped with the marker: writing
  /// `(?:^|[sep]EP…)…` would let the `^` branch match EMPTY at position 0
  /// (alternation precedence), yielding a null group — the bug that made
  /// every EP-marker file parse as `none`.
  static final RegExp _epMarker = RegExp(
    r'(?:^|[\s\.\-\_\[])(?:EP?)\.?\s*(\d{1,4})(?=\b)',
    caseSensitive: false,
  );

  /// Bare trailing number: `Show - 05.mkv`, `Show 03`. Requires the number
  /// to be delimited by separators so `1080p` and mid-title numbers don't
  /// match.
  static final RegExp _bareNumber = RegExp(
    r'(?:^|[\s\.\-\_])((?:\d{1,4}))$',
  );

  /// Leading numeric first segment: `001.mkv`, `001 - Title`, `001_1080p`.
  /// Mirrors `ParsedFileName`'s leading rule so the library and danmaku agree
  /// on the episode number; `2 Broke Girls - 05` still uses the trailing rule.
  static final RegExp _leadingNumber = RegExp(
    r'^\s*[\[\(]?\s*(\d{1,4})\s*[\]\)]?(?=\s*$|\s*[-_.])',
  );

  static final RegExp _year = RegExp(r'\b(18|19|20)\d{2}\b');

  /// Special markers. Same grouping rule as [_epMarker]: the separator
  /// alternation must be a self-contained group before the marker kind
  /// groups, or the `^` branch matches empty and every kind group is null.
  static final RegExp _specialMarker = RegExp(
    r'(?:^|[\s\.\-\_\[])'
    r'((?:OVA|OAD|NCOP|NCED|NC|PV|CM|Menu|Preview)(\d{1,2})?'
    r'|(?:SP|Special|Specials)(\d{1,2})?'
    r'|(?:特别篇|特別篇|番外)(\d{1,2})?)'
    r'(?=$|[\s\.\-\_\]\d])',
    caseSensitive: false,
  );

  /// Parses [fileName]. When the file itself carries no season, [folderName]
  /// supplies the season (`Season 2`, `S02`, `第二季` folders) and series
  /// name context. Pass [trustedBareNumber] = false when the listing is a
  /// mixed movie folder — bare `01.mkv` is then not treated as an episode
  /// unless the folder name itself looks episodic.
  static EpisodeInfo parse(
    String fileName, {
    String? folderName,
    bool trustedBareNumber = true,
  }) {
    final base = _baseName(fileName);
    final name = _stripExtensionNoise(base);

    // A catalog title such as `第1集预告` contains a valid-looking episode
    // number, but it is promotional material. Classify it before all numbered
    // patterns so it can never collide with the full episode automatically.
    if (isDanmakuPromotionalEpisodeTitle(name)) {
      return EpisodeInfo(
        source: EpisodeSource.special,
        season: _seasonFromFolder(folderName),
        episode: 0,
        special: SpecialKind.other,
        seriesName: _seriesFromFolder(folderName),
      );
    }

    // 1) Season + episode: S01E02 / 1x02.
    final se =
        _seasonEpisode.firstMatch(name) ?? _seasonEpisodeX.firstMatch(name);
    if (se != null) {
      return EpisodeInfo(
        source: EpisodeSource.seasonEpisode,
        season: int.parse(se.group(1)!),
        episode: int.parse(se.group(2)!),
        seriesName: _seriesBefore(name, se.start),
      );
    }

    // 2) CJK counter: 第01集 / 第3話.
    final cjk = _cjkEpisode.firstMatch(name);
    if (cjk != null) {
      return EpisodeInfo(
        source: EpisodeSource.episodeOnly,
        season: _seasonFromFolder(folderName),
        episode: int.parse(cjk.group(1)!),
        seriesName:
            _seriesBefore(name, cjk.start) ?? _seriesFromFolder(folderName),
      );
    }

    // 3) Specials: OVA / OAD / SP / 特别篇 …
    final sp = _specialMarker.firstMatch(name);
    if (sp != null) {
      // New regex shape: group 1 = whole marker (incl. index), group 2/3 =
      // the optional trailing index of the marker alternatives.
      final idxGroup = sp.group(2) ?? sp.group(3);
      final kindText = sp.group(1) ?? '';
      return EpisodeInfo(
        source: EpisodeSource.special,
        season: _seasonFromFolder(folderName),
        episode: 0,
        special: _specialKind(kindText),
        specialIndex: idxGroup != null ? int.tryParse(idxGroup) : null,
        seriesName:
            _seriesBefore(name, sp.start) ?? _seriesFromFolder(folderName),
      );
    }

    // 4) EP03 / E03 markers.
    final ep = _epMarker.firstMatch(name);
    if (ep != null && ep.group(1) != null) {
      final epNumber = int.tryParse(ep.group(1)!);
      if (epNumber != null) {
        return EpisodeInfo(
          source: EpisodeSource.episodeOnly,
          season: _seasonFromFolder(folderName),
          episode: epNumber,
          seriesName:
              _seriesBefore(name, ep.start) ?? _seriesFromFolder(folderName),
        );
      }
    }

    // 5) Bare number: `01.mkv`, `Show - 05.mkv`. Only trusted when the
    // caller says the listing is episode-shaped (a season folder, a show
    // folder…) — in a mixed movie folder `01.mkv` is ambiguous.
    if (trustedBareNumber) {
      final leading = _leadingNumber.firstMatch(name);
      final leadingNumber = leading == null
          ? null
          : int.parse(leading.group(1)!);
      // A leading number next to a release year (`24.2016`, `9 (2009)`) is
      // a movie name, not an episode prefix.
      if (leadingNumber != null &&
          !(leadingNumber >= 1800 && leadingNumber <= 2099) &&
          !_year.hasMatch(name)) {
        final folderSeason = _seasonFromFolder(folderName);
        return EpisodeInfo(
          source: EpisodeSource.bareNumber,
          season: folderSeason == 0 ? 1 : folderSeason,
          episode: leadingNumber,
          seriesName: _seriesFromFolder(folderName),
        );
      }
      final bare = leading != null ? null : _bareNumber.firstMatch(name);
      if (bare != null) {
        final episodeNumber = int.parse(bare.group(1)!);
        final folderSeason = _seasonFromFolder(folderName);
        // A standalone four-digit year is overwhelmingly a movie or a
        // release year, not an episode. Keep the numeric rule useful for
        // `001`/`146` while avoiding `2024.mkv` false positives.
        if (episodeNumber >= 1800 && episodeNumber <= 2099) {
          return EpisodeInfo(
            season: folderSeason,
            seriesName:
                _seriesBefore(name, bare.start) ?? _seriesFromFolder(folderName),
          );
        }
        return EpisodeInfo(
          source: EpisodeSource.bareNumber,
          season: folderSeason == 0 ? 1 : folderSeason,
          episode: episodeNumber,
          seriesName:
              _seriesBefore(name, bare.start) ?? _seriesFromFolder(folderName),
        );
      }
    }

    return EpisodeInfo(
      season: _seasonFromFolder(folderName),
      seriesName: _seriesFromFolder(folderName),
    );
  }

  /// Season number carried by a folder name: `Season 2`, `S02`,
  /// `第二季` → 2; 0 when absent or the folder itself is an episode.
  static int _seasonFromFolder(String? folderName) {
    if (folderName == null || folderName.isEmpty) return 0;
    final f = _stripExtensionNoise(_baseName(folderName));
    final m =
        RegExp(r'\bS(\d{1,2})\b', caseSensitive: false).firstMatch(f) ??
        RegExp(r'Season\s*(\d{1,2})', caseSensitive: false).firstMatch(f) ??
        RegExp(r'第\s*(\d{1,2})\s*季').firstMatch(f) ??
        RegExp(r'^(\d{1,2})$').firstMatch(f);
    if (m != null) {
      final s = int.parse(m.group(1)!);
      return s > 0 ? s : 0;
    }
    final cjk = RegExp(r'第\s*([一二三四五六七八九十]{1,3})\s*季').firstMatch(f);
    if (cjk != null) return _cjkNumeral(cjk.group(1)!);
    return 0;
  }

  static String? _seriesFromFolder(String? folderName) {
    if (folderName == null || folderName.isEmpty) return null;
    final f = _stripExtensionNoise(_baseName(folderName));
    if (f.isEmpty) return null;
    return _clean(f);
  }

  /// Text before the matched marker, cleaned; null when empty.
  static String? _seriesBefore(String name, int matchStart) {
    if (matchStart <= 0) return null;
    final before = name.substring(0, matchStart);
    final cleaned = _clean(before);
    if (cleaned.isEmpty) return null;
    return cleaned;
  }

  /// Base name: last path segment (works for posix paths and URLs).
  static String _baseName(String s) {
    var t = s.trim();
    final q = t.indexOf('?');
    if (q >= 0) t = t.substring(0, q);
    final h = t.indexOf('#');
    if (h >= 0) t = t.substring(0, h);
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    final slash = t.lastIndexOf('/');
    return slash >= 0 ? t.substring(slash + 1) : t;
  }

  /// Drops the container extension (≤4 letters after the last dot) and
  /// percent-escapes so URL names parse.
  static String _stripExtensionNoise(String name) {
    var t = name.trim();
    try {
      if (t.contains('%')) t = Uri.decodeComponent(t);
    } catch (_) {}
    final dot = t.lastIndexOf('.');
    if (dot > 0) {
      final ext = t.substring(dot + 1);
      if (ext.length <= 4 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) {
        t = t.substring(0, dot);
      }
    }
    return t;
  }

  static String _clean(String s) {
    var t = s;
    // Trim dangling separators left by the marker split.
    t = t.replaceAll(RegExp(r'[\s\.\-\_\[\(\{]+$'), '');
    t = t.replaceAll(RegExp(r'^[\s\.\-\_\]\)\}]+'), '');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ');
    return t.trim();
  }

  static SpecialKind _specialKind(String text) {
    final t = text.toLowerCase();
    // `text` may carry a trailing index (`OVA2`), so match by prefix.
    if (t.startsWith('ova')) return SpecialKind.ova;
    if (t.startsWith('oad')) return SpecialKind.oad;
    if (t.startsWith('sp') ||
        t.startsWith('special') ||
        t.startsWith('特别篇') ||
        t.startsWith('特別篇') ||
        t.startsWith('番外')) {
      return SpecialKind.special;
    }
    return SpecialKind.other;
  }

  /// `二` → 2, `十` → 10, `十二` → 12 (folder names like `第二季`).
  static int _cjkNumeral(String s) {
    const digits = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (s == '十') return 10;
    final ten = s.indexOf('十');
    if (ten < 0) return digits[s] ?? 0;
    // `十几` → 10+n, `十N` → 10, `M十` → M*10, `M十N` → M*10+N.
    final before = ten > 0 ? (digits[s[ten - 1]] ?? 1) : 1;
    final after = ten + 1 < s.length ? (digits[s[ten + 1]] ?? 0) : 0;
    return before * 10 + after;
  }
}

/// One episode in a danmu_api anime catalog (`/api/v2/bangumi/{animeId}`).
///
/// IDs stay strings: the PRD requires numeric AND string episode/anime ids
/// to survive without forced int casts.
class DanmuCatalogEpisode {
  const DanmuCatalogEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.animeId,
    this.animeTitle,
    this.episodeNumber = 0,
    this.raw = const {},
  });

  final String episodeId;
  final String episodeTitle;
  final String? animeId;
  final String? animeTitle;

  /// Parsed episode number from the title when recognizable (0 when not).
  final int episodeNumber;

  /// The original JSON map (subset of PRD fields: episodeId, animeId,
  /// animeTitle, episodeTitle, shift, url…).
  final Map<String, dynamic> raw;

  /// Tolerant builder: accepts int/string ids and missing fields.
  static DanmuCatalogEpisode fromJson(Map<String, dynamic> json) {
    String idOf(Object? v) => v == null ? '' : '$v';
    final title = (json['episodeTitle'] ?? json['episode_title'] ?? '')
        .toString();
    return DanmuCatalogEpisode(
      episodeId: idOf(json['episodeId'] ?? json['episode_id']),
      episodeTitle: title,
      animeId: json['animeId'] != null || json['anime_id'] != null
          ? idOf(json['animeId'] ?? json['anime_id'])
          : null,
      animeTitle: (json['animeTitle'] ?? json['anime_title'])?.toString(),
      episodeNumber: _episodeNumberOf(title),
      raw: json,
    );
  }

  static final RegExp _titleEpisode = RegExp(
    r'(?:第\s*(\d{1,4})\s*[集话話]?)|(?:^|\b)(?:EP?|ep)\.?\s*(\d{1,4})(?:\b|$)',
    caseSensitive: false,
  );

  /// Extracts the leading/counter episode number from a catalog title
  /// (`第3集` → 3, `EP12 x` → 12, `12. Foo` → 12, `OVA` → 0).
  static int _episodeNumberOf(String title) {
    final t = title.trim();
    if (t.isEmpty) return 0;
    if (isDanmakuPromotionalEpisodeTitle(t)) return 0;
    final m = _titleEpisode.firstMatch(t);
    if (m != null) {
      final g = m.group(1) ?? m.group(2);
      if (g != null) return int.tryParse(g) ?? 0;
    }
    // `12. Something` / `12 - Something` / bare `12`.
    final lead = RegExp(r'^(\d{1,4})(?:\b)').firstMatch(t);
    if (lead != null) return int.tryParse(lead.group(1)!) ?? 0;
    return 0;
  }
}

/// Outcome of mapping one local video to the danmu_api catalog.
enum EpisodeMatchStatus {
  /// Mapped to exactly one catalog episode.
  mapped,

  /// The episode number has no entry in the catalog (缺集).
  missing,

  /// Multiple catalog entries claim the same episode number (重复).
  duplicate,

  /// No episode number could be parsed from the file name.
  unmatched,

  /// Special episode (OVA/OAD/SP): mapping is by title similarity only.
  special,
}

class EpisodeMatch {
  const EpisodeMatch._({
    required this.status,
    this.episode,
    this.candidates = const [],
  });

  final EpisodeMatchStatus status;

  /// The single mapped catalog entry ([EpisodeMatchStatus.mapped] only).
  final DanmuCatalogEpisode? episode;

  /// All same-number entries for duplicates, or the best title candidates
  /// for specials.
  final List<DanmuCatalogEpisode> candidates;

  static EpisodeMatch mappedEpisode(DanmuCatalogEpisode e) =>
      EpisodeMatch._(status: EpisodeMatchStatus.mapped, episode: e);

  static EpisodeMatch missing() =>
      const EpisodeMatch._(status: EpisodeMatchStatus.missing);

  static EpisodeMatch duplicate(List<DanmuCatalogEpisode> candidates) =>
      EpisodeMatch._(
        status: EpisodeMatchStatus.duplicate,
        candidates: candidates,
      );

  static EpisodeMatch unmatched() =>
      const EpisodeMatch._(status: EpisodeMatchStatus.unmatched);

  static EpisodeMatch special(List<DanmuCatalogEpisode> candidates) =>
      EpisodeMatch._(
        status: EpisodeMatchStatus.special,
        candidates: candidates,
      );
}

/// Maps local episode numbers onto a danmu_api episode catalog.
///
/// Rules (PRD "自动匹配与剧集映射"):
/// - 缺集 (missing): local number absent from the catalog → [EpisodeMatchStatus.missing].
/// - 重复集 (duplicate): several catalog episodes share the number →
///   [EpisodeMatchStatus.duplicate] (caller shows a picker; never silently
///   picks one).
/// - 无季数 (no season): files/folders without a season are season 1 by
///   convention; a multi-season catalog must instead be scoped by the
///   caller passing the right catalog (season-scoped animeId).
/// - 特殊集 (specials): OVA/OAD/SP never map by number — the caller matches
///   them against [EpisodeMatch.candidates] by title.
class DanmuEpisodeMapper {
  DanmuEpisodeMapper._();

  /// Indexes [catalog] by parsed episode number. Entries whose title parses
  /// to 0 (specials) are listed under [specialsOf].
  static Map<int, List<DanmuCatalogEpisode>> byNumber(
    List<DanmuCatalogEpisode> catalog,
  ) {
    final map = <int, List<DanmuCatalogEpisode>>{};
    for (final e in catalog) {
      if (isDanmakuPromotionalEpisodeTitle(e.episodeTitle)) continue;
      final n = e.episodeNumber;
      if (n <= 0) continue;
      (map[n] ??= []).add(e);
    }
    return map;
  }

  /// Catalog entries without a parsed number (OVA/SP openings…).
  static List<DanmuCatalogEpisode> specialsOf(
    List<DanmuCatalogEpisode> catalog,
  ) => catalog.where((e) => e.episodeNumber <= 0).toList();

  /// Maps [info] against the catalog. [season] resolves season-less files
  /// (0 → 1) so `Show - 05.mkv` inside `Season 2` still maps to E5 of the
  /// season-2 catalog the caller supplies.
  static EpisodeMatch match(
    EpisodeInfo info,
    List<DanmuCatalogEpisode> catalog, {
    int? season,
  }) {
    if (!info.isEpisode) return EpisodeMatch.unmatched();
    if (info.source == EpisodeSource.special) {
      return EpisodeMatch.special(specialsOf(catalog));
    }
    final number = info.episode;
    if (number <= 0) return EpisodeMatch.unmatched();
    final entries = byNumber(catalog)[number] ?? const [];
    if (entries.isEmpty) return EpisodeMatch.missing();
    if (entries.length == 1) return EpisodeMatch.mappedEpisode(entries.first);
    return EpisodeMatch.duplicate(entries);
  }

  /// Score for a special-episode title match: 0..100 (0 = no match).
  /// Used when a special must pick between OVA/SP entries by title.
  static int titleSimilarity(String fileNameTitle, String catalogTitle) {
    final a = _normalizeTitle(fileNameTitle);
    final b = _normalizeTitle(catalogTitle);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 100;
    if (b.contains(a) || a.contains(b)) return 70;
    return 0;
  }

  static String _normalizeTitle(String s) {
    var t = s.toLowerCase().trim();
    t = t.replaceAll(RegExp(r'[\s\.\-_\[\]\(\)]+'), ' ');
    return t.trim();
  }
}
