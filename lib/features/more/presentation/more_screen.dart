import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../characters/presentation/characters_screen.dart';
import '../../settings/presentation/account_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import 'broadcast_schedule_screen.dart';
import 'coming_soon_screen.dart';
import 'global_statistics_screen.dart';
import 'recent_watched_screen.dart';
import 'seasons_screen.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isArabic = _isArabic(context);
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom + 88;
    final accountState = ref.watch(animeWitcherAccountControllerProvider);
    final accountProfile = accountState.asData?.value.profile;
    final accountPhotoUrl = accountProfile?.photoUrl?.trim() ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(isArabic ? 'المزيد' : 'More'),
        centerTitle: false,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          _MoreTile(
            icon: accountProfile == null
                ? Icons.account_circle_rounded
                : Icons.cloud_done_rounded,
            leading: accountPhotoUrl.isEmpty
                ? null
                : CircleAvatar(
                    radius: 24,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    foregroundImage: NetworkImage(accountPhotoUrl),
                    onForegroundImageError: (_, _) {},
                    child: Icon(
                      Icons.person_rounded,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
            title: accountProfile == null
                ? (isArabic
                      ? 'تسجيل الدخول أو إنشاء حساب'
                      : 'Sign in or create an account')
                : _accountDisplayName(accountProfile),
            subtitle: accountState.isLoading
                ? (isArabic ? 'جارٍ التحقق من الحساب...' : 'Checking account...')
                : accountProfile == null
                ? (isArabic
                      ? 'مزامنة القوائم والحلقات المشاهدة '
                            'وتقدم التشغيل'
                      : 'Sync lists, watched episodes, and playback progress')
                : accountProfile.email ??
                      (isArabic
                          ? 'المزامنة مفعلة'
                          : 'Synchronization enabled'),
            trailing: accountState.isLoading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const AnimeWitcherAccountScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.history_rounded,
            title: isArabic ? 'آخر المشاهدات' : 'Recently watched',
            subtitle: isArabic
                ? 'آخر الأنميات والأفلام التي شاهدتها'
                : 'Anime and movies you watched recently',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const RecentWatchedScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.groups_rounded,
            title: isArabic ? 'الشخصيات' : 'Characters',
            subtitle: isArabic
                ? 'تصفح الشخصيات وابحث عنها وأدر المفضلة'
                : 'Browse, search, and favorite characters',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const CharactersScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.upcoming_rounded,
            title: isArabic ? 'القادم قريبًا' : 'Coming soon',
            subtitle: isArabic
                ? 'أنميات لم يتم بثها بعد حسب بيانات AnimeWitcher'
                : 'Anime that has not aired yet, from AnimeWitcher',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const ComingSoonScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.query_stats_rounded,
            title: isArabic ? 'الإحصائيات العالمية' : 'Global statistics',
            subtitle: isArabic
                ? 'إحصائيات المشاهدات والحلقات والأفلام'
                : 'Global viewing, episode, and movie statistics',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const GlobalStatisticsScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.calendar_month_rounded,
            title: isArabic ? 'المواسم' : 'Seasons',
            subtitle: isArabic
                ? 'الموسم السابق والحالي والقادم وجميع المواسم'
                : 'Previous, current, next, and all seasons',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const SeasonsScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MoreTile(
            icon: Icons.calendar_view_week_rounded,
            title: isArabic ? 'جدول البث' : 'Broadcast schedule',
            subtitle: isArabic
                ? 'الأنميات موزعة على أيام الأسبوع السبعة'
                : 'Anime grouped across the seven weekdays',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const BroadcastScheduleScreen(),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Divider(color: theme.dividerColor.withValues(alpha: 0.55)),
          const SizedBox(height: 8),
          _MoreTile(
            icon: Icons.settings_rounded,
            title: isArabic ? 'الإعدادات' : 'Settings',
            subtitle: isArabic
                ? 'إعدادات التطبيق والمشغل'
                : 'App and player settings',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final Widget? leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _MoreTile({
    required this.icon,
    this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              leading ??
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: colors.primary),
                  ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.onSurfaceVariant,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

String _accountDisplayName(AnimeWitcherProfile profile) {
  final userName = profile.userName?.trim() ?? '';
  if (userName.isNotEmpty) return userName;
  final email = profile.email?.trim() ?? '';
  return email.isEmpty ? 'AnimeWitcher' : email;
}
