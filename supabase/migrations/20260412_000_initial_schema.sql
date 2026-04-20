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
