import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';

enum TransactionType {
  expense('EXPENSE'),
  income('INCOME');

  const TransactionType(this.wire);

  /// Value used by the database enum / RPC parameters.
  final String wire;

  static TransactionType fromWire(Object? v) =>
      v == 'INCOME' ? TransactionType.income : TransactionType.expense;

  String get label => this == expense ? 'Expense' : 'Income';
}

/// Where a transaction is relative to the server (local, offline-first).
enum SyncState { synced, pending, failed }

/// A group ledger entry. Collective by design: it carries no user reference.
class Transaction {
  const Transaction({
    required this.id,
    required this.groupId,
    required this.type,
    required this.amountPaise,
    required this.date,
    this.category,
    this.description,
    this.createdAt,
    this.updatedAt,
    this.syncVersion = 1,
    this.deletedAt,
    this.syncState = SyncState.synced,
    this.syncError,
  });

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    type: TransactionType.fromWire(json['type']),
    amountPaise: Money.fromNumeric(json['amount'] as Object),
    category: json['category'] as String?,
    description: json['description'] as String?,
    date: IstDate.parseDate(json['transaction_date'] as String),
    createdAt: json['created_at'] == null
        ? null
        : DateTime.parse(json['created_at'] as String),
    updatedAt: json['updated_at'] == null
        ? null
        : DateTime.parse(json['updated_at'] as String),
    syncVersion: (json['sync_version'] as num?)?.toInt() ?? 1,
    deletedAt: json['deleted_at'] == null
        ? null
        : DateTime.parse(json['deleted_at'] as String),
  );

  /// Client-generated UUID (idempotent sync key).
  final String id;
  final String groupId;
  final TransactionType type;

  /// Always positive; the [type] says whether it adds or subtracts.
  final int amountPaise;
  final String? category;
  final String? description;

  /// Calendar date (date-only, UTC midnight), the accounting date.
  final DateTime date;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int syncVersion;
  final DateTime? deletedAt;

  /// Local-only: not yet on the server (pending) or rejected (failed).
  final SyncState syncState;

  /// User-safe reason when [syncState] is failed.
  final String? syncError;

  bool get isSynced => syncState == SyncState.synced;
  bool get isPending => syncState == SyncState.pending;
  bool get isFailed => syncState == SyncState.failed;

  bool get isExpense => type == TransactionType.expense;

  /// Category for display; income may have none.
  String get title {
    final c = category?.trim();
    if (c != null && c.isNotEmpty) return c;
    return type == TransactionType.income ? 'Income' : 'Expense';
  }

  String get isoDate => IstDate.toIsoDate(date);
}

/// What the form produces (new or edited transaction).
class TransactionDraft {
  const TransactionDraft({
    required this.groupId,
    required this.type,
    required this.amountPaise,
    required this.date,
    this.category,
    this.description,
  });

  final String groupId;
  final TransactionType type;
  final int amountPaise;
  final String? category;
  final String? description;
  final DateTime date;
}

/// Filter for the transaction lists. `groupId == null` means all groups the
/// viewer can see; `from`/`to` are inclusive dates.
class TransactionFilter {
  const TransactionFilter({
    this.groupId,
    this.type,
    this.from,
    this.to,
    this.category,
    this.minPaise,
    this.maxPaise,
  });

  final String? groupId;
  final TransactionType? type;
  final DateTime? from;
  final DateTime? to;
  final String? category;
  final int? minPaise;
  final int? maxPaise;

  TransactionFilter copyWith({
    String? Function()? groupId,
    DateTime? Function()? from,
    DateTime? Function()? to,
    String? Function()? category,
    int? Function()? minPaise,
    int? Function()? maxPaise,
  }) => TransactionFilter(
    groupId: groupId != null ? groupId() : this.groupId,
    type: type,
    from: from != null ? from() : this.from,
    to: to != null ? to() : this.to,
    category: category != null ? category() : this.category,
    minPaise: minPaise != null ? minPaise() : this.minPaise,
    maxPaise: maxPaise != null ? maxPaise() : this.maxPaise,
  );

  bool get hasExtraFilters =>
      category != null || minPaise != null || maxPaise != null;

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter &&
      other.groupId == groupId &&
      other.type == type &&
      other.from == from &&
      other.to == to &&
      other.category == category &&
      other.minPaise == minPaise &&
      other.maxPaise == maxPaise;

  @override
  int get hashCode =>
      Object.hash(groupId, type, from, to, category, minPaise, maxPaise);
}

/// Keyset pagination cursor (the last row of the previous page).
class TransactionCursor {
  const TransactionCursor(this.date, this.createdAt, this.id);

  factory TransactionCursor.after(Transaction t) =>
      TransactionCursor(t.date, t.createdAt!, t.id);

  final DateTime date;
  final DateTime createdAt;
  final String id;
}

class TransactionPage {
  const TransactionPage(
    this.items, {
    required this.hasMore,
    this.fromCache = false,
  });

  final List<Transaction> items;
  final bool hasMore;

  /// True when the server couldn't be reached and local data was used.
  final bool fromCache;
}

/// A per-group category (owner decision 8).
class Category {
  const Category({
    required this.id,
    required this.groupId,
    required this.type,
    required this.name,
    required this.isActive,
  });

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    type: TransactionType.fromWire(json['type']),
    name: json['name'] as String,
    isActive: json['is_active'] as bool? ?? true,
  );

  final String id;
  final String groupId;
  final TransactionType type;
  final String name;
  final bool isActive;
}

/// Result of looking up one transaction (e.g. from a notification).
sealed class TransactionLookup {
  const TransactionLookup();
}

class TransactionFound extends TransactionLookup {
  const TransactionFound(this.transaction);
  final Transaction transaction;
}

/// Soft-deleted by a Group Admin / the Super Admin.
class TransactionDeleted extends TransactionLookup {
  const TransactionDeleted(this.type);
  final TransactionType type;
}

/// Not visible to this user (never existed, or access to the group ended).
class TransactionUnavailable extends TransactionLookup {
  const TransactionUnavailable();
}

/// One "who did it" record of an entry's history.
class HistoryEvent {
  const HistoryEvent({required this.name, required this.at});

  /// Null when that user has since been deleted.
  final String? name;
  final DateTime at;

  static HistoryEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    return HistoryEvent(
      name: json['name'] as String?,
      at: DateTime.parse(json['at'] as String).toLocal(),
    );
  }
}

/// Who added an entry and who last edited it (kept apart from the entry
/// itself: the group owns the money).
class TransactionHistory {
  const TransactionHistory({this.created, this.updated, this.canEdit = false});

  /// Null for entries added before history was recorded.
  final HistoryEvent? created;

  /// Null when the entry was never edited.
  final HistoryEvent? updated;

  /// Whether the viewer may edit/delete it: Group Admin / Super Admin, or a
  /// member who added it themselves (decided and enforced by the server).
  final bool canEdit;

  factory TransactionHistory.fromJson(Map<String, dynamic> json) =>
      TransactionHistory(
        created: HistoryEvent.fromJson(json['created']),
        updated: HistoryEvent.fromJson(json['updated']),
        canEdit: json['can_edit'] == true,
      );
}
