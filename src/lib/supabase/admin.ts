/**
 * Supabase-Admin-Client mit Service-Role-Key.
 *
 * !!! NIEMALS im Browser !!!
 * Nur in Server-Code, z.B. für Build-Time-Sync von Artikeln, Admin-Operationen
 * die RLS umgehen müssen, Cron-Jobs etc.
 *
 * Der Service-Role-Key umgeht ALLE RLS-Policies. Entsprechend vorsichtig.
 */

import { createClient } from '@supabase/supabase-js';
import type { Database } from './types';

function getEnv() {
  const url = import.meta.env.PUBLIC_SUPABASE_URL;
  const serviceKey = import.meta.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url) {
    throw new Error('PUBLIC_SUPABASE_URL muss gesetzt sein');
  }
  if (!serviceKey) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY muss gesetzt sein (NUR auf dem Server!)');
  }

  return { url, serviceKey };
}

/**
 * Singleton-Admin-Client.
 * NUR in Server-Modules (*.astro mit prerender=false oder API-Routes) aufrufen.
 */
let _adminClient: ReturnType<typeof createClient<Database>> | null = null;

export function getSupabaseAdminClient() {
  if (_adminClient) return _adminClient;

  const { url, serviceKey } = getEnv();
  _adminClient = createClient<Database>(url, serviceKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  return _adminClient;
}
