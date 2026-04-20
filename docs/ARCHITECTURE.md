# Architektur: Verifizierungsplattform

Dieses Dokument beschreibt die technische Architektur der Ärzte-Verifizierungsplattform von „Was Wirkt Wirklich". Zielgruppe: Entwickler und technisch versierte Stakeholder.

## Leitprinzipien

1. **Sauberes Fundament** — Langzeitnutzung, keine Abkürzungen
2. **Sicherheit per Design** — Row-Level Security, kein Vertrauen in Client-Code
3. **Typsicherheit von DB bis UI** — Zod + TypeScript + generierte Typen
4. **DSGVO-konform** — EU-Region, Datenminimalismus, Audit-Logs
5. **Öffentliche Seite bleibt statisch** — Artikel weiterhin blitzschnell, Backend separat

## System-Überblick

```
┌─────────────────────────────────────────────────────────┐
│                    Browser (Leser)                       │
└────────────┬────────────────────────────┬───────────────┘
             │                            │
             ▼                            ▼
   ┌──────────────────┐        ┌──────────────────────┐
   │  Öffentliche     │        │  Arzt-/Admin-        │
   │  Artikel-Seite   │        │  Backend             │
   │  (statisch)      │        │  (SSR, bewacht)      │
   │  /artikel/*      │        │  /arzt/*, /admin/*   │
   └─────────┬────────┘        └──────────┬───────────┘
             │                            │
             │   zeigt Prüfungs-          │  authentifiziert,
             │   Status an                │  schreibt Daten
             │                            │
             └──────────────┬─────────────┘
                            │
                            ▼
                  ┌──────────────────┐
                  │    Supabase      │
                  │  (EU, Frankfurt) │
                  │                  │
                  │  - Postgres DB   │
                  │  - Auth (Magic   │
                  │    Link E-Mail)  │
                  │  - Row-Level     │
                  │    Security      │
                  └──────────────────┘
```

## Technologie-Stack

| Ebene                  | Werkzeug                              | Begründung                                       |
|------------------------|---------------------------------------|--------------------------------------------------|
| Framework              | Astro 6 (hybrid mode)                 | Behält statische Artikel schnell, erlaubt SSR    |
| Hosting                | Vercel                                | Nahtlose Astro-Integration, EU-Edge              |
| Datenbank              | Supabase Postgres                     | Managed, DSGVO, eingebauter Auth & RLS           |
| Authentifizierung      | Supabase Auth (Magic Link)            | Passwortlos, einfach für Ärzte                   |
| DB-Zugriff (Server)    | `@supabase/supabase-js`               | Offizielle SDK, RLS-kompatibel                   |
| Validierung            | Zod                                   | Typsichere Eingabeprüfung                        |
| Styling                | Tailwind CSS 4 (bestehend)            | Konsistent mit öffentlichem Bereich              |
| E-Mail                 | Supabase Auth (anfangs)               | Für Magic Links reicht das                       |
| E-Mail (später)        | Resend                                | Für Erinnerungen, Benachrichtigungen             |
| Zahlungen (Phase 2)    | Stripe Checkout + Webhooks            | Branchenstandard, SEPA & Karten                  |
| Monitoring             | Sentry (Phase 3)                      | Frühwarnsystem bei Produktionsfehlern            |

## Astro-Rendering-Modus

- **Statische Seiten** (default): `/`, `/artikel/*`, `/fachgebiet/*`, `/fachgebiete`, `/impressum`, `/404`, `/rss.xml`
- **SSR-Seiten** (`export const prerender = false`): Alle Routen unter `/arzt/*` und `/admin/*`

Die Umstellung auf „hybrid mode" mit `@astrojs/vercel` Adapter ist rückwärtskompatibel — öffentliche Seiten bleiben genauso schnell und SEO-freundlich wie heute.

## Sicherheitsmodell

### Auth-Flow

1. Nutzer gibt E-Mail auf `/arzt/login` ein
2. Supabase sendet Magic Link per E-Mail
3. Klick auf Link → Callback-Route (`/arzt/callback`) setzt Session-Cookie
4. Sitzungen sind httpOnly-Cookies (nicht per JavaScript lesbar)
5. Server prüft bei jedem Request Gültigkeit und Rolle

### Rollen

Gespeichert im `profiles`-Tabelle pro User:

- `doctor` — Standard-Rolle für Ärzte
- `admin` — Vollzugriff auf alles

Keine Rollen in Tokens/Cookies — immer Quelle-of-Truth ist die Datenbank.

### Row-Level Security (RLS)

