import React from 'react';
import {
  Add20Filled,
  Add20Regular,
  ArrowDownload20Filled,
  ArrowDownload20Regular,
  ArrowSwap20Filled,
  ArrowSwap20Regular,
  ArrowUpRight20Filled,
  ArrowUpRight20Regular,
  Board20Filled,
  Board20Regular,
  BoardSplit20Filled,
  BoardSplit20Regular,
  Chat20Filled,
  Chat20Regular,
  CheckmarkCircle20Filled,
  CheckmarkCircle20Regular,
  Clock20Filled,
  Clock20Regular,
  Cloud20Filled,
  Cloud20Regular,
  CloudSync20Filled,
  CloudSync20Regular,
  Code20Filled,
  Code20Regular,
  Color20Filled,
  Color20Regular,
  Cube20Filled,
  Cube20Regular,
  Delete20Filled,
  Delete20Regular,
  Desktop20Filled,
  Desktop20Regular,
  DocumentText20Filled,
  DocumentText20Regular,
  Eye20Filled,
  Eye20Regular,
  Filmstrip20Filled,
  Filmstrip20Regular,
  Filter20Filled,
  Filter20Regular,
  Folder20Filled,
  Folder20Regular,
  FolderSearch20Filled,
  FolderSearch20Regular,
  Grid20Filled,
  Grid20Regular,
  LayoutColumnThree20Filled,
  LayoutColumnThree20Regular,
  LayoutRowTwo20Filled,
  LayoutRowTwo20Regular,
  MailInbox20Filled,
  MailInbox20Regular,
  Note20Filled,
  Note20Regular,
  PanelLeft20Filled,
  PanelLeft20Regular,
  PanelRight20Filled,
  PanelRight20Regular,
  Pen20Filled,
  Pen20Regular,
  Screenshot20Filled,
  Screenshot20Regular,
  Search20Filled,
  Search20Regular,
  Settings20Filled,
  Settings20Regular,
  Shapes20Filled,
  Shapes20Regular,
  Share20Filled,
  Share20Regular,
  SoundWaveCircle20Filled,
  SoundWaveCircle20Regular,
  Sparkle20Filled,
  Sparkle20Regular,
  SquareHint20Filled,
  SquareHint20Regular,
  Tag20Filled,
  Tag20Regular,
  WeatherMoon20Filled,
  WeatherMoon20Regular,
  WeatherSunny20Filled,
  WeatherSunny20Regular,
  bundleIcon,
  type FluentIcon,
} from '@fluentui/react-icons';
import {
  Archive,
  AudioWaveform,
  Bolt,
  Book,
  Bookmark,
  Box,
  Briefcase,
  Camera,
  Code2,
  Cpu,
  Eye,
  FileText,
  Film,
  Flame,
  Flag,
  Folder,
  Gamepad2,
  Globe,
  Hand,
  Headphones,
  Heart,
  Image as ImageIcon,
  Inbox,
  Leaf,
  Link2,
  MessageSquare,
  Monitor,
  Moon,
  Music,
  Paintbrush,
  Palette,
  PawPrint,
  PenTool,
  PlaySquare,
  Ruler,
  Scissors,
  Shapes,
  Smartphone,
  Smile,
  Sparkles,
  Star,
  Sun,
  Terminal,
  User,
  Users,
  Wand2,
  type LucideIcon,
} from 'lucide-react';
import { deriveDuotonePair, useResolvedIsDark } from './theme';

export type CharkleIconStyle = 'duotone' | 'layered';

