# Anime Rift Account and Download Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ربط حساب Anime Rift رسميًا برمز جهاز وتوجيه طلبات الحلقات والتنزيل المحمية بالتوكن المستعاد بأمان.

**Architecture:** يحتفظ `AnimeRiftApiClient` وحده بتوكن Rift داخل `flutter_secure_storage` مع عزل namespace/service، ويضيفه إلى الترويسة الحالية. يمرر `AnimeRiftProvider` API ضيقة إلى خانة إعدادات مدمجة؛ لا يتغير حساب AnimeWitcher ولا التخزين المحلي للمكتبات ولا Download Manager V2.

**Tech Stack:** Flutter/Dart، Dio، flutter_secure_storage 11.2.0، SharedPreferences لهوية التثبيت غير السرية، Flutter widget/unit tests.

**Spec:** `docs/superpowers/specs/2026-11-03-animerift-code-linking-design-ar.md`

## Global Constraints

- لا تُحفظ رموز Rift في SharedPreferences أو Hive ولا يوجد plaintext fallback.
- لا تُستعمل جلسة AnimeWitcher أو MAL أو AniList ولا تُحذف أي من مفاتيحها.
- لا يتغير مزود الأنمي النشط عند ربط حساب Rift أو إلغاء ربطه.
- لا يُقبل إلا HTTPS على بوابتي Rift المسموحتين، ويبقى `request()` العام مقيدًا بـ`library/*`.
- لا تُولد رموز دخول ولا تُخمن، ولا تُفعل اشتراكات أو إعلانات أو DRM اصطناعيًا.
- لا تضاف dependency جديدة؛ يعاد استعمال `flutter_secure_storage` الموجود.

## Review Focus

- رمز فارغ أو طويل/يحوي محارف تحكم: يرفض محليًا ولا يرسل طلبًا.
- رد 200 ناقص `items.profile` أو `items.token`: لا يُحفظ شيء ولا تصبح الجلسة مرتبطة.
- فشل الكتابة الآمنة بعد قبول الخادم: يظهر فشل ولا يبقى التوكن فعالًا في الذاكرة.
- توكن محفوظ لهوية تثبيت أخرى أو JSON تالف: لا يُستخدم في ترويسة API ولا يمس بيانات المزودات الأخرى.
- 401/403 بعد إعادة تسجيل الجهاز: يبقى الخطأ صريحًا ولا يتحول الطلب إلى AnimeWitcher أو تنزيل ضيف مزيف.

---

### Task 1: Secure Rift session and fixed code sign-in contract

**Files:**
- Modify: `lib/core/extensions/providers/anime_rift_api_client.dart`
- Modify: `lib/core/extensions/providers/anime_rift_streams.dart`
- Test: `test/core/extensions/providers/anime_rift_api_client_test.dart`

**Interfaces:**
- Consumes: `AnimeRiftConfig`، هوية التثبيت الحالية، و`FlutterSecureStorage`.
- Produces: `Future<bool> restoreAccountSession()`، `Future<void> signInWithCode(String code)`، `Future<void> signOut()`، و`bool get isAccountLinked`.

- [ ] **Step 1: Write failing client tests**

أضف اختبارات بأسماء صريحة تثبت: POST والجسم والنطاق؛ حفظ التوكن آمنًا ثم إرساله إلى download `can_play`؛ الاستعادة بعد إنشاء client جديد؛ عدم وجود التوكن في SharedPreferences؛ رفض الرد المشوه؛ رفض فشل التخزين؛ وحذف مفتاح Rift وحده.

- [ ] **Step 2: Run the tests and verify RED**

Run: `flutter test --no-pub test/core/extensions/providers/anime_rift_api_client_test.dart`

Expected: FAIL لأن API الربط والجلسة الآمنة غير موجودة.

- [ ] **Step 3: Implement the minimal client session**

أضف `FlutterSecureStorage` محقونًا، مفتاحًا واحدًا بإصدار، استعادة مرتبطة بـ`deviceId`، POST ثابتًا إلى `/auth/sign-in/with-code`، تحققًا محافظًا من الرد، وترويسة `Bearer <token>`؛ انقل `AnimeRiftAuthenticationRequired` إلى ملف العميل لتجنب اعتماد دائري.

- [ ] **Step 4: Run client and stream tests GREEN**

Run: `flutter test --no-pub test/core/extensions/providers/anime_rift_api_client_test.dart test/core/extensions/providers/anime_rift_streams_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/extensions/providers/anime_rift_api_client.dart lib/core/extensions/providers/anime_rift_streams.dart test/core/extensions/providers/anime_rift_api_client_test.dart
git commit -m "feat(animerift): add secure code-linked sessions"
```

### Task 2: Provider API and integrated settings control