RLS ist Postgres' Sicherheits-Feature auf Datenbank-Ebene: Selbst wenn der Anwendungs-Code kompromittiert würde, kann Arzt A niemals die Daten von Arzt B sehen.

Beispiel-Policy für `reservations`:

```sql
-- Ärzte sehen nur ihre eigenen Reservierungen
CREATE POLICY "doctors_see_own_reservations" ON reservations
  FOR SELECT USING (doctor_id = auth.uid());

-- Admins sehen alle
CREATE POLICY "admins_see_all_reservations" ON reservations
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );
```

### Audit-Trail

Jede Zustandsänderung wird in der `audit_log`-Tabelle persistiert:
- Wer? (user_id)
- Was? (action, entity_type, entity_id)
- Wann? (timestamp)
- Wie? (diff/payload als JSONB)

Audit-Einträge sind nur lesbar, nie bearbeitbar — auch nicht für Admins (durch RLS erzwungen).

## Datenhaltung: Hybrid-Ansatz

- **Artikel-Content** bleibt in Markdown (`src/content/artikel/*.md`) — Versionskontrolle via Git, Build-Performance, SEO
- **Verifizierungs-Status, Ärzte, Zahlungen** in Supabase — dynamisch, transaktional

Beim Rendern einer Artikelseite wird der aktuelle Verifizierungs-Status aus Supabase geladen (statisch vorgebaut für schnelle Auslieferung, bei Statusänderung Revalidation).

## Verzeichnisstruktur (geplant)

```
src/
  content/
    artikel/                  # Markdown-Artikel (unverändert)
  lib/
    supabase/
      client.ts               # Browser-Client
      server.ts               # Server-Client (mit Auth)
      admin.ts                # Service-Role-Client (nur Server)
      types.ts                # DB-Typen (generiert)
    validators/
      article.ts              # Zod-Schemas für Eingaben
      reservation.ts
      ...
    audit.ts                  # Audit-Log-Helper
  middleware.ts               # Astro-Middleware: Auth-Check für /arzt und /admin
  pages/
    (öffentlich, unverändert: /, /artikel/*, /fachgebiet/*, ...)
    arzt/
      login.astro
      callback.astro
      index.astro             # Dashboard
      artikel.astro           # Liste übernehmbarer Artikel
      profil/
        index.astro
      artikel/
        [id].astro            # Ein Artikel verifizieren/revidieren
    admin/
      index.astro
      revisionen/index.astro
      revisionen/[id].astro
      aerzte/index.astro
      aerzte/[id].astro
      preise.astro
      zuweisungen.astro
  components/
    (bestehende, plus:)
    ArticleClaimButton.astro
    VerifyForm.astro
    RevisionForm.astro
    ReviewerBadge.astro
    ...
supabase/
  migrations/
    20260412_000_initial_schema.sql
    20260412_001_rls_policies.sql
    20260412_002_seed_settings.sql
docs/
  ARCHITECTURE.md             # Dieses Dokument
  DATABASE.md                 # ER-Diagramm und Tabellen-Beschreibung
  USER_FLOWS.md               # Schritt-für-Schritt-Abläufe
  RUNBOOK.md                  # Was tun wenn X kaputt ist?
```

## Zustandsmaschine (State Machine) für Artikel

Jeder Artikel hat genau einen von diesen Zuständen zu einem Zeitpunkt. Die DB erzwingt gültige Übergänge via Check-Constraint und Trigger.

```
                    ┌──────────────────┐
                    │  unverified      │◄─────────────────────────┐
                    │  (Standard)      │                          │
                    └────────┬─────────┘                          │
                             │                                    │
                    (Arzt übernimmt                    (Admin schließt
                     oder Admin weist zu)               Revision ab)
                             │                                    │
                             ▼                                    │
                    ┌──────────────────┐                          │
                    │  reserved        │                          │
                    │  (bearbeitet)    │                          │
                    └────────┬─────────┘                          │
                             │                                    │
            ┌────────────────┼────────────────┐                   │
            │                │                │                   │
    (Arzt verifiziert)  (Timeout)      (Arzt sendet               │
            │                │          zur Revision)             │
            ▼                ▼                ▼                   │
    ┌───────────┐    (zurück zu      ┌──────────────────┐         │
    │ verified  │    unverified)     │  revision        │         │
    │           │                    │  requested       │         │
    └─────┬─────┘                    └────────┬─────────┘         │
          │                                   │                   │
   (nach 1 Jahr)                    (Admin übernimmt)             │
          │                                   │                   │
          ▼                                   ▼                   │
    ┌───────────┐                    ┌──────────────────┐         │
    │ expired   │                    │  admin_review    │─────────┘
    │           │                    │                  │
    └─────┬─────┘                    └──────────────────┘
          │
    (Verlängerung)
          │
          ▼
    ┌───────────┐
    │ verified  │
    │ (erneut)  │
    └───────────┘
```

