// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'AnimeWitcher';

  @override
  String get languageName => 'العربية';

  @override
  String get home => 'الرئيسية';

  @override
  String get search => 'بحث';

  @override
  String get explore => 'استكشاف';

  @override
  String get library => 'المكتبة';

  @override
  String get settings => 'الإعدادات';

  @override
  String get updateAvailable => 'يتوفر تحديث';

  @override
  String get retry => 'إعادة المحاولة';

  @override
  String get factoryReset => 'إعادة ضبط المصنع';

  @override
  String get startupError => 'خطأ في بدء التشغيل';

  @override
  String get general => 'عام';

  @override
  String get appTheme => 'مظهر التطبيق';

  @override
  String get recordWatchHistory => 'سجل المشاهدة';

  @override
  String get defaultHomeScreen => 'الشاشة الرئيسية الافتراضية';

  @override
  String get player => 'المشغل';

  @override
  String get defaultPlayer => 'المشغل الافتراضي';

  @override
  String get leftGesture => 'إيماءة اليسار';

  @override
  String get rightGesture => 'إيماءة اليمين';

  @override
  String get doubleTapToSeek => 'النقر المزدوج للتقديم/التأخير';

  @override
  String get swipeToSeek => 'السحب للتقديم/التأخير';

  @override
  String get seekDuration => 'مدة القفز';

  @override
  String get bufferDepth => 'عمق التخزين المؤقت';

  @override
  String get defaultResizeMode => 'وضع تغيير الحجم الافتراضي';

  @override
  String get hardwareDecoding => 'فك ترميز العتاد';

  @override
  String get network => 'الشبكة';

  @override
  String get dnsOverHttps => 'DNS عبر HTTPS';

  @override
  String get dohProvider => 'مزود DoH';

  @override
  String get appData => 'بيانات التطبيق';

  @override
  String get developer => 'المطور';

  @override
  String get developerOptions => 'خيارات المطور';

  @override
  String get about => 'حول';

  @override
  String get version => 'الإصدار';

  @override
  String get enabled => 'مفعل';

  @override
  String get disabled => 'معطل';

  @override
  String get system => 'النظام';

  @override
  String get dark => 'داكن';

  @override
  String get light => 'فاتح';

  @override
  String get later => 'لاحقاً';

  @override
  String get updateNow => 'التحديث الآن';

  @override
  String get save => 'حفظ';

  @override
  String get cancel => 'إلغاء';

  @override
  String get close => 'إغلاق';

  @override
  String get delete => 'حذف';

  @override
  String get viewDetails => 'عرض التفاصيل';

  @override
  String get clearAll => 'مسح الكل';

  @override
  String get clearAllHistory => 'مسح كل السجل';

  @override
  String get all => 'الكل';

  @override
  String get none => 'لا شيء';

  @override
  String get confirmDownload => 'تأكيد التنزيل';

  @override
  String get downloadNow => 'تنزيل الآن';

  @override
  String get selectSource => 'اختر المصدر';

  @override
  String get downloadUnavailable => 'التنزيل غير متاح';

  @override
  String get selectAnotherSource => 'اختر مصدراً آخر';

  @override
  String get watchHistoryCleared => 'تم مسح سجل المشاهدة';

  @override
  String get downloadingUpdate => 'جارٍ تنزيل التحديث...';

  @override
  String errorPrefix(String message) {
    return 'خطأ: $message';
  }

  @override
  String updateAvailableTag(String tag) {
    return 'التحديث متاح: $tag';
  }

  @override
  String get selectProviderToStart => 'اختر مزوداً لبدء المشاهدة';

  @override
  String get tapExtensionIcon => 'اضغط على أيقونة الإضافة في الزاوية';

  @override
  String get continueWatching => 'مواصلة المشاهدة';

  @override
  String get noInternetConnection => 'لا يوجد اتصال بالإنترنت';

  @override
  String get siteNotReachable => 'لا يمكن الوصول إلى الموقع';

  @override
  String get checkConnectionOrDownloads =>
      'تحقق من اتصالك أو شاهد المحتوى الذي قمت بتنزيله.';

  @override
  String get tryVpnOrConnection =>
      'يرجى محاولة الوصول إلى الموقع باستخدام VPN أو التحقق من اتصالك بالإنترنت.';

  @override
  String errorDetails(String error) {
    return 'تفاصيل الخطأ: $error';
  }

  @override
  String get goToDownloads => 'الانتقال إلى التنزيلات';

  @override
  String get selectProvider => 'اختر المزود';

  @override
  String get searchHint => 'ابحث عن الانمي';

  @override
  String get searchFavoriteContent => 'ابحث عن محتواك المفضل';

  @override
  String get pressSearchOrEnter => 'اضغط على مفتاح البحث أو الإدخال للبدء';

  @override
  String get noResultsFound => 'لم يتم العثور على نتائج.';

  @override
  String get couldNotLoadTrending => 'تعذر تحميل العناصر الشائعة';

  @override
  String get popularMovies => 'أفلام شعبية';

  @override
  String get popularTVShows => 'مسلسلات تلفزيونية شعبية';

  @override
  String get newMovies => 'أفلام جديدة';

  @override
  String get newTVShows => 'مسلسلات تلفزيونية جديدة';

  @override
  String get featuredMovies => 'أفلام مختارة';

  @override
  String get featuredTVShows => 'مسلسلات تلفزيونية مختارة';

  @override
  String get lastVideosTVShows => 'آخر المسلسلات التلفزيونية';

  @override
  String get downloads => 'التنزيلات';

  @override
  String get downloadsTabCompleted => 'المكتملة';

  @override
  String get noDownloadsYet => 'لا توجد تنزيلات بعد';

  @override
  String get noCompletedDownloadsYet => 'لا توجد تنزيلات مكتملة';

  @override
  String get bookmarks => 'الإشارات المرجعية';

  @override
  String episodesCount(int count, int done) {
    return '$count حلقة • $done اكتملت';
  }

  @override
  String get deleteAllEpisodes => 'حذف جميع الحلقات';

  @override
  String confirmDeleteAllEpisodes(int count, String title) {
    return 'هل أنت متأكد أنك تريد حذف جميع الحلقات الـ $count من \"$title\" وملفاتها؟';
  }

  @override
  String get deleteAll => 'حذف الكل';

  @override
  String get completed => 'مكتمل';

  @override
  String get statusQueued => 'في الانتظار...';

  @override
  String get statusDownloading => 'جارٍ التنزيل...';

  @override
  String get statusFinished => 'انتهى';

  @override
  String get statusFailed => 'فشل';

  @override
  String get statusCanceled => 'ملغى';

  @override
  String get statusPaused => 'متوقف مؤقتاً';

  @override
  String get statusWaiting => 'انتظار...';

  @override
  String get fileNotFoundRemoving =>
      'الملف غير موجود على القرص. جارٍ إزالة السجل.';

  @override
  String get fileNotFound => 'الملف غير موجود';

  @override
  String get deleteDownload => 'حذف التنزيل';

  @override
  String get confirmDeleteDownload =>
      'هل أنت متأكد أنك تريد حذف هذا التنزيل وملفه؟';

  @override
  String get libraryEmpty => 'مكتبتك فارغة';

  @override
  String get language => 'اللغة';

  @override
  String get english => 'الإنجليزية';

  @override
  String get hindi => 'الهندية';

  @override
  String get kannada => 'الكانادية';

  @override
  String get unknown => 'غير معروف';

  @override
  String get recommended => 'موصى به';

  @override
  String get on => 'تشغيل';

  @override
  String get off => 'إيقاف';

  @override
  String get resetDataSubtitle =>
      'مسح الإعدادات وقاعدة البيانات، والحفاظ على الإضافات';

  @override
  String get factoryResetSubtitle => 'حذف جميع البيانات والإعدادات والإضافات';

  @override
  String get developerOptionsSubtitle => 'أدوات التصحيح والتشغيل المحلي';

  @override
  String get loading => 'جارٍ التحميل...';

  @override
  String get sec => 'ثانية';

  @override
  String get min => 'دقيقة';

  @override
  String get internalPlayer => 'مشغل داخلي (media_kit)';

  @override
  String get builtInPlayer => 'المشغل المدمج';

  @override
  String get customNotSet => 'مخصص (غير محدد)';

  @override
  String selectGesture(String side) {
    return 'اختر إيماءة $side';
  }

  @override
  String get left => 'اليسار';

  @override
  String get right => 'اليمين';

  @override
  String get selectSeekDuration => 'اختر مدة القفز';

  @override
  String get selectBufferDepth => 'اختر عمق التخزين المؤقت';

  @override
  String get subtitleSettings => 'إعدادات الترجمة';

  @override
  String size(int size) {
    return 'الحجم: $size';
  }

  @override
  String get background => 'الخلفية';

  @override
  String get customDohUrlLabel => 'رابط DoH مخصص';

  @override
  String get enterCustomDohUrl => 'أدخل رابط DoH الخاص بك';

  @override
  String get chooseTheme => 'اختر المظهر';

  @override
  String get resetDataDialogTitle => 'إعادة ضبط البيانات؟';

  @override
  String get resetDataDialogContent =>
      'سيؤدي هذا إلى مسح الإعدادات والمفضلات والسجل. لن يتم حذف إضافاتك المثبتة.';

  @override
  String get factoryResetDialogTitle => 'إعادة ضبط المصنع؟';

  @override
  String get factoryResetDialogContent =>
      'سيؤدي هذا إلى حذف كل شيء: المفضلات والسجل والإعدادات وجميع الإضافات. لا يمكن التراجع عن هذا الإجراء.';

  @override
  String get selectLanguage => 'اختر اللغة';

  @override
  String get synopsis => 'ملخص';

  @override
  String get noDescription => 'لا يوجد وصف متاح.';

  @override
  String get videoAlreadyDownloadedPrompt =>
      'هذا الفيديو تم تنزيله بالفعل. ماذا تريد أن تفعل؟';

  @override
  String get playNow => 'تشغيل الآن';

  @override
  String get deleteDownloadPrompt => 'حذف التنزيل؟';

  @override
  String get deleteDownloadConfirmation =>
      'هل أنت متأكد أنك تريد حذف هذا الملف؟ لا يمكن التراجع عن هذا الإجراء.';

  @override
  String get no => 'لا';

  @override
  String get yesDelete => 'نعم، حذف';

  @override
  String get downloadPaused => 'التنزيل متوقف مؤقتاً';

  @override
  String get downloading => 'جارٍ التنزيل';

  @override
  String get speed => 'السرعة';

  @override
  String get remaining => 'المتبقي';

  @override
  String get resume => 'استئناف';

  @override
  String get pause => 'إيقاف مؤقت';

  @override
  String get torrentContent => 'محتوى تورنت';

  @override
  String get audioTracks => 'المسارات الصوتية';

  @override
  String get noAudioTracks => 'لم يتم العثور على مسارات صوتية';

  @override
  String get subtitles => 'الترجمات';

  @override
  String get options => 'خيارات';

  @override
  String get noSubtitlesFound => 'لم يتم العثور على مسارات ترجمة';

  @override
  String get playbackSpeed => 'سرعة التشغيل';

  @override
  String get subtitleOptions => 'خيارات الترجمة';

  @override
  String get hlsSubtitleWarning =>
      'ملفات الترجمة الخارجية غير مدعومة على مشغل HLS النشط على هذه المنصة.';

  @override
  String get loadFromDevice => 'تحميل من الجهاز';

  @override
  String get syncDelay => 'المزامنة / التأخير';

  @override
  String get styleSettings => 'إعدادات النمط';

  @override
  String get searchOnline => 'بحث عبر الإنترنت (بحث عن الترجمة)';

  @override
  String get subtitleSync => 'مزامنة الترجمة';

  @override
  String get subtitleDelayWarning =>
      'تأخير الترجمة غير مدعوم من قبل محرك التشغيل النشط.';

  @override
  String get resetDelay => 'إعادة ضبط التأخير';

  @override
  String get subtitleStyles => 'أنماط الترجمة';

  @override
  String get mediaKitStylingWarning =>
      'تنسيق الترجمة متاح فقط على مشغل media_kit حالياً.';

  @override
  String get resetToDefault => 'إعادة الضبط للافتراضي';

  @override
  String get fontSize => 'حجم الخط';

  @override
  String get verticalPosition => 'الموضع العمودي';

  @override
  String get textColor => 'لون النص';

  @override
  String get backgroundColor => 'لون الخلفية';

  @override
  String get backgroundOpacity => 'شفافية الخلفية';

  @override
  String get subtitleSearch => 'البحث عن الترجمة';

  @override
  String get searchSubtitleNameHint => 'ابحث عن اسم الترجمة...';

  @override
  String get enterSearchSubtitlePrompt =>
      'أدخل اسماً أو ابحث للعثور على الترجمة.';

  @override
  String get noSubtitleResults => 'لم يتم العثور على نتائج. جرب استعلاماً آخر.';

  @override
  String get downloadingApplyingSubtitle => 'جارٍ تنزيل وتطبيق الترجمة...';

  @override
  String get failedToDownloadSubtitle => 'فشل تنزيل الترجمة.';

  @override
  String get failedToLoadSubtitles =>
      'فشل تحميل الترجمة. يرجى المحاولة مرة أخرى.';

  @override
  String get error => 'خطأ';

  @override
  String get ok => 'موافق';

  @override
  String get movies => 'الأفلام';

  @override
  String get series => 'المسلسلات';

  @override
  String get anime => 'الأنمي';

  @override
  String get liveStreams => 'البث المباشر';

  @override
  String get debug => 'تصحيح';

  @override
  String get invalidNavigation => 'انتقال غير صالح. يرجى العودة.';

  @override
  String get startOver => 'البدء من جديد';

  @override
  String get goBack => 'العودة';

  @override
  String get resolving => 'جارٍ الحل...';

  @override
  String get downloaded => 'تم التنزيل';

  @override
  String get download => 'تنزيل';

  @override
  String get debugOnlyFeature => 'هذه الميزة متاحة فقط في إصدارات التصحيح';

  @override
  String get streamUrl => 'رابط البث';

  @override
  String get play => 'تشغيل';

  @override
  String get verifyingSourceSize => 'جارٍ التحقق من المصدر والحجم...';

  @override
  String get fileSaveLocationNotification =>
      'سيتم حفظ الملف في مجلد التنزيلات الخاص بك.';

  @override
  String get resumingPlayback => 'استئناف التشغيل';

  @override
  String pausedAt(String time) {
    return 'توقف عند $time';
  }

  @override
  String resumesAutomatically(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'يستأنف تلقائياً خلال $count ثوانٍ',
      one: 'يستأنف تلقائياً خلال ثانية واحدة',
    );
    return '$_temp0';
  }

  @override
  String get resumeNow => 'استئناف الآن';

  @override
  String get playbackError => 'خطأ في التشغيل';

  @override
  String get confirmClearHistory =>
      'هل أنت متأكد أنك تريد إزالة جميع العناصر من سجل المشاهدة؟';

  @override
  String seasonWithNumber(Object number) {
    return 'الموسم $number';
  }

  @override
  String get starting => 'جارٍ البدء...';

  @override
  String percentWatched(int percent) {
    return '$percent% تمت مشاهدته';
  }

  @override
  String get sub => 'ترجمة';

  @override
  String get dub => 'دبلجة';

  @override
  String playEpisode(String label, Object season, Object episode) {
    return '$label م$season ح$episode';
  }

  @override
  String get debugTools => 'أدوات التصحيح';

  @override
  String get playLocalVideo => 'تشغيل فيديو محلي';

  @override
  String get playLocalVideoSubtitle => 'تشغيل أي فيديو من الجهاز';

  @override
  String get streamUrlSubtitle => 'التشغيل من رابط شبكة';

  @override
  String get streamTorrent => 'بث تورنت';

  @override
  String get streamTorrentSubtitle => 'اختر ملف تورنت محلي للتشغيل';

  @override
  String get enterVideoUrlHint =>
      'أدخل رابط الفيديو (http أو magnet أو غيرهما)';

  @override
  String get networkStream => 'بث الشبكة';

  @override
  String removedFromHistory(String title) {
    return 'تمت إزالة $title من السجل';
  }

  @override
  String get custom => 'مخصص';

  @override
  String get refreshingLiveStream => 'جارٍ تحديث البث المباشر...';

  @override
  String get removeFromHistory => 'إزالة من السجل';

  @override
  String get live => 'مباشر';

  @override
  String get volume => 'الصوت';

  @override
  String get brightness => 'السطوع';

  @override
  String get fit => 'ملاءمة';

  @override
  String get zoom => 'تغيير الحجم والتركيز';

  @override
  String get stretch => 'تمطيط';

  @override
  String titleWithParam(String title) {
    return 'العنوان: $title';
  }

  @override
  String sourceWithParam(String source) {
    return 'المصدر: $source';
  }

  @override
  String sizeWithParam(String size) {
    return 'الحجم: $size';
  }

  @override
  String usingInternalPlayerError(String error) {
    return 'خطأ: $error. يتم استخدام المشغل الداخلي.';
  }

  @override
  String playerNotDetected(String playerName) {
    return 'لم يتم اكتشاف $playerName. جارٍ بدء المشغل الداخلي.';
  }

  @override
  String seasonWithEpisodes(Object number, int count) {
    return 'الموسم $number ($count حلقة)';
  }

  @override
  String get cloudflare => 'Cloudflare';

  @override
  String get google => 'Google';

  @override
  String get adguard => 'AdGuard';

  @override
  String get dnsWatch => 'DNS.Watch';

  @override
  String get quad9 => 'Quad9';

  @override
  String get dnsSb => 'DNS.SB';

  @override
  String get canadianShield => 'Canadian Shield';

  @override
  String get tmdb => 'TMDB';

  @override
  String selectSourceForPlayer(String playerName) {
    return 'اختر المصدر لـ $playerName';
  }

  @override
  String get noPluginsInstalled => 'لا توجد إضافات مثبتة';

  @override
  String get availableSources => 'المصادر المتاحة';

  @override
  String get seasons => 'المواسم';

  @override
  String get episodes => 'الحلقات';

  @override
  String get selectSourceToPlay =>
      'يرجى اختيار مصدر من \'المصادر المتاحة\' أعلاه للتشغيل.';

  @override
  String episodeCountOnly(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count حلقات',
      one: 'حلقة واحدة',
    );
    return '$_temp0';
  }

  @override
  String get noEpisodesFound => 'لم يتم العثور على حلقات';

  @override
  String get local => 'محلي';

  @override
  String get remote => 'عن بعد';

  @override
  String get torrent => 'تورنت';

  @override
  String get unlock => 'فتح القفل';

  @override
  String get lock => 'قفل';

  @override
  String get sources => 'المصادر';

  @override
  String get tracks => 'المسارات';

  @override
  String get content => 'المحتوى';

  @override
  String get stats => 'الإحصائيات';

  @override
  String get resize => 'تغيير الحجم';

  @override
  String get next => 'التالي';

  @override
  String get pip => 'صورة داخل صورة';

  @override
  String get pipUnavailable => 'تعذر تفعيل صورة داخل صورة على هذا الجهاز';

  @override
  String get rotate => 'تدوير';

  @override
  String get windowed => 'نوافذ';

  @override
  String get fullscreen => 'ملء الشاشة';

  @override
  String get movieDetails => 'تفاصيل الفيلم';

  @override
  String get showDetails => 'عرض التفاصيل';

  @override
  String get tagline => 'شعار';

  @override
  String get status => 'الحالة';

  @override
  String get releaseDate => 'تاريخ الإصدار';

  @override
  String get firstAirDate => 'تاريخ أول عرض';

  @override
  String get originalLanguage => 'اللغة الأصلية';

  @override
  String get originCountry => 'بلد المنشأ';

  @override
  String get budgetLabel => 'الميزانية';

  @override
  String get revenueLabel => 'الإيرادات';

  @override
  String get paused => 'متوقف';

  @override
  String get watched => 'تمت مشاهدته';

  @override
  String get watching => 'مشاهدة الآن';

  @override
  String get lastWatched => 'آخر مشاهدة';

  @override
  String get movie => 'فيلم';

  @override
  String get tvShow => 'مسلسل تلفزيوني';

  @override
  String get failedToLoadContent => 'فشل تحميل المحتوى';

  @override
  String get director => 'المخرج';

  @override
  String get creator => 'المبتكر';

  @override
  String get showMore => 'عرض المزيد';

  @override
  String get showLess => 'عرض أقل';

  @override
  String get viewAll => 'عرض الكل';

  @override
  String seasonsCount(int count) {
    return '$count مواسم';
  }

  @override
  String get noInternetError => 'لا يوجد اتصال بالإنترنت';

  @override
  String get timeoutError => 'انتهت مهلة الطلب. يرجى المحاولة مرة أخرى.';

  @override
  String get serverError => 'خطأ في الخادم. يرجى المحاولة مرة أخرى لاحقاً.';

  @override
  String get contentNotFoundError => 'المحتوى غير موجود.';

  @override
  String get accessDeniedError =>
      'تم رفض الوصول. تحقق من بيانات الاعتماد الخاصة بك.';

  @override
  String get serviceUnavailableError =>
      'الخادم غير متاح. حاول مرة أخرى لاحقاً.';

  @override
  String get generalError => 'حدث خطأ ما. يرجى المحاولة مرة أخرى.';

  @override
  String get skip => 'تخطي';

  @override
  String get goLive => 'البث المباشر';

  @override
  String get dismiss => 'إغلاق';

  @override
  String get nextUp => 'التالي';

  @override
  String sourceAttempt(int index, int total) {
    return 'المصدر $index من $total';
  }

  @override
  String get trying => 'محاولة';

  @override
  String get failed => 'فشل';

  @override
  String get selected => 'مختار';

  @override
  String get playing => 'تشغيل';

  @override
  String get pending => 'قيد الانتظار';

  @override
  String get discord => 'Discord';

  @override
  String get discordSubtitle => 'انضم إلى خادمنا';

  @override
  String get telegram => 'Telegram';

  @override
  String get telegramSubtitle => 'انضم إلى قناتنا';

  @override
  String developedBy(String name) {
    return 'تم التطوير بواسطة $name';
  }

  @override
  String playEpisodeOnly(String label, int episode) {
    return '$label حلقة $episode';
  }

  @override
  String get wifiQualityPreference => 'تفضيل جودة الواي فاي';

  @override
  String get mobileQualityPreference => 'تفضيل جودة الهاتف المحمول';

  @override
  String get anyNoPreference => 'أي نوع (لا يوجد تفضيل)';

  @override
  String get subtitleAccounts => 'حسابات الترجمة';

  @override
  String get notLoggedIn => 'غير مسجّل الدخول';

  @override
  String loggedInAs(String username) {
    return 'تم تسجيل الدخول باسم $username';
  }

  @override
  String get apiKeyConfigured => 'تم تكوين مفتاح API';

  @override
  String get keyNotSet => 'لم يتم تعيين المفتاح';

  @override
  String get testConnection => 'اختبار الاتصال';

  @override
  String get connectedSuccessfully => 'تم الاتصال بنجاح';

  @override
  String get connectionFailed => 'فشل الاتصال';

  @override
  String get username => 'اسم المستخدم';

  @override
  String get password => 'كلمة المرور';

  @override
  String get noAccountRegister => 'ليس لديك حساب؟ سجل هنا';

  @override
  String get apiKey => 'مفتاح API';

  @override
  String get email => 'البريد الإلكتروني';

  @override
  String get fetchMyApiKey => 'جلب مفتاح API الخاص بي';

  @override
  String get keyVerified => 'تم التحقق من المفتاح';

  @override
  String get invalidApiKey => 'مفتاح API غير صالح';

  @override
  String get openSubtitlesAuthSubtitle =>
      'أدخل بيانات اعتماد حسابك للحصول على حدود أعلى وترجمات خالية من الإعلانات.';

  @override
  String get subDlAuthSubtitle =>
      'أدخل مفتاح SubDL API الخاص بك مباشرة، أو احصل عليه باستخدام بيانات اعتماد حسابك أدناه.';

  @override
  String get orFetchViaAccount => 'أو الجلب عبر الحساب';

  @override
  String get subSourceAuthSubtitle =>
      'يعمل SubSource تلقائياً، ولكن يمكنك إضافة مفتاح API رسمي شخصي لتجاوز الافتراضي للحصول على موثوقية أفضل.';

  @override
  String get apiKeyOptionalOverride => 'مفتاح API (تجاوز اختياري)';

  @override
  String get enterKeyToOverrideDefault => 'أدخل المفتاح لتجاوز الافتراضي';

  @override
  String get getApiKeyFromProfile =>
      'احصل على مفتاح API الخاص بك من ملف SubSource الشخصي';

  @override
  String get qualityNotGuaranteed =>
      'الجودة غير مضمونة. يتم فرز المصادر حسب التفضيل، ولكن التشغيل يعتمد على ما يقدمه المزود بالفعل.';

  @override
  String get keepSourcesOriginalOrder => 'الحفاظ على المصادر في ترتيبها الأصلي';

  @override
  String get openLink => 'فتح الرابط';

  @override
  String get openSubtitles => 'OpenSubtitles';

  @override
  String get subDl => 'SubDL';

  @override
  String get subSource => 'SubSource';

  @override
  String get diagnostics => 'التشخيصات';

  @override
  String get viewLogs => 'عرض السجلات';

  @override
  String get viewLogsSubtitle => 'عرض نشاط التطبيق والأخطاء';

  @override
  String get clearCache => 'مسح ذاكرة الصور والفيديو المؤقتة';

  @override
  String get clearCacheSubtitle =>
      'تحرير مساحة التخزين المستخدمة للصور وملفات الفيديو المؤقتة';

  @override
  String get clearCacheDialogTitle => 'مسح الذاكرة المؤقتة؟';

  @override
  String get clearCacheDialogContent =>
      'سيؤدي هذا إلى حذف الصور وملفات الفيديو المؤقتة. لن تتأثر إعداداتك أو سجل المشاهدة أو الإضافات.';

  @override
  String get clearCacheNow => 'مسح الذاكرة المؤقتة';

  @override
  String get cacheCleared => 'تم مسح الذاكرة المؤقتة';

  @override
  String get calculating => 'جارٍ الحساب…';

  @override
  String get playerControls => 'عناصر تحكم المشغل';

  @override
  String get showPip => 'زر صورة داخل صورة';

  @override
  String get showResize => 'زر تغيير الحجم';

  @override
  String get showRotate => 'زر التدوير';

  @override
  String get showPlaybackSpeed => 'زر سرعة التشغيل';

  @override
  String get showEpisodes => 'زر الحلقات';

  @override
  String get playerControlsSubtitle =>
      'إظهار أزرار التحكم في المشغل أو إخفاؤها';

  @override
  String get relatedAnime => 'ذات صلة';

  @override
  String get accounts => 'الحسابات';

  @override
  String get exploreAnime => 'استكشاف الأنمي';

  @override
  String get exploreMovies => 'استكشاف الأفلام';

  @override
  String get skipIntro => 'تخطي المقدمة';

  @override
  String get skipOutro => 'تخطي النهاية';

  @override
  String get skipRecap => 'تخطي الملخص السابق';

  @override
  String get titlePosition => 'موضع العنوان';

  @override
  String get titlePositionBelowPoster => 'أسفل الملصق';

  @override
  String get titlePositionInsidePoster => 'داخل الملصق';

  @override
  String get upNext => 'التالي';
}
