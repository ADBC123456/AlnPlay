import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/scraper/episode_mapper.dart';

void main() {
  group('DanmakuEpisodeParser', () {
    test('numeric first segment is the episode, season from folder', () {
      for (final name in ['001.mkv', '001 - 标题.mkv', '001_1080p.mkv']) {
        final info = DanmakuEpisodeParser.parse(name);
        expect(info.source, EpisodeSource.bareNumber, reason: name);
        expect(info.season, 1, reason: name);
        expect(info.episode, 1, reason: name);
      }
      expect(DanmakuEpisodeParser.parse('001 - Part 2.mkv').episode, 1);
      for (final folder in ['Season 2', 'S02', '第二季', '第2季']) {
        final info = DanmakuEpisodeParser.parse('001.mkv', folderName: folder);
        expect(info.season, 2, reason: folder);
        expect(info.episode, 1, reason: folder);
      }
    });

    test('years, resolutions and middle numbers are not episodes', () {
      expect(DanmakuEpisodeParser.parse('2024.mkv').isEpisode, isFalse);
      expect(DanmakuEpisodeParser.parse('24.2016.1080p.mkv').isEpisode, isFalse);
      expect(DanmakuEpisodeParser.parse('Movie.1080p.mkv').isEpisode, isFalse);
      expect(
        DanmakuEpisodeParser.parse('Show 3 Title [WEB].mkv').isEpisode,
        isFalse,
      );
      expect(DanmakuEpisodeParser.parse('2 Broke Girls - 05.mkv').episode, 5);
    });

    test('S01E01 / S1E1 season+episode', () {
      final a = DanmakuEpisodeParser.parse('Show.S01E01.mkv');
      expect(a.source, EpisodeSource.seasonEpisode);
      expect(a.season, 1);
      expect(a.episode, 1);
      expect(a.seriesName, 'Show');

      final b = DanmakuEpisodeParser.parse('show s1e2.mp4');
      expect(b.season, 1);
      expect(b.episode, 2);
    });

    test('supports three and four digit SxxExxxx episodes', () {
      final threeDigits = DanmakuEpisodeParser.parse('凡人修仙传.S01E146.mp4');
      expect(threeDigits.season, 1);
      expect(threeDigits.episode, 146);

      final fourDigits = DanmakuEpisodeParser.parse('Long.Show.S02E1024.mkv');
      expect(fourDigits.season, 2);
      expect(fourDigits.episode, 1024);
    });

    test('1x04 Plex style', () {
      final a = DanmakuEpisodeParser.parse('Series.1x04.WEB-DL.mkv');
      expect(a.source, EpisodeSource.seasonEpisode);
      expect(a.season, 1);
      expect(a.episode, 4);
    });

    test('第1集 / 第03話 CJK counters', () {
      final a = DanmakuEpisodeParser.parse('某某剧 第1集.mkv');
      expect(a.source, EpisodeSource.episodeOnly);
      expect(a.episode, 1);
      expect(a.seriesName, '某某剧');

      final b = DanmakuEpisodeParser.parse('第03話 [1080p].mkv');
      expect(b.source, EpisodeSource.episodeOnly);
      expect(b.episode, 3);
    });

    test('EP03 marker', () {
      final a = DanmakuEpisodeParser.parse('Show EP03 [720p].mkv');
      expect(a.source, EpisodeSource.episodeOnly);
      expect(a.episode, 3);
    });

    test('bare 01.mkv needs trusted listing + folder season', () {
      final a = DanmakuEpisodeParser.parse('01.mkv', folderName: 'Season 2');
      expect(a.source, EpisodeSource.bareNumber);
      expect(a.season, 2);
      expect(a.episode, 1);

      // Untrusted context: ambiguous.
      final b = DanmakuEpisodeParser.parse('01.mkv', trustedBareNumber: false);
      expect(b.isEpisode, isFalse);
    });

    test('bare numeric names default to Season 1 and support release suffixes', () {
      for (final fileName in ['001.mkv', '001 - title.mkv', '001_1080p.mkv']) {
        final parsed = DanmakuEpisodeParser.parse(fileName);
        expect(parsed.source, EpisodeSource.bareNumber, reason: fileName);
        expect(parsed.season, 1, reason: fileName);
        expect(parsed.episode, 1, reason: fileName);
      }
    });

    test('bare release years are not treated as episodes', () {
      for (final fileName in ['2024.mkv', '2024_1080p.mkv']) {
        expect(
          DanmakuEpisodeParser.parse(fileName).isEpisode,
          isFalse,
          reason: fileName,
        );
      }
    });

    test('Show - 05.mkv bare trailing number', () {
      final a = DanmakuEpisodeParser.parse('Show - 05.mkv');
      expect(a.source, EpisodeSource.bareNumber);
      expect(a.season, 1);
      expect(a.episode, 5);
      expect(a.seriesName, 'Show');
    });

    test('OVA / OAD / SP specials with optional index', () {
      final ova = DanmakuEpisodeParser.parse('Show OVA.mkv');
      expect(ova.source, EpisodeSource.special);
      expect(ova.special, SpecialKind.ova);

      final ova2 = DanmakuEpisodeParser.parse('Show OVA2.mkv');
      expect(ova2.special, SpecialKind.ova);
      expect(ova2.specialIndex, 2);

      final oad = DanmakuEpisodeParser.parse('[Group] Show OAD.mp4');
      expect(oad.special, SpecialKind.oad);

      final sp = DanmakuEpisodeParser.parse('SP02.mp4');
      expect(sp.special, SpecialKind.special);
      expect(sp.specialIndex, 2);

      final special = DanmakuEpisodeParser.parse('Show Special.mkv');
      expect(special.special, SpecialKind.special);

      final cn = DanmakuEpisodeParser.parse('Show 特别篇1.mkv');
      expect(cn.source, EpisodeSource.special);
      expect(cn.special, SpecialKind.special);
    });

    test('preview titles never parse as numbered full episodes', () {
      for (final title in [
        '【bilibili1】 星海飞驰第1集预告',
        'Show S01E02 Preview',
        'Show EP03 Trailer',
        'Show 第4集先导片',
      ]) {
        final parsed = DanmakuEpisodeParser.parse(title);
        expect(parsed.source, EpisodeSource.special, reason: title);
        expect(parsed.episode, 0, reason: title);
      }
    });

    test('non-episodes stay non-episodes', () {
      // Resolution tokens must not parse as episode numbers.
      expect(DanmakuEpisodeParser.parse('1080p.mkv').isEpisode, isFalse);
      // Episode-in-title but movie-shaped name still parses the marker:
      // Gundam 00 S01E25 IS an episode.
      final g = DanmakuEpisodeParser.parse('Gundam 00 S01E25.mkv');
      expect(g.episode, 25);
      // 1917.mkv in a mixed movie folder is not trusted.
      expect(
        DanmakuEpisodeParser.parse(
          '1917.mkv',
          trustedBareNumber: false,
        ).isEpisode,
        isFalse,
      );
    });

    test('folder season applies to season-less files', () {
      final s02 = DanmakuEpisodeParser.parse('03.mkv', folderName: 'S02');
      expect(s02.season, 2);
      final cjk = DanmakuEpisodeParser.parse('03.mkv', folderName: '第二季');
      expect(cjk.season, 2);
      final twelve = DanmakuEpisodeParser.parse('03.mkv', folderName: '第十二季');
      expect(twelve.season, 12);
    });

    test('URL-encoded file names', () {
      final a = DanmakuEpisodeParser.parse('My%20Show%20S01E02.mkv');
      expect(a.season, 1);
      expect(a.episode, 2);
      expect(a.seriesName, 'My Show');
    });
  });

  group('DanmuCatalogEpisode', () {
    test('tolerates int and string ids', () {
      final a = DanmuCatalogEpisode.fromJson({
        'episodeId': 10001,
        'animeId': 100,
        'animeTitle': 'Show',
        'episodeTitle': '第1集',
      });
      expect(a.episodeId, '10001');
      expect(a.animeId, '100');
      expect(a.episodeNumber, 1);

      final b = DanmuCatalogEpisode.fromJson({
        'episodeId': 'str-42',
        'animeId': 'anime-9',
        'episodeTitle': 'EP2 起点',
      });
      expect(b.episodeId, 'str-42');
      expect(b.animeId, 'anime-9');
      expect(b.episodeNumber, 2);
    });

    test('parses episode numbers from common title shapes', () {
      int n(String t) => DanmuCatalogEpisode.fromJson({
        'episodeId': 1,
        'episodeTitle': t,
      }).episodeNumber;
      expect(n('第12集'), 12);
      expect(n('EP12 x'), 12);
      expect(n('12. Foo'), 12);
      expect(n('OVA'), 0);
      expect(n('【bilibili1】 星海飞驰第12集预告'), 0);
      expect(n(''), 0);
    });
  });

  group('DanmuEpisodeMapper', () {
    List<DanmuCatalogEpisode> catalog() => [
      DanmuCatalogEpisode.fromJson({'episodeId': 10001, 'episodeTitle': '第1集'}),
      DanmuCatalogEpisode.fromJson({
        'episodeId': '10002',
        'episodeTitle': 'EP2 起点',
      }),
      DanmuCatalogEpisode.fromJson({'episodeId': 10003, 'episodeTitle': '第3集'}),
      DanmuCatalogEpisode.fromJson({'episodeId': 10004, 'episodeTitle': 'OVA'}),
    ];

    test('mapped by number', () {
      final m = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('Show S01E03.mkv'),
        catalog(),
      );
      expect(m.status, EpisodeMatchStatus.mapped);
      expect(m.episode?.episodeId, '10003');
    });

    test('missing episode (缺集) when the number is absent', () {
      final m = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('Show S01E05.mkv'),
        catalog(),
      );
      expect(m.status, EpisodeMatchStatus.missing);
      expect(m.episode, isNull);
    });

    test('duplicate episodes (重复集) surface all candidates', () {
      final dup = [
        DanmuCatalogEpisode.fromJson({'episodeId': 1, 'episodeTitle': '第1集'}),
        DanmuCatalogEpisode.fromJson({
          'episodeId': 2,
          'episodeTitle': 'EP1 (recap)',
        }),
        DanmuCatalogEpisode.fromJson({'episodeId': 3, 'episodeTitle': '第2集'}),
      ];
      final m = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('第1集.mkv'),
        dup,
      );
      expect(m.status, EpisodeMatchStatus.duplicate);
      expect(m.candidates.map((c) => c.episodeId), ['1', '2']);
    });

    test('preview with the same number is ignored for automatic mapping', () {
      final entries = [
        DanmuCatalogEpisode.fromJson({
          'episodeId': 'preview-1',
          'episodeTitle': '【bilibili1】 星海飞驰第1集预告',
        }),
        DanmuCatalogEpisode.fromJson({
          'episodeId': 'full-1',
          'episodeTitle': '第1集 风起天南',
        }),
      ];
      final match = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('凡人修仙传.S01E01.mkv'),
        entries,
      );

      expect(match.status, EpisodeMatchStatus.mapped);
      expect(match.episode?.episodeId, 'full-1');
      expect(
        DanmuEpisodeMapper.specialsOf(entries).single.episodeId,
        'preview-1',
      );
    });

    test('preview-only catalog has no automatic numbered match', () {
      final match = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('凡人修仙传.S01E01.mkv'),
        [
          DanmuCatalogEpisode.fromJson({
            'episodeId': 'preview-1',
            'episodeTitle': '星海飞驰第1集预告',
          }),
        ],
      );

      expect(match.status, EpisodeMatchStatus.missing);
    });

    test('specials map by title candidates, never by number', () {
      final m = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('Show OVA.mkv'),
        catalog(),
      );
      expect(m.status, EpisodeMatchStatus.special);
      expect(m.candidates, hasLength(1));
      expect(m.candidates.first.episodeTitle, 'OVA');
    });

    test('unmatched when no episode marker exists', () {
      final m = DanmuEpisodeMapper.match(
        DanmakuEpisodeParser.parse('1080p.mkv', trustedBareNumber: false),
        catalog(),
      );
      expect(m.status, EpisodeMatchStatus.unmatched);
    });

    test('season-less local file maps through season fallback', () {
      // File `05.mkv` in `Season 2` folder → number 5; catalog has only E1-3
      // → missing (season scoping is the caller's catalog choice).
      final info = DanmakuEpisodeParser.parse('05.mkv', folderName: 'Season 2');
      final m = DanmuEpisodeMapper.match(info, catalog());
      expect(m.status, EpisodeMatchStatus.missing);
    });

    test('title similarity ranks special candidates', () {
      expect(DanmuEpisodeMapper.titleSimilarity('OVA', 'OVA'), 100);
      expect(DanmuEpisodeMapper.titleSimilarity('show ova', 'Show OVA'), 100);
      expect(DanmuEpisodeMapper.titleSimilarity('OVA', 'OVA 未放送'), 70);
      expect(DanmuEpisodeMapper.titleSimilarity('SP', 'OVA'), 0);
    });

    test('byNumber groups and specialsOf filters', () {
      final c = catalog();
      final byNum = DanmuEpisodeMapper.byNumber(c);
      expect(byNum.keys, [1, 2, 3]);
      expect(DanmuEpisodeMapper.specialsOf(c).first.episodeTitle, 'OVA');
    });
  });
}
