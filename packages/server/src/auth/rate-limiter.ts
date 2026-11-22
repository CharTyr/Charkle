/**
 * Sliding-window login failure rate limiter (max 10 failures per 15 minutes per IP + username).
 */
export interface RateLimitCheckResult {
  allowed: boolean;
  retryAfterSeconds: number;
  remainingAttempts: number;
}

export class LoginRateLimiter {
  private readonly maxFailures: number;
  private readonly windowMs: number;
  private readonly attempts = new Map<string, number[]>();

  constructor(maxFailures = 10, windowMs = 15 * 60 * 1000) {
    this.maxFailures = maxFailures;
    this.windowMs = windowMs;
  }

  private key(ip: string, username: string): string {
    return `${ip.trim().toLowerCase()}::${username.trim().toLowerCase()}`;
  }

  private prune(timestamps: number[], now: number): number[] {
    const cutoff = now - this.windowMs;
    let firstValid = 0;
    while (firstValid < timestamps.length && timestamps[firstValid] <= cutoff) {
      firstValid++;
    }
    return firstValid === 0 ? timestamps : timestamps.slice(firstValid);
  }

  check(ip: string, username: string, now: number = Date.now()): RateLimitCheckResult {
    const k = this.key(ip, username);
    const existing = this.attempts.get(k);
    if (!existing || existing.length === 0) {
      return { allowed: true, retryAfterSeconds: 0, remainingAttempts: this.maxFailures };
    }
    const active = this.prune(existing, now);
    if (active.length === 0) {
      this.attempts.delete(k);
      return { allowed: true, retryAfterSeconds: 0, remainingAttempts: this.maxFailures };
    }
    this.attempts.set(k, active);

    if (active.length >= this.maxFailures) {
      const oldest = active[0];
      const retryMs = Math.max(1000, oldest + this.windowMs - now);
      return {
        allowed: false,
        retryAfterSeconds: Math.ceil(retryMs / 1000),
        remainingAttempts: 0,
      };
    }

    return {
      allowed: true,
      retryAfterSeconds: 0,
      remainingAttempts: Math.max(0, this.maxFailures - active.length),
    };
  }

  recordFailure(ip: string, username: string, now: number = Date.now()): RateLimitCheckResult {
    const k = this.key(ip, username);
    const active = this.prune(this.attempts.get(k) ?? [], now);
    active.push(now);
    this.attempts.set(k, active);

    if (active.length >= this.maxFailures) {
      const oldest = active[0];
      const retryMs = Math.max(1000, oldest + this.windowMs - now);
      return {
        allowed: false,
        retryAfterSeconds: Math.ceil(retryMs / 1000),
        remainingAttempts: 0,
      };
    }

    return {
      allowed: true,
      retryAfterSeconds: 0,
      remainingAttempts: Math.max(0, this.maxFailures - active.length),
    };
  }

  reset(ip: string, username: string): void {
    this.attempts.delete(this.key(ip, username));
  }

  clearAll(): void {
    this.attempts.clear();
  }
}
