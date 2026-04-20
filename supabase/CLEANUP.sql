-- ============================================================================
--   AUFRÄUM-SKRIPT — löscht alles, was das Setup-Skript angelegt hat
-- ============================================================================
--
-- Nur benutzen, wenn das Setup-Skript versehentlich im falschen Projekt lief.
--
-- ACHTUNG: Dieses Skript löscht die Tabellen inkl. aller darin gespeicherter Daten.
-- Wenn du nur das falsche Projekt komplett entsorgen willst, nimm lieber
-- "Settings → Delete project" im Supabase-Dashboard.
--
-- ANLEITUNG:
-- 1. SQL Editor → New Query
-- 2. Diese Datei einfügen
-- 3. Run klicken
-- ============================================================================

-- Trigger zuerst (sonst blockiert er das Löschen)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- View
DROP VIEW IF EXISTS public.article_states;

-- Funktionen (umgekehrte Reihenfolge)
DROP FUNCTION IF EXISTS public.admin_revoke_verification(uuid, text);
DROP FUNCTION IF EXISTS public.admin_resolve_revision(uuid, text, text);
DROP FUNCTION IF EXISTS public.admin_claim_revision(uuid);
DROP FUNCTION IF EXISTS public.admin_assign_article(text, uuid, boolean);
DROP FUNCTION IF EXISTS public.cancel_reservation(uuid);
DROP FUNCTION IF EXISTS public.request_revision(uuid, text);
DROP FUNCTION IF EXISTS public.verify_article(uuid, boolean, text);
DROP FUNCTION IF EXISTS public.reserve_article(text);
DROP FUNCTION IF EXISTS public.log_action(text, text, text, jsonb, inet);
DROP FUNCTION IF EXISTS public.handle_new_user();
DROP FUNCTION IF EXISTS public.is_admin(uuid);
DROP FUNCTION IF EXISTS public.set_updated_at();

-- Tabellen (umgekehrte Reihenfolge wegen Fremdschlüsseln)
DROP TABLE IF EXISTS public.audit_log CASCADE;
DROP TABLE IF EXISTS public.settings CASCADE;
DROP TABLE IF EXISTS public.revisions CASCADE;
DROP TABLE IF EXISTS public.verifications CASCADE;
DROP TABLE IF EXISTS public.reservations CASCADE;
DROP TABLE IF EXISTS public.articles CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;

-- Fertig. "Success. No rows returned." sollte erscheinen.
