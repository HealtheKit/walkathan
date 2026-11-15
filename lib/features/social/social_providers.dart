import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/firebase_constants.dart';
import '../../core/time/local_day.dart';
import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/handle_exception.dart';
import 'social_models.dart';

/// Friends and groups. Every call names the acting profile; the server
/// verifies the signed-in account owns it and enforces all permissions.
class SocialRepository {
  String get _today => dateKey(DateTime.now());

  Future<T> _run<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      final msg = e.toString();
      for (final entry in const {
        'make someone else the owner first':
            'Make someone else the owner first, or delete the group.',
        'you cannot remove this member': 'You can\'t remove this member.',
        'not allowed in this group': 'You don\'t have permission to do that in this group.',
        'group limit reached': 'You already own the maximum number of groups.',
        'invalid date range': 'Choose a range of 1 to 366 days.',
        'groups_check': 'A challenge must run between 1 day and 1 year.',
      }.entries) {
        if (msg.contains(entry.key)) {
          throw CustomError(code: 'social', message: entry.value, plugin: 'supabase_db');
        }
      }
      throw handleException(e);
    }
  }

  // ---------------------------------------------------------- friends
  Future<FriendsOverview> friendsOverview(String me) => _run(() async =>
      FriendsOverview.fromMap(await supabaseClient.rpc('friends_overview',
          params: {'p_me': me, 'p_local_date': _today}) as Map));

  Future<List<RankRow>> friendBoard(String me, SocialPeriod period) =>
      _run(() async => parseRankRows((await supabaseClient.rpc('friend_board', params: {
            'p_me': me,
            'p_period': period.wire,
            'p_local_date': _today,
          }) as Map)['rows']));

  /// sent | accepted | pending | already_friends | not_found | limit
  Future<String> requestByCode(String me, String code) => _run(() async =>
      await supabaseClient.rpc('friend_request', params: {'p_me': me, 'p_code': code})
          as String);

  Future<String> requestProfile(String me, String profileId) => _run(() async =>
      await supabaseClient.rpc('friend_request',
          params: {'p_me': me, 'p_profile': profileId}) as String);

  Future<void> respond(String me, String other, bool accept) => _run(() =>
      supabaseClient.rpc('friend_respond',
          params: {'p_me': me, 'p_other': other, 'p_accept': accept}));

  Future<void> removeFriend(String me, String other) => _run(() =>
      supabaseClient.rpc('friend_remove', params: {'p_me': me, 'p_other': other}));

  Future<void> setHidden(String me, String other, bool hidden) => _run(() =>
      supabaseClient.rpc('friend_set_hidden',
          params: {'p_me': me, 'p_other': other, 'p_hidden': hidden}));

  Future<void> setBlocked(String me, String other, bool blocked) => _run(() =>
      supabaseClient.rpc('friend_block',
          params: {'p_me': me, 'p_other': other, 'p_blocked': blocked}));

  // ----------------------------------------------------------- groups
  Future<List<GroupInfo>> myGroups(String me) => _run(() async => [
        for (final g in (await supabaseClient.rpc('my_groups', params: {'p_me': me}) as List))
          GroupInfo.fromMap(g as Map),
      ]);

  Future<String> createGroup(String me, String name) => _run(() async =>
      await supabaseClient.rpc('group_create', params: {
        'p_me': me,
        'p_name': name,
        'p_tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      }) as String);

  /// joined | already_member | invalid | full | rate_limited
  Future<({String status, String? groupId})> joinGroup(String me, String code) =>
      _run(() async {
        final r = await supabaseClient
            .rpc('group_join', params: {'p_me': me, 'p_code': code}) as Map;
        return (status: r['status'] as String, groupId: r['group_id'] as String?);
      });

  Future<GroupBoard> groupBoard(String me, String groupId, SocialPeriod period) =>
      _run(() async => GroupBoard.fromMap(await supabaseClient.rpc('group_board', params: {
            'p_me': me,
            'p_group': groupId,
            'p_period': period.wire,
            'p_local_date': _today,
          }) as Map));

  Future<List<GroupMember>> groupMembers(String me, String groupId) => _run(() async => [
        for (final m in (await supabaseClient.rpc('group_members_list',
            params: {'p_me': me, 'p_group': groupId}) as List))
          GroupMember.fromMap(m as Map),
      ]);

  Future<void> updateGroup(String me, String groupId,
          {String? name, bool? chat, bool? taunts, bool? mystery}) =>
      _run(() => supabaseClient.rpc('group_update', params: {
            'p_me': me,
            'p_group': groupId,
            'p_name': name,
            'p_chat': chat,
            'p_taunts': taunts,
            'p_mystery': mystery,
            // keep the group's clock in step with its admin's phone
            'p_tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
          }));

  Future<void> setChallenge(String me, String groupId, DateTime? start, DateTime? end) =>
      _run(() => supabaseClient.rpc('group_set_challenge', params: {
            'p_me': me,
            'p_group': groupId,
            'p_start': start == null ? null : dateKey(start),
            'p_end': end == null ? null : dateKey(end),
          }));

  Future<String> createInvite(String me, String groupId) => _run(() async =>
      await supabaseClient.rpc('group_invite_create',
          params: {'p_me': me, 'p_group': groupId}) as String);

  Future<int> revokeInvites(String me, String groupId) => _run(() async =>
      (await supabaseClient.rpc('group_invites_revoke',
          params: {'p_me': me, 'p_group': groupId}) as num).toInt());

  Future<Map> exportReport(String me, String groupId, DateTime from, DateTime to) =>
      _run(() async => await supabaseClient.rpc('group_export', params: {
            'p_me': me,
            'p_group': groupId,
            'p_from': dateKey(from),
            'p_to': dateKey(to),
          }) as Map);

  Future<void> removeMember(String me, String groupId, String target) => _run(() =>
      supabaseClient.rpc('group_remove_member',
          params: {'p_me': me, 'p_group': groupId, 'p_target': target}));

  Future<void> setRole(String me, String groupId, String target, GroupRole role) =>
      _run(() => supabaseClient.rpc('group_set_role', params: {
            'p_me': me,
            'p_group': groupId,
            'p_target': target,
            'p_role': role.name,
          }));

  Future<void> leaveGroup(String me, String groupId) => _run(() =>
      supabaseClient.rpc('group_leave', params: {'p_me': me, 'p_group': groupId}));

  Future<void> deleteGroup(String me, String groupId) => _run(() =>
      supabaseClient.rpc('group_delete', params: {'p_me': me, 'p_group': groupId}));
}

final socialRepositoryProvider =
    Provider<SocialRepository>((ref) => SocialRepository());

/// The acting profile's id (the active profile on this device).
final _meProvider = FutureProvider.autoDispose<String?>(
    (ref) async => (await ref.watch(activeProfileProvider.future))?.id);

final friendsOverviewProvider = FutureProvider.autoDispose<FriendsOverview?>((ref) async {
  final me = await ref.watch(_meProvider.future);
  if (me == null) return null;
  return ref.watch(socialRepositoryProvider).friendsOverview(me);
});

final friendBoardProvider =
    FutureProvider.autoDispose.family<List<RankRow>, SocialPeriod>((ref, period) async {
  final me = await ref.watch(_meProvider.future);
  if (me == null) return const [];
  return ref.watch(socialRepositoryProvider).friendBoard(me, period);
});

final myGroupsProvider = FutureProvider.autoDispose<List<GroupInfo>>((ref) async {
  final me = await ref.watch(_meProvider.future);
  if (me == null) return const [];
  return ref.watch(socialRepositoryProvider).myGroups(me);
});

typedef GroupBoardKey = ({String groupId, SocialPeriod period});

final groupBoardProvider =
    FutureProvider.autoDispose.family<GroupBoard, GroupBoardKey>((ref, key) async {
  final me = await ref.watch(_meProvider.future);
  if (me == null) throw const CustomError(message: 'No active profile.');
  return ref.watch(socialRepositoryProvider).groupBoard(me, key.groupId, key.period);
});

final groupMembersProvider =
    FutureProvider.autoDispose.family<List<GroupMember>, String>((ref, groupId) async {
  final me = await ref.watch(_meProvider.future);
  if (me == null) return const [];
  return ref.watch(socialRepositoryProvider).groupMembers(me, groupId);
});
