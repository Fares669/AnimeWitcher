import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/anizip_service.dart';
import 'package:skystream/core/utils/episode_label.dart';

void main() {
  group('isGenericEpisodeTitle', () {
    test('detects Arabic placeholders', () {
      expect(isGenericEpisodeTitle('الحلقة 16'), isTrue);
      expect(isGenericEpisodeTitle('حلقة 16'), isTrue);
      expect(isGenericEpisodeTitle('الحلقة 12 والأخيرة'), isTrue);
      expect(isGenericEpisodeTitle('حلقة 12 والاخيرة'), isTrue);
    });

    test('detects English placeholders', () {
      expect(isGenericEpisodeTitle('Episode 3'), isTrue);
      expect(isGenericEpisodeTitle('Ep. 3'), isTrue);
      expect(isGenericEpisodeTitle('Episode 3 Final'), isTrue);
    });

    test('keeps creative titles and standalone labels', () {
      expect(isGenericEpisodeTitle('رفقاء جدد'), isFalse);
      expect(isGenericEpisodeTitle('مترجم'), isFalse);
      expect(isGenericEpisodeTitle('مدبلج'), isFalse);
    });
  });

  group('isStandaloneEpisodeCatalog', () {
    test('detects مترجم/مدبلج-only catalogs', () {
      expect(
        isStandaloneEpisodeCatalog(const [
          (serverName: 'مترجم', name: 'مترجم'),
          (serverName: 'مدبلج', name: 'مدبلج'),
        ]),
        isTrue,
      );
      expect(
        isStandaloneEpisodeCatalog(const [
          (serverName: 'الحلقة 1', name: ''),
          (serverName: 'الحلقة 2', name: ''),
        ]),
        isFalse,
      );
      expect(isStandaloneEpisodeCatalog(const []), isFalse);
    });
  });

  group('isStandaloneEpisodeLabel', () {
    test('detects AnimeWitcher movie variant labels', () {
      expect(isStandaloneEpisodeLabel('مترجم'), isTrue);
      expect(isStandaloneEpisodeLabel('مدبلج'), isTrue);
      expect(isStandaloneEpisodeLabel('Dubbed'), isTrue);
      expect(isStandaloneEpisodeLabel('رفقاء جدد'), isFalse);
      expect(isStandaloneEpisodeLabel('الحلقة 1'), isFalse);
    });
  });

  group('hasFinalEpisodeSuffix', () {
    test('detects Arabic and English final markers', () {
      expect(hasFinalEpisodeSuffix('الحلقة 12 والأخيرة'), isTrue);
      expect(hasFinalEpisodeSuffix('حلقة 12 والاخيرة'), isTrue);
      expect(hasFinalEpisodeSuffix('Episode 12 (Final)'), isTrue);
      expect(hasFinalEpisodeSuffix('الحلقة 11'), isFalse);
      expect(hasFinalEpisodeSuffix('رفقاء جدد'), isFalse);
    });
  });

  group('realEpisodeTitle', () {
    test('returns empty for missing, generic, or standalone labels', () {
      expect(realEpisodeTitle(null), '');
      expect(realEpisodeTitle(''), '');
      expect(realEpisodeTitle('الحلقة 16'), '');
      expect(realEpisodeTitle('الحلقة 12 والأخيرة'), '');
      expect(realEpisodeTitle('مترجم'), '');
      expect(realEpisodeTitle('مدبلج'), '');
    });

    test('keeps creative titles', () {
      expect(realEpisodeTitle('رفقاء جدد'), 'رفقاء جدد');
    });
  });

  group('formatCatalogEpisodeBadge', () {
    test('keeps والأخيرة on latest-episodes poster badges', () {
      expect(
        formatCatalogEpisodeBadge(
          episode: 10,
          serverName: 'الحلقة 10 والأخيرة',
        ),
        'حلقة 10 والأخيرة',
      );
      expect(
        formatCatalogEpisodeBadge(
          episode: 10,
          isFinal: true,
        ),
        'حلقة 10 والأخيرة',
      );
      expect(
        formatCatalogEpisodeBadge(episode: 10),
        'حلقة 10',
      );
    });
  });

  group('formatEpisodePrimaryLabel', () {
    test('builds Arabic number and final suffix from generic server names', () {
      expect(
        formatEpisodePrimaryLabel(
          episode: 12,
          isArabic: true,
          serverName: 'الحلقة 12 والأخيرة',
          isFinal: true,
        ),
        'حلقة 12 والأخيرة',
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 11,
          isArabic: true,
          serverName: 'الحلقة 11',
        ),
        'حلقة 11',
      );
    });

    test('keeps مترجم/مدبلج exactly like AnimeWitcher', () {
      expect(
        formatEpisodePrimaryLabel(
          episode: 1,
          isArabic: true,
          serverName: 'مترجم',
        ),
        'مترجم',
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 2,
          isArabic: true,
          serverName: 'مدبلج',
        ),
        'مدبلج',
      );
    });

    test('keeps والأخيرة from isFinal even without serverName', () {
      expect(
        formatEpisodePrimaryLabel(episode: 12, isArabic: true, isFinal: true),
        'حلقة 12 والأخيرة',
      );
    });
  });

  group('formatEpisodeLabel', () {
    test('formats Arabic episode with title', () {
      expect(
        formatEpisodeLabel(episode: 2, isArabic: true, title: 'بداية جديدة'),
        'حلقة 2: بداية جديدة',
      );
    });

    test('omits generic title', () {
      expect(
        formatEpisodeLabel(episode: 2, isArabic: true, title: 'الحلقة 2'),
        'حلقة 2',
      );
      expect(
        formatEpisodeLabel(
          episode: 12,
          isArabic: true,
          title: 'الحلقة 12 والأخيرة',
          serverName: 'الحلقة 12 والأخيرة',
        ),
        'حلقة 12 والأخيرة',
      );
    });

    test('keeps final marker with creative title', () {
      expect(
        formatEpisodeLabel(
          episode: 12,
          isArabic: true,
          title: 'نهاية الرحلة',
          isFinal: true,
        ),
        'حلقة 12 والأخيرة: نهاية الرحلة',
      );
    });

    test('adds quality only when present', () {
      expect(
        formatEpisodeFileName(
          episode: 2,
          title: 'بداية جديدة',
          quality: '1080p',
        ),
        'حلقة 2: بداية جديدة (1080p)',
      );
      expect(
        formatEpisodeFileName(
          episode: 2,
          title: 'بداية جديدة',
          quality: '1080',
        ),
        'حلقة 2: بداية جديدة (1080p)',
      );
      expect(
        formatEpisodeFileName(episode: 2, title: 'بداية جديدة'),
        'حلقة 2: بداية جديدة',
      );
      expect(
        formatEpisodeFileName(
          episode: 2,
          title: 'بداية جديدة',
          quality: 'متعدد',
        ),
        'حلقة 2: بداية جديدة',
      );
    });

    test('formatDownloadQualityLabel always ends with p', () {
      expect(formatDownloadQualityLabel('1080'), '1080p');
      expect(formatDownloadQualityLabel('720p'), '720p');
      expect(formatDownloadQualityLabel('FHD'), '1080p');
      expect(formatDownloadQualityLabel('hd'), '720p');
      expect(formatDownloadQualityLabel('متعدد'), isNull);
      expect(formatDownloadQualityLabel(null), isNull);
    });

    test('keeps final suffix from serverName / isFinal for download filenames', () {
      expect(
        formatEpisodeFileName(
          episode: 12,
          title: 'الحلقة 12 والأخيرة',
          serverName: 'الحلقة 12 والأخيرة',
          isFinal: true,
        ),
        'حلقة 12 والأخيرة',
      );
      expect(
        formatEpisodeFileName(
          episode: 12,
          title: 'الحلقة 12 والأخيرة',
          serverName: 'الحلقة 12 والأخيرة',
          isFinal: true,
          quality: '720',
        ),
        'حلقة 12 والأخيرة (720p)',
      );
      expect(
        formatEpisodeFileName(
          episode: 12,
          isFinal: true,
        ),
        'حلقة 12 والأخيرة',
      );
      // Generic titles that already include والأخيرة still keep it even when
      // isFinal/serverName were not passed through.
      expect(
        formatEpisodeFileName(
          episode: 12,
          title: 'الحلقة 12 والأخيرة',
        ),
        'حلقة 12 والأخيرة',
      );
      expect(
        sanitizeDownloadFileName(
          formatEpisodeFileName(
            episode: 12,
            title: 'نهاية الرحلة',
            isFinal: true,
            quality: '1080',
          ),
        ),
        'حلقة 12 والأخيرة_ نهاية الرحلة (1080p)',
      );
    });

    test('isDownloadedEpisodeFileName matches final and quality variants', () {
      expect(isDownloadedEpisodeFileName('حلقة 12.mp4', 12), isTrue);
      expect(
        isDownloadedEpisodeFileName('حلقة 12 والأخيرة.mp4', 12),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName('حلقة 12 والأخيرة (720p).mkv', 12),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName('حلقة 12 (1080p).mp4', 12),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName('حلقة 12 والأخيرة_ نهاية الرحلة.mp4', 12),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'حلقة 12 والأخيرة_ نهاية الرحلة (720p).mp4',
          12,
        ),
        isTrue,
      );

      // Episode boundary: 12 must not match 120 / 1 / 2.
      expect(isDownloadedEpisodeFileName('حلقة 120.mp4', 12), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 1.mp4', 12), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 11 والأخيرة.mp4', 12), isFalse);

      // Trailing p marks quality — never treated as the episode number.
      expect(isDownloadedEpisodeFileName('حلقة 12 (720p).mp4', 720), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 12 (1080p).mp4', 1080), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 12 (720p).mp4', 7), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 12 (720p).mp4', 20), isFalse);
      // Bare parentheses without trailing p are not a quality marker.
      expect(isDownloadedEpisodeFileName('حلقة 12 (1080).mp4', 12), isFalse);
    });

    test('matches numberless standalone names like مترجم / مدبلج', () {
      expect(
        usesEpisodeDownloadFileName(episode: 0, serverName: 'مترجم'),
        isTrue,
      );
      expect(
        usesEpisodeDownloadFileName(episode: 0, serverName: 'مدبلج'),
        isTrue,
      );
      expect(usesEpisodeDownloadFileName(episode: 0, title: 'مترجم'), isTrue);
      expect(usesEpisodeDownloadFileName(episode: 0), isFalse);

      expect(
        formatEpisodeFileName(episode: 0, serverName: 'مترجم', quality: '1080'),
        'مترجم (1080p)',
      );
      expect(
        formatEpisodeFileName(episode: 0, serverName: 'مدبلج', quality: '720'),
        'مدبلج (720p)',
      );

      expect(
        isDownloadedEpisodeFileName(
          'مترجم.mp4',
          0,
          serverName: 'مترجم',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'مترجم (1080p).mp4',
          0,
          serverName: 'مترجم',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'مدبلج (720p).mkv',
          0,
          serverName: 'مدبلج',
        ),
        isTrue,
      );
      // Must not cross-match the other variant.
      expect(
        isDownloadedEpisodeFileName(
          'مدبلج (1080p).mp4',
          0,
          serverName: 'مترجم',
        ),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName(
          'مترجم (1080p).mp4',
          0,
          serverName: 'مدبلج',
        ),
        isFalse,
      );
    });

    test('normalizes NFD Arabic hamza so والأخيرة filenames match', () {
      // iOS often stores أ as ا + combining hamza (NFD).
      const nfdName =
          'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p).mp4';
      expect(
        isDownloadedEpisodeFileName(nfdName, 16),
        isTrue,
      );
      expect(
        sanitizeDownloadFileName(
          'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p)',
        ),
        'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p)',
      );
      expect(
        normalizeDownloadText('والأخيرة'),
        'والأخيرة',
      );
    });
  });

  group('episodeTitleForStorage', () {
    test('stores creative titles as-is', () {
      expect(
        episodeTitleForStorage(episode: 13, title: 'رفقاء جدد'),
        'رفقاء جدد',
      );
    });

    test('stores final and standalone markers when title is generic', () {
      expect(
        episodeTitleForStorage(
          episode: 12,
          title: 'الحلقة 12 والأخيرة',
          isFinal: true,
          serverName: 'الحلقة 12 والأخيرة',
        ),
        'حلقة 12 والأخيرة',
      );
      expect(
        episodeTitleForStorage(
          episode: 1,
          serverName: 'مترجم',
        ),
        'مترجم',
      );
      expect(
        episodeTitleForStorage(episode: 11, title: 'الحلقة 11'),
        '',
      );
    });
  });

  group('AniZip enrichment', () {
    test('preserves serverName and isFinal when only poster changes', () async {
      final source = [
        Episode(
          name: '',
          url: 'anime|ep12',
          season: 1,
          episode: 12,
          isFinal: true,
          serverName: 'الحلقة 12 والأخيرة',
          posterUrl: 'https://example.com/old.jpg',
        ),
      ];

      // No sync ids → normalize path, still must keep identity fields.
      final enriched = await AniZipService().enrichEpisodes(
        MultimediaItem(
          title: 'Test',
          url: 'https://example.com/anime',
          posterUrl: '',
          contentType: MultimediaContentType.anime,
        ),
        source,
      );

      expect(enriched, isNotNull);
      expect(enriched!.single.isFinal, isTrue);
      expect(enriched.single.serverName, 'الحلقة 12 والأخيرة');
      expect(
        formatEpisodePrimaryLabel(
          episode: enriched.single.episode,
          isArabic: true,
          isFinal: enriched.single.isFinal,
          serverName: enriched.single.serverName,
        ),
        'حلقة 12 والأخيرة',
      );
    });
  });

  group('continueWatching labels', () {
    test('does not duplicate creative title as primary and secondary', () {
      expect(
        continueWatchingPrimaryLabel(
          episode: 12,
          isArabic: true,
          episodeTitle: 'تتطور الزنزانة',
        ),
        'حلقة 12',
      );
      expect(
        continueWatchingSecondaryTitle(episodeTitle: 'تتطور الزنزانة'),
        'تتطور الزنزانة',
      );
    });

    test('keeps والأخيرة from serverName', () {
      expect(
        continueWatchingPrimaryLabel(
          episode: 12,
          isArabic: true,
          episodeTitle: 'تتطور الزنزانة',
          episodeServerName: 'الحلقة 12 والأخيرة',
        ),
        'حلقة 12 والأخيرة',
      );
      expect(
        continueWatchingSecondaryTitle(
          episodeTitle: 'تتطور الزنزانة',
          episodeServerName: 'الحلقة 12 والأخيرة',
        ),
        'تتطور الزنزانة',
      );
    });

    test('shows مترجم as primary without secondary', () {
      expect(
        continueWatchingPrimaryLabel(
          episode: 1,
          isArabic: true,
          episodeServerName: 'مترجم',
        ),
        'مترجم',
      );
      expect(
        continueWatchingSecondaryTitle(episodeServerName: 'مترجم'),
        '',
      );
    });
  });
}
