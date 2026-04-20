-- ============================================================================
-- Migration: 001 - Row-Level Security Policies
-- Beschreibung: Sicherheitsregeln auf DB-Ebene. Ohne diese Policies könnten
-- eingeloggte Nutzer alle Daten sehen — mit ihnen nur das, was sie dürfen.
-- ============================================================================

-- ============================================================================
-- Helper: Prüft, ob aktueller User Admin ist
-- SECURITY DEFINER heißt: Läuft mit den Rechten des Erstellers (DB-Superuser),
-- nicht mit den Rechten des aufrufenden Users. Verhindert Rekursion in Policies.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_admin(user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = user_id
      AND role = 'admin'
      AND disabled_at IS NULL
  );
$$;

-- ============================================================================
-- RLS aktivieren auf allen Tabellen
-- ============================================================================

ALTER TABLE public.profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.articles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.revisions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log     ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- profiles: Ärzte sehen ihr eigenes Profil, Admins sehen alle.
-- Öffentlich sichtbar: nur Basis-Infos von Ärzten, die aktive Verifizierungen
-- haben (für "Geprüft von Dr. X" auf Artikel-Seiten)
-- ============================================================================

CREATE POLICY "profiles_self_select" ON public.profiles
  FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "profiles_admin_select_all" ON public.profiles
  FOR SELECT
  USING (public.is_admin());

CREATE POLICY "profiles_public_select_reviewers" ON public.profiles
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.verifications v
      WHERE v.doctor_id = profiles.id
        AND v.revoked_at IS NULL
        AND v.expires_at > now()
    )
  );

CREATE POLICY "profiles_self_update" ON public.profiles
  FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid() AND role = (SELECT role FROM public.profiles WHERE id = auth.uid()));
  -- Rolle kann NICHT per Self-Update geändert werden

CREATE POLICY "profiles_admin_update" ON public.profiles
  FOR UPDATE
  USING (public.is_admin());

CREATE POLICY "profiles_admin_insert" ON public.profiles
  FOR INSERT
  WITH CHECK (public.is_admin());

-- Kein DELETE für Profile (Ärzte werden "deactivated", nicht gelöscht)

-- ============================================================================
-- articles: Öffentlich lesbar, nur Admins dürfen schreiben
-- ============================================================================

CREATE POLICY "articles_public_select" ON public.articles
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "articles_admin_write" ON public.articles
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- reservations: Arzt sieht seine eigenen, Admin sieht alle.
-- Öffentlich: keine Sichtbarkeit.
-- ============================================================================

CREATE POLICY "reservations_doctor_select_own" ON public.reservations
  FOR SELECT
  USING (doctor_id = auth.uid());

CREATE POLICY "reservations_admin_select_all" ON public.reservations
  FOR SELECT
  USING (public.is_admin());

-- Einfügen: Arzt kann sich selbst zuweisen, Admin kann beliebigen Arzt zuweisen
CREATE POLICY "reservations_doctor_insert_self" ON public.reservations
  FOR INSERT
  WITH CHECK (
    doctor_id = auth.uid()
    AND status = 'active'
    AND free_assignment = false
  );

CREATE POLICY "reservations_admin_insert_any" ON public.reservations
  FOR INSERT
  WITH CHECK (public.is_admin());

-- Update: Nur Besitzer oder Admin; Status-Änderungen werden durch Server-Funktionen
-- gemacht, nicht direkt hier — aber wir erlauben eigene Cancel-Aktion
CREATE POLICY "reservations_doctor_update_own" ON public.reservations
  FOR UPDATE
  USING (doctor_id = auth.uid())
  WITH CHECK (doctor_id = auth.uid());

CREATE POLICY "reservations_admin_update_all" ON public.reservations
  FOR UPDATE
  USING (public.is_admin());

-- ============================================================================
-- verifications: Arzt sieht eigene, Admin sieht alle.
-- Öffentlich: Aktive (nicht abgelaufene, nicht zurückgezogene) sind lesbar
-- für die öffentliche Artikel-Seite ("Geprüft von Dr. X")
-- ============================================================================

CREATE POLICY "verifications_public_select_active" ON public.verifications
  FOR SELECT
  TO anon, authenticated
  USING (
    revoked_at IS NULL
    AND expires_at > now()
  );

CREATE POLICY "verifications_doctor_select_own" ON public.verifications
  FOR SELECT
  USING (doctor_id = auth.uid());

CREATE POLICY "verifications_admin_select_all" ON public.verifications
  FOR SELECT
  USING (public.is_admin());

-- INSERT: Nur über SECURITY DEFINER-Funktionen (siehe 002_functions.sql),
-- damit Disclaimer, Preis etc. vom Server korrekt gesetzt werden
-- Kein direktes INSERT/UPDATE von außen
CREATE POLICY "verifications_admin_update" ON public.verifications
  FOR UPDATE
  USING (public.is_admin());

-- ============================================================================
-- revisions: Arzt sieht eigene, Admin sieht alle
-- ============================================================================

CREATE POLICY "revisions_doctor_select_own" ON public.revisions
  FOR SELECT
  USING (doctor_id = auth.uid());

CREATE POLICY "revisions_admin_select_all" ON public.revisions
  FOR SELECT
  USING (public.is_admin());

CREATE POLICY "revisions_doctor_insert_own" ON public.revisions
  FOR INSERT
  WITH CHECK (doctor_id = auth.uid());

CREATE POLICY "revisions_admin_update" ON public.revisions
  FOR UPDATE
  USING (public.is_admin());

-- ============================================================================
-- settings: Jeder authentifizierte User liest, nur Admin schreibt
-- ============================================================================

CREATE POLICY "settings_authenticated_select" ON public.settings
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "settings_admin_write" ON public.settings
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- audit_log: Nur eigene Einträge lesbar für Ärzte, Admin alles.
-- INSERT nur über SECURITY DEFINER-Funktion. Kein UPDATE, kein DELETE.
-- ============================================================================

CREATE POLICY "audit_log_doctor_select_own" ON public.audit_log
  FOR SELECT
  USING (actor_id = auth.uid());

CREATE POLICY "audit_log_admin_select_all" ON public.audit_log
  FOR SELECT
  USING (public.is_admin());

-- KEIN INSERT-Policy direkt. Nur über log_action()-Funktion.
-- KEIN UPDATE-Policy. Nie.
-- KEIN DELETE-Policy. Nie.
