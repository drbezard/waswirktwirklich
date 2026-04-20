-- ============================================================================
--   KOMPLETTES DATENBANK-SETUP FÜR "WAS WIRKLICH WIRKT"
-- ============================================================================
-- 
-- ANLEITUNG:
-- 1. In Supabase: links im Menü auf "SQL Editor" klicken
-- 2. Oben rechts auf "New query" klicken
-- 3. Dieses gesamte File kopieren und einfügen (Strg+A dann Strg+C dann einfügen)
-- 4. Unten rechts auf "Run" klicken
-- 5. Warten bis "Success. No rows returned." erscheint
-- 6. Fertig!
--
-- ZEITAUFWAND: ca. 3 Minuten
-- ============================================================================


-- ======= Inhalt von: supabase/migrations/20260412_000_initial_schema.sql =======
-- ============================================================================
-- Migration: 000 - Initial Schema
-- Beschreibung: Grundstruktur für die Verifizierungsplattform
-- Abhängigkeiten: Supabase Auth Schema (vorhanden nach Projekt-Erstellung)
-- Reversibel: Nein (nur bei leerer Datenbank anwenden)
-- ============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";        -- für gen_random_uuid()

-- ============================================================================
-- Helper: updated_at Trigger
-- ============================================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ============================================================================
-- Table: profiles
-- Beschreibung: Erweitert auth.users um Rolle und fachliche Daten
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.profiles (
  id          uuid          PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role        text          NOT NULL DEFAULT 'doctor'
                            CHECK (role IN ('doctor', 'admin')),
  full_name   text,
  title       text,
  photo_url   text,
  bio         text,
  website_url text,
  disabled_at timestamptz,
  created_at  timestamptz   NOT NULL DEFAULT now(),
  updated_at  timestamptz   NOT NULL DEFAULT now()
);

CREATE TRIGGER profiles_set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Trigger: Wenn ein neuer Auth-User angelegt wird, automatisch Profil erstellen
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- Table: articles
-- Beschreibung: Spiegelt Markdown-Artikel für FK-Integrität und RLS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.articles (
  slug        text          PRIMARY KEY,
  title       text          NOT NULL,
  category    text          NOT NULL,
  excerpt     text,
  image_url   text,
  created_at  timestamptz   NOT NULL DEFAULT now(),
  updated_at  timestamptz   NOT NULL DEFAULT now()
);

CREATE TRIGGER articles_set_updated_at
  BEFORE UPDATE ON public.articles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX articles_category_idx ON public.articles (category);

-- ============================================================================
-- Table: reservations
-- Beschreibung: Ein Arzt hat einen Artikel übernommen, aber noch nicht
-- abgeschlossen. Genau eine aktive Reservierung pro Artikel.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.reservations (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  article_slug    text          NOT NULL REFERENCES public.articles(slug) ON DELETE RESTRICT,
  doctor_id       uuid          NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status          text          NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'verified', 'revised', 'cancelled', 'expired')),
  reserved_at     timestamptz   NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  free_assignment boolean       NOT NULL DEFAULT false,

  -- Consistency: completed_at nur gesetzt wenn status != 'active'
  CONSTRAINT reservations_completed_requires_final_status CHECK (
    (completed_at IS NULL AND status = 'active')
    OR (completed_at IS NOT NULL AND status != 'active')
  )
);

-- Unique partial index: max. 1 aktive Reservierung pro Artikel
CREATE UNIQUE INDEX reservations_one_active_per_article
  ON public.reservations (article_slug)
  WHERE status = 'active';

CREATE INDEX reservations_doctor_status_idx
  ON public.reservations (doctor_id, status);

