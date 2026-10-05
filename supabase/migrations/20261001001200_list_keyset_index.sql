-- Phase 13: performance. list_transactions pages by
-- (transaction_date desc, created_at desc, id desc) over live rows. With only
-- (group_id, transaction_date) indexed, every page scanned and sorted the
-- group's whole history (O(n) per page). This partial index matches the
-- keyset order exactly, so a page is an index range scan + LIMIT.
-- The spec's (group_id, transaction_date) index stays (balances/ranges).
create index if not exists transactions_group_keyset_idx
  on public.transactions (group_id, transaction_date desc, created_at desc, id desc)
  where deleted_at is null;
