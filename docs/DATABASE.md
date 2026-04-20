# Datenbank-Schema

Vollständige Beschreibung aller Tabellen, Beziehungen und Zustandsregeln.

## Überblick (ER-Diagramm als ASCII)

```
  ┌─────────────────┐
  │  auth.users     │◄── Supabase-eigene Tabelle
  │  (Supabase)     │    (nicht von uns erstellt)
  └────────┬────────┘
           │ 1:1
           ▼
  ┌─────────────────┐
  │  profiles       │    Erweiterung der Auth-User
  │  - role         │    um Rolle und Anzeigename
  │  - full_name    │
  └────────┬────────┘
           │ 1:n
           ├──────────────────────┬──────────────────────┐
           ▼                      ▼                      ▼
  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
  │  reservations   │   │  verifications  │   │  revisions      │
  │  - article_slug │   │  - article_slug │   │  - article_slug │
  │  - doctor_id    │   │  - doctor_id    │   │  - doctor_id    │
  │  - status       │   │  - verified_at  │   │  - comment      │
  │  - created_at   │   │  - expires_at   │   │  - status       │
  │                 │   │  - price_cents  │   │                 │
  │                 │   │  - is_free      │   │                 │
  └─────────────────┘   └─────────────────┘   └─────────────────┘


  ┌─────────────────┐   ┌─────────────────┐
  │  settings       │   │  audit_log      │
  │  - key          │   │  - user_id      │
  │  - value        │   │  - action       │
  │  (Preise etc.)  │   │  - entity_type  │
  │                 │   │  - entity_id    │
  │                 │   │  - payload      │
  └─────────────────┘   └─────────────────┘
```

## Tabellen im Detail

### `profiles`

Erweitert `auth.users` (von Supabase) um fachliche Daten. 1:1-Beziehung per gleicher ID.

| Spalte         | Typ         | Constraints                   | Zweck                              |
|----------------|-------------|-------------------------------|------------------------------------|
| `id`           | `uuid`      | PK, FK → `auth.users(id)`     | Gleich wie Auth-User-ID            |
| `role`         | `text`      | NOT NULL, CHECK in Enum       | `'doctor'` oder `'admin'`          |
| `full_name`    | `text`      |                               | Anzeigename                        |
| `title`        | `text`      |                               | z.B. „Facharzt für Orthopädie"    |
| `photo_url`    | `text`      |                               | Optional, URL zu Profilbild        |
| `bio`          | `text`      |                               | Kurzbeschreibung                   |
| `website_url`  | `text`      |                               | Eigene Webseite des Arztes         |
| `disabled_at`  | `timestamptz` |                             | Wenn gesetzt: Konto deaktiviert    |
| `created_at`   | `timestamptz` | NOT NULL DEFAULT now()      |                                    |
| `updated_at`   | `timestamptz` | NOT NULL DEFAULT now()      |                                    |

**Trigger**: `updated_at` wird bei jedem UPDATE automatisch aktualisiert.

**Seed**: Erster Admin manuell via SQL-Insert (siehe USER_FLOWS.md).

---

### `articles`

Spiegelt die Markdown-Artikel in der Datenbank, damit RLS und Fremdschlüssel funktionieren. Wird beim Build automatisch synchronisiert.

| Spalte         | Typ         | Constraints                   | Zweck                              |
|----------------|-------------|-------------------------------|------------------------------------|
| `slug`         | `text`      | PK                            | URL-Slug des Artikels              |
| `title`        | `text`      | NOT NULL                      | Aktueller Titel (für Admin-Listen) |
| `category`     | `text`      | NOT NULL                      | Für Filter                         |
| `created_at`   | `timestamptz` | NOT NULL DEFAULT now()      |                                    |
| `updated_at`   | `timestamptz` | NOT NULL DEFAULT now()      |                                    |

**Sync**: Ein Skript (oder ein Astro-Build-Hook) pflegt die Tabelle bei jedem Deploy.

---

### `reservations`

Wenn ein Arzt einen Artikel übernimmt, aber noch nicht abgeschlossen hat.