-- ============================================================================
-- Table: verifications
-- Beschreibung: Erfolgreiche Verifizierungen mit Ablaufdatum.
-- Eine aktive Verifizierung = neueste mit revoked_at IS NULL AND expires_at > now()
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.verifications (
  id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  article_slug          text          NOT NULL REFERENCES public.articles(slug) ON DELETE RESTRICT,
  doctor_id             uuid          NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reservation_id        uuid          REFERENCES public.reservations(id) ON DELETE SET NULL,
  kind                  text          NOT NULL
                                      CHECK (kind IN ('initial', 'renewal', 'free_admin')),
  verified_at           timestamptz   NOT NULL DEFAULT now(),
  expires_at            timestamptz   NOT NULL,
  price_cents_paid      integer       NOT NULL CHECK (price_cents_paid >= 0),
  disclaimer_confirmed  boolean       NOT NULL DEFAULT true,
  payment_reference     text,
  revoked_at            timestamptz,
  revoked_reason        text,

  -- Consistency: expires_at muss nach verified_at liegen
  CONSTRAINT verifications_expires_after_verified CHECK (expires_at > verified_at),

  -- Consistency: revoked_reason nur wenn revoked_at gesetzt
  CONSTRAINT verifications_revoked_reason_requires_revoked_at CHECK (
    (revoked_at IS NULL AND revoked_reason IS NULL)
    OR revoked_at IS NOT NULL
  ),

  -- Free admin assignments haben price = 0
  CONSTRAINT verifications_free_admin_price_zero CHECK (
    kind != 'free_admin' OR price_cents_paid = 0
  )
);

CREATE INDEX verifications_article_latest_idx
  ON public.verifications (article_slug, verified_at DESC);

CREATE INDEX verifications_doctor_idx
  ON public.verifications (doctor_id, verified_at DESC);

CREATE INDEX verifications_expiring_soon_idx
  ON public.verifications (expires_at)
  WHERE revoked_at IS NULL;

-- ============================================================================
-- Table: revisions
-- Beschreibung: Revisions-Anforderungen durch Ärzte
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.revisions (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  article_slug    text          NOT NULL REFERENCES public.articles(slug) ON DELETE RESTRICT,
  reservation_id  uuid          REFERENCES public.reservations(id) ON DELETE SET NULL,
  doctor_id       uuid          NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  comment         text          NOT NULL CHECK (char_length(comment) >= 10),
  status          text          NOT NULL DEFAULT 'open'
                                CHECK (status IN ('open', 'in_admin_review', 'resolved', 'dismissed')),
  admin_id        uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  admin_notes     text,
  created_at      timestamptz   NOT NULL DEFAULT now(),
  resolved_at     timestamptz,

  CONSTRAINT revisions_resolved_requires_final_status CHECK (
    (resolved_at IS NULL AND status IN ('open', 'in_admin_review'))
    OR (resolved_at IS NOT NULL AND status IN ('resolved', 'dismissed'))
  ),

  CONSTRAINT revisions_admin_id_set_when_in_review CHECK (
    status != 'in_admin_review' OR admin_id IS NOT NULL
  )
);

CREATE INDEX revisions_status_created_idx ON public.revisions (status, created_at DESC);
CREATE INDEX revisions_doctor_idx ON public.revisions (doctor_id, created_at DESC);

-- ============================================================================
-- Table: settings
-- Beschreibung: Globale Konfiguration (Preise etc.)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.settings (
  key         text          PRIMARY KEY,
  value       jsonb         NOT NULL,
  description text,
  updated_by  uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at  timestamptz   NOT NULL DEFAULT now()
);

CREATE TRIGGER settings_set_updated_at
  BEFORE UPDATE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- Table: audit_log
