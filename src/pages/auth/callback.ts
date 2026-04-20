/**
 * Auth-Callback: Supabase leitet hierher nach Klick auf den Magic Link.
 *
 * Unterstützt drei Flows:
 *   1. PKCE-Flow: ?code=... → exchangeCodeForSession (Supabase default 2024+)
 *   2. OTP-Flow: ?token_hash=...&type=... → verifyOtp
 *   3. Hash-Flow: #access_token=... (legacy) → setSession via JS
 */

import type { APIRoute } from 'astro';
import { createSupabaseServerClient } from '../../lib/supabase/server';

export const prerender = false;

export const GET: APIRoute = async ({ url, cookies, request }) => {
  const code = url.searchParams.get('code');
  const token_hash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type');
  const error = url.searchParams.get('error');
  const errorDescription = url.searchParams.get('error_description');
  const next = url.searchParams.get('next') || '/arzt';

  // Fehler-Parameter von Supabase durchgereicht
  if (error) {
    console.error('[auth/callback] Supabase error:', error, errorDescription);
    return Response.redirect(
      `${url.origin}/arzt/login?error=${encodeURIComponent(error)}`,
      303
    );
  }

  // === Flow 1: PKCE (Supabase default seit 2024) ===
  if (code) {
    const supabase = createSupabaseServerClient(request, cookies);
    const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code);

    if (exchangeError) {
      console.error('[auth/callback] exchangeCodeForSession failed:', exchangeError.message);
      return Response.redirect(
        `${url.origin}/arzt/login?error=${encodeURIComponent('link_expired_or_invalid')}`,
        303
      );
    }

    return Response.redirect(`${url.origin}${next}`, 303);
  }

  // === Flow 2: OTP (token_hash + type) ===
  if (token_hash && type) {
    return Response.redirect(
      `${url.origin}/auth/exchange?token_hash=${encodeURIComponent(token_hash)}&type=${encodeURIComponent(type)}&next=${encodeURIComponent(next)}`,
      303
    );
  }

  // === Flow 3: Hash-based (legacy) ===
  // Token im URL-Hash — Server kann Hash nicht lesen, JS-Client macht POST zu /auth/exchange
  return new Response(
    `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>Anmeldung wird abgeschlossen…</title>
  <style>body{font-family:system-ui;padding:2rem;max-width:500px;margin:auto;text-align:center;color:#333}</style>
</head>
<body>
  <p>Anmeldung wird abgeschlossen…</p>
  <script>
    (async () => {
      const hash = window.location.hash.substring(1);
      const params = new URLSearchParams(hash);
      const access_token = params.get('access_token');
      const refresh_token = params.get('refresh_token');

      if (!access_token) {
        document.body.innerHTML = '<p>Fehler: Kein Token im Link. <a href="/arzt/login">Zurück zum Login</a></p>';
        return;
      }

      const res = await fetch('/auth/exchange', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ access_token, refresh_token }),
      });

      if (res.ok) {
        window.location.href = ${JSON.stringify(next)};
      } else {
        document.body.innerHTML = '<p>Anmeldung fehlgeschlagen. <a href="/arzt/login">Erneut versuchen</a></p>';
      }
    })();
  </script>
</body>
</html>`,
    { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } }
  );
};
