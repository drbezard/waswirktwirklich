/**
 * Manus-API Auth-Helper.
 *
 * Manus ist kein User — er authentifiziert sich über einen statischen
 * MANUS_API_TOKEN (env var, in Vercel gesetzt).
 *
 * Pause-Schalter: Bei `pipeline_paused = true` blockt requireNotPaused alle
 * write-Operationen mit 423 Locked. Read-Operationen bleiben erlaubt, damit
 * Manus weiß, dass die Pipeline pausiert ist.
 */

import { getSupabaseAdminClient } from './supabase/admin';

export function requireManusAuth(request: Request): Response | null {
  const token = request.headers.get('x-manus-token');
  const expected = import.meta.env.MANUS_API_TOKEN;

  if (!expected) {
    return new Response(
      JSON.stringify({ error: 'MANUS_API_TOKEN nicht konfiguriert' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }

  if (!token || token !== expected) {
    return new Response(
      JSON.stringify({ error: 'Ungültiger oder fehlender X-Manus-Token' }),
      { status: 401, headers: { 'Content-Type': 'application/json' } }
    );
  }

  return null;
}

export async function isPipelinePaused(): Promise<boolean> {
  const supabase = getSupabaseAdminClient();
  const { data } = await supabase
    .from('settings')
    .select('value')
    .eq('key', 'pipeline_paused')
    .maybeSingle();
  return data?.value === true || data?.value === 'true';
}

export async function requireNotPaused(): Promise<Response | null> {
  const paused = await isPipelinePaused();
  if (paused) {
    return new Response(
      JSON.stringify({
        error: 'Pipeline pausiert',
        action: 'no_op',
        message: 'Heute keine Schreib-Operationen — Admin hat pause aktiv',
      }),
      { status: 423, headers: { 'Content-Type': 'application/json' } }
    );
  }
  return null;
}

export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

export function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}
