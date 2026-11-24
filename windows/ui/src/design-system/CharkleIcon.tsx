import React, { useEffect, useMemo, useState } from 'react';
import {
  Archive,
  ArrowDownCircle,
  ArrowLeftRight,
  ArrowUpRight,
  AudioWaveform,
  Bolt,
  Book,
  Bookmark,
  Box,
  Briefcase,
  Camera,
  CheckCircle2,
  Clock,
  CloudUpload,
  Code2,
  Columns3,
  Cpu,
  Eye,
  FileText,
  Film,
  Filter,
  Flame,
  Flag,
  Folder,
  FolderCog,
  Gamepad2,
  Globe,
  Hand,
  Headphones,
  Heart,
  Image as ImageIcon,
  Inbox,
  LayoutGrid,
  Leaf,
  Link2,
  MessageSquare,
  Monitor,
  Moon,
  Music,
  Paintbrush,
  Palette,
  PanelLeft,
  PawPrint,
  PenTool,
  PlaySquare,
  Rows2,
  Ruler,
  Scissors,
  Search,
  Settings,
  Shapes,
  Share,
  Smartphone,
  Smile,
  Sparkles,
  SquareDashed,
  Star,
  StickyNote,
  Sun,
  Tag,
  Terminal,
  Trash2,
  User,
  Users,
  Wand2,
  type LucideIcon,
} from 'lucide-react';
import { deriveDuotonePair, useResolvedIsDark } from './theme';

export type CharkleIconStyle = 'duotone' | 'layered';

const SOURCE_PRIMARY = '#445C94';
const SOURCE_SECONDARY = '#B4BED4';

const svgTextCache = new Map<string, string | null>();
const svgPromiseCache = new Map<string, Promise<string | null>>();

function fetchSvgSource(baseName: string): Promise<string | null> {
  if (svgTextCache.has(baseName)) {
    return Promise.resolve(svgTextCache.get(baseName) ?? null);
  }
  const existing = svgPromiseCache.get(baseName);
  if (existing) return existing;

  if (typeof fetch === 'undefined') {
    return Promise.resolve(null);
  }

  const promise = fetch(`/icons/${baseName}.svg`)
    .then(async (res) => {
      if (!res.ok) return null;
      const text = await res.text();
      if (!text.includes('<svg')) return null;
      svgTextCache.set(baseName, text);
      return text;
    })
    .catch(() => null)
    .then((result) => {
      if (result === null) svgTextCache.set(baseName, null);
      return result;
    });

  svgPromiseCache.set(baseName, promise);
  return promise;
}

function adaptDuotoneSvg(
  rawSvg: string,
  isDark: boolean,
  isActive: boolean,
  tintHex?: string | null,
): string {
  let primary: string | null = null;
  let secondary: string | null = null;

  if (tintHex) {
    const pair = deriveDuotonePair(tintHex, isDark);
    if (pair) {
      primary = pair.primary;
      secondary = pair.secondary;
    }
  }

  if (!primary || !secondary) {
    if (!isDark && !isActive) return rawSvg;
    if (!isDark && isActive) {
      primary = '#2A60E0';
      secondary = '#AFC6F7';
    } else if (isDark && !isActive) {
      primary = '#8EA8E8';
      secondary = '#3D4E75';
    } else {
      primary = '#9BB7FF';
      secondary = '#3E5998';
    }
  }

  return rawSvg
    .replace(new RegExp(SOURCE_PRIMARY, 'gi'), primary)
    .replace(new RegExp(SOURCE_SECONDARY, 'gi'), secondary);
}

