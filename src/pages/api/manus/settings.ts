import type { APIRoute } from 'astro';
import { getSupabaseAdminClient } from '../../../lib/supabase/admin';
import { requireManusAuth, jsonResponse, errorResponse } from '../../../lib/manus-auth';

export const prerender = false;

/**
 * GET /api/manus/settings
 *   Liefert Pipeline-Steuerungs-Settings als Objekt:
 *   { pipeline_paused, drafts_per_week_target, topics_discovery_per_day,
 *     max_pool_size_in_review, freshness_check_days, tags_vocabulary }
 */

const PIPELINE_KEYS = [
  'pipeline_paused',
  'drafts_per_week_target',
  'topics_discovery_per_day',
  'max_pool_size_in_review',
  'freshness_check_days',
  'tags_vocabulary',
];

export const GET: APIRoute = async ({ request }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const supabase = getSupabaseAdminClient();
  const { data, error } = await supabase
    .from('settings')
    .select('key, value')
    .in('key', PIPELINE_KEYS);

  if (error) return errorResponse(error.message, 500);

  const out: Record<string, unknown> = {};
  for (const row of data ?? []) {
    out[row.key] = row.value;
  }

  // Pool-Status: aktuelle Anzahl Topics pro Status
  const { data: counts } = await supabase
    .from('topics')
    .select('status', { count: 'exact', head: false })
    .not('status', 'in', '(published,discarded)');

  const poolByStatus: Record<string, number> = {};
  for (const t of counts ?? []) {
    poolByStatus[t.status as string] = (poolByStatus[t.status as string] || 0) + 1;
  }
  out.pool_status = poolByStatus;

  return jsonResponse(out);
};
