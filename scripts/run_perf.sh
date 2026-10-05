#!/usr/bin/env bash
# Phase 13 profile-mode frame timings on a device/emulator against dev.
# Seeds a temporary "Perf" group (1,000 entries, qa_member as Group Admin),
# runs integration_test/perf_test.dart with --profile, then deletes the group.
# Usage: QA_MEMBER_PASSWORD=... scripts/run_perf.sh <device-id>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QA_MEMBER_PASSWORD:?set QA_MEMBER_PASSWORD}"
DEVICE="${1:?device id}"

cleanup() {
  npx supabase db query --linked "
    delete from public.notifications where group_id in (select id from public.groups where name = 'Perf (temporary)');
    delete from public.transactions where group_id in (select id from public.groups where name = 'Perf (temporary)');
    delete from public.group_members where group_id in (select id from public.groups where name = 'Perf (temporary)');
    delete from public.group_categories where group_id in (select id from public.groups where name = 'Perf (temporary)');
    delete from public.groups where name = 'Perf (temporary)';" </dev/null >/dev/null
}
trap cleanup EXIT
cleanup

npx supabase db query --linked "
with g as (insert into public.groups (name) values ('Perf (temporary)') returning id),
     m as (insert into public.group_members (group_id, user_id, group_role)
           select g.id, p.id, 'GROUP_ADMIN' from g, public.profiles p where p.username = 'qa_member')
insert into public.transactions (id, group_id, type, amount, category, description, transaction_date)
select gen_random_uuid(), g.id,
       (case when n % 5 = 0 then 'INCOME' else 'EXPENSE' end)::public.transaction_type,
       (100 + (n * 37) % 5000)::numeric,
       (array['Food','Groceries','Rent','Utilities','Travel'])[1 + n % 5],
       'perf entry ' || n,
       public.ist_today() - (n % 365)
from g, generate_series(1, 1000) n;" </dev/null >/dev/null

flutter drive --profile --no-dds \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/perf_test.dart \
  -d "$DEVICE" \
  --dart-define-from-file=env/dev.json \
  --dart-define=QA_MEMBER_PASSWORD="$QA_MEMBER_PASSWORD" \
  --dart-define=PERF_MOTION="${PERF_MOTION:-true}"
cat build/perf/summary.json
