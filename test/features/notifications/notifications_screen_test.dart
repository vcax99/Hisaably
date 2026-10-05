import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/features/notifications/data/notifications_repository.dart';
import 'package:hisaably/features/notifications/domain/app_notification.dart';
import 'package:hisaably/features/notifications/presentation/notifications_screen.dart';

import '../../helpers/fake_notifications_repository.dart';

AppNotification _n(int i, {bool read = false}) => AppNotification(
  id: 'n$i',
  type: i.isEven
      ? NotificationType.expenseAdded
      : NotificationType.monthStarted,
  title: 'Title $i',
  body: 'Body $i',
  isRead: read,
  createdAt: DateTime.utc(2026, 9, 26, 10).subtract(Duration(minutes: i)),
);

Future<FakeNotificationsRepository> _pump(
  WidgetTester tester,
  List<AppNotification> items,
) async {
  final repo = FakeNotificationsRepository(items);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notificationsRepositoryProvider.overrideWithValue(repo)],
      retry: (_, _) => null,
      child: const MaterialApp(home: NotificationsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('lists notifications; unread ones have a dot', (tester) async {
    await _pump(tester, [_n(0), _n(1, read: true)]);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Body 1'), findsOneWidget);
    expect(find.byKey(const Key('unread-dot')), findsOneWidget);
    expect(find.byKey(const Key('mark-all-read')), findsOneWidget);
  });

  testWidgets('tapping an unread one marks it read at once', (tester) async {
    final repo = await _pump(tester, [_n(0)]);
    await tester.tap(find.text('Title 0'));
    await tester.pumpAndSettle();
    expect(repo.markedRead, ['n0']);
    expect(find.byKey(const Key('unread-dot')), findsNothing);
    expect(find.byKey(const Key('mark-all-read')), findsNothing);
  });

  testWidgets('mark all read clears every dot', (tester) async {
    final repo = await _pump(tester, [_n(0), _n(1), _n(2)]);
    expect(find.byKey(const Key('unread-dot')), findsNWidgets(3));
    await tester.tap(find.byKey(const Key('mark-all-read')));
    await tester.pumpAndSettle();
    expect(repo.markAllCalls, 1);
    expect(find.byKey(const Key('unread-dot')), findsNothing);
  });

  testWidgets('empty state', (tester) async {
    await _pump(tester, []);
    expect(find.text('No notifications yet'), findsOneWidget);
  });

  testWidgets('loads the next page when scrolled', (tester) async {
    await _pump(tester, [for (var i = 0; i < 45; i++) _n(i, read: true)]);
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(find.text('Title 44'), findsOneWidget);
  });

  testWidgets('offline with nothing cached: friendly retry', (tester) async {
    final repo = FakeNotificationsRepository([_n(0)])..offline = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notificationsRepositoryProvider.overrideWithValue(repo)],
        retry: (_, _) => null,
        child: const MaterialApp(home: NotificationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('You are offline'), findsOneWidget);
    repo.offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Title 0'), findsOneWidget);
  });
}
