import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';

/// In-memory ledger mirroring the server rules used by the UI tests.
class FakeLedger {
  FakeLedger({this.canManage = false});

  /// Whether the signed-in viewer may edit/delete (Group Admin / Super Admin).
  bool canManage;
  final transactions = <String, Transaction>{};

  /// Soft-deleted ids (for findById).
  final deletedTypes = <String, TransactionType>{};
  final categories = <Category>[];
  final listCalls = <TransactionCursor?>[];
  int _seq = 0;
  int _clock = 0;

  void seedCategories(String groupId) {
    for (final (type, names) in [
      (TransactionType.expense, ['Food', 'Groceries', 'Rent']),
      (TransactionType.income, ['Contribution', 'Salary']),
    ]) {
      for (final n in names) {
        categories.add(
          Category(
            id: 'c-${++_seq}',
            groupId: groupId,
            type: type,
            name: n,
            isActive: true,
          ),
        );
      }
    }
  }

  Transaction seed(
    String groupId,
    TransactionType type,
    int paise, {
    String? category,
    DateTime? date,
    String? description,
  }) {
    final t = Transaction(
      id: 't-${++_seq}',
      groupId: groupId,
      type: type,
      amountPaise: paise,
      category: category,
      description: description,
      date: date ?? IstDate.today(),
      createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: ++_clock)),
    );
    transactions[t.id] = t;
    return t;
  }
}

class FakeTransactionsRepository implements TransactionsRepository {
  FakeTransactionsRepository(this.db);

  final FakeLedger db;

  @override
  Future<TransactionLookup> findById(String id) async {
    final t = db.transactions[id];
    if (t != null) return TransactionFound(t);
    final type = db.deletedTypes[id];
    return type != null
        ? TransactionDeleted(type)
        : const TransactionUnavailable();
  }

  String? _canonical(TransactionDraft d) {
    final name = d.category?.trim();
    if (name == null || name.isEmpty) return null;
    final existing = db.categories.where(
      (c) =>
          c.groupId == d.groupId &&
          c.type == d.type &&
          c.name.toLowerCase() == name.toLowerCase(),
    );
    if (existing.isNotEmpty) return existing.first.name;
    db.categories.add(
      Category(
        id: 'c-new-${db.categories.length}',
        groupId: d.groupId,
        type: d.type,
        name: name,
        isActive: true,
      ),
    );
    return name;
  }

  void _validate(TransactionDraft d) {
    if (d.amountPaise <= 0) {
      throw const ValidationFailure('Amount must be greater than zero.');
    }
    if (IstDate.isFuture(d.date)) {
      throw const ValidationFailure(
        'Transaction date cannot be in the future.',
      );
    }
  }

  @override
  Future<Transaction> add(TransactionDraft draft, {String? id}) async {
    final key = id ?? 'new-${db.transactions.length + 1}';
    final existing = db.transactions[key];
    if (existing != null) return existing; // idempotent
    _validate(draft);
    final t = Transaction(
      id: key,
      groupId: draft.groupId,
      type: draft.type,
      amountPaise: draft.amountPaise,
      category: _canonical(draft),
      description: draft.description,
      date: draft.date,
      createdAt: DateTime.utc(2026, 6, 1).add(Duration(seconds: ++db._clock)),
    );
    db.transactions[key] = t;
    return t;
  }

  @override
  Future<Transaction> update(
    String id,
    TransactionDraft draft, {
    required int expectedVersion,
  }) async {
    if (!db.canManage) {
      throw const PermissionFailure(
        'Only the Group Admin can edit transactions.',
      );
    }
    final t = db.transactions[id]!;
    if (t.syncVersion != expectedVersion) {
      throw const RuleFailure(
        'CONFLICT',
        'This transaction was changed by someone else.',
      );
    }
    _validate(draft);
    final updated = Transaction(
      id: id,
      groupId: t.groupId,
      type: draft.type,
      amountPaise: draft.amountPaise,
      category: _canonical(draft),
      description: draft.description,
      date: draft.date,
      createdAt: t.createdAt,
      syncVersion: t.syncVersion + 1,
    );
    db.transactions[id] = updated;
    return updated;
  }

  @override
  Future<void> delete(String id, {required int expectedVersion}) async {
    if (!db.canManage) {
      throw const PermissionFailure(
        'Only the Group Admin can delete transactions.',
      );
    }
    final removed = db.transactions.remove(id);
    if (removed != null) db.deletedTypes[id] = removed.type;
  }

  List<Transaction> _matching(TransactionFilter f) {
    final list = db.transactions.values.where((t) {
      if (f.groupId != null && t.groupId != f.groupId) return false;
      if (f.type != null && t.type != f.type) return false;
      if (f.from != null && t.date.isBefore(f.from!)) return false;
      if (f.to != null && t.date.isAfter(f.to!)) return false;
      if (f.category != null &&
          (t.category ?? '').toLowerCase() != f.category!.toLowerCase()) {
        return false;
      }
      if (f.minPaise != null && t.amountPaise < f.minPaise!) return false;
      if (f.maxPaise != null && t.amountPaise > f.maxPaise!) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      final d = b.date.compareTo(a.date);
      if (d != 0) return d;
      final c = b.createdAt!.compareTo(a.createdAt!);
      if (c != 0) return c;
      return b.id.compareTo(a.id);
    });
    return list;
  }

  @override
  Future<TransactionPage> list(
    TransactionFilter filter, {
    TransactionCursor? after,
    int limit = 30,
  }) async {
    db.listCalls.add(after);
    var list = _matching(filter);
    if (after != null) {
      final i = list.indexWhere((t) => t.id == after.id);
      list = list.sublist(i + 1);
    }
    final hasMore = list.length > limit;
    return TransactionPage(list.take(limit).toList(), hasMore: hasMore);
  }

  @override
  Future<int> total(TransactionFilter filter) async => _matching(
    TransactionFilter(
      groupId: filter.groupId,
      type: filter.type,
      from: filter.from,
      to: filter.to,
      category: filter.category,
    ),
  ).fold<int>(0, (sum, t) => sum + t.amountPaise);
}

class FakeCategoriesRepository implements CategoriesRepository {
  FakeCategoriesRepository(this.db);

  final FakeLedger db;

  @override
  Future<List<Category>> list(
    String groupId, {
    TransactionType? type,
    bool includeInactive = false,
  }) async => db.categories
      .where(
        (c) =>
            c.groupId == groupId &&
            (type == null || c.type == type) &&
            (includeInactive || c.isActive),
      )
      .toList();

  @override
  Future<void> rename(String categoryId, String name) async {
    final i = db.categories.indexWhere((c) => c.id == categoryId);
    final c = db.categories[i];
    db.categories[i] = Category(
      id: c.id,
      groupId: c.groupId,
      type: c.type,
      name: name,
      isActive: c.isActive,
    );
  }

  @override
  Future<void> delete(String categoryId) async {
    final i = db.categories.indexWhere((c) => c.id == categoryId);
    final c = db.categories[i];
    db.categories[i] = Category(
      id: c.id,
      groupId: c.groupId,
      type: c.type,
      name: c.name,
      isActive: false,
    );
  }
}
