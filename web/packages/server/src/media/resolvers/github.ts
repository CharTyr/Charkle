import type { GitHubRepoMetadata } from '@charkle/shared';
import { base64ToBytes, readEnv, utf8Decode } from '../../runtime/web-crypto-utils.js';
import { inspectImageHeader } from '../../runtime/workers-image.js';

const GITHUB_HOSTS = new Set(['github.com', 'www.github.com']);

const RESERVED_OWNERS = new Set([
  'settings',
  'explore',
  'issues',
  'pulls',
  'gist',
  'orgs',
  'marketplace',
  'sponsors',
  'topics',
  'trending',
  'collections',
  'events',
  'notifications',
  'login',
  'signup',
  'join',
  'about',
  'pricing',
  'features',
  'enterprise',
  'team',
  'security',
  'customer-stories',
  'readme',
  'codespaces',
  'copilot',
  'apps',
  'new',
  'search',
  'stars',
  'watching',
  'organizations',
  'users',
]);

const MAX_README_CHARS = 120_000;
const MAX_TOPICS = 16;

export interface ParsedGitHubRepoURL {
  owner: string;
  repo: string;
  branch: string | null;
  canonicalURL: string;
}

export function parseGitHubRepoURL(rawUrl: string): ParsedGitHubRepoURL | null {
  let u: URL;
  try {
    u = new URL(rawUrl.trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (!GITHUB_HOSTS.has(u.hostname.toLowerCase())) return null;

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length < 2) return null;

  const owner = parts[0];
  if (RESERVED_OWNERS.has(owner.toLowerCase())) return null;

  const repo = parts[1].replace(/\.git$/i, '');
  if (!repo || repo.startsWith('.')) return null;

  let branch: string | null = null;
  if (parts.length === 2) {
    // /<owner>/<repo>
  } else if (parts.length >= 4 && parts[2].toLowerCase() === 'tree') {
    branch = parts.slice(3).join('/');
  } else {
    // Reject deep paths (/blob/, /issues/, /pull/, etc.)
    return null;
  }

  return {
    owner,
    repo,
    branch,
    canonicalURL: `https://github.com/${owner}/${repo}`,
  };
}

async function fetchWithTimeout(url: string, headers: Record<string, string>, timeoutMs = 10_000): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { signal: controller.signal, headers });
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function resolveGitHubRepo(rawUrl: string): Promise<GitHubRepoMetadata | null> {
  const parsed = parseGitHubRepoURL(rawUrl);
  if (!parsed) return null;

  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'CharkleWeb/1.0',
  };
  const githubToken = readEnv('GITHUB_TOKEN');
  if (githubToken) {
    headers.Authorization = `Bearer ${githubToken}`;
  }

  const repoUrl = `https://api.github.com/repos/${encodeURIComponent(parsed.owner)}/${encodeURIComponent(parsed.repo)}`;
  const readmeUrl = parsed.branch
    ? `${repoUrl}/readme?ref=${encodeURIComponent(parsed.branch)}`
    : `${repoUrl}/readme`;

  const [repoRes, readmeRes] = await Promise.all([
    fetchWithTimeout(repoUrl, headers),
    fetchWithTimeout(readmeUrl, headers),
  ]);

  let repoJson: Record<string, unknown> | null = null;
  if (repoRes?.ok) {
    try {
      repoJson = (await repoRes.json()) as Record<string, unknown>;
    } catch {
      repoJson = null;
    }
  }

  const defaultBranch =
    parsed.branch ||
    (typeof repoJson?.default_branch === 'string' ? repoJson.default_branch : 'main');

  let readmeMarkdown: string | null = null;
  if (readmeRes?.ok) {
    try {
      const rj = (await readmeRes.json()) as Record<string, unknown>;
      if (typeof rj.content === 'string') {
        readmeMarkdown = utf8Decode(base64ToBytes(rj.content.replace(/\s+/g, '')))
          .slice(0, MAX_README_CHARS);
      }
    } catch {
      readmeMarkdown = null;
    }
  }

  if (!readmeMarkdown) {
    const rawCandidates = [
      `https://raw.githubusercontent.com/${parsed.owner}/${parsed.repo}/${defaultBranch}/README.md`,
      `https://raw.githubusercontent.com/${parsed.owner}/${parsed.repo}/${defaultBranch}/readme.md`,
      `https://raw.githubusercontent.com/${parsed.owner}/${parsed.repo}/master/README.md`,
    ];
    for (const candidate of rawCandidates) {
      const res = await fetchWithTimeout(candidate, { 'User-Agent': 'CharkleWeb/1.0' }, 8_000);
      if (res?.ok) {
        const text = await res.text();
        if (text.trim().length > 0) {
          readmeMarkdown = text.slice(0, MAX_README_CHARS);
          break;
        }
      }
    }
  }

  const ownerObj = (repoJson?.owner ?? {}) as Record<string, unknown>;
  const licenseObj = (repoJson?.license ?? {}) as Record<string, unknown>;
  const topics = Array.isArray(repoJson?.topics)
    ? repoJson.topics.map(String).slice(0, MAX_TOPICS)
    : [];

  return {
    owner: parsed.owner,
    repo: parsed.repo,
    fullName:
      typeof repoJson?.full_name === 'string'
        ? repoJson.full_name
        : `${parsed.owner}/${parsed.repo}`,
    ownerAvatarURL: typeof ownerObj.avatar_url === 'string' ? ownerObj.avatar_url : null,
    description: typeof repoJson?.description === 'string' ? repoJson.description : null,
    stars: typeof repoJson?.stargazers_count === 'number' ? repoJson.stargazers_count : 0,
    forks: typeof repoJson?.forks_count === 'number' ? repoJson.forks_count : 0,
    watchers: typeof repoJson?.subscribers_count === 'number' ? repoJson.subscribers_count : null,
    language: typeof repoJson?.language === 'string' ? repoJson.language : null,
    licenseName:
      typeof licenseObj.spdx_id === 'string' && licenseObj.spdx_id !== 'NOASSERTION'
        ? licenseObj.spdx_id
        : typeof licenseObj.name === 'string'
          ? licenseObj.name
          : null,
    topics,
    defaultBranch,
    homepageURL:
      typeof repoJson?.homepage === 'string' && repoJson.homepage.trim().length > 0
        ? repoJson.homepage.trim()
        : null,
    openGraphImageURL: `https://opengraph.githubassets.com/1/${parsed.owner}/${parsed.repo}`,
    readmeMarkdown,
    fetchedAt: new Date().toISOString(),
  };
}

