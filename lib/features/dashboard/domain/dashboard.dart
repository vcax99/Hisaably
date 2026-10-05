import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';
import '../../transactions/domain/transaction.dart';

/// One month of the ledger (balances computed server-side from transactions).
class MonthSummary {
  const MonthSummary({
    required this.month,
    required this.openingPaise,
    required this.incomePaise,
    required this.expensePaise,
    required this.closingPaise,
  });

  factory MonthSummary.fromJson(Map<String, dynamic> json) => MonthSummary(
    month: IstDate.parseDate(json['month'] as String),
    openingPaise: Money.fromNumeric(json['opening_balance'] as Object),
    incomePaise: Money.fromNumeric(json['total_income'] as Object),
    expensePaise: Money.fromNumeric(json['total_expense'] as Object),
    closingPaise: Money.fromNumeric(json['closing_balance'] as Object),
  );

  /// First day of the month.
  final DateTime month;
  final int openingPaise;
  final int incomePaise;
  final int expensePaise;
  final int closingPaise;

  int get netPaise => incomePaise - expensePaise;
}

class CategoryTotal {
  const CategoryTotal({
    required this.category,
    required this.totalPaise,
    required this.count,
  });

  factory CategoryTotal.fromJson(Map<String, dynamic> json) => CategoryTotal(
    category: json['category'] as String,
    totalPaise: Money.fromNumeric(json['total'] as Object),
    count: (json['count'] as num).toInt(),
  );

  final String category;
  final int totalPaise;
  final int count;
}

/// Everything one dashboard screen needs, from a single `get_dashboard` call.
class DashboardData {
  const DashboardData({
    required this.month,
    required this.currentBalancePaise,
    required this.summary,
    required this.trend,
    required this.expenseBreakdown,
    required this.recent,
    this.cachedAt,
  });

  factory DashboardData.fromJson(
    Map<String, dynamic> json, {
    DateTime? cachedAt,
  }) {
    List<Map<String, dynamic>> rows(String key) => [
      for (final r in (json[key] as List<dynamic>? ?? const []))
        (r as Map).cast<String, dynamic>(),
    ];
    final trend = [for (final r in rows('trend')) MonthSummary.fromJson(r)];
    final summaryJson = json['month_summary'];
    return DashboardData(
      month: IstDate.parseDate(json['month'] as String),
      currentBalancePaise: Money.fromNumeric(json['current_balance'] as Object),
      summary: summaryJson == null
          ? null
          : MonthSummary.fromJson((summaryJson as Map).cast<String, dynamic>()),
      trend: trend,
      expenseBreakdown: [
        for (final r in rows('expense_breakdown')) CategoryTotal.fromJson(r),
      ],
      recent: [
        for (final r in rows('recent_transactions')) Transaction.fromJson(r),
      ],
      cachedAt: cachedAt,
    );
  }

  /// First day of the selected month.
  final DateTime month;

  /// Balance of everything recorded so far (all months).
  final int currentBalancePaise;
  final MonthSummary? summary;

  /// Six months ending with [month], oldest first.
  final List<MonthSummary> trend;

  /// Expense totals by category for [month], largest first.
  final List<CategoryTotal> expenseBreakdown;
  final List<Transaction> recent;

  /// Set when shown from the offline cache: when it was fetched.
  final DateTime? cachedAt;
}

class AdminOverview {
  const AdminOverview({
    required this.usersTotal,
    required this.usersActive,
    required this.usersDisabled,
    required this.groupsTotal,
    required this.groupsActive,
  });

  factory AdminOverview.fromJson(Map<String, dynamic> json) => AdminOverview(
    usersTotal: (json['users_total'] as num).toInt(),
    usersActive: (json['users_active'] as num).toInt(),
    usersDisabled: (json['users_disabled'] as num).toInt(),
    groupsTotal: (json['groups_total'] as num).toInt(),
    groupsActive: (json['groups_active'] as num).toInt(),
  );

  final int usersTotal;
  final int usersActive;
  final int usersDisabled;
  final int groupsTotal;
  final int groupsActive;
}

/// One row of the Dashboard's "By group" list.
class GroupBalance {
  const GroupBalance({
    required this.groupId,
    required this.name,
    required this.isActive,
    required this.currentBalancePaise,
    required this.monthIncomePaise,
    required this.monthExpensePaise,
  });

  factory GroupBalance.fromJson(Map<String, dynamic> j) => GroupBalance(
    groupId: j['group_id'] as String,
    name: j['name'] as String,
    isActive: j['status'] == 'ACTIVE',
    currentBalancePaise: Money.fromNumeric(j['current_balance'] as Object),
    monthIncomePaise: Money.fromNumeric(j['month_income'] as Object),
    monthExpensePaise: Money.fromNumeric(j['month_expense'] as Object),
  );

  final String groupId;
  final String name;
  final bool isActive;
  final int currentBalancePaise;
  final int monthIncomePaise;
  final int monthExpensePaise;
}
