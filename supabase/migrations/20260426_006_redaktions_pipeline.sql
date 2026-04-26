-- ============================================================================
-- Migration: 006 - Redaktions-Pipeline (Topics, Prompts, Tags, Freshness)
-- Beschreibung: Schafft das Datenmodell für die autonome Pipeline:
--   * topics: Pool & Status-Maschine (discovered → drafted → polished → published)
--   * prompts/prompt_history: versionierte Master-Prompts für Manus + Claude
--   * articles erweitert: Tags + Freshness-Audit
--   * settings: Pipeline-Steuerung (Pause, Rate, Pool-Limit, Vokabular)
-- ============================================================================

-- ============================================================================
-- 1. topics: Pool aller Themen aus allen Quellen
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.topics (
  id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  title             text          NOT NULL,
  description       text,
  source            text          NOT NULL
                                  CHECK (source IN ('admin','patient','manus','revision')),
  type              text          NOT NULL DEFAULT 'new'
                                  CHECK (type IN ('new','revision','refresh')),
  status            text          NOT NULL DEFAULT 'discovered'
                                  CHECK (status IN (
                                    'discovered',      -- frisch im Pool
                                    'drafted',         -- Manus hat Draft mit Quellen
                                    'polished',        -- Claude hat sprachlich poliert
                                    'published',       -- live
                                    'discarded'        -- verworfen
                                  )),

  -- Verknüpfungen
  draft_path        text,                                                -- src/content/drafts/<slug>.md
  article_slug      text          REFERENCES public.articles(slug) ON DELETE SET NULL,
  parent_topic_id   uuid          REFERENCES public.topics(id) ON DELETE SET NULL,
  duplicate_of_id   uuid          REFERENCES public.topics(id) ON DELETE SET NULL,
  revision_id       uuid          REFERENCES public.revisions(id) ON DELETE SET NULL,

  -- Tag-System (Vorschlag, finalisiert wird beim Publish in articles.tags)
  suggested_tags    text[],

  -- Eingang
  submitted_by      uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  source_url        text,

  -- Audit
  created_at        timestamptz   NOT NULL DEFAULT now(),
  updated_at        timestamptz   NOT NULL DEFAULT now(),
  published_at      timestamptz,
  notes             text,

  -- Bei Refresh muss article_slug gesetzt sein
  CONSTRAINT topics_refresh_needs_article CHECK (
    type != 'refresh' OR article_slug IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS topics_status_idx       ON public.topics(status);
CREATE INDEX IF NOT EXISTS topics_source_idx       ON public.topics(source);
CREATE INDEX IF NOT EXISTS topics_type_idx         ON public.topics(type);
CREATE INDEX IF NOT EXISTS topics_article_slug_idx ON public.topics(article_slug);
CREATE INDEX IF NOT EXISTS topics_created_at_idx   ON public.topics(created_at DESC);

CREATE TRIGGER topics_set_updated_at
  BEFORE UPDATE ON public.topics
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.topics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "topics_admin_all" ON public.topics
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- 2. prompts: aktuelle Master-Prompts (key-based, eine Zeile pro Prompt)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.prompts (
  key               text          PRIMARY KEY,
  title             text          NOT NULL,
  description       text,
  body              text          NOT NULL,
  version           int           NOT NULL DEFAULT 1,
  updated_by        uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at        timestamptz   NOT NULL DEFAULT now()
);

ALTER TABLE public.prompts ENABLE ROW LEVEL SECURITY;

-- Öffentlich lesbar — Manus + Claude lesen ohne User-Auth (über Manus-Token bzw.
-- direkten Anon-Zugriff). Die Bodies enthalten keine Geheimnisse.
CREATE POLICY "prompts_public_select" ON public.prompts
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "prompts_admin_write" ON public.prompts
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- 3. prompt_history: append-only Audit-Trail jeder Prompt-Änderung
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.prompt_history (
  id                bigserial     PRIMARY KEY,
  prompt_key        text          NOT NULL,
  version           int           NOT NULL,
  body              text          NOT NULL,
  changed_by        uuid          REFERENCES public.profiles(id) ON DELETE SET NULL,
  changed_at        timestamptz   NOT NULL DEFAULT now(),
  diff_summary      text
);

CREATE INDEX IF NOT EXISTS prompt_history_key_idx
  ON public.prompt_history(prompt_key, changed_at DESC);

ALTER TABLE public.prompt_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "prompt_history_admin_select" ON public.prompt_history
  FOR SELECT
  USING (public.is_admin());

-- INSERT nur über Trigger / SECURITY DEFINER (kein direkter Write)

-- ============================================================================
-- 4. Trigger: bei Prompt-Update automatisch History-Eintrag schreiben
-- ============================================================================

CREATE OR REPLACE FUNCTION public.write_prompt_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Nur bei Body-Änderung loggen
  IF (TG_OP = 'UPDATE' AND OLD.body IS DISTINCT FROM NEW.body) OR TG_OP = 'INSERT' THEN
    INSERT INTO public.prompt_history (prompt_key, version, body, changed_by)
    VALUES (NEW.key, NEW.version, NEW.body, NEW.updated_by);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prompts_history_trigger ON public.prompts;
CREATE TRIGGER prompts_history_trigger
  AFTER INSERT OR UPDATE ON public.prompts
  FOR EACH ROW EXECUTE FUNCTION public.write_prompt_history();

-- ============================================================================
-- 5. articles erweitern: Tags + Freshness
-- ============================================================================

ALTER TABLE public.articles
  ADD COLUMN IF NOT EXISTS tags                  text[],
  ADD COLUMN IF NOT EXISTS last_freshness_check  timestamptz,
  ADD COLUMN IF NOT EXISTS refresh_count         int NOT NULL DEFAULT 0;

-- GIN-Index für Tag-Overlap-Queries (für „Weitere Artikel" via Tag-Score)
CREATE INDEX IF NOT EXISTS articles_tags_gin_idx ON public.articles USING GIN (tags);

-- ============================================================================
-- 6. Settings: Pipeline-Defaults (idempotent)
-- ============================================================================

INSERT INTO public.settings (key, value) VALUES
  ('pipeline_paused',            'false'::jsonb),
  ('drafts_per_week_target',     '3'::jsonb),
  ('topics_discovery_per_day',   '5'::jsonb),
  ('max_pool_size_in_review',    '5'::jsonb),
  ('freshness_check_days',       '365'::jsonb),
  ('tags_vocabulary',
   '["orthopaedie","kardiologie","augenheilkunde","dermatologie","innere-medizin","operation","medikament","injektion","screening","supplement","placebo-kontrolliert","leitlinie","cochrane","igel","arthrose","knie","huefte","schulter","ruecken","wirbelsaeule","herz","blutdruck","cholesterin","vitamin-d","ppi","akne","neurodermitis","auge","prostata","krebs"]'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- 7. Initial-Prompts als Platzhalter (echte Bodies werden im Code gesetzt)
-- ============================================================================

INSERT INTO public.prompts (key, title, description, body) VALUES
  ('manus_discovery',
   'Manus: Themen-Discovery',
   'Wie Manus relevante neue Patientenfragen findet (Reddit, NetDoktor, PubMed Trending)',
   'PLATZHALTER — wird durch Setup-Skript ersetzt'),
  ('manus_drafting',
   'Manus: Artikel-Draft',
   'Wie Manus einen evidenzbasierten Patientenartikel schreibt — autonom, mit Live-Recherche',
   'PLATZHALTER — wird durch Setup-Skript ersetzt'),
  ('claude_polishing',
   'Claude: Stil-Politur',
   'Wie Claude einen Manus-Draft sprachlich poliert ohne Inhalt oder Quellen zu ändern',
   'PLATZHALTER — wird durch Setup-Skript ersetzt'),
  ('manus_review_publish',
   'Manus: Review + Veröffentlichung',
   'Wie Manus den finalen DOI-Check macht und den polierten Artikel veröffentlicht',
   'PLATZHALTER — wird durch Setup-Skript ersetzt')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- 8. RPC: Topic-Status-Transition mit Audit
-- ============================================================================

CREATE OR REPLACE FUNCTION public.transition_topic_status(
  p_topic_id    uuid,
  p_new_status  text,
  p_actor_id    uuid DEFAULT NULL,
  p_notes       text DEFAULT NULL
)
RETURNS public.topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_topic public.topics;
  v_old_status text;
BEGIN
  SELECT status INTO v_old_status FROM public.topics WHERE id = p_topic_id;

  UPDATE public.topics
  SET status        = p_new_status,
      published_at  = CASE WHEN p_new_status = 'published' THEN now() ELSE published_at END,
      notes         = CASE
                        WHEN p_notes IS NOT NULL
                        THEN COALESCE(notes, '') || E'\n[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || '] ' || p_notes
                        ELSE notes
                      END
  WHERE id = p_topic_id
  RETURNING * INTO v_topic;

  INSERT INTO public.audit_log (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    p_actor_id,
    'topic_status_changed',
    'topic',
    p_topic_id::text,
    jsonb_build_object(
      'old_status', v_old_status,
      'new_status', p_new_status,
      'notes',      p_notes
    )
  );

  RETURN v_topic;
END;
$$;

GRANT EXECUTE ON FUNCTION public.transition_topic_status(uuid, text, uuid, text) TO authenticated;

-- ============================================================================
-- 9. RPC: Refresh-Publish (überschreibt Artikel + revoked alte Verifikationen)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.publish_refresh(
  p_topic_id    uuid,
  p_actor_id    uuid DEFAULT NULL
)
RETURNS public.topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_topic public.topics;
BEGIN
  SELECT * INTO v_topic FROM public.topics WHERE id = p_topic_id;

  IF v_topic.type != 'refresh' THEN
    RAISE EXCEPTION 'publish_refresh: Topic % ist kein refresh-Topic', p_topic_id;
  END IF;

  IF v_topic.article_slug IS NULL THEN
    RAISE EXCEPTION 'publish_refresh: Topic % hat keinen article_slug', p_topic_id;
  END IF;

  -- Alle aktiven Verifikationen revoken
  UPDATE public.verifications
  SET revoked_at      = now(),
      revoked_reason  = 'refresh'
  WHERE article_slug = v_topic.article_slug
    AND revoked_at IS NULL;

  -- Article-Counter hochzählen
  UPDATE public.articles
  SET refresh_count        = refresh_count + 1,
      last_freshness_check = now()
  WHERE slug = v_topic.article_slug;

  -- Topic auf published setzen
  UPDATE public.topics
  SET status        = 'published',
      published_at  = now()
  WHERE id = p_topic_id
  RETURNING * INTO v_topic;

  -- Audit
  INSERT INTO public.audit_log (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    p_actor_id,
    'article_refreshed',
    'article',
    v_topic.article_slug,
    jsonb_build_object('topic_id', p_topic_id)
  );

  RETURN v_topic;
END;
$$;

GRANT EXECUTE ON FUNCTION public.publish_refresh(uuid, uuid) TO authenticated;

-- ============================================================================
-- 10. View: pipeline_overview — kombiniert für Dashboard
-- ============================================================================

CREATE OR REPLACE VIEW public.pipeline_overview AS
SELECT
  t.status,
  t.source,
  t.type,
  COUNT(*)            AS count,
  MIN(t.created_at)   AS oldest_at,
  MAX(t.updated_at)   AS most_recent_at
FROM public.topics t
WHERE t.status NOT IN ('published','discarded')
GROUP BY t.status, t.source, t.type;
