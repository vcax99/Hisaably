import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/dashboard/domain/dashboard.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';

void main() {
  test('get_dashboard JSON (real server shape) parses with UTC dates', () {
    final d = DashboardData.fromJson({
      'month': '2026-10-01',
      'current_balance': 71600.0,
      'month_summary': {
        'month': '2026-10-01',
        'opening_balance': 71600.0,
        'total_income': 300.0,
        'total_expense': 18.5,
        'closing_balance': 71881.5,
      },
      'trend': [
        {
          'month': '2026-09-01',
          'opening_balance': 48550.0,
          'total_income': 57500.0,
          'total_expense': 34450.0,
          'closing_balance': 71600.0,
        },
      ],
      'expense_breakdown': [
        {'category': 'Rent', 'total': 18000.0, 'count': 1},
      ],
      'recent_transactions': [
        {
          'id': 'a',
          'group_id': 'g',
          'type': 'EXPENSE',
          'amount': 18.5,
          'category': 'Food',
          'description': null,
          'transaction_date': '2026-10-01',
          'created_at': '2026-10-01T08:00:00.000000+00:00',
          'updated_at': '2026-10-01T08:00:00.000000+00:00',
          'sync_version': 1,
          'deleted_at': null,
        },
      ],
    });
    expect(d.month, DateTime.utc(2026, 10));
    expect(d.currentBalancePaise, 7160000);
    expect(d.summary!.closingPaise, 7188150);
    expect(d.trend.single.month, DateTime.utc(2026, 9));
    expect(d.expenseBreakdown.single.totalPaise, 1800000);
    final t = d.recent.single;
    expect(t.amountPaise, 1850);
    expect(t.type, TransactionType.expense);
    expect(t.date, IstDate.parseDate('2026-10-01'));
    expect(t.date.isUtc, isTrue);
  });

  test('keeps the cache timestamp (drives the offline banner)', () {
    final at = DateTime.utc(2026, 10, 1, 8);
    final json = {'month': '2026-10-01', 'current_balance': 0};
    expect(DashboardData.fromJson(json).cachedAt, isNull);
    expect(DashboardData.fromJson(json, cachedAt: at).cachedAt, at);
  });
}
