/**
 * TypeScript-Typen für die Supabase-Datenbank.
 *
 * Diese Typen werden später durch `supabase gen types typescript` automatisch
 * aus der Datenbank generiert. Aktuell manuell gepflegt, bis der CLI-Zugang
 * eingerichtet ist.
 */

export type UserRole = 'doctor' | 'admin';

export type ReservationStatus =
  | 'active'
  | 'verified'
  | 'revised'
  | 'cancelled'
  | 'expired';

export type VerificationKind = 'initial' | 'renewal' | 'free_admin';

export type RevisionStatus =
  | 'open'
  | 'in_admin_review'
  | 'resolved'
  | 'dismissed';

export type ArticleState =
  | 'unverified'
  | 'reserved'
  | 'verified'
  | 'expired'
  | 'revision_requested';

export interface Profile {
  id: string;
  role: UserRole;
  full_name: string | null;
  title: string | null;
  photo_url: string | null;
  bio: string | null;
  website_url: string | null;
  disabled_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface Article {
  slug: string;
  title: string;
  category: string;
  excerpt: string | null;
  image_url: string | null;
  created_at: string;
  updated_at: string;
}

export interface Reservation {
  id: string;
  article_slug: string;
  doctor_id: string;
  status: ReservationStatus;
  reserved_at: string;
  completed_at: string | null;
  free_assignment: boolean;
}

export interface Verification {
  id: string;
  article_slug: string;
  doctor_id: string;
  reservation_id: string | null;
  kind: VerificationKind;
  verified_at: string;
  expires_at: string;
  price_cents_paid: number;
  disclaimer_confirmed: boolean;
  payment_reference: string | null;
  revoked_at: string | null;
  revoked_reason: string | null;
}

export interface Revision {
  id: string;
  article_slug: string;
  reservation_id: string | null;
  doctor_id: string;
  comment: string;
  status: RevisionStatus;
  admin_id: string | null;
  admin_notes: string | null;
  created_at: string;
  resolved_at: string | null;
}

export interface Setting {
  key: string;
  value: unknown;
  description: string | null;
  updated_by: string | null;
  updated_at: string;
}

export interface AuditLog {
  id: number;
  actor_id: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  payload: unknown;
  ip_address: string | null;
  created_at: string;
}

export interface ArticleStateView {
  slug: string;
  title: string;
  category: string;
  state: ArticleState;
  active_verification_id: string | null;
}

/**
 * Root-Typ für supabase-js.
 * Wird verwendet als `SupabaseClient<Database>`.
 */
export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: Profile;
        Insert: Omit<Profile, 'created_at' | 'updated_at'>;
        Update: Partial<Omit<Profile, 'id' | 'created_at' | 'updated_at'>>;
      };
      articles: {
        Row: Article;
        Insert: Omit<Article, 'created_at' | 'updated_at'>;
        Update: Partial<Omit<Article, 'slug' | 'created_at' | 'updated_at'>>;
      };
      reservations: {
        Row: Reservation;
        Insert: Omit<Reservation, 'id' | 'reserved_at'>;
        Update: Partial<Omit<Reservation, 'id' | 'reserved_at'>>;
      };
      verifications: {
        Row: Verification;
        Insert: Omit<Verification, 'id' | 'verified_at'>;
        Update: Partial<Omit<Verification, 'id' | 'verified_at'>>;
      };
      revisions: {
        Row: Revision;
        Insert: Omit<Revision, 'id' | 'created_at'>;
        Update: Partial<Omit<Revision, 'id' | 'created_at'>>;
      };
      settings: {
        Row: Setting;
        Insert: Omit<Setting, 'updated_at'>;
        Update: Partial<Omit<Setting, 'key' | 'updated_at'>>;
      };
      audit_log: {
        Row: AuditLog;
        Insert: Omit<AuditLog, 'id' | 'created_at'>;
        Update: never;
      };
    };
    Views: {
      article_states: {
        Row: ArticleStateView;
      };
    };
    Functions: {
      reserve_article: {
        Args: { p_article_slug: string };
        Returns: string;
      };
      verify_article: {
        Args: {
          p_reservation_id: string;
          p_disclaimer_confirmed: boolean;
          p_payment_reference?: string | null;
        };
        Returns: string;
      };
      request_revision: {
        Args: { p_reservation_id: string; p_comment: string };
        Returns: string;
      };
      cancel_reservation: {
        Args: { p_reservation_id: string };
        Returns: void;
      };
      admin_assign_article: {
        Args: {
          p_article_slug: string;
          p_doctor_id: string;
          p_free?: boolean;
        };
        Returns: string;
      };
      admin_claim_revision: {
        Args: { p_revision_id: string };
        Returns: void;
      };
      admin_resolve_revision: {
        Args: {
          p_revision_id: string;
          p_status: 'resolved' | 'dismissed';
          p_admin_notes?: string | null;
        };
        Returns: void;
      };
      admin_revoke_verification: {
        Args: { p_verification_id: string; p_reason: string };
        Returns: void;
      };
      is_admin: {
        Args: { user_id?: string };
        Returns: boolean;
      };
    };
  };
}
