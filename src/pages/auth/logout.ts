import type { APIRoute } from 'astro';
import { createSupabaseServerClient } from '../../lib/supabase/server';

export const prerender = false;

export const POST: APIRoute = async ({ cookies, redirect, request }) => {
  const supabase = createSupabaseServerClient(request, cookies);
  await supabase.auth.signOut();
  return redirect('/arzt/login', 303);
};

// GET fallback: einfacher Logout-Link, redirect zurück
export const GET: APIRoute = async ({ cookies, redirect, request }) => {
  const supabase = createSupabaseServerClient(request, cookies);
  await supabase.auth.signOut();
  return redirect('/', 303);
};
