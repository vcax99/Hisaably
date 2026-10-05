import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/transactions/application/transactions_providers.dart';
import '../../features/transactions/data/transactions_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'sync_bootstrap.dart';

/// Shows "offline · last updated …" when [cachedAt] is set (data came from
/// the local cache) and the number of writes waiting to sync, with "Sync now".
class SyncBanner extends ConsumerStatefulWidget {
  const SyncBanner({super.key, this.cachedAt, this.offline = false});

  /// When the shown data was cached (null = fresh from the server).
  final DateTime? cachedAt;

  /// Data came from the device (no timestamp available).
  final bool offline;

  @override
  ConsumerState<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends ConsumerState<SyncBanner> {
  bool _busy = false;

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await syncNow(ref);
    invalidateTransactions(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result == null || result.offline
              ? 'Still offline. Will sync when the connection is back.'
              : result.failed > 0
              ? '${result.failed} could not be synced. Tap it for details.'
              : 'All changes synced',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unsynced = ref.watch(unsyncedCountProvider).value ?? 0;
    final offline = widget.offline || widget.cachedAt != null;
    if (!ref.watch(localSyncEnabledProvider) || (unsynced == 0 && !offline)) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;
    final parts = [
      if (offline)
        widget.cachedAt == null
            ? 'Offline · showing saved data'
            : 'Offline · updated '
                  '${DateFormat('d MMM, h:mm a').format(widget.cachedAt!.toLocal())}',
      if (unsynced > 0) '$unsynced waiting to sync',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        key: const Key('sync-banner'),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              offline ? Icons.cloud_off_rounded : Icons.cloud_upload_outlined,
              color: AppColors.warning,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(parts.join(' · '), style: textTheme.bodyMedium),
            ),
            if (unsynced > 0)
              _busy
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(
                      key: const Key('sync-now'),
                      onPressed: _syncNow,
                      child: const Text('Sync now'),
                    ),
          ],
        ),
      ),
    );
  }
}