| Spalte             | Typ           | Constraints                   | Zweck                              |
|--------------------|---------------|-------------------------------|------------------------------------|
| `id`               | `uuid`        | PK, DEFAULT gen_random_uuid() |                                    |
| `article_slug`     | `text`        | NOT NULL, FK → articles(slug) |                                    |
| `doctor_id`        | `uuid`        | NOT NULL, FK → profiles(id)   |                                    |
| `status`           | `text`        | NOT NULL, CHECK in Enum       | `'active'`, `'verified'`, `'revised'`, `'cancelled'`, `'expired'` |
| `reserved_at`      | `timestamptz` | NOT NULL DEFAULT now()        |                                    |
| `completed_at`     | `timestamptz` |                               | Verifizierung oder Revision erfolgt |
| `free_assignment`  | `boolean`     | NOT NULL DEFAULT false        | Von Admin kostenlos zugewiesen?    |

**Unique-Constraint**: `(article_slug) WHERE status = 'active'` — verhindert doppelte aktive Reservierungen.

**Indexe**:
- `(doctor_id, status)` — für „meine aktiven Reservierungen"
- `(article_slug)` — für Artikel-Suche

---

### `verifications`

Wenn ein Arzt einen Artikel erfolgreich verifiziert hat.

| Spalte             | Typ           | Constraints                   | Zweck                              |
|--------------------|---------------|-------------------------------|------------------------------------|
| `id`               | `uuid`        | PK, DEFAULT gen_random_uuid() |                                    |
| `article_slug`     | `text`        | NOT NULL, FK → articles(slug) |                                    |
| `doctor_id`        | `uuid`        | NOT NULL, FK → profiles(id)   |                                    |
| `reservation_id`   | `uuid`        | FK → reservations(id)         | Aus welcher Reservierung?          |
| `kind`             | `text`        | NOT NULL, CHECK in Enum       | `'initial'`, `'renewal'`, `'free_admin'` |
| `verified_at`      | `timestamptz` | NOT NULL DEFAULT now()        |                                    |
| `expires_at`       | `timestamptz` | NOT NULL                      | Standardmäßig +1 Jahr              |
| `price_cents_paid` | `integer`     | NOT NULL                      | In Cent, 0 wenn kostenlos          |
| `disclaimer_confirmed` | `boolean` | NOT NULL DEFAULT true         | Arzt hat Disclaimer bestätigt      |
| `payment_reference`| `text`        |                               | Stripe Session ID o.ä.             |
| `revoked_at`       | `timestamptz` |                               | Wenn Admin Verifizierung zurückzieht |
| `revoked_reason`   | `text`        |                               |                                    |

**Aktuelle Verifizierung**: Die „aktive" Verifizierung eines Artikels ist der neueste Eintrag mit `revoked_at IS NULL AND expires_at > now()`.

**Index**: `(article_slug, verified_at DESC)` — für schnellen Zugriff auf aktuellste Verifizierung.

---

### `revisions`

Wenn ein Arzt einen Artikel zur Überarbeitung meldet.

| Spalte             | Typ           | Constraints                   | Zweck                              |
|--------------------|---------------|-------------------------------|------------------------------------|
| `id`               | `uuid`        | PK, DEFAULT gen_random_uuid() |                                    |
| `article_slug`     | `text`        | NOT NULL, FK → articles(slug) |                                    |
| `reservation_id`   | `uuid`        | FK → reservations(id)         |                                    |
| `doctor_id`        | `uuid`        | NOT NULL, FK → profiles(id)   |                                    |
| `comment`          | `text`        | NOT NULL                      | Arzt beschreibt das Problem        |
| `status`           | `text`        | NOT NULL, CHECK in Enum       | `'open'`, `'in_admin_review'`, `'resolved'`, `'dismissed'` |
| `admin_id`         | `uuid`        | FK → profiles(id)             | Welcher Admin bearbeitet           |
| `admin_notes`      | `text`        |                               | Interne Notizen                    |
| `created_at`       | `timestamptz` | NOT NULL DEFAULT now()        |                                    |
| `resolved_at`      | `timestamptz` |                               |                                    |

**Index**: `(status, created_at DESC)` — für Admin-Liste „offene Revisionen".

---

### `settings`

Globale Einstellungen, z.B. Preise. Nur Admins dürfen schreiben.

| Spalte         | Typ         | Constraints                   | Zweck                              |
|----------------|-------------|-------------------------------|------------------------------------|
| `key`          | `text`      | PK                            | z.B. `'verification_price_cents'`  |
| `value`        | `jsonb`     | NOT NULL                      | Flexibel typisiert                 |
| `updated_by`   | `uuid`      | FK → profiles(id)             | Wer hat zuletzt geändert           |
| `updated_at`   | `timestamptz` | NOT NULL DEFAULT now()      |                                    |

