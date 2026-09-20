import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('ar')];

  /// No description provided for @appTitle.
  ///
  /// In ar, this message translates to:
  /// **'AnimeWitcher'**
  String get appTitle;

  /// No description provided for @languageName.
  ///
  /// In ar, this message translates to:
  /// **'العربية'**
  String get languageName;

  /// No description provided for @home.
  ///
  /// In ar, this message translates to:
  /// **'الرئيسية'**
  String get home;

  /// No description provided for @search.
  ///
  /// In ar, this message translates to:
  /// **'بحث'**
  String get search;

  /// No description provided for @explore.
  ///
  /// In ar, this message translates to:
  /// **'استكشاف'**
  String get explore;

  /// No description provided for @library.
  ///
  /// In ar, this message translates to:
  /// **'المكتبة'**
  String get library;

  /// No description provided for @settings.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات'**
  String get settings;

  /// No description provided for @updateAvailable.
  ///
  /// In ar, this message translates to:
  /// **'يتوفر تحديث'**
  String get updateAvailable;

  /// No description provided for @retry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retry;

  /// No description provided for @factoryReset.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط المصنع'**
  String get factoryReset;

  /// No description provided for @startupError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ في بدء التشغيل'**
  String get startupError;

  /// No description provided for @general.
  ///
  /// In ar, this message translates to:
  /// **'عام'**
  String get general;

  /// No description provided for @appTheme.
  ///
  /// In ar, this message translates to:
  /// **'مظهر التطبيق'**
  String get appTheme;

  /// No description provided for @recordWatchHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل المشاهدة'**
  String get recordWatchHistory;

  /// No description provided for @defaultHomeScreen.
  ///
  /// In ar, this message translates to:
  /// **'الشاشة الرئيسية الافتراضية'**
  String get defaultHomeScreen;

  /// No description provided for @player.
  ///
  /// In ar, this message translates to:
  /// **'المشغل'**
  String get player;

  /// No description provided for @defaultPlayer.
  ///
  /// In ar, this message translates to:
  /// **'المشغل الافتراضي'**
  String get defaultPlayer;

  /// No description provided for @leftGesture.
  ///
  /// In ar, this message translates to:
  /// **'إيماءة اليسار'**
  String get leftGesture;

  /// No description provided for @rightGesture.
  ///
  /// In ar, this message translates to:
  /// **'إيماءة اليمين'**
  String get rightGesture;

  /// No description provided for @doubleTapToSeek.
  ///
  /// In ar, this message translates to:
  /// **'النقر المزدوج للتقديم/التأخير'**
  String get doubleTapToSeek;

  /// No description provided for @swipeToSeek.
  ///
  /// In ar, this message translates to:
  /// **'السحب للتقديم/التأخير'**
  String get swipeToSeek;

  /// No description provided for @seekDuration.
  ///
  /// In ar, this message translates to:
  /// **'مدة القفز'**
  String get seekDuration;

  /// No description provided for @bufferDepth.
  ///
  /// In ar, this message translates to:
  /// **'عمق التخزين المؤقت'**
  String get bufferDepth;

  /// No description provided for @defaultResizeMode.
  ///
  /// In ar, this message translates to:
  /// **'وضع تغيير الحجم الافتراضي'**
  String get defaultResizeMode;

  /// No description provided for @hardwareDecoding.
  ///
  /// In ar, this message translates to:
  /// **'فك ترميز العتاد'**
  String get hardwareDecoding;

  /// No description provided for @network.
  ///
  /// In ar, this message translates to:
  /// **'الشبكة'**
  String get network;

  /// No description provided for @dnsOverHttps.
  ///
  /// In ar, this message translates to:
  /// **'DNS عبر HTTPS'**
  String get dnsOverHttps;

  /// No description provided for @dohProvider.
  ///
  /// In ar, this message translates to:
  /// **'مزود DoH'**
  String get dohProvider;

  /// No description provided for @appData.
  ///
  /// In ar, this message translates to:
  /// **'بيانات التطبيق'**
  String get appData;

  /// No description provided for @developer.
  ///
  /// In ar, this message translates to:
  /// **'المطور'**
  String get developer;

  /// No description provided for @developerOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات المطور'**
  String get developerOptions;

  /// No description provided for @about.
  ///
  /// In ar, this message translates to:
  /// **'حول'**
  String get about;

  /// No description provided for @version.
  ///
  /// In ar, this message translates to:
  /// **'الإصدار'**
  String get version;

  /// No description provided for @enabled.
  ///
  /// In ar, this message translates to:
  /// **'مفعل'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In ar, this message translates to:
  /// **'معطل'**
  String get disabled;

  /// No description provided for @system.
  ///
  /// In ar, this message translates to:
  /// **'النظام'**
  String get system;

  /// No description provided for @dark.
  ///
  /// In ar, this message translates to:
  /// **'داكن'**
  String get dark;

  /// No description provided for @light.
  ///
  /// In ar, this message translates to:
  /// **'فاتح'**
  String get light;

  /// No description provided for @later.
  ///
  /// In ar, this message translates to:
  /// **'لاحقاً'**
  String get later;

  /// No description provided for @updateNow.
  ///
  /// In ar, this message translates to:
  /// **'التحديث الآن'**
  String get updateNow;

  /// No description provided for @save.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get close;

  /// No description provided for @delete.
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get delete;

  /// No description provided for @viewDetails.
  ///
  /// In ar, this message translates to:
  /// **'عرض التفاصيل'**
  String get viewDetails;

  /// No description provided for @clearAll.
  ///
  /// In ar, this message translates to:
  /// **'مسح الكل'**
  String get clearAll;

  /// No description provided for @clearAllHistory.
  ///
  /// In ar, this message translates to:
  /// **'مسح كل السجل'**
  String get clearAllHistory;

  /// No description provided for @all.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get all;

  /// No description provided for @none.
  ///
  /// In ar, this message translates to:
  /// **'لا شيء'**
  String get none;

  /// No description provided for @confirmDownload.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد التنزيل'**
  String get confirmDownload;

  /// No description provided for @downloadNow.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل الآن'**
  String get downloadNow;

  /// No description provided for @selectSource.
  ///
  /// In ar, this message translates to:
  /// **'اختر المصدر'**
  String get selectSource;

  /// No description provided for @downloadUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'التنزيل غير متاح'**
  String get downloadUnavailable;

  /// No description provided for @selectAnotherSource.
  ///
  /// In ar, this message translates to:
  /// **'اختر مصدراً آخر'**
  String get selectAnotherSource;

  /// No description provided for @watchHistoryCleared.
  ///
  /// In ar, this message translates to:
  /// **'تم مسح سجل المشاهدة'**
  String get watchHistoryCleared;

  /// No description provided for @downloadingUpdate.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تنزيل التحديث...'**
  String get downloadingUpdate;

  /// No description provided for @errorPrefix.
  ///
  /// In ar, this message translates to:
  /// **'خطأ: {message}'**
  String errorPrefix(String message);

  /// No description provided for @updateAvailableTag.
  ///
  /// In ar, this message translates to:
  /// **'التحديث متاح: {tag}'**
  String updateAvailableTag(String tag);

  /// No description provided for @selectProviderToStart.
  ///
  /// In ar, this message translates to:
  /// **'اختر مزوداً لبدء المشاهدة'**
  String get selectProviderToStart;

  /// No description provided for @tapExtensionIcon.
  ///
  /// In ar, this message translates to:
  /// **'اضغط على أيقونة الإضافة في الزاوية'**
  String get tapExtensionIcon;

  /// No description provided for @continueWatching.
  ///
  /// In ar, this message translates to:
  /// **'مواصلة المشاهدة'**
  String get continueWatching;

  /// No description provided for @noInternetConnection.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد اتصال بالإنترنت'**
  String get noInternetConnection;

  /// No description provided for @siteNotReachable.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن الوصول إلى الموقع'**
  String get siteNotReachable;

  /// No description provided for @checkConnectionOrDownloads.
  ///
  /// In ar, this message translates to:
  /// **'تحقق من اتصالك أو شاهد المحتوى الذي قمت بتنزيله.'**
  String get checkConnectionOrDownloads;

  /// No description provided for @tryVpnOrConnection.
  ///
  /// In ar, this message translates to:
  /// **'يرجى محاولة الوصول إلى الموقع باستخدام VPN أو التحقق من اتصالك بالإنترنت.'**
  String get tryVpnOrConnection;

  /// No description provided for @errorDetails.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الخطأ: {error}'**
  String errorDetails(String error);

  /// No description provided for @goToDownloads.
  ///
  /// In ar, this message translates to:
  /// **'الانتقال إلى التنزيلات'**
  String get goToDownloads;

  /// No description provided for @selectProvider.
  ///
  /// In ar, this message translates to:
  /// **'اختر المزود'**
  String get selectProvider;

  /// No description provided for @searchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن الانمي'**
  String get searchHint;

  /// No description provided for @searchFavoriteContent.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن محتواك المفضل'**
  String get searchFavoriteContent;

  /// No description provided for @pressSearchOrEnter.
  ///
  /// In ar, this message translates to:
  /// **'اضغط على مفتاح البحث أو الإدخال للبدء'**
  String get pressSearchOrEnter;

  /// No description provided for @noResultsFound.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على نتائج.'**
  String get noResultsFound;

  /// No description provided for @couldNotLoadTrending.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل العناصر الشائعة'**
  String get couldNotLoadTrending;

  /// No description provided for @popularMovies.
  ///
  /// In ar, this message translates to:
  /// **'أفلام شعبية'**
  String get popularMovies;

  /// No description provided for @popularTVShows.
  ///
  /// In ar, this message translates to:
  /// **'مسلسلات تلفزيونية شعبية'**
  String get popularTVShows;

  /// No description provided for @newMovies.
  ///
  /// In ar, this message translates to:
  /// **'أفلام جديدة'**
  String get newMovies;

  /// No description provided for @newTVShows.
  ///
  /// In ar, this message translates to:
  /// **'مسلسلات تلفزيونية جديدة'**
  String get newTVShows;

  /// No description provided for @featuredMovies.
  ///
  /// In ar, this message translates to:
  /// **'أفلام مختارة'**
  String get featuredMovies;

  /// No description provided for @featuredTVShows.
  ///
  /// In ar, this message translates to:
  /// **'مسلسلات تلفزيونية مختارة'**
  String get featuredTVShows;

  /// No description provided for @lastVideosTVShows.
  ///
  /// In ar, this message translates to:
  /// **'آخر المسلسلات التلفزيونية'**
  String get lastVideosTVShows;

  /// No description provided for @downloads.
  ///
  /// In ar, this message translates to:
  /// **'التنزيلات'**
  String get downloads;

  /// No description provided for @downloadsTabCompleted.
  ///
  /// In ar, this message translates to:
  /// **'المكتملة'**
  String get downloadsTabCompleted;

  /// No description provided for @noDownloadsYet.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تنزيلات بعد'**
  String get noDownloadsYet;

  /// No description provided for @noCompletedDownloadsYet.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تنزيلات مكتملة'**
  String get noCompletedDownloadsYet;

  /// No description provided for @bookmarks.
  ///
  /// In ar, this message translates to:
  /// **'الإشارات المرجعية'**
  String get bookmarks;

  /// No description provided for @episodesCount.
  ///
  /// In ar, this message translates to:
  /// **'{count} حلقة • {done} اكتملت'**
  String episodesCount(int count, int done);

  /// No description provided for @deleteAllEpisodes.
  ///
  /// In ar, this message translates to:
  /// **'حذف جميع الحلقات'**
  String get deleteAllEpisodes;

  /// No description provided for @confirmDeleteAllEpisodes.
  ///
  /// In ar, this message translates to:
  /// **'هل أنت متأكد أنك تريد حذف جميع الحلقات الـ {count} من \"{title}\" وملفاتها؟'**
  String confirmDeleteAllEpisodes(int count, String title);

  /// No description provided for @deleteAll.
  ///
  /// In ar, this message translates to:
  /// **'حذف الكل'**
  String get deleteAll;

  /// No description provided for @completed.
  ///
  /// In ar, this message translates to:
  /// **'مكتمل'**
  String get completed;

  /// No description provided for @statusQueued.
  ///
  /// In ar, this message translates to:
  /// **'في الانتظار...'**
  String get statusQueued;

  /// No description provided for @statusDownloading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التنزيل...'**
  String get statusDownloading;

  /// No description provided for @statusFinished.
  ///
  /// In ar, this message translates to:
  /// **'انتهى'**
  String get statusFinished;

  /// No description provided for @statusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل'**
  String get statusFailed;

  /// No description provided for @statusCanceled.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get statusCanceled;

  /// No description provided for @statusPaused.
  ///
  /// In ar, this message translates to:
  /// **'متوقف مؤقتاً'**
  String get statusPaused;

  /// No description provided for @statusWaiting.
  ///
  /// In ar, this message translates to:
  /// **'انتظار...'**
  String get statusWaiting;

  /// No description provided for @fileNotFoundRemoving.
  ///
  /// In ar, this message translates to:
  /// **'الملف غير موجود على القرص. جارٍ إزالة السجل.'**
  String get fileNotFoundRemoving;

  /// No description provided for @fileNotFound.
  ///
  /// In ar, this message translates to:
  /// **'الملف غير موجود'**
  String get fileNotFound;

  /// No description provided for @deleteDownload.
  ///
  /// In ar, this message translates to:
  /// **'حذف التنزيل'**
  String get deleteDownload;

  /// No description provided for @confirmDeleteDownload.
  ///
  /// In ar, this message translates to:
  /// **'هل أنت متأكد أنك تريد حذف هذا التنزيل وملفه؟'**
  String get confirmDeleteDownload;

  /// No description provided for @libraryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'مكتبتك فارغة'**
  String get libraryEmpty;

  /// No description provided for @language.
  ///
  /// In ar, this message translates to:
  /// **'اللغة'**
  String get language;

  /// No description provided for @english.
  ///
  /// In ar, this message translates to:
  /// **'الإنجليزية'**
  String get english;

  /// No description provided for @hindi.
  ///
  /// In ar, this message translates to:
  /// **'الهندية'**
  String get hindi;

  /// No description provided for @kannada.
  ///
  /// In ar, this message translates to:
  /// **'الكانادية'**
  String get kannada;

  /// No description provided for @unknown.
  ///
  /// In ar, this message translates to:
  /// **'غير معروف'**
  String get unknown;

  /// No description provided for @recommended.
  ///
  /// In ar, this message translates to:
  /// **'موصى به'**
  String get recommended;

  /// No description provided for @on.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل'**
  String get on;

  /// No description provided for @off.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف'**
  String get off;

  /// No description provided for @resetDataSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح الإعدادات وقاعدة البيانات، والحفاظ على الإضافات'**
  String get resetDataSubtitle;

  /// No description provided for @factoryResetSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف جميع البيانات والإعدادات والإضافات'**
  String get factoryResetSubtitle;

  /// No description provided for @developerOptionsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدوات التصحيح والتشغيل المحلي'**
  String get developerOptionsSubtitle;

  /// No description provided for @loading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحميل...'**
  String get loading;

  /// No description provided for @sec.
  ///
  /// In ar, this message translates to:
  /// **'ثانية'**
  String get sec;

  /// No description provided for @min.
  ///
  /// In ar, this message translates to:
  /// **'دقيقة'**
  String get min;

  /// No description provided for @internalPlayer.
  ///
  /// In ar, this message translates to:
  /// **'مشغل داخلي (media_kit)'**
  String get internalPlayer;

  /// No description provided for @builtInPlayer.
  ///
  /// In ar, this message translates to:
  /// **'المشغل المدمج'**
  String get builtInPlayer;

  /// No description provided for @customNotSet.
  ///
  /// In ar, this message translates to:
  /// **'مخصص (غير محدد)'**
  String get customNotSet;

  /// No description provided for @selectGesture.
  ///
  /// In ar, this message translates to:
  /// **'اختر إيماءة {side}'**
  String selectGesture(String side);

  /// No description provided for @left.
  ///
  /// In ar, this message translates to:
  /// **'اليسار'**
  String get left;

  /// No description provided for @right.
  ///
  /// In ar, this message translates to:
  /// **'اليمين'**
  String get right;

  /// No description provided for @selectSeekDuration.
  ///
  /// In ar, this message translates to:
  /// **'اختر مدة القفز'**
  String get selectSeekDuration;

  /// No description provided for @selectBufferDepth.
  ///
  /// In ar, this message translates to:
  /// **'اختر عمق التخزين المؤقت'**
  String get selectBufferDepth;

  /// No description provided for @subtitleSettings.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الترجمة'**
  String get subtitleSettings;

  /// No description provided for @size.
  ///
  /// In ar, this message translates to:
  /// **'الحجم: {size}'**
  String size(int size);

  /// No description provided for @background.
  ///
  /// In ar, this message translates to:
  /// **'الخلفية'**
  String get background;

  /// No description provided for @customDohUrlLabel.
  ///
  /// In ar, this message translates to:
  /// **'رابط DoH مخصص'**
  String get customDohUrlLabel;

  /// No description provided for @enterCustomDohUrl.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رابط DoH الخاص بك'**
  String get enterCustomDohUrl;

  /// No description provided for @chooseTheme.
  ///
  /// In ar, this message translates to:
  /// **'اختر المظهر'**
  String get chooseTheme;

  /// No description provided for @resetDataDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط البيانات؟'**
  String get resetDataDialogTitle;

  /// No description provided for @resetDataDialogContent.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي هذا إلى مسح الإعدادات والمفضلات والسجل. لن يتم حذف إضافاتك المثبتة.'**
  String get resetDataDialogContent;

  /// No description provided for @factoryResetDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط المصنع؟'**
  String get factoryResetDialogTitle;

  /// No description provided for @factoryResetDialogContent.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي هذا إلى حذف كل شيء: المفضلات والسجل والإعدادات وجميع الإضافات. لا يمكن التراجع عن هذا الإجراء.'**
  String get factoryResetDialogContent;

  /// No description provided for @selectLanguage.
  ///
  /// In ar, this message translates to:
  /// **'اختر اللغة'**
  String get selectLanguage;

  /// No description provided for @synopsis.
  ///
  /// In ar, this message translates to:
  /// **'ملخص'**
  String get synopsis;

  /// No description provided for @noDescription.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد وصف متاح.'**
  String get noDescription;

  /// No description provided for @videoAlreadyDownloadedPrompt.
  ///
  /// In ar, this message translates to:
  /// **'هذا الفيديو تم تنزيله بالفعل. ماذا تريد أن تفعل؟'**
  String get videoAlreadyDownloadedPrompt;

  /// No description provided for @playNow.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل الآن'**
  String get playNow;

  /// No description provided for @deleteDownloadPrompt.
  ///
  /// In ar, this message translates to:
  /// **'حذف التنزيل؟'**
  String get deleteDownloadPrompt;

  /// No description provided for @deleteDownloadConfirmation.
  ///
  /// In ar, this message translates to:
  /// **'هل أنت متأكد أنك تريد حذف هذا الملف؟ لا يمكن التراجع عن هذا الإجراء.'**
  String get deleteDownloadConfirmation;

  /// No description provided for @no.
  ///
  /// In ar, this message translates to:
  /// **'لا'**
  String get no;

  /// No description provided for @yesDelete.
  ///
  /// In ar, this message translates to:
  /// **'نعم، حذف'**
  String get yesDelete;

  /// No description provided for @downloadPaused.
  ///
  /// In ar, this message translates to:
  /// **'التنزيل متوقف مؤقتاً'**
  String get downloadPaused;

  /// No description provided for @downloading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التنزيل'**
  String get downloading;

  /// No description provided for @speed.
  ///
  /// In ar, this message translates to:
  /// **'السرعة'**
  String get speed;

  /// No description provided for @remaining.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي'**
  String get remaining;

  /// No description provided for @resume.
  ///
  /// In ar, this message translates to:
  /// **'استئناف'**
  String get resume;

  /// No description provided for @pause.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف مؤقت'**
  String get pause;

  /// No description provided for @torrentContent.
  ///
  /// In ar, this message translates to:
  /// **'محتوى تورنت'**
  String get torrentContent;

  /// No description provided for @audioTracks.
  ///
  /// In ar, this message translates to:
  /// **'المسارات الصوتية'**
  String get audioTracks;

  /// No description provided for @noAudioTracks.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على مسارات صوتية'**
  String get noAudioTracks;

  /// No description provided for @subtitles.
  ///
  /// In ar, this message translates to:
  /// **'الترجمات'**
  String get subtitles;

  /// No description provided for @options.
  ///
  /// In ar, this message translates to:
  /// **'خيارات'**
  String get options;

  /// No description provided for @noSubtitlesFound.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على مسارات ترجمة'**
  String get noSubtitlesFound;

  /// No description provided for @playbackSpeed.
  ///
  /// In ar, this message translates to:
  /// **'سرعة التشغيل'**
  String get playbackSpeed;

  /// No description provided for @subtitleOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات الترجمة'**
  String get subtitleOptions;

  /// No description provided for @hlsSubtitleWarning.
  ///
  /// In ar, this message translates to:
  /// **'ملفات الترجمة الخارجية غير مدعومة على مشغل HLS النشط على هذه المنصة.'**
  String get hlsSubtitleWarning;

  /// No description provided for @loadFromDevice.
  ///
  /// In ar, this message translates to:
  /// **'تحميل من الجهاز'**
  String get loadFromDevice;

  /// No description provided for @syncDelay.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة / التأخير'**
  String get syncDelay;

  /// No description provided for @styleSettings.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات النمط'**
  String get styleSettings;

  /// No description provided for @searchOnline.
  ///
  /// In ar, this message translates to:
  /// **'بحث عبر الإنترنت (بحث عن الترجمة)'**
  String get searchOnline;

  /// No description provided for @subtitleSync.
  ///
  /// In ar, this message translates to:
  /// **'مزامنة الترجمة'**
  String get subtitleSync;

  /// No description provided for @subtitleDelayWarning.
  ///
  /// In ar, this message translates to:
  /// **'تأخير الترجمة غير مدعوم من قبل محرك التشغيل النشط.'**
  String get subtitleDelayWarning;

  /// No description provided for @resetDelay.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط التأخير'**
  String get resetDelay;

  /// No description provided for @subtitleStyles.
  ///
  /// In ar, this message translates to:
  /// **'أنماط الترجمة'**
  String get subtitleStyles;

  /// No description provided for @mediaKitStylingWarning.
  ///
  /// In ar, this message translates to:
  /// **'تنسيق الترجمة متاح فقط على مشغل media_kit حالياً.'**
  String get mediaKitStylingWarning;

  /// No description provided for @resetToDefault.
  ///
  /// In ar, this message translates to:
  /// **'إعادة الضبط للافتراضي'**
  String get resetToDefault;

  /// No description provided for @fontSize.
  ///
  /// In ar, this message translates to:
  /// **'حجم الخط'**
  String get fontSize;

  /// No description provided for @verticalPosition.
  ///
  /// In ar, this message translates to:
  /// **'الموضع العمودي'**
  String get verticalPosition;

  /// No description provided for @textColor.
  ///
  /// In ar, this message translates to:
  /// **'لون النص'**
  String get textColor;

  /// No description provided for @backgroundColor.
  ///
  /// In ar, this message translates to:
  /// **'لون الخلفية'**
  String get backgroundColor;

  /// No description provided for @backgroundOpacity.
  ///
  /// In ar, this message translates to:
  /// **'شفافية الخلفية'**
  String get backgroundOpacity;

  /// No description provided for @subtitleSearch.
  ///
  /// In ar, this message translates to:
  /// **'البحث عن الترجمة'**
  String get subtitleSearch;

  /// No description provided for @searchSubtitleNameHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن اسم الترجمة...'**
  String get searchSubtitleNameHint;

  /// No description provided for @enterSearchSubtitlePrompt.
  ///
  /// In ar, this message translates to:
  /// **'أدخل اسماً أو ابحث للعثور على الترجمة.'**
  String get enterSearchSubtitlePrompt;

  /// No description provided for @noSubtitleResults.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على نتائج. جرب استعلاماً آخر.'**
  String get noSubtitleResults;

  /// No description provided for @downloadingApplyingSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تنزيل وتطبيق الترجمة...'**
  String get downloadingApplyingSubtitle;

  /// No description provided for @failedToDownloadSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'فشل تنزيل الترجمة.'**
  String get failedToDownloadSubtitle;

  /// No description provided for @failedToLoadSubtitles.
  ///
  /// In ar, this message translates to:
  /// **'فشل تحميل الترجمة. يرجى المحاولة مرة أخرى.'**
  String get failedToLoadSubtitles;

  /// No description provided for @error.
  ///
  /// In ar, this message translates to:
  /// **'خطأ'**
  String get error;

  /// No description provided for @ok.
  ///
  /// In ar, this message translates to:
  /// **'موافق'**
  String get ok;

  /// No description provided for @movies.
  ///
  /// In ar, this message translates to:
  /// **'الأفلام'**
  String get movies;

  /// No description provided for @series.
  ///
  /// In ar, this message translates to:
  /// **'المسلسلات'**
  String get series;

  /// No description provided for @anime.
  ///
  /// In ar, this message translates to:
  /// **'الأنمي'**
  String get anime;

  /// No description provided for @liveStreams.
  ///
  /// In ar, this message translates to:
  /// **'البث المباشر'**
  String get liveStreams;

  /// No description provided for @debug.
  ///
  /// In ar, this message translates to:
  /// **'تصحيح'**
  String get debug;

  /// No description provided for @invalidNavigation.
  ///
  /// In ar, this message translates to:
  /// **'انتقال غير صالح. يرجى العودة.'**
  String get invalidNavigation;

  /// No description provided for @startOver.
  ///
  /// In ar, this message translates to:
  /// **'البدء من جديد'**
  String get startOver;

  /// No description provided for @goBack.
  ///
  /// In ar, this message translates to:
  /// **'العودة'**
  String get goBack;

  /// No description provided for @resolving.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الحل...'**
  String get resolving;

  /// No description provided for @downloaded.
  ///
  /// In ar, this message translates to:
  /// **'تم التنزيل'**
  String get downloaded;

  /// No description provided for @download.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل'**
  String get download;

  /// No description provided for @debugOnlyFeature.
  ///
  /// In ar, this message translates to:
  /// **'هذه الميزة متاحة فقط في إصدارات التصحيح'**
  String get debugOnlyFeature;

  /// No description provided for @streamUrl.
  ///
  /// In ar, this message translates to:
  /// **'رابط البث'**
  String get streamUrl;

  /// No description provided for @play.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل'**
  String get play;

  /// No description provided for @verifyingSourceSize.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحقق من المصدر والحجم...'**
  String get verifyingSourceSize;

  /// No description provided for @fileSaveLocationNotification.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حفظ الملف في مجلد التنزيلات الخاص بك.'**
  String get fileSaveLocationNotification;

  /// No description provided for @resumingPlayback.
  ///
  /// In ar, this message translates to:
  /// **'استئناف التشغيل'**
  String get resumingPlayback;

  /// No description provided for @pausedAt.
  ///
  /// In ar, this message translates to:
  /// **'توقف عند {time}'**
  String pausedAt(String time);

  /// No description provided for @resumesAutomatically.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{يستأنف تلقائياً خلال ثانية واحدة} other{يستأنف تلقائياً خلال {count} ثوانٍ}}'**
  String resumesAutomatically(int count);

  /// No description provided for @resumeNow.
  ///
  /// In ar, this message translates to:
  /// **'استئناف الآن'**
  String get resumeNow;

  /// No description provided for @playbackError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ في التشغيل'**
  String get playbackError;

  /// No description provided for @confirmClearHistory.
  ///
  /// In ar, this message translates to:
  /// **'هل أنت متأكد أنك تريد إزالة جميع العناصر من سجل المشاهدة؟'**
  String get confirmClearHistory;

  /// No description provided for @seasonWithNumber.
  ///
  /// In ar, this message translates to:
  /// **'الموسم {number}'**
  String seasonWithNumber(Object number);

  /// No description provided for @starting.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ البدء...'**
  String get starting;

  /// No description provided for @percentWatched.
  ///
  /// In ar, this message translates to:
  /// **'{percent}% تمت مشاهدته'**
  String percentWatched(int percent);

  /// No description provided for @sub.
  ///
  /// In ar, this message translates to:
  /// **'ترجمة'**
  String get sub;

  /// No description provided for @dub.
  ///
  /// In ar, this message translates to:
  /// **'دبلجة'**
  String get dub;

  /// No description provided for @playEpisode.
  ///
  /// In ar, this message translates to:
  /// **'{label} م{season} ح{episode}'**
  String playEpisode(String label, Object season, Object episode);

  /// No description provided for @debugTools.
  ///
  /// In ar, this message translates to:
  /// **'أدوات التصحيح'**
  String get debugTools;

  /// No description provided for @playLocalVideo.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل فيديو محلي'**
  String get playLocalVideo;

  /// No description provided for @playLocalVideoSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل أي فيديو من الجهاز'**
  String get playLocalVideoSubtitle;

  /// No description provided for @streamUrlSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'التشغيل من رابط شبكة'**
  String get streamUrlSubtitle;

  /// No description provided for @streamTorrent.
  ///
  /// In ar, this message translates to:
  /// **'بث تورنت'**
  String get streamTorrent;

  /// No description provided for @streamTorrentSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر ملف تورنت محلي للتشغيل'**
  String get streamTorrentSubtitle;

  /// No description provided for @enterVideoUrlHint.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رابط الفيديو (http أو magnet أو غيرهما)'**
  String get enterVideoUrlHint;

  /// No description provided for @networkStream.
  ///
  /// In ar, this message translates to:
  /// **'بث الشبكة'**
  String get networkStream;

  /// No description provided for @removedFromHistory.
  ///
  /// In ar, this message translates to:
  /// **'تمت إزالة {title} من السجل'**
  String removedFromHistory(String title);

  /// No description provided for @custom.
  ///
  /// In ar, this message translates to:
  /// **'مخصص'**
  String get custom;

  /// No description provided for @refreshingLiveStream.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تحديث البث المباشر...'**
  String get refreshingLiveStream;

  /// No description provided for @removeFromHistory.
  ///
  /// In ar, this message translates to:
  /// **'إزالة من السجل'**
  String get removeFromHistory;

  /// No description provided for @live.
  ///
  /// In ar, this message translates to:
  /// **'مباشر'**
  String get live;

  /// No description provided for @volume.
  ///
  /// In ar, this message translates to:
  /// **'الصوت'**
  String get volume;

  /// No description provided for @brightness.
  ///
  /// In ar, this message translates to:
  /// **'السطوع'**
  String get brightness;

  /// No description provided for @fit.
  ///
  /// In ar, this message translates to:
  /// **'ملاءمة'**
  String get fit;

  /// No description provided for @zoom.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الحجم والتركيز'**
  String get zoom;

  /// No description provided for @stretch.
  ///
  /// In ar, this message translates to:
  /// **'تمطيط'**
  String get stretch;

  /// No description provided for @titleWithParam.
  ///
  /// In ar, this message translates to:
  /// **'العنوان: {title}'**
  String titleWithParam(String title);

  /// No description provided for @sourceWithParam.
  ///
  /// In ar, this message translates to:
  /// **'المصدر: {source}'**
  String sourceWithParam(String source);

  /// No description provided for @sizeWithParam.
  ///
  /// In ar, this message translates to:
  /// **'الحجم: {size}'**
  String sizeWithParam(String size);

  /// No description provided for @usingInternalPlayerError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ: {error}. يتم استخدام المشغل الداخلي.'**
  String usingInternalPlayerError(String error);

  /// No description provided for @playerNotDetected.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم اكتشاف {playerName}. جارٍ بدء المشغل الداخلي.'**
  String playerNotDetected(String playerName);

  /// No description provided for @seasonWithEpisodes.
  ///
  /// In ar, this message translates to:
  /// **'الموسم {number} ({count} حلقة)'**
  String seasonWithEpisodes(Object number, int count);

  /// No description provided for @cloudflare.
  ///
  /// In ar, this message translates to:
  /// **'Cloudflare'**
  String get cloudflare;

  /// No description provided for @google.
  ///
  /// In ar, this message translates to:
  /// **'Google'**
  String get google;

  /// No description provided for @adguard.
  ///
  /// In ar, this message translates to:
  /// **'AdGuard'**
  String get adguard;

  /// No description provided for @dnsWatch.
  ///
  /// In ar, this message translates to:
  /// **'DNS.Watch'**
  String get dnsWatch;

  /// No description provided for @quad9.
  ///
  /// In ar, this message translates to:
  /// **'Quad9'**
  String get quad9;

  /// No description provided for @dnsSb.
  ///
  /// In ar, this message translates to:
  /// **'DNS.SB'**
  String get dnsSb;

  /// No description provided for @canadianShield.
  ///
  /// In ar, this message translates to:
  /// **'Canadian Shield'**
  String get canadianShield;

  /// No description provided for @tmdb.
  ///
  /// In ar, this message translates to:
  /// **'TMDB'**
  String get tmdb;

  /// No description provided for @selectSourceForPlayer.
  ///
  /// In ar, this message translates to:
  /// **'اختر المصدر لـ {playerName}'**
  String selectSourceForPlayer(String playerName);

  /// No description provided for @noPluginsInstalled.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد إضافات مثبتة'**
  String get noPluginsInstalled;

  /// No description provided for @availableSources.
  ///
  /// In ar, this message translates to:
  /// **'المصادر المتاحة'**
  String get availableSources;

  /// No description provided for @seasons.
  ///
  /// In ar, this message translates to:
  /// **'المواسم'**
  String get seasons;

  /// No description provided for @episodes.
  ///
  /// In ar, this message translates to:
  /// **'الحلقات'**
  String get episodes;

  /// No description provided for @selectSourceToPlay.
  ///
  /// In ar, this message translates to:
  /// **'يرجى اختيار مصدر من \'المصادر المتاحة\' أعلاه للتشغيل.'**
  String get selectSourceToPlay;

  /// No description provided for @episodeCountOnly.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{حلقة واحدة} other{{count} حلقات}}'**
  String episodeCountOnly(num count);

  /// No description provided for @noEpisodesFound.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على حلقات'**
  String get noEpisodesFound;

  /// No description provided for @local.
  ///
  /// In ar, this message translates to:
  /// **'محلي'**
  String get local;

  /// No description provided for @remote.
  ///
  /// In ar, this message translates to:
  /// **'عن بعد'**
  String get remote;

  /// No description provided for @torrent.
  ///
  /// In ar, this message translates to:
  /// **'تورنت'**
  String get torrent;

  /// No description provided for @unlock.
  ///
  /// In ar, this message translates to:
  /// **'فتح القفل'**
  String get unlock;

  /// No description provided for @lock.
  ///
  /// In ar, this message translates to:
  /// **'قفل'**
  String get lock;

  /// No description provided for @sources.
  ///
  /// In ar, this message translates to:
  /// **'المصادر'**
  String get sources;

  /// No description provided for @tracks.
  ///
  /// In ar, this message translates to:
  /// **'المسارات'**
  String get tracks;

  /// No description provided for @content.
  ///
  /// In ar, this message translates to:
  /// **'المحتوى'**
  String get content;

  /// No description provided for @stats.
  ///
  /// In ar, this message translates to:
  /// **'الإحصائيات'**
  String get stats;

  /// No description provided for @resize.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الحجم'**
  String get resize;

  /// No description provided for @next.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get next;

  /// No description provided for @pip.
  ///
  /// In ar, this message translates to:
  /// **'صورة داخل صورة'**
  String get pip;

  /// No description provided for @pipUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تفعيل صورة داخل صورة على هذا الجهاز'**
  String get pipUnavailable;

  /// No description provided for @rotate.
  ///
  /// In ar, this message translates to:
  /// **'تدوير'**
  String get rotate;

  /// No description provided for @windowed.
  ///
  /// In ar, this message translates to:
  /// **'نوافذ'**
  String get windowed;

  /// No description provided for @fullscreen.
  ///
  /// In ar, this message translates to:
  /// **'ملء الشاشة'**
  String get fullscreen;

  /// No description provided for @movieDetails.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الفيلم'**
  String get movieDetails;

  /// No description provided for @showDetails.
  ///
  /// In ar, this message translates to:
  /// **'عرض التفاصيل'**
  String get showDetails;

  /// No description provided for @tagline.
  ///
  /// In ar, this message translates to:
  /// **'شعار'**
  String get tagline;

  /// No description provided for @status.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get status;

  /// No description provided for @releaseDate.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإصدار'**
  String get releaseDate;

  /// No description provided for @firstAirDate.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ أول عرض'**
  String get firstAirDate;

  /// No description provided for @originalLanguage.
  ///
  /// In ar, this message translates to:
  /// **'اللغة الأصلية'**
  String get originalLanguage;

  /// No description provided for @originCountry.
  ///
  /// In ar, this message translates to:
  /// **'بلد المنشأ'**
  String get originCountry;

  /// No description provided for @budgetLabel.
  ///
  /// In ar, this message translates to:
  /// **'الميزانية'**
  String get budgetLabel;

  /// No description provided for @revenueLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإيرادات'**
  String get revenueLabel;

  /// No description provided for @paused.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get paused;

  /// No description provided for @watched.
  ///
  /// In ar, this message translates to:
  /// **'تمت مشاهدته'**
  String get watched;

  /// No description provided for @watching.
  ///
  /// In ar, this message translates to:
  /// **'مشاهدة الآن'**
  String get watching;

  /// No description provided for @lastWatched.
  ///
  /// In ar, this message translates to:
  /// **'آخر مشاهدة'**
  String get lastWatched;

  /// No description provided for @movie.
  ///
  /// In ar, this message translates to:
  /// **'فيلم'**
  String get movie;

  /// No description provided for @tvShow.
  ///
  /// In ar, this message translates to:
  /// **'مسلسل تلفزيوني'**
  String get tvShow;

  /// No description provided for @failedToLoadContent.
  ///
  /// In ar, this message translates to:
  /// **'فشل تحميل المحتوى'**
  String get failedToLoadContent;

  /// No description provided for @director.
  ///
  /// In ar, this message translates to:
  /// **'المخرج'**
  String get director;

  /// No description provided for @creator.
  ///
  /// In ar, this message translates to:
  /// **'المبتكر'**
  String get creator;

  /// No description provided for @showMore.
  ///
  /// In ar, this message translates to:
  /// **'عرض المزيد'**
  String get showMore;

  /// No description provided for @showLess.
  ///
  /// In ar, this message translates to:
  /// **'عرض أقل'**
  String get showLess;

  /// No description provided for @viewAll.
  ///
  /// In ar, this message translates to:
  /// **'عرض الكل'**
  String get viewAll;

  /// No description provided for @seasonsCount.
  ///
  /// In ar, this message translates to:
  /// **'{count} مواسم'**
  String seasonsCount(int count);

  /// No description provided for @noInternetError.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد اتصال بالإنترنت'**
  String get noInternetError;

  /// No description provided for @timeoutError.
  ///
  /// In ar, this message translates to:
  /// **'انتهت مهلة الطلب. يرجى المحاولة مرة أخرى.'**
  String get timeoutError;

  /// No description provided for @serverError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ في الخادم. يرجى المحاولة مرة أخرى لاحقاً.'**
  String get serverError;

  /// No description provided for @contentNotFoundError.
  ///
  /// In ar, this message translates to:
  /// **'المحتوى غير موجود.'**
  String get contentNotFoundError;

  /// No description provided for @accessDeniedError.
  ///
  /// In ar, this message translates to:
  /// **'تم رفض الوصول. تحقق من بيانات الاعتماد الخاصة بك.'**
  String get accessDeniedError;

  /// No description provided for @serviceUnavailableError.
  ///
  /// In ar, this message translates to:
  /// **'الخادم غير متاح. حاول مرة أخرى لاحقاً.'**
  String get serviceUnavailableError;

  /// No description provided for @generalError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ ما. يرجى المحاولة مرة أخرى.'**
  String get generalError;

  /// No description provided for @skip.
  ///
  /// In ar, this message translates to:
  /// **'تخطي'**
  String get skip;

  /// No description provided for @goLive.
  ///
  /// In ar, this message translates to:
  /// **'البث المباشر'**
  String get goLive;

  /// No description provided for @dismiss.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get dismiss;

  /// No description provided for @nextUp.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get nextUp;

  /// No description provided for @sourceAttempt.
  ///
  /// In ar, this message translates to:
  /// **'المصدر {index} من {total}'**
  String sourceAttempt(int index, int total);

  /// No description provided for @trying.
  ///
  /// In ar, this message translates to:
  /// **'محاولة'**
  String get trying;

  /// No description provided for @failed.
  ///
  /// In ar, this message translates to:
  /// **'فشل'**
  String get failed;

  /// No description provided for @selected.
  ///
  /// In ar, this message translates to:
  /// **'مختار'**
  String get selected;

  /// No description provided for @playing.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل'**
  String get playing;

  /// No description provided for @pending.
  ///
  /// In ar, this message translates to:
  /// **'قيد الانتظار'**
  String get pending;

  /// No description provided for @discord.
  ///
  /// In ar, this message translates to:
  /// **'Discord'**
  String get discord;

  /// No description provided for @discordSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'انضم إلى خادمنا'**
  String get discordSubtitle;

  /// No description provided for @telegram.
  ///
  /// In ar, this message translates to:
  /// **'Telegram'**
  String get telegram;

  /// No description provided for @telegramSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'انضم إلى قناتنا'**
  String get telegramSubtitle;

  /// No description provided for @developedBy.
  ///
  /// In ar, this message translates to:
  /// **'تم التطوير بواسطة {name}'**
  String developedBy(String name);

  /// No description provided for @playEpisodeOnly.
  ///
  /// In ar, this message translates to:
  /// **'{label} حلقة {episode}'**
  String playEpisodeOnly(String label, int episode);

  /// No description provided for @wifiQualityPreference.
  ///
  /// In ar, this message translates to:
  /// **'تفضيل جودة الواي فاي'**
  String get wifiQualityPreference;

  /// No description provided for @mobileQualityPreference.
  ///
  /// In ar, this message translates to:
  /// **'تفضيل جودة الهاتف المحمول'**
  String get mobileQualityPreference;

  /// No description provided for @anyNoPreference.
  ///
  /// In ar, this message translates to:
  /// **'أي نوع (لا يوجد تفضيل)'**
  String get anyNoPreference;

  /// No description provided for @subtitleAccounts.
  ///
  /// In ar, this message translates to:
  /// **'حسابات الترجمة'**
  String get subtitleAccounts;

  /// No description provided for @notLoggedIn.
  ///
  /// In ar, this message translates to:
  /// **'غير مسجّل الدخول'**
  String get notLoggedIn;

  /// No description provided for @loggedInAs.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الدخول باسم {username}'**
  String loggedInAs(String username);

  /// No description provided for @apiKeyConfigured.
  ///
  /// In ar, this message translates to:
  /// **'تم تكوين مفتاح API'**
  String get apiKeyConfigured;

  /// No description provided for @keyNotSet.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم تعيين المفتاح'**
  String get keyNotSet;

  /// No description provided for @testConnection.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الاتصال'**
  String get testConnection;

  /// No description provided for @connectedSuccessfully.
  ///
  /// In ar, this message translates to:
  /// **'تم الاتصال بنجاح'**
  String get connectedSuccessfully;

  /// No description provided for @connectionFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل الاتصال'**
  String get connectionFailed;

  /// No description provided for @username.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get username;

  /// No description provided for @password.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get password;

  /// No description provided for @noAccountRegister.
  ///
  /// In ar, this message translates to:
  /// **'ليس لديك حساب؟ سجل هنا'**
  String get noAccountRegister;

  /// No description provided for @apiKey.
  ///
  /// In ar, this message translates to:
  /// **'مفتاح API'**
  String get apiKey;

  /// No description provided for @email.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني'**
  String get email;

  /// No description provided for @fetchMyApiKey.
  ///
  /// In ar, this message translates to:
  /// **'جلب مفتاح API الخاص بي'**
  String get fetchMyApiKey;

  /// No description provided for @keyVerified.
  ///
  /// In ar, this message translates to:
  /// **'تم التحقق من المفتاح'**
  String get keyVerified;

  /// No description provided for @invalidApiKey.
  ///
  /// In ar, this message translates to:
  /// **'مفتاح API غير صالح'**
  String get invalidApiKey;

  /// No description provided for @openSubtitlesAuthSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل بيانات اعتماد حسابك للحصول على حدود أعلى وترجمات خالية من الإعلانات.'**
  String get openSubtitlesAuthSubtitle;

  /// No description provided for @subDlAuthSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مفتاح SubDL API الخاص بك مباشرة، أو احصل عليه باستخدام بيانات اعتماد حسابك أدناه.'**
  String get subDlAuthSubtitle;

  /// No description provided for @orFetchViaAccount.
  ///
  /// In ar, this message translates to:
  /// **'أو الجلب عبر الحساب'**
  String get orFetchViaAccount;

  /// No description provided for @subSourceAuthSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يعمل SubSource تلقائياً، ولكن يمكنك إضافة مفتاح API رسمي شخصي لتجاوز الافتراضي للحصول على موثوقية أفضل.'**
  String get subSourceAuthSubtitle;

  /// No description provided for @apiKeyOptionalOverride.
  ///
  /// In ar, this message translates to:
  /// **'مفتاح API (تجاوز اختياري)'**
  String get apiKeyOptionalOverride;

  /// No description provided for @enterKeyToOverrideDefault.
  ///
  /// In ar, this message translates to:
  /// **'أدخل المفتاح لتجاوز الافتراضي'**
  String get enterKeyToOverrideDefault;

  /// No description provided for @getApiKeyFromProfile.
  ///
  /// In ar, this message translates to:
  /// **'احصل على مفتاح API الخاص بك من ملف SubSource الشخصي'**
  String get getApiKeyFromProfile;

  /// No description provided for @qualityNotGuaranteed.
  ///
  /// In ar, this message translates to:
  /// **'الجودة غير مضمونة. يتم فرز المصادر حسب التفضيل، ولكن التشغيل يعتمد على ما يقدمه المزود بالفعل.'**
  String get qualityNotGuaranteed;

  /// No description provided for @keepSourcesOriginalOrder.
  ///
  /// In ar, this message translates to:
  /// **'الحفاظ على المصادر في ترتيبها الأصلي'**
  String get keepSourcesOriginalOrder;

  /// No description provided for @openLink.
  ///
  /// In ar, this message translates to:
  /// **'فتح الرابط'**
  String get openLink;

  /// No description provided for @openSubtitles.
  ///
  /// In ar, this message translates to:
  /// **'OpenSubtitles'**
  String get openSubtitles;

  /// No description provided for @subDl.
  ///
  /// In ar, this message translates to:
  /// **'SubDL'**
  String get subDl;

  /// No description provided for @subSource.
  ///
  /// In ar, this message translates to:
  /// **'SubSource'**
  String get subSource;

  /// No description provided for @diagnostics.
  ///
  /// In ar, this message translates to:
  /// **'التشخيصات'**
  String get diagnostics;

  /// No description provided for @viewLogs.
  ///
  /// In ar, this message translates to:
  /// **'عرض السجلات'**
  String get viewLogs;

  /// No description provided for @viewLogsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عرض نشاط التطبيق والأخطاء'**
  String get viewLogsSubtitle;

  /// No description provided for @clearCache.
  ///
  /// In ar, this message translates to:
  /// **'مسح ذاكرة الصور والفيديو المؤقتة'**
  String get clearCache;

  /// No description provided for @clearCacheSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تحرير مساحة التخزين المستخدمة للصور وملفات الفيديو المؤقتة'**
  String get clearCacheSubtitle;

  /// No description provided for @clearCacheDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح الذاكرة المؤقتة؟'**
  String get clearCacheDialogTitle;

  /// No description provided for @clearCacheDialogContent.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي هذا إلى حذف الصور وملفات الفيديو المؤقتة. لن تتأثر إعداداتك أو سجل المشاهدة أو الإضافات.'**
  String get clearCacheDialogContent;

  /// No description provided for @clearCacheNow.
  ///
  /// In ar, this message translates to:
  /// **'مسح الذاكرة المؤقتة'**
  String get clearCacheNow;

  /// No description provided for @cacheCleared.
  ///
  /// In ar, this message translates to:
  /// **'تم مسح الذاكرة المؤقتة'**
  String get cacheCleared;

  /// No description provided for @calculating.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الحساب…'**
  String get calculating;

  /// No description provided for @playerControls.
  ///
  /// In ar, this message translates to:
  /// **'عناصر تحكم المشغل'**
  String get playerControls;

  /// No description provided for @showPip.
  ///
  /// In ar, this message translates to:
  /// **'زر صورة داخل صورة'**
  String get showPip;

  /// No description provided for @showResize.
  ///
  /// In ar, this message translates to:
  /// **'زر تغيير الحجم'**
  String get showResize;

  /// No description provided for @showRotate.
  ///
  /// In ar, this message translates to:
  /// **'زر التدوير'**
  String get showRotate;

  /// No description provided for @showPlaybackSpeed.
  ///
  /// In ar, this message translates to:
  /// **'زر سرعة التشغيل'**
  String get showPlaybackSpeed;

  /// No description provided for @showEpisodes.
  ///
  /// In ar, this message translates to:
  /// **'زر الحلقات'**
  String get showEpisodes;

  /// No description provided for @playerControlsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'إظهار أزرار التحكم في المشغل أو إخفاؤها'**
  String get playerControlsSubtitle;

  /// No description provided for @relatedAnime.
  ///
  /// In ar, this message translates to:
  /// **'ذات صلة'**
  String get relatedAnime;

  /// No description provided for @accounts.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات'**
  String get accounts;

  /// No description provided for @exploreAnime.
  ///
  /// In ar, this message translates to:
  /// **'استكشاف الأنمي'**
  String get exploreAnime;

  /// No description provided for @exploreMovies.
  ///
  /// In ar, this message translates to:
  /// **'استكشاف الأفلام'**
  String get exploreMovies;

  /// No description provided for @skipIntro.
  ///
  /// In ar, this message translates to:
  /// **'تخطي المقدمة'**
  String get skipIntro;

  /// No description provided for @skipOutro.
  ///
  /// In ar, this message translates to:
  /// **'تخطي النهاية'**
  String get skipOutro;

  /// No description provided for @skipRecap.
  ///
  /// In ar, this message translates to:
  /// **'تخطي الملخص السابق'**
  String get skipRecap;

  /// No description provided for @titlePosition.
  ///
  /// In ar, this message translates to:
  /// **'موضع العنوان'**
  String get titlePosition;

  /// No description provided for @titlePositionBelowPoster.
  ///
  /// In ar, this message translates to:
  /// **'أسفل الملصق'**
  String get titlePositionBelowPoster;

  /// No description provided for @titlePositionInsidePoster.
  ///
  /// In ar, this message translates to:
  /// **'داخل الملصق'**
  String get titlePositionInsidePoster;

  /// No description provided for @upNext.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get upNext;

  String get manga;
  String get manhwa;
  String get chapters;
  String get latestChapters;
  String get mangaDetails;
  String get mangaNoChapters;
  String get mangaNoPages;
  String get mangaDownloadChapter;
  String get mangaDeleteChapter;
  String get mangaCompleted;
  String get mangaLibraryType;
  String get mangaReadingNow;
  String get mangaContinueLater;
  String get mangaPlanToRead;
  String get mangaCompletedReading;
  String get mangaNotInterested;
  String get searchDomainAnime;
  String get searchDomainAnimation;
  String get searchDomainManga;
  String get searchDomainCharacters;
  String get searchDomainTooltip;
  String mangaChapterCount(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
