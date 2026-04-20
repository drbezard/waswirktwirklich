# Setup-Anleitung

Schritt-für-Schritt, um die Verifizierungsplattform zum Laufen zu bringen.
Nach diesen Schritten ist das System lebendig — Arzt kann sich einloggen, Artikel übernehmen, verifizieren.

## Voraussetzungen

- Supabase-Projekt in EU-Region (Frankfurt oder Ireland) ✓ bereits angelegt
- Vercel-Konto (bereits vorhanden, da die Seite schon dort deployt wird) ✓
- Node.js ≥ 22.12 lokal ✓

## Phase A — Datenbank einrichten (5 Minuten)

### 1. Migrationen einspielen

Alle SQL-Dateien im Ordner `supabase/migrations/` nacheinander in Supabase ausführen:

1. Supabase-Dashboard öffnen → links im Menü **SQL Editor**
2. **New Query**
3. Inhalt von `supabase/migrations/20260412_000_initial_schema.sql` kopieren, einfügen, **Run**
4. Neue Query → Inhalt von `20260412_001_rls_policies.sql` → Run
5. Neue Query → Inhalt von `20260412_002_functions.sql` → Run
6. Neue Query → Inhalt von `20260412_003_seed_data.sql` → Run

Bei jedem sollte Supabase "Success" zeigen. Falls ein Fehler kommt: nicht weitermachen, Fehler an mich schicken.

### 2. Ersten Admin anlegen

1. Supabase Dashboard → **Authentication → Users**
2. Oben rechts **Add user → Send invitation**
3. Deine E-Mail-Adresse eingeben → Invite senden
4. In deinem Postfach den Link anklicken (führt zu einer Supabase-Seite — das ist noch ohne unsere Seite, reicht aber)

Danach im **SQL Editor** diese Query ausführen (E-Mail anpassen):

```sql
UPDATE public.profiles
SET role = 'admin',
    full_name = 'Dein Name'
WHERE id = (SELECT id FROM auth.users WHERE email = 'deine@email.de');
```

Damit bist du Admin.

## Phase B — E-Mail-Versand konfigurieren (10 Minuten)

Supabase verschickt in der kostenlosen Stufe E-Mails mit einem Limit (~4/Stunde). Für Produktion solltest du später deinen eigenen SMTP-Server einhängen (z.B. Resend), aber für den Anfang reicht's.

### Login-E-Mail-Vorlage anpassen

1. Dashboard → **Authentication → Emails**
2. Tab **Magic Link** auswählen
3. Subject: `Dein Login-Link für "Was Wirkt Wirklich"`
4. Body (HTML), z.B.:

```html
<h2>Dein Login-Link</h2>
<p>Klicke auf den Button unten, um dich bei "Was Wirkt Wirklich" anzumelden:</p>
<p><a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:12px 24px;background:#2563eb;color:white;text-decoration:none;border-radius:8px;">Jetzt anmelden</a></p>
<p>Der Link ist 1 Stunde gültig. Falls du dich nicht anmelden wolltest, kannst du diese E-Mail ignorieren.</p>
```

5. Im Tab **URL Configuration**:
   - **Site URL**: `https://waswirktwirklich.com` (oder deine Produktions-Domain)
   - **Redirect URLs**: füge hinzu: `https://waswirktwirklich.com/auth/callback`

Ohne diese Konfiguration wird der Magic Link auf die Supabase-Standardseite geleitet.

## Phase C — Vercel konfigurieren (5 Minuten)

### Environment Variables setzen

1. Vercel-Dashboard → dein Projekt → **Settings → Environment Variables**
2. Drei Variablen anlegen (alle drei Umgebungen: Production, Preview, Development):

| Name                           | Wert                                                |
|--------------------------------|-----------------------------------------------------|
| `PUBLIC_SUPABASE_URL`          | `https://qyaivjcczncckifsrrps.supabase.co`           |
| `PUBLIC_SUPABASE_ANON_KEY`     | `sb_publishable_...` (aus Supabase Settings → API) |
| `SUPABASE_SERVICE_ROLE_KEY`    | `sb_secret_...` (markiere als **Sensitive**!)      |