**Initial-Seeds**:
- `verification_price_cents` = 4000 (40 €)
- `renewal_price_cents` = 500 (5 €)
- `renewal_grace_period_days` = 365 (wie lange nach Ablauf man verlängern kann)
- `verification_duration_days` = 365 (Gültigkeitsdauer)

---

### `audit_log`

Unveränderliches Protokoll aller Aktionen. Append-only.

| Spalte             | Typ           | Constraints                   | Zweck                              |
|--------------------|---------------|-------------------------------|------------------------------------|
| `id`               | `bigserial`   | PK                            |                                    |
| `actor_id`         | `uuid`        | FK → profiles(id)             | Wer hat die Aktion ausgeführt      |
| `action`           | `text`        | NOT NULL                      | z.B. `'verification_created'`      |
| `entity_type`      | `text`        | NOT NULL                      | z.B. `'article'`, `'reservation'`  |
| `entity_id`        | `text`        |                               | Slug oder UUID                     |
| `payload`          | `jsonb`       |                               | Snapshot der Änderung              |
| `ip_address`       | `inet`        |                               | Optional, für Sicherheits-Audits   |
| `created_at`       | `timestamptz` | NOT NULL DEFAULT now()        |                                    |

**RLS**: INSERT nur durch Server-Code (Service-Role oder via SECURITY DEFINER function). UPDATE/DELETE für niemanden.

**Index**: `(actor_id, created_at DESC)`, `(entity_type, entity_id, created_at DESC)`.

---

## Beziehungen und Kardinalitäten

- `profiles` 1:n `reservations` (Arzt kann viele Reservierungen haben)
- `profiles` 1:n `verifications`
- `profiles` 1:n `revisions`
- `articles` 1:n `reservations`, `verifications`, `revisions`
- `reservations` 1:0..1 `verifications` (eine Reservierung endet in höchstens einer Verifizierung)
- `reservations` 1:0..1 `revisions` (oder in einer Revision)

## Zustände: Aus DB-Sicht

Der „Status" eines Artikels wird nicht in der `articles`-Tabelle gespeichert, sondern dynamisch berechnet aus den anderen Tabellen:

```sql
CREATE OR REPLACE VIEW article_states AS
SELECT
  a.slug,
  a.title,
  a.category,
  CASE
    -- Aktive Verifizierung vorhanden und nicht abgelaufen?
    WHEN EXISTS (
      SELECT 1 FROM verifications v
      WHERE v.article_slug = a.slug
        AND v.revoked_at IS NULL
        AND v.expires_at > now()
    ) THEN 'verified'
    -- Aktive Verifizierung, aber abgelaufen?
    WHEN EXISTS (
      SELECT 1 FROM verifications v
      WHERE v.article_slug = a.slug
        AND v.revoked_at IS NULL
        AND v.expires_at <= now()
    ) THEN 'expired'
    -- Offene Revision?
    WHEN EXISTS (
      SELECT 1 FROM revisions r
      WHERE r.article_slug = a.slug
        AND r.status IN ('open', 'in_admin_review')
    ) THEN 'revision_requested'
    -- Aktive Reservierung?
    WHEN EXISTS (
      SELECT 1 FROM reservations r
      WHERE r.article_slug = a.slug
        AND r.status = 'active'
    ) THEN 'reserved'
    ELSE 'unverified'
  END AS state
FROM articles a;
```

Diese View wird in der UI verwendet. Single Source of Truth, kein Drift zwischen Zustand und Daten möglich.

## Warum diese Struktur?

1. **Audit-Freundlich**: Statt Status zu überschreiben, wird immer neuer Datensatz angelegt. Historie automatisch da.
2. **Preise versioniert**: `price_cents_paid` ist unveränderlich gespeichert. Preisänderung im `settings` beeinflusst alte Verifizierungen nicht.
3. **RLS-kompatibel**: Jede Zeile hat einen klaren „Besitzer" (doctor_id) für Policy-Checks.
4. **Einfache Queries für Dashboards**: „meine verifizierten Artikel" ist ein einfaches `SELECT WHERE doctor_id = auth.uid() AND revoked_at IS NULL AND expires_at > now()`.
5. **Rollback-sicher**: Admin-Revoke setzt nur `revoked_at`, löscht nie Daten.
