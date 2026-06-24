/**
 * Database types for Miles.
 *
 * NOTE: After your Supabase project is created, regenerate this with:
 *   npx supabase gen types typescript \
 *     --project-id <your-project-ref> \
 *     --schema public > src/types/database.ts
 *
 * The hand-written version below matches the schema in /supabase/schema.sql
 * and will let the app compile end-to-end before that step.
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type PresenceStatus = "asleep" | "awake" | "work" | "free" | "busy";

export type RitualType =
  | "goodnight"
  | "goodmorning"
  | "weekly_highlow"
  | "custom";

export interface Database {
  public: {
    Tables: {
      couples: {
        Row: {
          id: string;
          created_at: string;
          invite_code: string;
          name: string | null;
          primary_tz: string | null;
          stripe_customer_id: string | null;
        };
        Insert: {
          id?: string;
          created_at?: string;
          invite_code: string;
          name?: string | null;
          primary_tz?: string | null;
          stripe_customer_id?: string | null;
        };
        Update: Partial<Database["public"]["Tables"]["couples"]["Insert"]>;
      };
      profiles: {
        Row: {
          id: string;
          couple_id: string | null;
          display_name: string;
          avatar_url: string | null;
          timezone: string;
          wake_time: string | null;
          sleep_time: string | null;
          presence_status: PresenceStatus;
          created_at: string;
        };
        Insert: {
          id: string;
          couple_id?: string | null;
          display_name: string;
          avatar_url?: string | null;
          timezone: string;
          wake_time?: string | null;
          sleep_time?: string | null;
          presence_status?: PresenceStatus;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["profiles"]["Insert"]>;
      };
      visits: {
        Row: {
          id: string;
          couple_id: string;
          start_date: string;
          end_date: string | null;
          location: string | null;
          note: string | null;
          is_upcoming: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          couple_id: string;
          start_date: string;
          end_date?: string | null;
          location?: string | null;
          note?: string | null;
          is_upcoming?: boolean;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["visits"]["Insert"]>;
      };
      daily_prompts: {
        Row: {
          id: string;
          prompt_text: string;
          scheduled_date: string;
          couple_id: string;
        };
        Insert: {
          id?: string;
          prompt_text: string;
          scheduled_date: string;
          couple_id: string;
        };
        Update: Partial<Database["public"]["Tables"]["daily_prompts"]["Insert"]>;
      };
      prompt_responses: {
        Row: {
          id: string;
          prompt_id: string;
          user_id: string;
          response_text: string | null;
          responded_at: string;
        };
        Insert: {
          id?: string;
          prompt_id: string;
          user_id: string;
          response_text?: string | null;
          responded_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["prompt_responses"]["Insert"]>;
      };
      rituals: {
        Row: {
          id: string;
          couple_id: string;
          type: RitualType;
          cron: string | null;
          message: string | null;
          deliver_at: string | null;
          delivered: boolean;
        };
        Insert: {
          id?: string;
          couple_id: string;
          type: RitualType;
          cron?: string | null;
          message?: string | null;
          deliver_at?: string | null;
          delivered?: boolean;
        };
        Update: Partial<Database["public"]["Tables"]["rituals"]["Insert"]>;
      };
      visit_memories: {
        Row: {
          id: string;
          visit_id: string;
          photo_url: string | null;
          caption: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          visit_id: string;
          photo_url?: string | null;
          caption?: string | null;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["visit_memories"]["Insert"]>;
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: {
      presence_status: PresenceStatus;
      ritual_type: RitualType;
    };
  };
}

export type Couple = Database["public"]["Tables"]["couples"]["Row"];
export type Profile = Database["public"]["Tables"]["profiles"]["Row"];
export type Visit = Database["public"]["Tables"]["visits"]["Row"];
export type Ritual = Database["public"]["Tables"]["rituals"]["Row"];
export type DailyPrompt = Database["public"]["Tables"]["daily_prompts"]["Row"];
export type PromptResponse =
  Database["public"]["Tables"]["prompt_responses"]["Row"];
export type VisitMemory =
  Database["public"]["Tables"]["visit_memories"]["Row"];
