import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/anizip_service.dart';
import 'package:animewitcher/core/utils/episode_label.dart';

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

  group('latest-episodes poster badges', () {
    test('shows the server episode name unchanged', () {
      expect(latestEpisodesPosterBadge('الفيلم'), 'الفيلم');
      expect(latestEpisodesPosterBadge('الفلم'), 'الفلم');
      expect(latestEpisodesPosterBadge('حلقة 5'), 'حلقة 5');
      expect(latestEpisodesPosterBadge('حلقة 12 والأخيرة'), 'حلقة 12 والأخيرة');
      expect(
        latestEpisodesPosterBadge('الحلقة 10 والأخيرة'),
        'الحلقة 10 والأخيرة',
      );
      expect(latestEpisodesPosterBadge('مترجم'), 'مترجم');
      expect(latestEpisodesPosterBadge('مدبلج'), 'مدبلج');
      expect(latestEpisodesPosterBadge('  '), isNull);
      expect(latestEpisodesPosterBadge(null), isNull);
    });
  });

  group('formatEpisodePrimaryLabel', () {
    test('shows the server episode name unchanged', () {
      expect(
        formatEpisodePrimaryLabel(
          episode: 12,
          isArabic: true,
          serverName: 'الحلقة 12 والأخيرة',
          isFinal: true,
        ),
        'الحلقة 12 والأخيرة',
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 11,
          isArabic: true,
          serverName: 'الحلقة 11',
        ),
        'الحلقة 11',
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 1,
          isArabic: true,
          serverName: 'الفيلم',
        ),
        'الفيلم',
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 5,
          isArabic: true,
          serverName: 'حلقة 5',
        ),
        'حلقة 5',
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
        'الحلقة 2',
      );
      expect(
        formatEpisodeLabel(
          episode: 12,
          isArabic: true,
          title: 'الحلقة 12 والأخيرة',
          serverName: 'الحلقة 12 والأخيرة',
        ),
        'الحلقة 12 والأخيرة',
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

    test(
      'keeps final suffix from serverName / isFinal for download filenames',
      () {
        expect(
          formatEpisodeFileName(
            episode: 12,
            title: 'الحلقة 12 والأخيرة',
            serverName: 'الحلقة 12 والأخيرة',
            isFinal: true,
          ),
          'الحلقة 12 والأخيرة',
        );
        expect(
          formatEpisodeFileName(
            episode: 12,
            title: 'الحلقة 12 والأخيرة',
            serverName: 'الحلقة 12 والأخيرة',
            isFinal: true,
            quality: '720',
          ),
          'الحلقة 12 والأخيرة (720p)',
        );
        expect(
          formatEpisodeFileName(episode: 12, isFinal: true),
          'حلقة 12 والأخيرة',
        );
        // Generic titles that already include والأخيرة still keep it even when
        // isFinal/serverName were not passed through.
        expect(
          formatEpisodeFileName(episode: 12, title: 'الحلقة 12 والأخيرة'),
          'الحلقة 12 والأخيرة',
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
      },
    );

    test('isDownloadedEpisodeFileName matches the server name as-is', () {
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12.mp4',
          12,
          serverName: 'الحلقة 12',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 والأخيرة.mp4',
          12,
          serverName: 'الحلقة 12 والأخيرة',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 والأخيرة (720p).mkv',
          12,
          serverName: 'الحلقة 12 والأخيرة',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'حلقة 5 (1080p).mp4',
          5,
          serverName: 'حلقة 5',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName('الفيلم.mp4', 1, serverName: 'الفيلم'),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 والأخيرة_ نهاية الرحلة.mp4',
          12,
          serverName: 'الحلقة 12 والأخيرة',
          title: 'نهاية الرحلة',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 والأخيرة_ نهاية الرحلة (720p).mp4',
          12,
          serverName: 'الحلقة 12 والأخيرة',
          title: 'نهاية الرحلة',
        ),
        isTrue,
      );

      // No rewritten-name fallback: الحلقة ≠ حلقة, and الفيلم ≠ حلقة 1.
      expect(
        isDownloadedEpisodeFileName('حلقة 12.mp4', 12, serverName: 'الحلقة 12'),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName('الحلقة 12.mp4', 12, serverName: 'حلقة 12'),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName('حلقة 1.mp4', 1, serverName: 'الفيلم'),
        isFalse,
      );

      // Episode boundary: الحلقة 12 must not match 120 / 1 / 11.
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 120.mp4',
          12,
          serverName: 'الحلقة 12',
        ),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 1.mp4',
          12,
          serverName: 'الحلقة 12',
        ),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 11 والأخيرة.mp4',
          12,
          serverName: 'الحلقة 12 والأخيرة',
        ),
        isFalse,
      );

      // Trailing p marks quality — never treated as the episode number.
      expect(isDownloadedEpisodeFileName('حلقة 12 (720p).mp4', 720), isFalse);
      expect(isDownloadedEpisodeFileName('حلقة 12 (1080p).mp4', 1080), isFalse);
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 (720p).mp4',
          720,
          serverName: 'الحلقة 720',
        ),
        isFalse,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 (1080p).mp4',
          1080,
          serverName: 'الحلقة 1080',
        ),
        isFalse,
      );
      // Bare parentheses without trailing p are not a quality marker.
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة 12 (1080).mp4',
          12,
          serverName: 'الحلقة 12',
        ),
        isFalse,
      );
    });

    test('without a server name only the exact synthesized file matches', () {
      expect(isDownloadedEpisodeFileName('حلقة 12.mp4', 12), isTrue);
      expect(isDownloadedEpisodeFileName('حلقة 12 (1080p).mp4', 12), isTrue);
      expect(isDownloadedEpisodeFileName('حلقة 12 والأخيرة.mp4', 12), isFalse);
      expect(isDownloadedEpisodeFileName('الحلقة 12.mp4', 12), isFalse);
    });

    test('names numberless specials after their own label', () {
      expect(
        usesEpisodeDownloadFileName(episode: 0, serverName: 'الحلقة الخاصة'),
        isTrue,
      );
      expect(
        usesEpisodeDownloadFileName(episode: 0, serverName: 'OVA'),
        isTrue,
      );
      expect(
        usesEpisodeDownloadFileName(episode: 0, title: 'الحلقة الخاصة'),
        isTrue,
      );

      expect(
        formatEpisodeFileName(
          episode: 0,
          serverName: 'الحلقة الخاصة',
          quality: '1080',
        ),
        'الحلقة الخاصة (1080p)',
      );
      expect(
        formatEpisodeFileName(
          episode: 0,
          serverName: 'الحلقة الخاصة',
          title: 'مذكرات نامي',
        ),
        'الحلقة الخاصة: مذكرات نامي',
      );

      expect(
        isDownloadedEpisodeFileName(
          'الحلقة الخاصة.mp4',
          0,
          serverName: 'الحلقة الخاصة',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة الخاصة (1080p).mp4',
          0,
          serverName: 'الحلقة الخاصة',
        ),
        isTrue,
      );
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة الخاصة_ مذكرات نامي (720p).mkv',
          0,
          serverName: 'الحلقة الخاصة',
          title: 'مذكرات نامي',
        ),
        isTrue,
      );
      // The series-title filename is not this episode's file.
      expect(
        isDownloadedEpisodeFileName(
          'One Piece.mp4',
          0,
          serverName: 'الحلقة الخاصة',
        ),
        isFalse,
      );
      // Different specials must not cross-match.
      expect(
        isDownloadedEpisodeFileName(
          'الحلقة الخاصة 2.mp4',
          0,
          serverName: 'الحلقة الخاصة',
        ),
        isFalse,
      );
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
        isDownloadedEpisodeFileName('مترجم.mp4', 0, serverName: 'مترجم'),
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
        isDownloadedEpisodeFileName('مدبلج (720p).mkv', 0, serverName: 'مدبلج'),
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
      const nfdName = 'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p).mp4';
      expect(
        isDownloadedEpisodeFileName(
          nfdName,
          16,
          serverName: 'حلقة 16 والأخيرة',
          title: 'نتيجة معركة بريستيلا',
        ),
        isTrue,
      );
      expect(
        sanitizeDownloadFileName(
          'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p)',
        ),
        'حلقة 16 والأخيرة_ نتيجة معركة بريستيلا (480p)',
      );
      expect(normalizeDownloadText('والأخيرة'), 'والأخيرة');
    });
  });

  group('resolveEpisodeLabel', () {
    test('keeps numberless names instead of falling back to nothing', () {
      expect(
        formatEpisodeLabel(
          episode: 0,
          isArabic: true,
          serverName: 'الحلقة الخاصة',
        ),
        'الحلقة الخاصة',
      );
      expect(
        formatEpisodeLabel(episode: 0, isArabic: true, serverName: 'مترجم'),
        'مترجم',
      );
      expect(
        formatEpisodeLabel(episode: 0, isArabic: true, title: 'مذكرات نامي'),
        'مذكرات نامي',
      );
    });

    test('splits the primary line from the creative title', () {
      final label = resolveEpisodeLabel(
        episode: 12,
        isArabic: true,
        title: 'نهاية الرحلة',
        serverName: 'الحلقة 12 والأخيرة',
      );
      expect(label.primary, 'الحلقة 12 والأخيرة');
      expect(label.secondary, 'نهاية الرحلة');
      expect(label.full, 'الحلقة 12 والأخيرة: نهاية الرحلة');
      expect(label.isEmpty, isFalse);
    });

    test('builds numbered labels like the episode list', () {
      expect(
        formatEpisodeLabel(
          episode: 12,
          isArabic: true,
          serverName: 'الحلقة 12 والأخيرة',
          isFinal: true,
        ),
        'الحلقة 12 والأخيرة',
      );
      expect(
        formatEpisodeLabel(episode: 5, isArabic: true, title: 'رفقاء جدد'),
        'حلقة 5: رفقاء جدد',
      );
    });

    test('is empty only when the episode has no name at all', () {
      expect(formatEpisodeLabel(episode: 0, isArabic: true), '');
      expect(resolveEpisodeLabel(episode: 0, isArabic: true).isEmpty, isTrue);
      expect(
        formatEpisodeLabel(
          episode: 0,
          isArabic: true,
          serverName: '',
          title: '',
        ),
        '',
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
        'الحلقة 12 والأخيرة',
      );
      expect(episodeTitleForStorage(episode: 1, serverName: 'مترجم'), 'مترجم');
      expect(episodeTitleForStorage(episode: 11, title: 'الحلقة 11'), '');
    });

    test('keeps the label of numberless episodes', () {
      expect(
        episodeTitleForStorage(episode: 0, serverName: 'الحلقة الخاصة'),
        'الحلقة الخاصة',
      );
      expect(episodeTitleForStorage(episode: 0), '');
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
        'الحلقة 12 والأخيرة',
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
        continueWatchingSecondaryTitle(
          episode: 12,
          episodeTitle: 'تتطور الزنزانة',
        ),
        'تتطور الزنزانة',
      );
    });

    test('numberless rows show their stored label once', () {
      expect(
        continueWatchingPrimaryLabel(
          episode: 0,
          isArabic: true,
          episodeTitle: 'الحلقة الخاصة',
        ),
        'الحلقة الخاصة',
      );
      expect(
        continueWatchingSecondaryTitle(
          episode: 0,
          episodeTitle: 'الحلقة الخاصة',
        ),
        '',
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
        'الحلقة 12 والأخيرة',
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
      expect(continueWatchingSecondaryTitle(episodeServerName: 'مترجم'), '');
    });
  });
}
