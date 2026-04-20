-- ============================================================================
-- Migration: 004 - Migration tracking table
-- Beschreibung: Interne Tabelle, um nachzuhalten welche Migrationen bereits
-- auf die Datenbank angewendet wurden. Ermöglicht idempotente Auto-Migrationen
-- via GitHub Actions.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public._migrations (
  filename    text         PRIMARY KEY,
  applied_at  timestamptz  NOT NULL DEFAULT now(),
  checksum    text,
  applied_by  text
);

-- RLS: Nur Admins sehen (über Supabase Dashboard oder via service_role)
ALTER TABLE public._migrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "migrations_admin_only" ON public._migrations
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- Trage die Setup-Migrationen, die manuell via SETUP_COMPLETE.sql eingespielt
-- wurden, als "bereits angewendet" ein. Damit sie beim ersten Auto-Run nicht
-- erneut ausgeführt werden.
INSERT INTO public._migrations (filename, applied_by) VALUES
  ('20260412_000_initial_schema.sql',  'manual_setup'),
  ('20260412_001_rls_policies.sql',    'manual_setup'),
  ('20260412_002_functions.sql',       'manual_setup'),
  ('20260412_003_seed_data.sql',       'manual_setup'),
  ('20260412_004_migration_tracking.sql', 'self')
ON CONFLICT (filename) DO NOTHING;
