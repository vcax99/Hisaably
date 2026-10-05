import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../errors/app_failure.dart';
import '../errors/error_mapper.dart';

/// Key/value JSON cache of the last server responses (groups, categories,
/// dashboards) so read-only screens still open offline.
class CacheStore {
  CacheStore(this._db);

  final AppDatabase _db;

  Future<void> put(String key, Object? value) => _db
      .into(_db.cacheEntries)
      .insertOnConflictUpdate(
        CacheEntriesCompanion.insert(
          key: key,
          json: jsonEncode(value),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  /// Returns the cached value and when it was stored, or null.
  Future<({Object? value, DateTime updatedAt})?> get(String key) async {
    final row = await (_db.select(
      _db.cacheEntries,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    return (value: jsonDecode(row.json), updatedAt: row.updatedAt);
  }
}

/// Online: fetch, cache the raw response, parse. Offline: parse the last
/// cached response (the parsed value's age is passed to [parse]), or rethrow
/// the NetworkFailure when nothing is cached. Other errors propagate mapped.
Future<T> fetchWithCache<T>(
  CacheStore? cache,
  String key,
  Future<Object?> Function() fetchRaw,
  T Function(Object? raw, DateTime? cachedAt) parse,
) async {
  try {
    final raw = await fetchRaw();
    await cache?.put(key, raw);
    return parse(raw, null);
  } catch (e, st) {
    final failure = mapError(e, st);
    if (failure is NetworkFailure && cache != null) {
      final hit = await cache.get(key);
      if (hit != null) return parse(hit.value, hit.updatedAt);
    }
    throw failure;
  }
}

final cacheStoreProvider = Provider<CacheStore>(
  (ref) => CacheStore(ref.watch(appDatabaseProvider)),
);
