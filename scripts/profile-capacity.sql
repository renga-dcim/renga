-- Run with psql against the same disposable capacity database during the load.
-- Keep this observer outside the BEAM so VM scheduling pauses cannot hide a
-- database wait. No parameters, production settings or statistics are changed.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset pager off
DO $$ BEGIN
  IF current_database() !~ '^renga_test_capacity' THEN
    RAISE EXCEPTION 'capacity profiling requires a disposable capacity database';
  END IF;
END $$;
-- Waits need 50 ms resolution; cumulative IO/WAL counters need only about
-- one sample per second, avoiding large diagnostic writes during the load.
WITH cadence AS MATERIALIZED (
  SELECT mod(floor(extract(epoch FROM clock_timestamp())*20)::bigint,20)=0 AS counters
)
SELECT jsonb_build_object(
  'sample_at', clock_timestamp(),
  'activity', COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'pid', pid, 'state', state, 'wait_type', wait_event_type, 'wait_event', wait_event,
    'query_age_ms', extract(epoch FROM clock_timestamp()-query_start)*1000,
    'transaction_age_ms', extract(epoch FROM clock_timestamp()-xact_start)*1000,
    'blockers', pg_blocking_pids(pid), 'query', left(query, 600)))
    FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()
      AND ((state='active' AND query_start < clock_timestamp()-interval '10 milliseconds')
        OR pid IN (SELECT unnest(pg_blocking_pids(a.pid)) FROM pg_stat_activity a
                   WHERE a.datname=current_database() AND a.state='active'))), '[]'),
  'io', CASE WHEN counters THEN
    (SELECT jsonb_agg(to_jsonb(s)) FROM pg_stat_io s
     WHERE backend_type IN ('client backend','checkpointer','walwriter','autovacuum worker')) END,
  'wal', CASE WHEN counters THEN (SELECT to_jsonb(w) FROM pg_stat_wal w) END,
  'checkpointer', CASE WHEN counters THEN (SELECT to_jsonb(c) FROM pg_stat_checkpointer c) END
) FROM cadence;
\watch 0.05