## Preis-Handhabung

- Preise liegen in `settings`-Tabelle (`verification_price_cents`, `renewal_price_cents`)
- Bei jeder Verifizierung wird der **aktuelle** Preis in `verifications.price_cents_paid` gespeichert
- Preisänderungen beeinflussen nie bereits bezahlte Verifizierungen (Versionierung)
- Admin-kostenlose Zuweisungen: `verifications.is_free = true`, `price_cents_paid = 0`

## Reservierungsschutz

Problem: Zwei Ärzte dürfen nicht gleichzeitig denselben Artikel bearbeiten.

Lösung: Unique-Constraint auf `reservations(article_id) WHERE status IN ('reserved')`. Durchgesetzt auf DB-Ebene, nicht nur im Code.

Optional: Zeit-Timeout (z.B. 7 Tage) via Cron-Job, der alte Reservierungen löscht.

## Phasen der Umsetzung

### Phase 0 — Fundament (in Arbeit)
- Diese Architektur-Doku
- Datenbank-Schema + Migrationen
- RLS-Policies
- Astro hybrid mode
- Supabase-Client-Wrapper
- Audit-Log-Infrastruktur

### Phase 1 — Arzt-Backend (ohne Zahlung)
- Magic-Link-Login
- Artikel-Liste (verfügbar, eigene)
- Übernahme-Flow
- Verifizierungs-Flow
- Revisions-Flow
- Arzt-Profil

### Phase 2 — Admin-Backend
- Revisions-Management
- Benutzer-/Rollen-Verwaltung
- Preis-Steuerung
- Manuelle (kostenlose) Zuweisung
- Manuelle Status-Änderung (Admin-Override)

### Phase 3 — Zahlungen
- Stripe-Integration
- Webhook-Handling (fehlertolerant)
- Rechnungs-Generierung (PDF)
- Zahlungs-Historie

### Phase 4 — Produktion
- Erinnerungs-E-Mails (30/7/0 Tage vor Ablauf)
- Sentry-Monitoring
- Backup-Strategie
- Staging-Umgebung

## DSGVO-Überlegungen

- **Region**: Supabase in EU (Frankfurt oder Ireland) — keine Daten in USA
- **Datenminimalismus**: Nur E-Mail und fachlich nötige Daten der Ärzte
- **Recht auf Löschung**: Admin-Funktion „Arzt-Konto löschen" — entfernt PII, behält anonymisierte Audit-Einträge (steuerrechtlich nötig für Zahlungen)
- **Recht auf Export**: Arzt kann eigene Daten als JSON herunterladen
- **Auftragsverarbeitung**: AV-Verträge mit Supabase, Stripe, Resend (vom Nutzer zu unterschreiben)

## Offene Punkte für den Geschäftsbetreiber

Diese Punkte kann Code nicht lösen — braucht menschliche Entscheidung/externe Dienstleister:

- AGB für Ärzte (Anwalt)
- Datenschutzerklärung (Anwalt)
- Ärztekammer-Rückfrage: Honorarform der Verifizierung
- Stripe-Konto (Verifizierung dauert 3-7 Werktage)
- Eigene Domain (statt `.vercel.app`, für E-Mail-Zustellung entscheidend)

## Glossar (für nicht-technische Leser)

- **SSR** (Server-Side Rendering): Seite wird auf dem Server gebaut, wenn sie angefragt wird. Gegenteil von statisch.
- **RLS** (Row-Level Security): Sicherheitsregeln direkt in der Datenbank, die bestimmen, welche Zeilen welcher User sehen/ändern darf.
- **Magic Link**: Login-Link per E-Mail — ein Klick und du bist eingeloggt, kein Passwort nötig.
- **Migration**: Versioniertes SQL-Skript, das Änderungen am Datenbank-Schema beschreibt. Reproduzierbar, rückverfolgbar.
- **Seed**: Initial-Daten, die direkt nach Schema-Erstellung eingespielt werden (z.B. Standardpreise).
- **Webhook**: Eine Art umgekehrter API-Call — Stripe ruft bei uns an, wenn z.B. eine Zahlung bestätigt wurde.
- **Audit-Trail**: Protokoll aller Änderungen, unveränderbar, für Compliance und Nachvollziehbarkeit.