const LibraryIcon = bundleIcon(Grid20Filled, Grid20Regular);
const InboxIcon = bundleIcon(MailInbox20Filled, MailInbox20Regular);
const MoodboardIcon = bundleIcon(Board20Filled, Board20Regular);
const FolderFluentIcon = bundleIcon(Folder20Filled, Folder20Regular);
const SmartFolderIcon = bundleIcon(FolderSearch20Filled, FolderSearch20Regular);
const TagIcon = bundleIcon(Tag20Filled, Tag20Regular);
const RecentIcon = bundleIcon(Clock20Filled, Clock20Regular);
const TrashIcon = bundleIcon(Delete20Filled, Delete20Regular);
const SidebarToggleIcon = bundleIcon(PanelLeft20Filled, PanelLeft20Regular);
const InspectorToggleIcon = bundleIcon(PanelRight20Filled, PanelRight20Regular);
const MasonryVerticalIcon = bundleIcon(LayoutColumnThree20Filled, LayoutColumnThree20Regular);
const MasonryHorizontalIcon = bundleIcon(LayoutRowTwo20Filled, LayoutRowTwo20Regular);
const FilmstripIcon = bundleIcon(Filmstrip20Filled, Filmstrip20Regular);
const GalleryRingIcon = bundleIcon(Shapes20Filled, Shapes20Regular);
const CodeIcon = bundleIcon(Code20Filled, Code20Regular);
const Model3DIcon = bundleIcon(Cube20Filled, Cube20Regular);
const AudioIcon = bundleIcon(SoundWaveCircle20Filled, SoundWaveCircle20Regular);
const SocialPostIcon = bundleIcon(Chat20Filled, Chat20Regular);
const MarkdownIcon = bundleIcon(DocumentText20Filled, DocumentText20Regular);
const SparkleIcon = bundleIcon(Sparkle20Filled, Sparkle20Regular);
const AutoLayoutIcon = bundleIcon(BoardSplit20Filled, BoardSplit20Regular);
const PenIcon = bundleIcon(Pen20Filled, Pen20Regular);
const NoteIcon = bundleIcon(Note20Filled, Note20Regular);
const GroupFrameIcon = bundleIcon(SquareHint20Filled, SquareHint20Regular);
const ConnectorIcon = bundleIcon(ArrowUpRight20Filled, ArrowUpRight20Regular);
const PaletteIcon = bundleIcon(Color20Filled, Color20Regular);
const ExportIcon = bundleIcon(Share20Filled, Share20Regular);
const SwapIcon = bundleIcon(ArrowSwap20Filled, ArrowSwap20Regular);
const PinOfflineIcon = bundleIcon(ArrowDownload20Filled, ArrowDownload20Regular);
const ShelfIcon = bundleIcon(Desktop20Filled, Desktop20Regular);
const ScreenshotIcon = bundleIcon(Screenshot20Filled, Screenshot20Regular);
const DriveSyncIcon = bundleIcon(CloudSync20Filled, CloudSync20Regular);
const DriveCloudIcon = bundleIcon(Cloud20Filled, Cloud20Regular);
const FilterIcon = bundleIcon(Filter20Filled, Filter20Regular);
const SearchIcon = bundleIcon(Search20Filled, Search20Regular);
const SettingsIcon = bundleIcon(Settings20Filled, Settings20Regular);
const QuickLookIcon = bundleIcon(Eye20Filled, Eye20Regular);
const ReadyIcon = bundleIcon(CheckmarkCircle20Filled, CheckmarkCircle20Regular);
const SunIcon = bundleIcon(WeatherSunny20Filled, WeatherSunny20Regular);
const MoonIcon = bundleIcon(WeatherMoon20Filled, WeatherMoon20Regular);
const AddIcon = bundleIcon(Add20Filled, Add20Regular);

const FLUENT_ICON_MAP: Record<string, FluentIcon> = {
  library: LibraryIcon,
  gallery: LibraryIcon,
  inbox: InboxIcon,
  moodboard: MoodboardIcon,
  folder: FolderFluentIcon,
  'smart-folder': SmartFolderIcon,
  untagged: TagIcon,
  recent: RecentIcon,
  trash: TrashIcon,
  tag: TagIcon,
  'sidebar-toggle': SidebarToggleIcon,
  'inspector-toggle': InspectorToggleIcon,
  'masonry-vertical': MasonryVerticalIcon,
  'masonry-horizontal': MasonryHorizontalIcon,
  'gallery-filmstrip': FilmstripIcon,
  'gallery-ring': GalleryRingIcon,
  github: CodeIcon,
  model3d: Model3DIcon,
  audio: AudioIcon,
  'social-post': SocialPostIcon,
  markdown: MarkdownIcon,
  similar: SparkleIcon,
  'sparkle-board': SparkleIcon,
  'ai-spark': SparkleIcon,
  'auto-layout': AutoLayoutIcon,
  freeform: PenIcon,
  note: NoteIcon,
  'group-frame': GroupFrameIcon,
  connector: ConnectorIcon,
  'ink-pen': PenIcon,
  palette: PaletteIcon,
  export: ExportIcon,
  swap: SwapIcon,
  'pin-offline': PinOfflineIcon,
  notch: ShelfIcon,
  screenshot: ScreenshotIcon,
  'drive-sync': DriveSyncIcon,
  drive: DriveCloudIcon,
  filter: FilterIcon,
  search: SearchIcon,
  settings: SettingsIcon,
  quicklook: QuickLookIcon,
  ready: ReadyIcon,
  sun: SunIcon,
  moon: MoonIcon,
  add: AddIcon,
};

