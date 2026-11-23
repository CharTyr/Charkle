export type ShortcutScope = '采集与全局' | '画廊与整理' | '预览与视图' | '情绪板画布';

export interface ShortcutEntry {
  keys: string[];
  title: string;
  description: string;
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
    description: '上传文件、粘贴网页/社媒/GitHub 链接、文本灵感、网页取色或截屏',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', 'V'],
    title: '全局剪贴板采集',
    description: '非输入状态下自动识别截图、网页链接、#HEX 色卡或文本并入库',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', 'J'],
    title: '任意跳转',
    description: '快速检索并跳转文件夹、情绪板、标签、素材与常用命令',
    scope: '采集与全局',
  },
  {
    keys: ['⌘', ','],
    title: '打开设置',
    description: '管理账号安全、素材库位置、云同步、AI 与扩展插件',
    scope: '采集与全局',
  },
  {
    keys: ['1', '–', '9'],
    title: '收件箱快速归档',
    description: '在收件箱中按数字键 1–9 将当前素材直接归档至前 9 个文件夹',
    scope: '画廊与整理',
  },
  {
    keys: ['⌘', 'A'],
    title: '全选当前素材',
    description: '选中当前视图下全部素材以便批量整理或生成情绪板',
    scope: '画廊与整理',
  },
  {
    keys: ['Backspace'],
    title: '移入废纸篓',
    description: '将选中素材移入废纸篓（随时可还原）',
    scope: '画廊与整理',
  },
  {
    keys: ['⌘', '\\'],
    title: '折叠 / 展开侧边栏',
    description: '在精简图标栏与完整导航栏之间切换',
    scope: '预览与视图',
  },
  {
    keys: ['⌘', 'I'],
    title: '切换右侧检查器',
    description: '展开或收起素材属性、色卡、标签与相似推荐面板',
    scope: '预览与视图',
  },
  {
    keys: ['Space'],
    title: '全媒体快速预览',
    description: '沉浸预览图片、视频、音频波形、Markdown、PDF、网页与 3D 模型',
    scope: '预览与视图',
  },
  {
    keys: ['←', '/', '→'],
    title: '上一项 / 下一项',
    description: '在快速预览或画廊视图中切换相邻素材',
    scope: '预览与视图',
  },
  {
    keys: ['+', '=', '-', '0'],
    title: '缩放与 100% 重置',
    description: '放大 (+/=)、缩小 (-) 或一键重置缩放与画面状态 (0)',
    scope: '预览与视图',
  },
  {
    keys: ['R', '/', '⇧R'],
    title: '顺时针 / 逆时针旋转 90°',
    description: '在快速预览、画廊视图或情绪板画布中旋转素材',
    scope: '情绪板画布',
  },
  {
    keys: ['⇧H', '/', '⇧V'],
    title: '水平 / 上下翻转',
    description: '镜像翻转预览画面或情绪板选中卡片',
    scope: '情绪板画布',
  },
  {
    keys: ['V / H / C / P / E'],
    title: '自由画布工具切换',
    description: '选择 (V)、抓手平移 (H)、箭头连线 (C)、手绘标注 (P)、橡皮擦 (E)',
    scope: '情绪板画布',
  },
  {
    keys: ['⌘', 'Z', '/', '⇧⌘Z'],
    title: '画布撤销 / 重做',
    description: '多步撤销或重做移动、缩放、裁切、连线、批注与排版整理',
    scope: '情绪板画布',
  },
];

export interface MCPToolDescriptor {
  name: string;
  access: 'read' | 'write';
  label: string;
  summary: string;
}

export const MCP_TOOL_INVENTORY: readonly MCPToolDescriptor[] = [
  { name: 'library_overview', access: 'read', label: '素材库总览', summary: '读取素材总数、收件箱待整理数、文件夹树与热门标签' },
  { name: 'search_assets', access: 'read', label: '多维检索素材', summary: '支持关键词、拼音、目录、标签、颜色与评分筛选' },
  { name: 'list_inbox', access: 'read', label: '列出收件箱', summary: '获取待归档素材列表供外部助手分析与分拣' },
  { name: 'get_asset', access: 'read', label: '读取素材详情', summary: '获取单条素材完整属性、图内文字、AI 描述与色板' },
  { name: 'render_contact_sheet', access: 'read', label: '渲染视觉联系表', summary: '将最多 16 张素材拼成带编号徽章的联系表供看图审片' },
  { name: 'list_boards', access: 'read', label: '列出情绪板', summary: '获取所有情绪板摘要、数量与提取色板' },
  { name: 'get_board_context', access: 'read', label: '读取情绪板内容', summary: '读取指定情绪板的分区、便签、主图与锁定卡片' },
  { name: 'export_board_image', access: 'read', label: '导出高清拼图', summary: '将情绪板导出为高清 PNG 图像供外部审核或汇报' },
  { name: 'organize_assets', access: 'write', label: '整理素材属性', summary: '批量移动文件夹、增删标签、评星、修改备注与采纳建议标签' },
  { name: 'create_folder', access: 'write', label: '创建文件夹', summary: '在指定父目录下新建分类文件夹' },
  { name: 'ingest_asset', access: 'write', label: '导入新素材', summary: '从本地路径、网页链接或文本片段采集新素材入库' },
  { name: 'compose_moodboard', access: 'write', label: '自动生成情绪板', summary: '按提示词或指定素材分组创建全新情绪板并自动提取色板' },
  { name: 'patch_moodboard', access: 'write', label: '更新情绪板', summary: '向情绪板增删素材（跳过锁定卡片）、追加便签或重命名' },
  { name: 'trash_assets', access: 'write', label: '移入回收站（仅软删）', summary: '移入废纸篓可随时还原，永不提供永久删除能力' },
];

export interface SamplePromptItem {
  id: string;
  title: string;
  prompt: string;
}

export const EXTERNAL_AGENT_SAMPLE_PROMPTS: readonly SamplePromptItem[] = [
  {
    id: 'curate-board',
    title: '按风格找图并直接生成情绪板',
    prompt:
      '帮我从 Charkle 素材库里筛选 10 张「极简陶艺、暖白留白、自然光」风格的参考图，排除高饱和暗色调，创建一块新的情绪板并附带简短策展便签。',
  },
  {
    id: 'triage-inbox',
    title: '查看联系表并整理收件箱',
    prompt:
      '列出 Charkle 收件箱里待整理的素材，拼一张视觉联系表看看画面内容，再按照我现有的文件夹结构批量归档并补充合适的标签。',
  },
  {
    id: 'refine-board',
    title: '审阅并补充现有情绪板',
    prompt:
      '读取我最近的一块 Charkle 情绪板，检查整体色板与视觉节奏是否统一；在不改动已锁定卡片的前提下，补充 2–3 张更贴合主色调的参考素材。',
  },
];

export function buildHttpMcpConfigJson(
  origin: string,
  tokenPlaceholder = 'chk_your_personal_access_token',
): string {
  const endpoint = `${origin.replace(/\/$/, '')}/api/v1/mcp`;
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

export function buildStdioMcpConfigJson(dataDir = '.charkle-data'): string {
  return JSON.stringify(
    {
      mcpServers: {
        'charkle-local': {
          command: 'npm',
          args: ['run', 'mcp', '--prefix', '/path/to/Charkle-Web'],
          env: {
            CHARKLE_DATA_DIR: dataDir,
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
