# أدلة فحص APK الخاص بـAnime Rift ومقارنته بمرجع CloudStream

**تاريخ الفحص:** 2026-11-02. **النطاق:** تحليل ثابت للملف المحدد ومراجعة مصدر Kotlin منشور؛ لم يُشغَّل التطبيق، ولم تُجرَ محاكاة جهاز أو اعتراض شبكة أو اختبار دخول أو بث. هذا تقرير أدلة مكمّل لخريطة التنفيذ، وليس إثباتاً لتكامل API يعمل.

## 1. المصادر وإمكانية إعادة التحقق

1. **APK المحلي:** `/home/ubuntu/Documents/Codex/2026-11-02/https-github-com-morluto-rea-setup/app-release-3.13.13.apk`، حجمه **159,588,338 بايت**، وبصمة SHA-256: `5e0cba4d9bb397a94f9809ae7344394f0efcacb31f874b02909239174f00f288`. تحدد البصمة الملف المفحوص بالضبط ولا تثبت أن جهة معينة نشرته.
2. **مصدر المقارنة:** [`AnimeRift/src/main/kotlin/com/animerift/animerift.kt`](https://github.com/Abodabodd/re-3arabi/blob/main/AnimeRift/src/main/kotlin/com/animerift/animerift.kt) في مستودع `Abodabodd/re-3arabi`، مقروء مباشرة من فرع `main` يوم الفحص. هو **إضافة CloudStream منشورة مستقلة**؛ لا يمكن اعتبارها الكود المصدري الأصلي لتطبيق Anime Rift أو وثيقة API رسمية صادرة عن مالك الخدمة. أرقام الأسطر أدناه تخص محتوى هذا الملف يوم الاطلاع ويمكن أن تتغير في الفرع.
3. **أدوات التحقق:** `aapt dump badging` و`aapt dump xmltree` و`aapt dump resources`، و`apkanalyzer manifest print` و`dex references`، وقراءة محتويات ZIP ونصوص مكتبة Flutter دون تنفيذ، وREA CLI **6.8.0** باستخدام `inspect-dart-aot` و`inspect-apk-signature`، إضافة إلى قراءة Kotlin. نتيجة `inspect-android-class` من REA لم تتوفر لأن موفر JADX المطلوب غير مهيأ؛ لذلك **لا يوجد في هذا التقرير تفكيك مضمون لشيفرة Android/Java أو استعادة دوال Dart الأصلية**.

تُستخدم المصطلحات التالية بدقة: **مؤكد في APK** يعني قراءة ثابتة مباشرة من بايتات الحزمة؛ **مؤكد في المرجع** يعني سلوك مكتوب في إضافة Kotlin فقط؛ **استنتاج** يعني تفسيراً محتملاً لا يؤكده تتبّع تشغيل؛ **غير متحقق** يعني غياب دليل كافٍ. لا تعني أسماء الدوال أو الموارد الموجودة أن مساراتها تُنفَّذ.

## 2. هوية التطبيق وبنيته [مؤكد في APK]

| العنصر | الدليل الثابت | النتيجة |
|---|---|---|
| اسم الحزمة | `AndroidManifest.xml` و`aapt dump badging` | `com.riftapps.animerift`؛ اسم العرض `Anime Rift - Official` |
| الإصدار الداخلي | حقول `versionName` و`versionCode` في Manifest | **3.13.5** و**68**؛ الاسم الخارجي `app-release-3.13.13.apk` لا يحدد الإصدار الحقيقي |
| Android API | `uses-sdk` | `minSdkVersion=24` و`targetSdkVersion=36`؛ compile SDK 36 |
| محتويات الحزمة | جرد ZIP | **815 مدخلاً**؛ خمسة ملفات DEX (`classes.dex` حتى `classes5.dex`)؛ لا يشير عدد DEX إلى عدد وحدات تطبيق Dart |
| Flutter AOT | `lib/<ABI>/libapp.so` و`libflutter.so` و`assets/flutter_assets/` | APK مبني بـFlutter مع كود Dart مترجم AOT؛ ليس تطبيق Kotlin أصلياً |
| المعماريات | مدخلات ZIP | `arm64-v8a` و`armeabi-v7a` و`x86_64`، وفي كل منها `libapp.so` و`libflutter.so` و`libmpv.so` و`libmediakitandroidhelper.so` و`libdatastore_shared_counter.so` |
| Snapshot | `REA inspect-dart-aot --abi arm64-v8a` | بصمة Dart snapshot: `1ce86630892e2dca9a8543fdb8ed8e22`؛ تحليل تجمّع النصوص **جزئي**، لا يعيد بناء أصناف ودوال Dart |
| التوقيع المعلن | `REA inspect-apk-signature` | توجد بنية توقيع APK **v2** (ولا يظهر v1/v3)، وبصمة شهادة الموقّع المعلنة SHA-256 هي `200687cccdbc5c6fb03eadd2ed2a677aed2564736e0b1ab2aed5065955d8dcc1`. تماسك بصمة المحتوى لا يساوي تحققاً تشفيرياً من التوقيع أو من هوية الناشر |

المكتبات الأصلية `libmpv.so` و`libmediakitandroidhelper.so` وملف `assets/flutter_assets/packages/media_kit/assets/web/hls1.4.10.js` **تدعم استنتاج** أن التطبيق مجهّز لمسارات تشغيل فيديو متقدمة، لكنها لا تثبت اللاعب المختار فعلياً لكل سيرفر أو جودة أو منصة. توجد أيضاً أصول وملفات ترجمة `assets/flutter_assets/assets/translations/{ar,de,en,es,fr,it}.json`. فحص `ar.json` و`en.json` أظهر **1474 مفتاح ترجمة** في كل ملف؛ هذه موارد واجهة وليست استجابات API.

## 3. Manifest وأمن الاتصال والتنزيل [مؤكد في APK]

- **الصلاحيات:** `INTERNET` و`ACCESS_NETWORK_STATE` و`WAKE_LOCK` و`POST_NOTIFICATIONS` وأذونات وسائط/تخزين، و`RECEIVE_BOOT_COMPLETED` و`FOREGROUND_SERVICE` و`FOREGROUND_SERVICE_DATA_SYNC` و`DOWNLOAD_WITHOUT_NOTIFICATION` و`com.android.vending.BILLING` وصلاحيات القياسات/الإعلان. الصلاحية المعلنة لا تثبت استعمالها أو منحها وقت التشغيل.
- **المكونات المسماة:** `com.riftapps.animerift.MainActivity` بوصفها نشاط Flutter، و`androidx.work.impl.foreground.SystemForegroundService`، و`com.pravera.flutter_foreground_task.service.ForegroundService` و`RebootReceiver`، و`com.bbflight.background_downloader.NotificationReceiver` و`UIDTJobService`، وFirebase Messaging background service/receiver وFirebase ComponentDiscovery وGoogle Mobile Ads وBilling. وجود مكوّنات التنزيل في Manifest **لا يثبت** دعم الاستمرار بعد إغلاق التطبيق أو صحة الاستئناف.
- **سياسة الشبكة قابلة للقراءة:** `AndroidManifest.xml` يحدد `android:usesCleartextTraffic=false` و`networkSecurityConfig=@0x7f120006`؛ حُلّ اسم المورد من `aapt dump resources` إلى `xml/network_security_config` ومساره المجمّع `res/8G.xml`. محتواه المقروء بواسطة `aapt dump xmltree ... res/8G.xml`: منع حركة `cleartext` أساسياً، وتهيئة `domain-config` للنطاق `anime-rift.com` مع النطاقات الفرعية، و`trust-anchors` من `system`. **لم يظهر** في هذا المورد تثبيت شهادة صريح (certificate pinning)، ولا يصح تعميم ذلك على كل مكتبات الشبكة أو الادعاء بعدم وجود تحقق آخر.
- **نطاق Android/Flutter:** مؤشر `flutterEmbedding=2` في Manifest؛ `inspect-dart-aot` أظهر مساراً من الكود المترجم يحمل الاسم `package:anime_rift_app/offline_mode/services/foreground/HlsForegroundService.dart`، وآخر من `package:background_downloader/src/native_downloader.dart`، وكذلك `package:media_kit`. هذه **أسماء مسارات مستخرجة جزئياً** لا شيفرة قابلة للمراجعة ولا ضماناً أن المكوّن يعمل حالياً.

## 4. نصوص المسارات المستخرجة من Flutter AOT [مؤكد في بايتات APK؛ التشغيل غير متحقق]

تمت قراءة سلاسل ASCII القابلة للطباعة من **`lib/arm64-v8a/libapp.so`** فقط، دون استخراج رموز وصول أو أسرار. من النصوص التي طابقت مسارات API حرفياً:

| المجال | مسارات نصية مرصودة داخل `libapp.so` | الاستنتاج المحدود |
|---|---|---|
| فهرس الأنمي | `/library/home_content`, `/library/search`, `/library/all`, `/library/details/`, `/library/episodes/`, `/library/genres`, `/library/tags` | وجود أسماء لمسارات تصفح وتفاصيل وحلقات؛ لا دليل على صيغة الرد أو شروط استعمالها |
| ترتيب ومحتوى إضافي | `/library/seasons`, `/library/schedule`, `/library/pick-random`, `/library/hidden`, `/library/hide` | **فرق ملموس عن مرجع CloudStream:** التطبيق يحتوي نصوصاً لمسارات مواسم وجدول، وإن كان المرجع لا يعرّضها |
| التشغيل | `/library/episode/sources`, `/library/episode/source/can_play`, `/library/episode/source/direct_link`, `/library/episode/source/next_episode`, `/library/episode/source/can_use/` | بنية مسارات متوافقة بالاسم مع قراءة المرجع؛ التسلسل والحقوق الفعلية يحتاجان واجهة مصرحاً بها |
| حسابات | `/auth/register/device`, `/auth/sign-in/google`, `/auth/sign-in/with-code`, `/user/view/` | توجد أسماء لمسارات تسجيل/عرض مستخدم؛ آلية المصادقة غير مثبتة من النص وحده |
| تعليقات | `/comment/all`, `/comment/create`, `/comment/history`, `/comment/edit/`, `/comment/delete/`, `/comment/report/`, `/comment/react/` | التطبيق يحتوي نصوصاً لوظائف تعليقات غائبة عن وظائف إضافة CloudStream |
| إعلانات | `/ads_manager/claim` | مسار ادعاء مرتبط بالإعلانات؛ لا يُعد دليل استحقاق بث أو إذن لصناعة ادعاءات بديلة |

وجد الفحص في `libapp.so` نصاً يبدأ بـ`https://gateway.anime-rift.com/api/v4` ونصوصاً أخرى قد تشير إلى بيئات تطوير/اختبار، بالإضافة إلى المفتاح النصي `anime_rift_android_gateway_base_url_v4`، ورمز الخطأ `UNSUPPORTED_PLATFORM` واسم ترويسة `x-firebase-app-check`. **وجود عنوان أو ترويسة كنص لا يثبت** أنه عنوان الإنتاج الحالي، ولا يُبيح استخدامه كعميل خارجي. لم تُدرَ اتصالات إلى تلك العناوين في هذا الفحص.

توجد في الترجمات مفاتيح تدل على **نطاق تصميم واجهة التطبيق** مثل `schedule`, `seasons`, `favorite_characters`, `comments`, `reviews`, `offlineMode`, `downloads`, `downloadWasPaused`, `subtitles`, `downloadIsNotAvailableOnThisServer`, `watchOnlyServerPleasePickAnOtherServer`, `syncYourAnimeList`, `leaderboard`, `activateSubscription`. **استنتاج فقط:** التطبيق يقدّم أو يُعدّ وظائف تخص هذه الأسماء؛ لا تثبت الموارد تفعيلها للمستخدم، ولا واجهاتها الخلفية، ولا دعماً قابلاً للنقل إلى AnimeWitcher.

## 5. مقارنة الأدلة بتوابع إضافة Kotlin [مؤكد في المرجع حصراً]

| التابع/الأسطر في `animerift.kt` | ما ينفذه المرجع المكتوب | حدود المقارنة مع APK |
|---|---|---|
| `AnimeRift : MainAPI`، 19–32 | تعريف إضافة لـCloudStream تدعم `TvType.Anime` وواجهة رئيسية وتنزيلاً | لا يمثل مكوّناً داخلياً في APK؛ تصريح دعم التنزيل تخص الإضافة |
| `getMainPage`، 381–424 | طلب `library/home_content?with_genres=true`، وتحويل `sections[].items[]` إلى بطاقات، وعدم تحميل صفحات إضافية بعد الأولى | السلسلة `/library/home_content` مرصودة في APK؛ بنية `sections` افتراض متبنّى من المرجع لم تؤكده استجابة حقيقية في هذا الفحص |
| `search`، 426–460 | `POST library/search` بجسم `query`، وتحويل الصفحة من ترقيم 1 إلى 0، وقراءة `items` و`hasNext` | السلسلة `/library/search` موجودة في APK؛ شكل الجسم و`hasNext` و`sort_by` موثوقون **كمعلومة عن المرجع** فحسب |
| `load`، 462–524 | `library/details/{id}` ثم `library/episodes/{id}`، وعرض `others.recommendations`؛ حلقة `episode_number` و`thumbnail`، والتصنيفات `genreLabels` | مسارا التفاصيل والحلقات مرصودان؛ عدم نجاح جلب الحلقات في المرجع يُبتلع باستثناء صامت، فلا يستدل من نتيجته على افتقار أنمي لحلقات |
| `loadLinks`، 526–691 | `episode/sources` ثم فحص إمكانية التشغيل، ثم `episode/source/direct_link`؛ يقرأ `qualities` و`tracks` و`http_headers` ويحوّل الروابط إلى `ExtractorLink` | مسارات المراحل مرصودة نصياً في APK؛ **لا تُثبت** صحة ترتيب النداءات أو عمل روابط الفيديو، وتظهر بالمرجع خطوات إعلانات/صلاحية يجب عدم نقلها بلا عقد رسمي |
| `extractQuality`، 693–706 | مطابقة نصوص دقة 240–2160 إلى تصنيفات CloudStream | يمكن الاستفادة من التحويل كنموذج محلي، مع اختبار قيم جودة فعلية من API معتمدة |
| `ensureInitialized` و`apiCall`، 153–379 | تخزين حالة محلية وإعادة المحاولة؛ 429 مرة بعد تأخير و401/403/404 قد تستدعي إعادة تسجيل | هذه **سياسة الإضافة**؛ لا دليل أنها سياسة الخادم أو أن إعادة التسجيل بهذه الطريقة مصرح بها |

**تنبيه تحليلي:** المرجع يتضمن دوال لإنشاء هوية جهاز وادعاءات سلامة اصطناعية، إضافة إلى خطوة ادعاء حدث إعلاني. هذا يفسر بعض اختلافات سلوك الإضافة عن التطبيق لكنه **لا يصلح قالباً للتكامل**. لم تُنسخ قيم سرية أو تعليمات انتحال هوية، ولم تُحاول محاكاة أو تخطي App Check أو Play Integrity أو استحقاقات الإعلان.

**تمييز مهم:** غياب `schedule` أو التعليقات أو الحسابات عن `MainAPI` الخاص بمرجع CloudStream ليس دليلاً على غيابها عن Anime Rift؛ مسارات نصية وموارد مختلفة في APK تشير إلى اتساع واجهة التطبيق. والعكس صحيح: مطابقة اسم مسار بين المرجع وAPK لا تكشف عقده الحالي، ولا نجاحه، ولا حق طرف ثالث في استعماله.

## 6. القيود والنتائج غير المحسومة

1. **الفحص ثابت حصراً:** لم تُشغَّل أي شاشة أو جلسة مستخدم أو جهاز، ولم يُلتقط HTTP أو TLS؛ لا توجد بيانات استجابة موثقة، أو إثبات لقابلية التصفح/التشغيل/التنزيل أو صلاحيات المحتوى.
2. **استعادة الشيفرة ناقصة:** `inspect-dart-aot` يذكر صراحة أن استخراج سلاسل Dart جزئي وذو حدود قصوى، وأن `class_like_tokens` قد تضم تطابقات عرضية؛ لا يجوز نسبة تسلسل دوال/حقول/طلبات بعينه إلى التطبيق الأصلي بناءً على النصوص فقط. تعذر `inspect-android-class` لأن `REA_JADX_MCP_JAR` غير مهيأ؛ لم تُفكك أصناف Android.
3. **توقيع المصدر والنسخة:** فحص بنية APK v2 كان ثابتاً ويذكر أنه لم يتحقق من صحة التوقيع تشفيرياً ولا من سلسلة الثقة/هوية الناشر. كذلك لا تؤكد تسمية ملف APK ولا اسم العرض أنه نسخة مأخوذة من متجر موثوق.
4. **حقوق الاستخدام والتكامل:** توجد إفادة ضمن سياق مهمة الدمج بأن المستخدم حصل على موافقة فريق Anime Rift؛ لم يظهر في الأدلة المفحوصة **عقد API أو مستند تفويض يحدد نطاق الوصول أو حقوق البث/التنزيل أو طريقة مصادقة تطبيق طرف ثالث**. يلزم توضيح هذه التفاصيل من مالك الخدمة قبل تنفيذ وصول حقيقي، ولا تعوض إضافة CloudStream ذلك. لا يعني هذا التشكيك في إفادة المستخدم، بل الفصل بين الإذن المبلّغ وآلية التكامل الموثقة.
5. **التنفيذ متعدد المنصات:** APK يصف Android وحده؛ لا يحدد شكل مصادقة معتمد يعمل على iOS أو Windows أو Linux، ولا يعالج فصل الهوية والتخزين والتنزيلات في AnimeWitcher. هذه أمور تتطلب تحققاً مستقلاً.

## 7. أدلة عملية يمكن تمريرها لفريق الدمج

- **تطابق أسماء مسارات عالي الثقة:** `home_content`, `search`, `details`, `episodes`, `sources`, `can_play`, `direct_link` ظاهرة في نصوص Flutter AOT **وفي Kotlin**. استخدمها لتحديد أسئلة عقد API الرسمي، دون افتراض استجابات أو توليد طلبات تقلّد تطبيق Android.
- **النطاق أوسع من إضافة CloudStream:** يحتوي APK نصوصاً لـ`seasons` و`schedule` والتعليقات والحسابات؛ ينبغي وسم هذه الوظائف **غير متحققة في مزود AnimeWitcher** إلى حين وجود واجهة مسموحة، لا وصفها بأنها غير موجودة لدى Anime Rift.
- **للاختبارات المحلية الآمنة:** يمكن بناء محللات نماذج من بيانات اصطناعية، واختبار العزل بين المزودين والانتقال والتاريخ والتنزيلات، مع تمييز الاختبار الوهمي عن إثبات اتصال حقيقي. يجب الحفاظ على فصل جلسة المزود وملفات التنزيل والترويسات والروابط المؤقتة وعدم خلطها مع مصدر AnimeWitcher الأصلي.
- **القرار المعلّق:** الحصول على **توثيق أو قناة وصول مصرح بها** تشمل عنوان الخدمة، طريقة هوية العميل، الحصص والأخطاء، صلاحيات تشغيل/تنزيل الوسائط، ومدد وصلاحيات الروابط. عندها فقط يمكن تحويل أدلة المسارات إلى تكامل طرفي قابل للتحقق.

**حالة التسليم:** هذا المستند نتائج فحص فقط؛ لم يُعدَّل منطق التطبيق ولم تُنشأ طلبات دخول أو توقيعات أو جلسات أو روابط بث. لا تُنقل منه أسرار أو قيم اعتماد.
