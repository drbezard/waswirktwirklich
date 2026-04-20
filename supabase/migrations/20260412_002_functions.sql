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