/** Custom SF-symbol badge lookup preserved for `CharkleFolderIcon` and folder customization. */
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

/**
 * Fluent 2 chrome, navigation & action icon backed by `@fluentui/react-icons` `bundleIcon`.
 * Automatically transitions between `Regular` (inactive) and `Filled` (active) geometry.
 */
export const CharkleIcon: React.FC<CharkleIconProps> = ({
  name,
  style = 'duotone',
  size = 18,
  isActive = false,
  tintHex = null,
  className = '',
  alt = '',
}) => {
  const BundledIcon = FLUENT_ICON_MAP[name] ?? GroupFrameIcon;
  const resolvedSize = style === 'layered' ? Math.round(size * 0.62) : size;

  if (style === 'layered') {
    return (
      <span
        role={alt ? 'img' : undefined}
        aria-label={alt || undefined}
        aria-hidden={alt ? undefined : true}
        className={[
          'inline-flex items-center justify-center shrink-0 select-none',
          'rounded-[var(--win-radius-card)] bg-[var(--accent-soft)] text-[var(--accent)]',
          className,
        ]
          .filter(Boolean)
          .join(' ')}
        style={{
          width: size,
          height: size,
          ...(tintHex ? { color: tintHex } : undefined),
        }}
      >
        <BundledIcon
          filled={true}
          style={{ width: resolvedSize, height: resolvedSize }}
        />
      </span>
    );
  }

  return (
    <span
      role={alt ? 'img' : undefined}
      aria-label={alt || undefined}
      aria-hidden={alt ? undefined : true}
      className={[
        'inline-flex items-center justify-center shrink-0 select-none',
        isActive && !tintHex ? 'text-[var(--accent)]' : '',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
      style={{
        width: size,
        height: size,
        ...(tintHex ? { color: tintHex } : undefined),
      }}
    >
      <BundledIcon
        filled={isActive}
        style={{ width: size, height: size }}
      />
    </span>
  );
};

export interface CharkleFolderIconProps {
  colorHex?: string | null;
  customSymbol?: string | null;
  size?: number;
  isActive?: boolean;
  className?: string;
}

/**
 * Custom Charkle brand folder icon supporting custom folder colors & embossed emoji/symbol badges.
 */
export const CharkleFolderIcon: React.FC<CharkleFolderIconProps> = ({
  colorHex = null,
  customSymbol = null,
  size = 18,
  isActive = false,
  className = '',
}) => {
  const isDark = useResolvedIsDark();
  const pair = colorHex ? deriveDuotonePair(colorHex, isDark) : null;

  const backFill = pair
    ? pair.primary
    : isActive
      ? 'var(--accent)'
      : isDark
        ? '#8EA8E8'
        : '#4A6FA5';
  const frontFill = pair
    ? pair.secondary
    : isActive
      ? isDark
        ? '#3E5998'
        : '#AFC6F7'
      : isDark
        ? '#3D4E75'
        : '#B8C6E0';

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
      className={`relative inline-flex items-center justify-center shrink-0 select-none ${className}`}
      style={{ width: size, height: size }}
    >
      <svg
        viewBox="0 0 20 20"
        width={size}
        height={size}
        aria-hidden="true"
        className="block shrink-0"
      >
        <path
          d="M2.5 5.25C2.5 4.28 3.28 3.5 4.25 3.5H7.6c.48 0 .94.2 1.26.55l.9.95h5.99c.97 0 1.75.78 1.75 1.75V14.75c0 .97-.78 1.75-1.75 1.75H4.25c-.97 0-1.75-.78-1.75-1.75V5.25Z"
          fill={backFill}
        />
        <rect
          x="2.5"
          y="7"
          width="15"
          height="9.5"
          rx="1.75"
          fill={frontFill}
          fillOpacity={isActive ? 0.92 : 0.85}
        />
      </svg>
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
