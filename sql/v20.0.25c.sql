-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.25c — DSI is a daily code
--   UPI bills DSI by the day (unit type D). Provly's code table listed it as
--   quarter-hour, so the authorization used-units counter would count a 6-hour
--   DSI day as 24 units instead of 1. The payment file was never affected (it
--   uses UPI's own unit type from the download).
--   • service_code_definitions: DSI → daily
--   • every DSI authorization's used units recounted under the daily rule
-- 🟢 Run in the Supabase SQL editor. Idempotent. Database only; no app change.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

UPDATE public.service_code_definitions
   SET billing_unit = 'daily'
 WHERE code = 'DSI' AND billing_unit::text IS DISTINCT FROM 'daily';

UPDATE public.person_service_authorizations a
   SET used_units = CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END
 WHERE a.service_code_id IN (SELECT id FROM public.service_code_definitions WHERE code = 'DSI')
   AND a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END;

COMMIT;

-- Verification: paste this table into chat. Rows 3+ are for you to check by eye.
SELECT * FROM (
  SELECT 1 AS n, 'DSI counts by the day' AS check_item,
    (SELECT billing_unit::text FROM public.service_code_definitions WHERE code = 'DSI') AS value,
    'daily' AS want
  UNION ALL
  SELECT 2, 'DSI authorizations whose used units match the daily count',
    (SELECT format('%s of %s', count(*) FILTER (WHERE a.used_units IS NOT DISTINCT FROM
              CASE WHEN a.status::text = 'rejected' THEN 0
                   ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END),
              count(*))
       FROM public.person_service_authorizations a
      WHERE a.service_code_id IN (SELECT id FROM public.service_code_definitions WHERE code = 'DSI')),
    '(both numbers equal)'
  UNION ALL
  SELECT 3, 'DSI requires EVV in Provly',
    (SELECT evv_required::text FROM public.service_code_definitions WHERE code = 'DSI'),
    '(tell me: do Tony''s DSI staff clock in on EVV?)'
  UNION ALL
  SELECT 3 + row_number() OVER (ORDER BY p.last_name, a.start_date)::integer,
    'DSI authorization: ' || p.first_name || ' ' || p.last_name,
    format('%s → %s · %s units · rate %s · used %s · %s',
           coalesce(a.start_date::text, '?'), coalesce(a.end_date::text, 'open'),
           coalesce(a.authorized_units::text, '—'), coalesce(a.rate_per_unit::text, 'pending'),
           coalesce(a.used_units::text, '0'), coalesce(a.status::text, '—')),
    '(check against UPI: days per month, rate per day)'
    FROM public.person_service_authorizations a
    JOIN public.persons p ON p.id = a.person_id
   WHERE a.service_code_id IN (SELECT id FROM public.service_code_definitions WHERE code = 'DSI')
) v ORDER BY n;
