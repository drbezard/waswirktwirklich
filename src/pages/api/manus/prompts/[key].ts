import type { APIRoute } from 'astro';
import { getSupabaseAdminClient } from '../../../../lib/supabase/admin';
import { requireManusAuth, jsonResponse, errorResponse } from '../../../../lib/manus-auth';

export const prerender = false;

/**
 * GET /api/manus/prompts/{key}
 *   Liefert den aktuellen Master-Prompt zur Laufzeit ab. Manus + Claude rufen
 *   das vor jedem Run auf, damit sie immer mit der aktuellen Version arbeiten.
 *   key ∈ { manus_discovery, manus_drafting, claude_polishing, manus_review_publish }
 */

export const GET: APIRoute = async ({ request, params }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const key = params.key;
  if (!key) return errorResponse('Prompt-Key fehlt', 400);

  const supabase = getSupabaseAdminClient();
  const { data, error } = await supabase
    .from('prompts')
    .select('key, title, description, body, version, updated_at')
    .eq('key', key)
    .maybeSingle();

  if (error) return errorResponse(error.message, 500);
  if (!data) return errorResponse(`Prompt "${key}" nicht gefunden`, 404);

  return jsonResponse(data);
};
