import { createClient } from "@supabase/supabase-js";

// Supabase publishable credentials are public browser configuration, not
// service-role secrets. Sites runtime variables are not injected into the
// prebuilt client bundle, so retain production-safe fallbacks for the browser.
const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "https://fuplobbciabkikfzrxdt.supabase.co";
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_40tPaolvt1B7zjNKXPovCg_tHta0G5k";

export const supabase = createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});
