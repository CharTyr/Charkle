import type { HealthResponse } from '@charkle/shared';

export const SERVER_DEFAULT_PORT = 3417;

export function createPlaceholderHealth(): HealthResponse {
  return {
    ok: true,
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  };
}