const LUCIDE_FALLBACK_MAP: Record<string, LucideIcon> = {
  library: LayoutGrid,
  inbox: Inbox,
  moodboard: Columns3,
  folder: Folder,
  'smart-folder': FolderCog,
  untagged: Tag,
  recent: Clock,
  trash: Trash2,
  tag: Tag,
  'sidebar-toggle': PanelLeft,
  'masonry-vertical': Columns3,
  'masonry-horizontal': Rows2,
  'gallery-ring': Shapes,
  github: Code2,
  model3d: Box,
  audio: AudioWaveform,
  'social-post': MessageSquare,
  markdown: FileText,
  similar: Sparkles,
  'sparkle-board': Sparkles,
  'auto-layout': LayoutGrid,
  freeform: PenTool,
  note: StickyNote,
  'group-frame': SquareDashed,
  connector: ArrowUpRight,
  'ink-pen': PenTool,
  palette: Palette,
  export: Share,
  swap: ArrowLeftRight,
  'pin-offline': ArrowDownCircle,
  notch: Monitor,
  screenshot: Camera,
  'drive-sync': CloudUpload,
  filter: Filter,
  search: Search,
  settings: Settings,
  quicklook: Eye,
  drive: CloudUpload,
  'ai-spark': Sparkles,
  gallery: LayoutGrid,
  ready: CheckCircle2,
};

export const SF_SYMBOL_TO_LUCIDE: Record<string, LucideIcon> = {
  'paintbrush.fill': Paintbrush,
  'paintpalette.fill': Palette,
  sparkles: Sparkles,
  'wand.and.stars': Wand2,
  'swatchpalette.fill': Palette,
  'pencil.and.outline': PenTool,
  scissors: Scissors,
  'ruler.fill': Ruler,
  'square.on.circle': Shapes,
  'cube.fill': Box,
  'view.3d': Box,
  'scribble.variable': PenTool,
  'photo.fill': ImageIcon,
  'camera.fill': Camera,
  'film.fill': Film,
  'play.rectangle.fill': PlaySquare,
  'music.note': Music,
  waveform: AudioWaveform,
  headphones: Headphones,
  'book.fill': Book,
  'doc.richtext.fill': FileText,
  globe: Globe,
  link: Link2,
  'bubble.left.and.bubble.right.fill': MessageSquare,
  'person.fill': User,
  'person.2.fill': Users,
  'face.smiling': Smile,
  'eye.fill': Eye,
  'hand.raised.fill': Hand,
  'heart.fill': Heart,
  'star.fill': Star,
  'flame.fill': Flame,
  'sun.max.fill': Sun,
  'moon.stars.fill': Moon,
  'leaf.fill': Leaf,
  'pawprint.fill': PawPrint,
  'chevron.left.forwardslash.chevron.right': Code2,
  'terminal.fill': Terminal,
  'cpu.fill': Cpu,
  desktopcomputer: Monitor,
  iphone: Smartphone,
  'gamecontroller.fill': Gamepad2,
  'briefcase.fill': Briefcase,
  'archivebox.fill': Archive,
  'tray.full.fill': Inbox,
  'bolt.fill': Bolt,
  'flag.fill': Flag,
  'bookmark.fill': Bookmark,
};

export interface CharkleIconProps {
  name: string;
  style?: CharkleIconStyle;
  size?: number;
  isActive?: boolean;
  tintHex?: string | null;
  className?: string;
  alt?: string;
}

