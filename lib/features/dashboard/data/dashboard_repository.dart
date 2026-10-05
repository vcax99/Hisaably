import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../../core/sync/cache_store.dart';
import '../../../core/utils/ist_date.dart';
import '../domain/dashboard.dart';

/// Server-side aggregation only: the app never downloads raw transactions to
/// compute totals. Throws [AppFailure]s.
abstract interface class DashboardRepository {
  /// [groupId] null = all groups the viewer can see ("All Groups").
  Future<DashboardData> getDashboard({
    String? groupId,
    required DateTime month,
  });

  /// Super Admin only.
  Future<AdminOverview> getAdminOverview();

  /// Per-group balance + [month]'s income/expense for every visible group.
  Future<List<GroupBalance>> getGroupBalances({required DateTime month});
}

class SupabaseDashboardRepository implements DashboardRepository {
  SupabaseDashboardRepository(this._client, [this._cache]);

  final SupabaseClient _client;
  final CacheStore? _cache;

  @override
  Future<DashboardData> getDashboard({
    String? groupId,
    required DateTime month,
  }) => fetchWithCache(
    _cache,
    'dashboard.${groupId ?? 'all'}.${IstDate.toIsoDate(month)}',
    () => _client.rpc<Map<String, dynamic>>(
      'get_dashboard',
      params: {
        'p_group_id': groupId,
        'p_month': IstDate.toIsoDate(month),
        'p_recent_limit': 5,
      },
    ),
    (raw, cachedAt) => DashboardData.fromJson(
      (raw! as Map).cast<String, dynamic>(),
      cachedAt: cachedAt,
    ),
  );

  @override
  Future<List<GroupBalance>> getGroupBalances({required DateTime month}) =>
      fetchWithCache(
        _cache,
        'dashboard.groups.${IstDate.toIsoDate(month)}',
        () => _client.rpc<List<dynamic>>(
          'get_group_balances',
          params: {'p_month': IstDate.toIsoDate(month)},
        ),
        (raw, _) => [
          for (final r in raw! as List)
            GroupBalance.fromJson((r as Map).cast<String, dynamic>()),
        ],
      );

  @override
  Future<AdminOverview> getAdminOverview() => fetchWithCache(
    _cache,
    'admin.overview',
    () => _client.rpc<Map<String, dynamic>>('get_admin_overview'),
    (raw, _) => AdminOverview.fromJson((raw! as Map).cast<String, dynamic>()),
  );
}

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => SupabaseDashboardRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(cacheStoreProvider),
  ),
);
