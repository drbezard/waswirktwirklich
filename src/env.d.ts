/// <reference path="../.astro/types.d.ts" />

interface ImportMetaEnv {
  readonly PUBLIC_SUPABASE_URL: string;
  readonly PUBLIC_SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_ROLE_KEY: string;
  readonly DEV_LOGIN_SECRET?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

// Astro locals
declare namespace App {
  interface Locals {
    user: {
      id: string;
      email: string;
      role: 'doctor' | 'admin';
      fullName: string | null;
    } | null;
  }
}