export const CharkleIcon: React.FC<CharkleIconProps> = ({
  name,
  style = 'duotone',
  size = 18,
  isActive = false,
  tintHex = null,
  className = '',
  alt = '',
}) => {
  const isDark = useResolvedIsDark();
  const baseName = `${style}-${name}`;
  const [svgRaw, setSvgRaw] = useState<string | null | undefined>(() =>
    svgTextCache.has(baseName) ? svgTextCache.get(baseName) : undefined,
  );

  useEffect(() => {
    let mounted = true;
    if (svgTextCache.has(baseName)) {
      setSvgRaw(svgTextCache.get(baseName));
      return;
    }
    fetchSvgSource(baseName).then((loaded) => {
      if (mounted) setSvgRaw(loaded);
    });
    return () => {
      mounted = false;
    };
  }, [baseName]);

  const dataUri = useMemo(() => {
    if (!svgRaw) return null;
    const finalSvg =
      style === 'duotone' ? adaptDuotoneSvg(svgRaw, isDark, isActive, tintHex) : svgRaw;
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(finalSvg)}`;
  }, [svgRaw, style, isDark, isActive, tintHex]);

  if (dataUri) {
    return (
      <img
        src={dataUri}
        alt={alt}
        width={size}
        height={size}
        draggable={false}
        className={`inline-block shrink-0 select-none ${className}`}
        style={{ width: size, height: size }}
      />
    );
  }

  const FallbackIcon = LUCIDE_FALLBACK_MAP[name] ?? SquareDashed;
  return (
    <FallbackIcon
      size={style === 'layered' ? Math.round(size * 0.68) : size}
      strokeWidth={1.75}
      className={`inline-block shrink-0 ${className}`}
      style={tintHex ? { color: tintHex } : undefined}
    />
  );
};

export interface CharkleFolderIconProps {
  colorHex?: string | null;
  customSymbol?: string | null;
  size?: number;
  isActive?: boolean;
  className?: string;
}

export const CharkleFolderIcon: React.FC<CharkleFolderIconProps> = ({
  colorHex = null,
  customSymbol = null,
  size = 18,
  isActive = false,
  className = '',
}) => {
  const isDark = useResolvedIsDark();
  const embossColor = colorHex
    ? isDark
      ? 'rgba(255, 255, 255, 0.92)'
      : colorHex
    : isDark
      ? 'rgba(255, 255, 255, 0.88)'
      : '#314678';

  const renderBadge = () => {
    if (!customSymbol) return null;
    if (customSymbol.startsWith('emoji:')) {
      const emoji = customSymbol.slice(6);
      return (
        <span
          className="pointer-events-none select-none leading-none"
          style={{
            fontSize: Math.max(8, size * 0.45),
            transform: `translateY(${size * 0.08}px)`,
          }}
        >
          {emoji}
        </span>
      );
    }
    const sfName = customSymbol.startsWith('sf:') ? customSymbol.slice(3) : customSymbol;
    const SymbolIcon = SF_SYMBOL_TO_LUCIDE[sfName] ?? Folder;
    return (
      <SymbolIcon
        size={Math.max(8, Math.round(size * 0.43))}
        strokeWidth={2.2}
        className="pointer-events-none"
        style={{
          color: embossColor,
          transform: `translateY(${size * 0.08}px)`,
        }}
      />
    );
  };

  return (
    <span
      className={`relative inline-flex items-center justify-center shrink-0 ${className}`}
      style={{ width: size, height: size }}
    >
      <CharkleIcon
        name="folder"
        style="duotone"
        size={size}
        isActive={isActive}
        tintHex={colorHex}
      />
      {customSymbol && (
        <span className="absolute inset-0 flex items-center justify-center">{renderBadge()}</span>
      )}
    </span>
  );
};

export interface CharkleBrandMarkProps {
  size?: number;
  variant?: 'auto' | 'light' | 'dark';
  rounded?: boolean;
  className?: string;
}

export const CharkleBrandMark: React.FC<CharkleBrandMarkProps> = ({
  size = 20,
  variant = 'auto',
  rounded = true,
  className = '',
}) => {
  const isDark = useResolvedIsDark();
  const useDark = variant === 'dark' || (variant === 'auto' && isDark);
  const src = useDark ? '/app-icons/Charkle-Dark.svg' : '/app-icons/Charkle-Light.svg';

  return (
    <img
      src={src}
      alt="Charkle"
      width={size}
      height={size}
      draggable={false}
      className={`inline-block shrink-0 select-none ${rounded ? 'rounded-[22%]' : ''} ${className}`}
      style={{ width: size, height: size }}
    />
  );
};
