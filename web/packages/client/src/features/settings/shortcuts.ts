export type ShortcutScope = '采集与全局' | '画廊与整理' | '预览与视图' | '情绪板画布';

export interface ShortcutEntry {
  keys: string[];
  title: string;
  scope: ShortcutScope;
}

export const SHORTCUT_SCOPES: readonly ShortcutScope[] = [
  '采集与全局',
  '画廊与整理',
  '预览与视图',
  '情绪板画布',
] as const;

export const KEYBOARD_SHORTCUTS: readonly ShortcutEntry[] = [
  {
    keys: ['⇧', '⌘', 'N'],
    title: '打开快速采集',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', 'V'],
    title: '全局剪贴板采集',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', 'J'],
    title: '任意跳转',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', ','],
    title: '打开设置',
    scope: '采集与全局',
  },
  {
    keys: ['1', '–', '9'],
    title: '收件箱快速归档',
    scope: '画廊与整理',
  },
  {
    keys: ['⌘', 'A'],
    title: '全选当前素材',
    scope: '画廊与整理',
  },
  {
    keys: ['Backspace'],
    title: '移入回收站',
    scope: '画廊与整理',
  },
  {
    keys: ['⌘', '\\'],
    title: '折叠 / 展开侧边栏',
    scope: '预览与视图',
  },
  {
    keys: ['⌘', 'I'],
    title: '切换右侧检查器',
    scope: '预览与视图',
  },
  {
    keys: ['Space'],
    title: '全媒体快速预览',
    scope: '预览与视图',
  },
  {
    keys: ['←', '/', '→'],
    title: '上一项 / 下一项',
    scope: '预览与视图',
  },
  {
    keys: ['+', '=', '-', '0'],
    title: '缩放与 100% 重置',
    scope: '预览与视图',
  },
  {
    keys: ['R', '/', '⇧R'],
    title: '顺时针 / 逆时针旋转 90°',
    scope: '情绪板画布',
  },
  {
    keys: ['⇧H', '/', '⇧V'],
    title: '水平 / 上下翻转',
    scope: '情绪板画布',
  },
  {
    keys: ['V', 'H', 'C', 'P', 'E'],
    title: '自由画布工具切换',
    scope: '情绪板画布',
  },
  {
    keys: ['⌘', 'Z', '/', '⇧⌘Z'],
    title: '画布撤销 / 重做',
    scope: '情绪板画布',
  },
];

export interface SamplePromptItem {
  id: string;
  title: string;
  prompt: string;
}

export const EXTERNAL_AGENT_SAMPLE_PROMPTS: readonly SamplePromptItem[] = [
  {
    id: 'curate-board',
    title: '找参考图并建情绪板',
    prompt:
      '帮我从 Charkle 素材库里挑 10 张温暖胶片质感、偏奶油色调的咖啡馆参考图，确认无重复后生成一块名为「早秋咖啡馆视觉」的情绪板。',
  },
  {
    id: 'triage-inbox',
    title: '整理收件箱',
    prompt:
      '帮我看看 Charkle 收件箱里未整理的素材，按画面风格归档到现有文件夹，并补齐统一标签。',
  },
  {
    id: 'extract-palette-prompts',
    title: '提取情绪板色板与配方',
    prompt:
      '读取我在 Charkle 里名为「品牌改版」的情绪板，导出主色板、分区批注与其中 AI 参考图的生成提示词。',
  },
];

export function buildHttpMcpEndpoint(origin: string): string {
  return `${origin.replace(/\/$/, '')}/api/v1/mcp`;
}

export function buildClaudeCodeHttpCommand(
  origin: string,
  tokenPlaceholder = 'YOUR_ACCESS_TOKEN',
): string {
  const endpoint = buildHttpMcpEndpoint(origin);
  return `claude mcp add --transport http charkle ${endpoint} --header "Authorization: Bearer ${tokenPlaceholder}"`;
}

export function buildCodexHttpSnippet(
  origin: string,
  tokenPlaceholder = 'YOUR_ACCESS_TOKEN',
): string {
  const endpoint = buildHttpMcpEndpoint(origin);
  return [
    `export CHARKLE_API_TOKEN="${tokenPlaceholder}"`,
    `codex mcp add charkle --url ${endpoint} --bearer-token-env-var CHARKLE_API_TOKEN`,
    '',
    '[mcp_servers.charkle]',
    `url = "${endpoint}"`,
    `http_headers = { Authorization = "Bearer ${tokenPlaceholder}" }`,
  ].join('\n');
}

export function buildHttpMcpConfigJson(
  origin: string,
  tokenPlaceholder = 'YOUR_ACCESS_TOKEN',
): string {
  const endpoint = buildHttpMcpEndpoint(origin);
  return JSON.stringify(
    {
      mcpServers: {
        charkle: {
          type: 'http',
          url: endpoint,
          headers: {
            Authorization: `Bearer ${tokenPlaceholder}`,
          },
        },
      },
    },
    null,
    2,
  );
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 100 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

export function formatRelativeDate(iso?: string | null): string {
  if (!iso) return '从未';
  const ts = Date.parse(iso);
  if (!Number.isFinite(ts)) return iso;
  const diffSec = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (diffSec < 60) return '刚刚';
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)} 分钟前`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)} 小时前`;
  if (diffSec < 86400 * 7) return `${Math.floor(diffSec / 86400)} 天前`;
  return new Date(ts).toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}