const MAX_GITHUB_OG_BYTES = 4 * 1024 * 1024;

async function downloadBoundedImageBytes(
  url: string,
  maxBytes: number,
  timeoutMs = 6_000,
): Promise<Uint8Array | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {
        Accept: 'image/png,image/webp,image/jpeg,image/*',
        'User-Agent': 'CharkleWeb/1.0',
      },
    });
    if (!res.ok) return null;
    const contentLength = Number(res.headers.get('content-length') ?? '0');
    if (contentLength > maxBytes) return null;

    const reader = res.body?.getReader();
    if (!reader) {
      const bytes = new Uint8Array(await res.arrayBuffer());
      return bytes.byteLength <= maxBytes ? bytes : null;
    }
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => undefined);
        return null;
      }
      chunks.push(value);
    }
    if (total === 0) return null;
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) {
      out.set(c, offset);
      offset += c.byteLength;
    }
    return out;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetches GitHub's official OpenGraph preview card (`opengraph.githubassets.com/1/<owner>/<repo>`)
 * validating magic bytes and minimum dimensions (>= 200x100). 100% Workers-safe.
 */
export async function fetchGitHubOpenGraphCardBytes(
  repo: Pick<GitHubRepoMetadata, 'owner' | 'repo' | 'openGraphImageURL'>,
): Promise<{ bytes: Uint8Array; mimeType: string } | null> {
  const candidates: string[] = [];
  const custom = repo.openGraphImageURL?.trim();
  if (custom) candidates.push(custom);
  const standard = `https://opengraph.githubassets.com/1/${encodeURIComponent(repo.owner)}/${encodeURIComponent(repo.repo)}`;
  if (!candidates.includes(standard)) candidates.push(standard);

  for (const url of candidates) {
    const bytes = await downloadBoundedImageBytes(url, MAX_GITHUB_OG_BYTES, 6_000);
    if (!bytes) continue;
    const header = inspectImageHeader(bytes);
    if (
      header &&
      header.format !== 'svg' &&
      header.width >= 200 &&
      header.height >= 100
    ) {
      return { bytes, mimeType: header.mimeType };
    }
  }
  return null;
}
