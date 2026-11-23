/**
 * Optional runtime secrets (configured via `wrangler secret put` or `.dev.vars`)
 * and optional bindings that are not required in `wrangler.jsonc`.
 *
 * All declared bindings (`ASSETS`, `CHARKLE_LIBRARY`, `MEDIA_BUCKET`, `CHARKLE_LIBRARY_ID`)
 * come from the Wrangler-generated global `Env` in `worker-configuration.d.ts`.
 */
export interface CharkleOptionalSecrets {
  /** Master encryption secret for AES-256-GCM SecretVault (`wrangler secret put CHARKLE_VAULT_KEY`). */
  CHARKLE_VAULT_KEY?: string;
  CHARKLE_VAULT_SECRET?: string;
  /** Optional headless initial admin credentials. */
  CHARKLE_ADMIN_USERNAME?: string;
  CHARKLE_ADMIN_PASSWORD?: string;
  CHARKLE_ADMIN_DISPLAY_NAME?: string;
  /** Optional Google Drive OAuth client credentials (can also be configured in Web Settings UI). */
  CHARKLE_GOOGLE_CLIENT_ID?: string;
  CHARKLE_GOOGLE_CLIENT_SECRET?: string;
  /** Optional Cloud AI provider keys (can also be configured in Web Settings UI). */
  GEMINI_API_KEY?: string;
  OPENAI_API_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  TYPESAFE_API_KEY?: string;
  GITHUB_TOKEN?: string;
  /** Optional Cloudflare Images binding for edge raster thumbnail transforms. */
  IMAGES?: ImagesBinding;
}

export type CharkleWorkerEnv = Env & CharkleOptionalSecrets;
