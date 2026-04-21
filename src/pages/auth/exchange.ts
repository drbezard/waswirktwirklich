/**
 * Token-Exchange: Nimmt entweder (a) access_token via POST aus dem Hash-Flow
 * oder (b) token_hash + type aus der Query für PKCE-OTP-Verifikation entgegen
 * und setzt Session-Cookies.
 */

import type { APIRoute } from 'astro';
import { createSupabaseServerClient } from '../../lib/supabase/server';

export const prerender = false;

// GET: Verify OTP mit token_hash (Supabase standard flow)
export const GET: APIRoute = async ({ cookies, url, request, redirect }) => {
  const token_hash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type') as 'email' | 'magiclink' | null;
  const next = url.searchParams.get('next') || '/arzt';

  if (!token_hash || !type) {
    return new Response('Missing parameters', { status: 400 });
  }

  const supabase = createSupabaseServerClient(request, cookies);
  const { error } = await supabase.auth.verifyOtp({ token_hash, type });

  if (error) {
    return redirect('/arzt/login?error=link_invalid', 303);
  }

  return redirect(next, 303);
};

// POST: Hash-based flow (ältere Magic-Links senden Token im Hash)
export const POST: APIRoute = async ({ cookies, request }) => {
  try {
    const body = await request.json();
    const { access_token, refresh_token } = body;

    if (!access_token) {
      return new Response('Missing access_token', { status: 400 });
    }

    const supabase = createSupabaseServerClient(request, cookies);
    const { error } = await supabase.auth.setSession({
      access_token,
      refresh_token: refresh_token || '',
    });

    if (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response('Invalid request', { status: 400 });
  }
};
