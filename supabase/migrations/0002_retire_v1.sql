-- =====================================================================
-- 0002_retire_v1: remove the v1 tables and their "everyone can read
-- everything" policies (audit finding S1).
--
-- DESTRUCTIVE: drops all v1 profile and step data permanently.
-- Apply only as part of the confirmed launch reset (after
-- ops.reset_launch_data), never on its own.
-- =====================================================================
drop table if exists public.daily_steps;
drop table if exists public.users;
