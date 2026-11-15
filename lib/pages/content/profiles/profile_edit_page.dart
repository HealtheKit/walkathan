import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/countries.dart';
import '../../../models/custom_error.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../repositories/profile_repository_provider.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/buttons.dart';
import '../../widgets/state_widgets.dart';

/// Create (profileId == null) or edit a walker profile.
class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key, this.profileId});

  final String? profileId;

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _goal = TextEditingController(text: '${WalkerProfile.defaultGoal}');
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _birthYear = TextEditingController();
  ProfileRelation _relation = ProfileRelation.spouse;
  String? _country;
  String? _sex;
  bool _share = true;
  bool _loaded = false;
  bool _saving = false;
  WalkerProfile? _existing;

  bool get _isNew => widget.profileId == null;

  @override
  void dispose() {
    for (final c in [_name, _goal, _height, _weight, _birthYear]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(WalkerProfile p) {
    if (_loaded) return;
    _loaded = true;
    _existing = p;
    _relation = p.relation;
    _name.text = p.displayName;
    _goal.text = '${p.dailyGoal}';
    _height.text = p.heightCm?.toString() ?? '';
    _weight.text = p.weightKg?.toString() ?? '';
    _birthYear.text = p.birthYear?.toString() ?? '';
    _country = p.countryCode;
    _sex = p.sex;
    _share = p.shareWithFriends;
  }

  String? _optionalNumber(String? v, num min, num max, String label) {
    if (v == null || v.trim().isEmpty) return null;
    final n = num.tryParse(v.trim());
    if (n == null || n < min || n > max) return '$label must be $min to $max';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = ref.read(profileRepositoryProvider);
    final details = WalkerProfile(
      id: _existing?.id ?? '',
      accountId: _existing?.accountId ?? '',
      relation: _relation,
      displayName: _name.text.trim(),
      countryCode: _country,
      heightCm: double.tryParse(_height.text.trim()),
      weightKg: double.tryParse(_weight.text.trim()),
      birthYear: int.tryParse(_birthYear.text.trim()),
      sex: _sex,
      dailyGoal: int.parse(_goal.text.trim()),
      shareWithFriends: _share,
    );
    try {
      if (_isNew) {
        await repo.addProfile(relation: _relation, details: details);
      } else {
        await repo.updateProfile(details);
      }
      ref.invalidate(profilesProvider);
      if (!mounted) return;
      showAppSnackBar(context, _isNew ? 'Profile added' : 'Profile saved');
      context.go('/profiles');
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = _existing?.displayName ?? 'this profile';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text(
            'This permanently deletes $name and all of their step history. '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await ref.read(profileRepositoryProvider).deleteProfile(_existing!.id);
      ref.invalidate(profilesProvider);
      if (!mounted) return;
      context.go('/profiles');
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (!_isNew) {
      final profiles = ref.watch(profilesProvider);
      final found = profiles.value
          ?.where((p) => p.id == widget.profileId)
          .firstOrNull;
      if (found != null) _load(found);
      if (!_loaded) {
        return Scaffold(
          appBar: AppBar(title: const Text('Profile')),
          body: profiles.isLoading
              ? const LoadingState()
              : ErrorState(
                  message: 'This profile could not be found.',
                  onRetry: () => ref.invalidate(profilesProvider)),
        );
      }
    }

    final isSelf = _existing?.isSelf ?? false;
    final year = DateTime.now().year;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add a profile' : 'Edit profile'),
        leading: BackButton(onPressed: () => context.go('/profiles')),
      ),
      body: PageContainer(
        maxWidth: AppSpacing.formMaxWidth + 80,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: AppSpacing.pagePadding,
            children: [
              if (_isNew) ...[
                DropdownButtonFormField<ProfileRelation>(
                  initialValue: _relation,
                  decoration: const InputDecoration(
                      labelText: 'Who is this?',
                      prefixIcon: Icon(Icons.family_restroom)),
                  items: [
                    for (final r in ProfileRelation.values)
                      if (r != ProfileRelation.self)
                        DropdownMenuItem(value: r, child: Text(r.label)),
                  ],
                  onChanged: (r) => setState(() => _relation = r!),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.length < 2 || t.length > 40) {
                    return 'Name must be 2 to 40 characters';
                  }
                  return null;
                },
              ),
              if (_relation == ProfileRelation.child) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusField),
                  ),
                  child: Text(
                    'You manage this child\'s profile. Their name and steps '
                    'can appear on event leaderboards, so please only add a '
                    'child if you are their parent or guardian.',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _goal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Daily step goal',
                    prefixIcon: Icon(Icons.flag_outlined)),
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n < 1000 || n > 100000) {
                    return 'Goal must be 1,000 to 100,000 steps';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              DropdownButtonFormField<String?>(
                initialValue: _country,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Country (for country rankings)',
                    prefixIcon: Icon(Icons.public)),
                items: [
                  for (final c in kCountries)
                    DropdownMenuItem(value: c.code, child: Text(c.name)),
                ],
                onChanged: (c) => setState(() => _country = c),
              ),
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _share,
                onChanged: (v) => setState(() => _share = v),
                title: const Text('Share steps with friends'),
                subtitle: const Text(
                    'Only friends this person has accepted can see their '
                    'steps. Turn off to hide steps from all friends. Event '
                    'and group leaderboards work separately.'),
              ),
              DropdownButtonFormField<String?>(
                initialValue: _sex,
                decoration: const InputDecoration(
                    labelText: 'Sex',
                    helperText: 'Used for the men\'s and women\'s boards',
                    prefixIcon: Icon(Icons.wc_outlined)),
                validator: (v) => v == null ? 'Please choose' : null,
                items: const [
                  DropdownMenuItem(value: 'female', child: Text('Female')),
                  DropdownMenuItem(value: 'male', child: Text('Male')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (s) => setState(() => _sex = s),
              ),
              const SizedBox(height: AppSpacing.md),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Optional: improves calorie estimates'),
                childrenPadding: const EdgeInsets.only(bottom: AppSpacing.md),
                children: [
                  TextFormField(
                    controller: _height,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Height (cm)',
                        prefixIcon: Icon(Icons.height)),
                    validator: (v) => _optionalNumber(v, 50, 260, 'Height'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _weight,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Weight (kg)',
                        prefixIcon: Icon(Icons.monitor_weight_outlined)),
                    validator: (v) => _optionalNumber(v, 20, 400, 'Weight'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _birthYear,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Birth year',
                        prefixIcon: Icon(Icons.cake_outlined)),
                    validator: (v) => _optionalNumber(v, 1900, year, 'Year'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                  label: _isNew ? 'Add profile' : 'Save',
                  loading: _saving,
                  onPressed: _save),
              if (!_isNew && !isSelf) ...[
                const SizedBox(height: AppSpacing.md),
                TextButton.icon(
                  onPressed: _saving ? null : _delete,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete this profile'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
