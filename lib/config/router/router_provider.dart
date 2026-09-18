import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:walkathan/pages/content/leader_board/female_board_page.dart';
import 'package:walkathan/pages/content/leader_board/male_board_page.dart';

import '../../constants/firebase_constants.dart';
import '../../pages/auth/reset_password/reset_password_page.dart';
import '../../pages/auth/signin/signin_page.dart';
import '../../pages/auth/signup/signup_page.dart';
import '../../pages/content/change_password/change_password_page.dart';
import '../../pages/content/walk_home/walk_home_page.dart';
import '../../pages/content/leader_board/leader_board_page.dart';
import '../../pages/content/home/home_page.dart';
import '../../pages/page_not_found.dart';
import '../../pages/splash/firebase_error_page.dart';
import '../../pages/splash/splash_page.dart';
import '../../repositories/auth_repository_provider.dart';
import 'route_names.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateStreamProvider);

  return GoRouter(
    initialLocation: '/splash',
    redirect: (context, state) {
      if (authState is AsyncLoading<AuthState>) {
        return '/splash';
      }

      if (authState is AsyncError<AuthState>) {
        return '/firebaseError';
      }

      final session = supabaseClient.auth.currentSession;
      final authenticated = session != null;

      final authenticating = (state.matchedLocation == '/signin') ||
          (state.matchedLocation == '/signup') ||
          (state.matchedLocation == '/resetPassword');

      if (!authenticated) {
        return authenticating ? null : '/signin';
      }

      // Supabase handles email verification differently — 
      // if you have email confirmations enabled, users won't be able to sign in
      // until confirmed. So we skip the verifyEmail redirect here.

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
        path: '/signup',
        name: RouteNames.signup,
        builder: (context, state) {
          return const SignupPage();
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
      GoRoute(
        path: '/leaderBoard',
        name: RouteNames.leaderBoard,
        builder: (context, state) {
          return LeaderBoardPage();
        },
      ),
      GoRoute(
        path: '/maleLeaderBoard',
        name: RouteNames.maleLeaderBoard,
        builder: (context, state) {
          return MaleBoardPage();
        },
      ),
      GoRoute(
        path: '/femaleLeaderBoard',
        name: RouteNames.femaleLeaderBoard,
        builder: (context, state) {
          return FeMaleBoardPage();
        },
      ),
    ],
    errorBuilder: (context, state) {
      return PageNotFound(
        errorMessage: state.error.toString(),
      );
    },
  );
});