**Files:**
- Modify: `lib/core/extensions/providers/anime_rift_provider.dart`
- Modify: `lib/features/settings/presentation/widgets/anime_provider_picker.dart`
- Modify: `lib/features/settings/presentation/settings_screen.dart`
- Test: `test/features/settings/presentation/anime_provider_selection_test.dart`

**Interfaces:**
- Consumes: Task 1 session methods through the provider-owned client.
- Produces: provider account methods and `AnimeRiftAccountSettingsTile` without changing `activeProviderProvider`.

- [ ] **Step 1: Write failing widget tests**

اختبر ظهور خانة الربط عند تسجيل Rift، إدخال رمز وتمريره بعد trim، تحديث الحالة، بقاء المزود النشط كما هو، ثم إلغاء الربط دون حذف إعداد اختيار المزود.

- [ ] **Step 2: Run the widget test and verify RED**

Run: `flutter test --no-pub test/features/settings/presentation/anime_provider_selection_test.dart`

Expected: FAIL لأن خانة الربط وAPI المزود غير موجودتين.

- [ ] **Step 3: Implement provider forwarding and settings tile**

أضف عمليات ضيقة إلى `AnimeRiftProvider`، وخانة إعدادات بحوار رمز وحالة تحميل/خطأ وتأكيد إلغاء الربط. لا تنشئ شاشة حساب جديدة ولا تغيّر المزود النشط.

- [ ] **Step 4: Run widget and provider regressions GREEN**

Run: `flutter test --no-pub test/features/settings/presentation/anime_provider_selection_test.dart test/core/extensions/providers/anime_rift_provider_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/extensions/providers/anime_rift_provider.dart lib/features/settings/presentation/widgets/anime_provider_picker.dart lib/features/settings/presentation/settings_screen.dart test/features/settings/presentation/anime_provider_selection_test.dart
git commit -m "feat(animerift): expose account linking in settings"
```

### Task 3: Download-route regression, documentation, and branch validation

**Files:**
- Modify: `test/core/extensions/providers/anime_rift_api_client_test.dart`
- Modify: `docs/animerift-apk-and-reference-evidence-ar.md`
- Modify: `docs/animerift-features-validation-ar.md`
- Modify: `docs/animerift-investigation-roadmap-ar.md`

**Interfaces:**
- Consumes: Task 1 bearer restoration and existing V2 provider refresh routing.
- Produces: executable regression proving authenticated `can_play` routing and an honest E2E status.

- [ ] **Step 1: Add or refine the failing download-path regression**

يثبت الاختبار أن طلب `library/episode/source/can_play` ذو `is_download: true` يحمل توكن المستخدم بعد الربط وبعد restart، وأن تسجيل الخروج يعيده إلى `Bearer null` دون تغيير descriptor أو provider ID.

- [ ] **Step 2: Run RED if the behavior is not already covered, then GREEN after the smallest fix**

Run: `flutter test --no-pub test/core/extensions/providers/anime_rift_api_client_test.dart test/core/extensions/providers/anime_rift_streams_test.dart test/core/services/download_v2`

Expected: PASS بعد تنفيذ أقل تعديل لازم.

- [ ] **Step 3: Update Arabic evidence and checklist**

سجّل عنواني AOT المرصودين، حدود التحليل الثابت، الاختبارات المنفذة، وأن E2E الحسابي الحقيقي ينتظر رمزًا صالحًا من المالك.

- [ ] **Step 4: Format, analyze, focused tests, then CI**

Run: `dart format --output=none --set-exit-if-changed <changed dart files>`

Run: `flutter analyze --no-pub`

Run: `flutter test --no-pub test/core/extensions/providers/anime_rift_api_client_test.dart test/core/extensions/providers/anime_rift_streams_test.dart test/features/settings/presentation/anime_provider_selection_test.dart test/core/services/download_v2`

Expected: no analyzer errors and all focused tests PASS. Push the dedicated branch, update Draft PR #280, and let GitHub Actions provide the full cross-platform gate and unsigned iOS artifact.

- [ ] **Step 5: Commit**

```bash
git add docs test/core/extensions/providers/anime_rift_api_client_test.dart
git commit -m "docs(animerift): record authenticated download boundary"
```

## Self-review result

- Spec coverage: secure storage, fixed endpoint, bearer routing, restart, sign-out isolation, UI, download path, and E2E limitation all map to tasks.
- Type consistency: Task 2 consumes the four exact methods produced by Task 1; Task 3 uses the same client request path already consumed by streams.
- Proportion: three independently testable tasks; no new account framework or dependency.
- Ruling: the existing dedicated branch is retained instead of creating another worktree because the user explicitly required all integration work on this one branch and it is clean. Cost if wrong: weaker filesystem isolation, mitigated by explicit staging and CI.
