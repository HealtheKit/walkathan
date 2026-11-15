import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/firebase_constants.dart';
import '../../pages/auth/reset_password/reset_password_page.dart';
import '../../pages/auth/signin/signin_page.dart';
import '../../pages/auth/device/device_gate_page.dart';
import '../../pages/auth/device/select_profile_page.dart';
import '../../pages/auth/welcome/welcome_page.dart';
import '../../features/login/login_gate.dart';
import '../../features/walk_workout/presentation/walk_active_page.dart';
import '../../features/walk_workout/presentation/walk_setup_page.dart';
import '../../features/walk_workout/presentation/walk_summary_page.dart';
import '../../pages/admin/admin_events_page.dart';
import '../../pages/admin/admin_members_page.dart';
import '../../pages/admin/transfer_approvals_page.dart';
import '../../pages/content/profiles/profile_edit_page.dart';
import '../../pages/content/profiles/profile_transfer_page.dart';
import '../../pages/content/profiles/profiles_page.dart';
import '../../pages/content/settings/settings_page.dart';
import '../../repositories/account_repository.dart';
import '../../pages/content/change_password/change_password_page.dart';
import '../../pages/content/activity/activity_page.dart';
import '../../pages/content/social/social_page.dart';
import '../../pages/content/walk_home/walk_home_page.dart';
import '../../pages/content/event/event_dashboard_page.dart';
import '../../pages/content/home/home_page.dart';
import '../../pages/page_not_found.dart';
import '../../pages/splash/firebase_error_page.dart';
import '../../pages/splash/splash_page.dart';
import '../../repositories/auth_repository_provider.dart';
import 'route_names.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // ONE router for the life of the app. Re-creating it on every auth or
  // sign-in-stage change swaps the router under MaterialApp.router and
  // crashes with "_dependents.isEmpty is not true". Instead the router is
  // told to re-run its redirect whenever either changes.
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateStreamProvider, (prev, next) => refresh.value++);
  ref.listen(loginGateProvider.select((g) => g.stage), (prev, next) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authState = ref.read(authStateStreamProvider);
      final stage = ref.read(loginGateProvider).stage;
      if (authState is AsyncLoading<AuthState>) {
        return '/splash';
      }

      if (authState is AsyncError<AuthState>) {
        return '/firebaseError';
      }

      final session = supabaseClient.auth.currentSession;
      final authenticated = session != null;

      // Sign-up is closed: members are added by a Super Admin.
      final authenticating = (state.matchedLocation == '/signin') ||
          (state.matchedLocation == '/resetPassword');

      if (!authenticated) {
        return authenticating ? null : '/signin';
      }

      // First login: temporary password must be replaced and the privacy
      // notice accepted before anything else is reachable.
      final account = AccountRepository();
      final needsWelcome =
          account.mustChangePassword || !account.hasConsented;
      if (needsWelcome) {
        return state.matchedLocation == '/welcome' ? null : '/welcome';
      }

      // After the password/consent step: is this phone approved for the
      // login (a new phone waits for approval), and who is walking on it?
      final loc = state.matchedLocation;
      if (stage == LoginStage.chooseProfile) {
        return loc == '/selectProfile' ? null : '/selectProfile';
      }
      if (stage != LoginStage.ready) {
        return loc == '/device' ? null : '/device';
      }
      if (loc == '/device' || loc == '/selectProfile' || loc == '/welcome') {
        return '/home';
      }

      final splashing = state.matchedLocation == '/splash';

      return (authenticating || splashing) ? '/home' : null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        name: RouteNames.splash,
        builder: (context, state) {
          return const SplashPage();
        },
      ),
      GoRoute(
        path: '/firebaseError',
        name: RouteNames.firebaseError,
        builder: (context, state) {
          return const FirebaseErrorPage();
        },
      ),
      GoRoute(
        path: '/signin',
        name: RouteNames.signin,
        builder: (context, state) {
          return const SigninPage();
        },
      ),
      GoRoute(
        path: '/resetPassword',
        name: RouteNames.resetPassword,
        builder: (context, state) {
          return const ResetPasswordPage();
        },
      ),
      GoRoute(
        path: '/device',
        name: RouteNames.deviceGate,
        builder: (context, state) => const DeviceGatePage(),
      ),
      GoRoute(
        path: '/selectProfile',
        name: RouteNames.selectProfile,
        builder: (context, state) => const SelectProfilePage(),
      ),
      GoRoute(
        path: '/welcome',
        name: RouteNames.welcome,
        builder: (context, state) => const WelcomePage(),
      ),
      GoRoute(
        path: '/profiles',
        name: RouteNames.profiles,
        builder: (context, state) => const ProfilesPage(),
        routes: [
          GoRoute(
            path: 'new',
            name: RouteNames.profileNew,
            builder: (context, state) => const ProfileEditPage(),
          ),
          GoRoute(
            path: 'transfer',
            name: RouteNames.profileTransfer,
            builder: (context, state) => const ProfileTransferPage(),
          ),
          GoRoute(
            path: ':profileId',
            name: RouteNames.profileEdit,
            builder: (context, state) =>
                ProfileEditPage(profileId: state.pathParameters['profileId']),
          ),
        ],
      ),
      GoRoute(
        path: '/settings',
        name: RouteNames.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: '/admin/events',
        name: RouteNames.adminEvents,
        builder: (context, state) => const AdminEventsPage(),
      ),
      GoRoute(
        path: '/admin/transfers',
        name: RouteNames.transferApprovals,
        builder: (context, state) => const TransferApprovalsPage(),
      ),
      GoRoute(
        path: '/admin/members',
        name: RouteNames.adminMembers,
        builder: (context, state) => const AdminMembersPage(),
      ),
      GoRoute(
        path: '/home',
        name: RouteNames.home,
        builder: (context, state) {
          return const HomePage();
        },
        routes: [
          GoRoute(
            path: 'changePassword',
            name: RouteNames.changePassword,
            builder: (context, state) {
              return const ChangePasswordPage();
            },
          ),
        ],
      ),
      GoRoute(
        path: '/walkHome/:userId',
        name: RouteNames.walkHome,
        builder: (context, state) {
          final userId = state.pathParameters['userId']!;
          return WalkHomePage(userId: userId);
        },
      ),
      // Walk workout. '/walk' is the setup; the live walk and its summary are
      // separate so "Return to walk" can open them from anywhere.
      GoRoute(
        path: '/walk',
        builder: (context, state) => const WalkSetupPage(),
        routes: [
          GoRoute(path: 'active', builder: (context, state) => const WalkActivePage()),
          GoRoute(path: 'summary', builder: (context, state) => const WalkSummaryPage()),
        ],
      ),
      GoRoute(
        path: '/social',
        name: RouteNames.social,
        builder: (context, state) => const SocialPage(),
      ),
      GoRoute(
        path: '/activity',
        name: RouteNames.activity,
        builder: (context, state) => const ActivityPage(),
      ),
      GoRoute(
        path: '/leaderBoard',
        name: RouteNames.leaderBoard,
        builder: (context, state) => const EventDashboardPage(),
      ),
    ],
    errorBuilder: (context, state) {
      return PageNotFound(
        errorMessage: state.error.toString(),
      );
    },
  );
  ref.onDispose(router.dispose);
  return router;
});