⚠️ Wichtig: `SUPABASE_SERVICE_ROLE_KEY` muss auf "Sensitive" gesetzt sein, damit er nicht in Logs landet.

3. Nach dem Speichern: **Redeploy** auslösen (Vercel-Dashboard → Deployments → ⋯ → Redeploy).

### Produktionsdomain in Supabase nachtragen

Falls du eine eigene Domain hast (z.B. `waswirktwirklich.com`):
- Supabase → Authentication → URL Configuration
- **Site URL** und **Redirect URLs** entsprechend aktualisieren

## Phase D — Testen (10 Minuten)

### Als Admin:
1. Öffne `https://<deine-domain>/admin/login`
2. Gib deine Admin-E-Mail ein → E-Mail anfordern
3. Link aus E-Mail klicken → solltest auf `/admin` landen
4. Du solltest das Admin-Dashboard sehen mit 15 Artikeln unverifiziert.

### Ersten Arzt einladen:
1. Im Admin-Bereich → **Ärzte**
2. E-Mail des Arztes + Namen eingeben → Einladung senden
3. Der Arzt bekommt eine E-Mail mit Einladungs-Link

### Als Arzt (optional zum Testen):
1. Nimm eine Zweit-E-Mail von dir selbst
2. Im Admin-Bereich einladen
3. E-Mail → Link → landest auf `/arzt` (Dashboard)
4. **Artikel übernehmen** → einen auswählen → Button → du landest auf der Verifizierungs-Seite
5. Disclaimer ankreuzen → **Verifizieren** → fertig

### Öffentliche Seite prüfen:
- Rufe den verifizierten Artikel auf
- Der Prüfer-Kasten sollte deinen Namen anzeigen (nicht mehr "Ausstehend")

## Was noch NICHT drin ist (Phase 2 und 3)

- **Zahlungen (Stripe)**: Der Preis wird gespeichert, aber nicht abgerechnet. Aktuell ist Verifizierung "kostenlos" aus Sicht des Nutzers.
- **Automatische Erinnerungs-E-Mails**: Keine Benachrichtigung 30/7/0 Tage vor Ablauf.
- **Abrechnungs-Export**: Keine CSV/PDF-Rechnungen.
- **Reservierungs-Timeout-Cronjob**: Läuft noch nicht automatisch.

Das sind Phase 2 und 3. Erstmal läuft das Grundgerüst — Probier es aus, sag Bescheid was gut ist und was nicht.

## Häufige Fragen

### Was passiert wenn ich einen Fehler in den Migrationen mache?
Solange noch niemand was eingetragen hat (Start-Zustand), kannst du das Projekt in Supabase einfach "resetten" oder neu anlegen. Bei vielen Daten sind Migrationen reversibel über manuell geschriebene "Down"-Skripte.

### Wie ändere ich später die Preise?
Admin-Bereich → **Preise**. Werte werden in Cent eingegeben. Änderungen gelten nur für **neue** Verifizierungen. Bereits bezahlte bleiben unverändert.

### Wie sehe ich was passiert ist?
Das Audit-Log wird in der DB-Tabelle `audit_log` geschrieben. Für eine schön UI musst du mir Bescheid geben — ich baue dir eine Admin-Ansicht.

### Was wenn ein Arzt sein Konto gelöscht haben will (DSGVO)?
Im Admin-Bereich → Ärzte → **Deaktivieren**. Das Profil bleibt für Audit-Zwecke erhalten, aber der Arzt kann sich nicht mehr einloggen. Für vollständige Löschung (komplett anonymisiert) brauchen wir eine zusätzliche Admin-Funktion — sag Bescheid wenn's akut wird.

## Nach dem Setup: Keys rotieren!

Wir haben die Supabase-Keys offen im Chat ausgetauscht. Nachdem alles läuft, rotiere sie:

1. Supabase Dashboard → **Settings → API**
2. Bei beiden Keys: Punkt-Menü (⋯) → **Rotate**
3. Neue Keys in Vercel eintragen, Redeploy

Damit sind die Keys aus der Chat-Historie wertlos.
