# Mangayomi Reader port plan

Source baseline: kodjodevf/mangayomi @ 698a32f45ce638264bbd7236dec24330e3933c64 (Apache-2.0)

- [ ] Port the complete reader preference surface into AnimeWitcher persistence.
- [ ] Add all Mangayomi reading modes and automatic dual-page behavior.
- [ ] Port reader display controls: scale, gaps, padding, background, filters, page number, fullscreen, keep-awake.
- [ ] Port interaction controls: tap zones, direction inversion, zoom behavior, keyboard/pointer navigation, auto-scroll.
- [ ] Port reader chrome: toggleable top/bottom controls, chapter navigation, page slider, quick settings.
- [ ] Integrate the reader settings entry into AnimeWitcher Settings.
- [ ] Keep AnimeWitcher MangaChapter/MangaPage, progress, offline manifest and Download V2 as the data adapter.
- [ ] Preserve third-party attribution and Apache-2.0 notice for the adapted reader implementation.
- [ ] Run focused reader tests, Manga contract suites, analyze and full test suite.