-- Beschreibung: Unveränderliches Protokoll. Nur INSERT erlaubt.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.audit_log (
  id            bigserial     PRIMARY KEY,
  actor_id      uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  action        text          NOT NULL,
  entity_type   text          NOT NULL,
  entity_id     text,
  payload       jsonb,
  ip_address    inet,
  created_at    timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX audit_log_actor_idx ON public.audit_log (actor_id, created_at DESC);
CREATE INDEX audit_log_entity_idx ON public.audit_log (entity_type, entity_id, created_at DESC);
CREATE INDEX audit_log_action_idx ON public.audit_log (action, created_at DESC);

-- ============================================================================
-- View: article_states
-- Beschreibung: Dynamisch berechneter Zustand jedes Artikels
-- ============================================================================

CREATE OR REPLACE VIEW public.article_states AS
SELECT
  a.slug,
  a.title,
  a.category,
  CASE
    WHEN EXISTS (
      SELECT 1 FROM public.verifications v
      WHERE v.article_slug = a.slug
        AND v.revoked_at IS NULL
        AND v.expires_at > now()
    ) THEN 'verified'
    WHEN EXISTS (
      SELECT 1 FROM public.verifications v
      WHERE v.article_slug = a.slug
        AND v.revoked_at IS NULL
        AND v.expires_at <= now()
    ) THEN 'expired'
    WHEN EXISTS (
      SELECT 1 FROM public.revisions r
      WHERE r.article_slug = a.slug
        AND r.status IN ('open', 'in_admin_review')
    ) THEN 'revision_requested'
    WHEN EXISTS (
      SELECT 1 FROM public.reservations r
      WHERE r.article_slug = a.slug
        AND r.status = 'active'
    ) THEN 'reserved'
    ELSE 'unverified'
  END AS state,
  -- Aktive Verifizierung mitliefern (für "wer hat verifiziert" etc.)
  (
    SELECT v.id FROM public.verifications v
    WHERE v.article_slug = a.slug
      AND v.revoked_at IS NULL
      AND v.expires_at > now()
    ORDER BY v.verified_at DESC
    LIMIT 1
  ) AS active_verification_id
FROM public.articles a;

-- ======= Inhalt von: supabase/migrations/20260412_001_rls_policies.sql =======
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

-- ======= Inhalt von: supabase/migrations/20260412_002_functions.sql =======
-- ============================================================================
-- Migration: 002 - Geschäftslogik-Funktionen
-- Beschreibung: SECURITY DEFINER-Funktionen, die komplexe Aktionen atomar
-- und sicher durchführen. Diese werden vom Server-Code aufgerufen.
-- ============================================================================

-- ============================================================================
-- Helper: Audit-Log-Eintrag anlegen
-- ============================================================================

CREATE OR REPLACE FUNCTION public.log_action(
  p_action      text,
  p_entity_type text,
  p_entity_id   text,
  p_payload     jsonb DEFAULT NULL,
  p_ip_address  inet DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  log_id bigint;
BEGIN
  INSERT INTO public.audit_log (actor_id, action, entity_type, entity_id, payload, ip_address)
  VALUES (auth.uid(), p_action, p_entity_type, p_entity_id, p_payload, p_ip_address)
  RETURNING id INTO log_id;
  RETURN log_id;
END;
$$;

-- ============================================================================
-- Funktion: Artikel übernehmen (reservieren)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reserve_article(
  p_article_slug text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid;
  v_reservation_id uuid;
  v_existing_active boolean;
  v_article_state text;
BEGIN
  v_doctor_id := auth.uid();

  IF v_doctor_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Prüfen, ob User ein aktives Profil hat
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_doctor_id AND disabled_at IS NULL) THEN
    RAISE EXCEPTION 'Account deactivated' USING ERRCODE = '42501';
  END IF;

  -- Prüfen, ob Artikel existiert
  IF NOT EXISTS (SELECT 1 FROM public.articles WHERE slug = p_article_slug) THEN
    RAISE EXCEPTION 'Article not found: %', p_article_slug USING ERRCODE = '02000';
  END IF;

  -- Zustand prüfen: Nur unverifiziert oder expired darf reserviert werden
  SELECT state INTO v_article_state
    FROM public.article_states
    WHERE slug = p_article_slug;

  IF v_article_state NOT IN ('unverified', 'expired') THEN
    RAISE EXCEPTION 'Article cannot be reserved in state: %', v_article_state USING ERRCODE = '22023';
  END IF;

  -- Reservierung anlegen
  INSERT INTO public.reservations (article_slug, doctor_id, status, free_assignment)
  VALUES (p_article_slug, v_doctor_id, 'active', false)
  RETURNING id INTO v_reservation_id;

  -- Audit
  PERFORM public.log_action(
    'reservation_created',
    'reservation',
    v_reservation_id::text,
    jsonb_build_object('article_slug', p_article_slug, 'doctor_id', v_doctor_id)
  );

  RETURN v_reservation_id;
END;
$$;

-- ============================================================================
-- Funktion: Artikel verifizieren
-- ============================================================================

CREATE OR REPLACE FUNCTION public.verify_article(
  p_reservation_id       uuid,
  p_disclaimer_confirmed boolean,
  p_payment_reference    text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid;
  v_reservation record;
  v_verification_id uuid;
  v_price_cents int;
  v_duration_days int;
  v_kind text;
  v_was_expired boolean;
BEGIN
  v_doctor_id := auth.uid();

  IF v_doctor_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT p_disclaimer_confirmed THEN
    RAISE EXCEPTION 'Disclaimer must be confirmed' USING ERRCODE = '22023';
  END IF;

  -- Reservierung laden und prüfen
  SELECT * INTO v_reservation
    FROM public.reservations
    WHERE id = p_reservation_id
      AND doctor_id = v_doctor_id
      AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active reservation not found or not owned' USING ERRCODE = '02000';
  END IF;

  -- Prüfen: War der Artikel vorher verifiziert und abgelaufen? Dann renewal.
  v_was_expired := EXISTS (
    SELECT 1 FROM public.verifications
    WHERE article_slug = v_reservation.article_slug
      AND revoked_at IS NULL
      AND expires_at <= now()
  );

  -- Kind bestimmen
  IF v_reservation.free_assignment THEN
    v_kind := 'free_admin';
    v_price_cents := 0;
  ELSIF v_was_expired THEN
    v_kind := 'renewal';
    SELECT (value::text)::int INTO v_price_cents FROM public.settings WHERE key = 'renewal_price_cents';
  ELSE
    v_kind := 'initial';
    SELECT (value::text)::int INTO v_price_cents FROM public.settings WHERE key = 'verification_price_cents';
  END IF;

  IF v_price_cents IS NULL THEN
    v_price_cents := 0;  -- Fallback, sollte nie passieren wenn Seeds richtig
  END IF;

  -- Gültigkeitsdauer laden
  SELECT (value::text)::int INTO v_duration_days FROM public.settings WHERE key = 'verification_duration_days';
  IF v_duration_days IS NULL THEN
    v_duration_days := 365;
  END IF;

  -- Verifizierung anlegen
  INSERT INTO public.verifications (
    article_slug, doctor_id, reservation_id, kind,
    verified_at, expires_at, price_cents_paid,
    disclaimer_confirmed, payment_reference
  ) VALUES (
    v_reservation.article_slug, v_doctor_id, p_reservation_id, v_kind,
    now(), now() + (v_duration_days || ' days')::interval, v_price_cents,
    p_disclaimer_confirmed, p_payment_reference
  ) RETURNING id INTO v_verification_id;

  -- Reservierung abschließen
  UPDATE public.reservations
    SET status = 'verified', completed_at = now()
    WHERE id = p_reservation_id;

  -- Audit
  PERFORM public.log_action(
    'article_verified',
    'verification',
    v_verification_id::text,
    jsonb_build_object(
      'article_slug', v_reservation.article_slug,
      'kind', v_kind,
      'price_cents_paid', v_price_cents,
      'expires_at', now() + (v_duration_days || ' days')::interval
    )
  );

  RETURN v_verification_id;
END;
$$;

-- ============================================================================
-- Funktion: Revision anfordern
-- ============================================================================

CREATE OR REPLACE FUNCTION public.request_revision(
  p_reservation_id uuid,
  p_comment        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid;
  v_reservation record;
  v_revision_id uuid;
BEGIN
  v_doctor_id := auth.uid();

  IF v_doctor_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF char_length(trim(p_comment)) < 10 THEN
    RAISE EXCEPTION 'Comment too short (min 10 chars)' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_reservation
    FROM public.reservations
    WHERE id = p_reservation_id
      AND doctor_id = v_doctor_id
      AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active reservation not found or not owned' USING ERRCODE = '02000';
  END IF;

  INSERT INTO public.revisions (article_slug, reservation_id, doctor_id, comment, status)
  VALUES (v_reservation.article_slug, p_reservation_id, v_doctor_id, p_comment, 'open')
  RETURNING id INTO v_revision_id;

  UPDATE public.reservations
    SET status = 'revised', completed_at = now()
    WHERE id = p_reservation_id;

  PERFORM public.log_action(
    'revision_requested',
    'revision',
    v_revision_id::text,
    jsonb_build_object('article_slug', v_reservation.article_slug, 'comment_length', char_length(p_comment))
  );

  RETURN v_revision_id;
END;
$$;

-- ============================================================================
-- Funktion: Reservierung abbrechen (Arzt)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancel_reservation(
  p_reservation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid;
  v_reservation record;
BEGIN
  v_doctor_id := auth.uid();

  SELECT * INTO v_reservation
    FROM public.reservations
    WHERE id = p_reservation_id
      AND doctor_id = v_doctor_id
      AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active reservation not found or not owned' USING ERRCODE = '02000';
  END IF;

  UPDATE public.reservations
    SET status = 'cancelled', completed_at = now()
    WHERE id = p_reservation_id;

  PERFORM public.log_action(
    'reservation_cancelled',
    'reservation',
    p_reservation_id::text,
    jsonb_build_object('article_slug', v_reservation.article_slug)
  );
END;
$$;

-- ============================================================================
-- Funktion: Admin weist Artikel kostenlos zu
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_assign_article(
  p_article_slug text,
  p_doctor_id    uuid,
  p_free         boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reservation_id uuid;
  v_article_state text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin only' USING ERRCODE = '42501';
  END IF;

  -- Prüfen ob Arzt existiert und aktiv ist
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_doctor_id AND role = 'doctor' AND disabled_at IS NULL) THEN
    RAISE EXCEPTION 'Doctor not found or disabled' USING ERRCODE = '02000';
  END IF;

  -- Prüfen Zustand
  SELECT state INTO v_article_state
    FROM public.article_states
    WHERE slug = p_article_slug;

  IF v_article_state NOT IN ('unverified', 'expired') THEN
    RAISE EXCEPTION 'Article cannot be assigned in state: %', v_article_state USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.reservations (article_slug, doctor_id, status, free_assignment)
  VALUES (p_article_slug, p_doctor_id, 'active', p_free)
  RETURNING id INTO v_reservation_id;

  PERFORM public.log_action(
    'article_assigned_by_admin',
    'reservation',
    v_reservation_id::text,
    jsonb_build_object('article_slug', p_article_slug, 'doctor_id', p_doctor_id, 'free', p_free)
  );

  RETURN v_reservation_id;
END;
$$;

-- ============================================================================
-- Funktion: Admin übernimmt Revision
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_claim_revision(
  p_revision_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF NOT public.is_admin(v_admin_id) THEN
    RAISE EXCEPTION 'Admin only' USING ERRCODE = '42501';
  END IF;

  UPDATE public.revisions
    SET status = 'in_admin_review', admin_id = v_admin_id
    WHERE id = p_revision_id AND status = 'open';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Revision not found or not open' USING ERRCODE = '02000';
  END IF;

  PERFORM public.log_action(
    'revision_claimed',
    'revision',
    p_revision_id::text,
    jsonb_build_object('admin_id', v_admin_id)
  );
END;
$$;

-- ============================================================================
-- Funktion: Admin schließt Revision ab
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_resolve_revision(
  p_revision_id uuid,
  p_status      text,  -- 'resolved' oder 'dismissed'
  p_admin_notes text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin only' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('resolved', 'dismissed') THEN
    RAISE EXCEPTION 'Invalid status: %', p_status USING ERRCODE = '22023';
  END IF;

  UPDATE public.revisions
    SET status = p_status,
        admin_notes = p_admin_notes,
        resolved_at = now()
    WHERE id = p_revision_id AND status IN ('open', 'in_admin_review');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Revision not found' USING ERRCODE = '02000';
  END IF;

  PERFORM public.log_action(
    'revision_resolved',
    'revision',
    p_revision_id::text,
    jsonb_build_object('status', p_status)
  );
END;
$$;

-- ============================================================================
-- Funktion: Admin zieht Verifizierung zurück
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_revoke_verification(
  p_verification_id uuid,
  p_reason          text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin only' USING ERRCODE = '42501';
  END IF;

  IF char_length(trim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'Reason required' USING ERRCODE = '22023';
  END IF;

  UPDATE public.verifications
    SET revoked_at = now(), revoked_reason = p_reason
    WHERE id = p_verification_id AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active verification not found' USING ERRCODE = '02000';
  END IF;

  PERFORM public.log_action(
    'verification_revoked',
    'verification',
    p_verification_id::text,
    jsonb_build_object('reason', p_reason)
  );
END;
$$;

-- ============================================================================
-- Grants: Welche Funktionen dürfen aus authenticated context aufgerufen werden
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.reserve_article(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_article(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_revision(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_reservation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_article(text, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_claim_revision(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_revision(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_verification(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin(uuid) TO authenticated, anon;

-- ======= Inhalt von: supabase/migrations/20260412_003_seed_data.sql =======
-- ============================================================================
-- Migration: 003 - Seed-Daten
-- Beschreibung: Initiale Einstellungen und Artikel-Spiegelung
-- ============================================================================

-- Standard-Einstellungen
INSERT INTO public.settings (key, value, description) VALUES
  ('verification_price_cents',       '4000'::jsonb,
    'Preis für Erstverifizierung eines Artikels in Cent (4000 = 40 Euro)'),
  ('renewal_price_cents',            '500'::jsonb,
    'Preis für Verlängerung einer Verifizierung in Cent (500 = 5 Euro)'),
  ('verification_duration_days',     '365'::jsonb,
    'Gültigkeitsdauer einer Verifizierung in Tagen'),
  ('renewal_grace_period_days',      '365'::jsonb,
    'Wie lange nach Ablauf noch verlängert werden kann'),
  ('reservation_timeout_days',       '7'::jsonb,
    'Nach wie vielen Tagen inaktiver Reservierungen diese automatisch abbrechen (Cronjob)')
ON CONFLICT (key) DO NOTHING;

-- Artikel spiegeln (aus dem Markdown-Bestand zum Zeitpunkt der Erstmigration)
-- Titel und Kategorien werden später vom Sync-Skript aktuell gehalten
INSERT INTO public.articles (slug, title, category) VALUES
  ('augenlaser-operation-was-die-studien-wirklich-zeigen',
    'Augenlaser-Operation: Was die Studien wirklich zeigen', 'Augenheilkunde'),
  ('bandscheibenvorfall-op-vs-konservativ',
    'Bandscheibenvorfall: OP oder abwarten?', 'Orthopädie'),
  ('grauer-star-katarakt-op-linse-evidenz',
    'Grauer Star OP: Wann sinnvoll, welche Linse?', 'Augenheilkunde'),
  ('hyaluronsaeure-knie-arthrose-evidenz',
    'Hyaluronsäure bei Kniearthrose: Was die Evidenz wirklich zeigt', 'Orthopädie'),
  ('isotretinoin-akne-evidenz',
    'Isotretinoin bei Akne: Gefährlich oder unterschätzt?', 'Dermatologie'),
  ('kreuzbandriss-op-physiotherapie-evidenz',
    'Kreuzbandriss: Wann ist die OP wirklich nötig?', 'Orthopädie'),
  ('meniskusriss-op-vs-physiotherapie',
    'Meniskusriss: OP oder Physiotherapie?', 'Orthopädie'),
  ('neurodermitis-cortison-angst-evidenz',
    'Neurodermitis: Ist die Angst vor Cortison berechtigt?', 'Dermatologie'),
  ('protonenpumpenhemmer-langzeiteinnahme-evidenz',
    'Protonenpumpenhemmer: Gefährlich auf Dauer?', 'Innere Medizin'),
  ('rueckenschmerzen-mrt-bildgebung-evidenz',
    'Rückenschmerzen und MRT: Wann Bildgebung schadet', 'Orthopädie'),
  ('schulter-impingement-op-evidenz',
    'Schulter-Impingement: Hilft die OP wirklich?', 'Orthopädie'),
  ('schulter-impingement-subakromiale-dekompression',
    'Schulter-OP: Subakromiale Dekompression im Evidenz-Check', 'Orthopädie'),
  ('statine-cholesterin-primaerpraevention-evidenz',
    'Statine zur Cholesterinsenkung: Nützen Sie?', 'Innere Medizin'),
  ('vitamin-d-supplementierung-evidenz',
    'Vitamin D: Wundermittel oder Hype? Die Evidenz', 'Innere Medizin'),
  ('vorhofflimmern-katheterablation-evidenz',
    'Vorhofflimmern: Katheterablation vs Medikamente', 'Kardiologie')
ON CONFLICT (slug) DO UPDATE SET
  title = EXCLUDED.title,
  category = EXCLUDED.category,
  updated_at = now();

-- ============================================================================
-- WICHTIG: Ersten Admin manuell anlegen
-- ============================================================================
--
-- Nach Anwenden dieser Migration, gehe in Supabase Dashboard:
--
-- 1. Authentication → Users → "Add user" → "Send invitation"
--    - E-Mail eingeben (deine eigene)
--    - Invite senden
--    - Link anklicken, einloggen
--
-- 2. Danach im SQL Editor ausführen (E-Mail-Adresse anpassen):
--
--    UPDATE public.profiles
--    SET role = 'admin',
--        full_name = 'Dein Name'
--    WHERE id = (SELECT id FROM auth.users WHERE email = 'dein@email.de');
--
-- Ab dann bist du Admin und kannst andere Ärzte einladen.
-- ============================================================================
