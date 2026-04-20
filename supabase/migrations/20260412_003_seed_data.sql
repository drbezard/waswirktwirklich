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
