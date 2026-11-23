import React, { useRef, useState } from 'react';
import {
  AudioWaveform,
  Box,
  Check,
  Code2,
  ExternalLink,
  Eye,
  FileText,
  FolderInput,
  FolderOpen,
  LayoutGrid,
  MessageSquare,
  Pin,
  RotateCcw,
  Share2,
  Star,
  Trash2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Popover,
  formatDuration,
  getGitHubLanguageColor,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';
import { ASSET_DRAG_MIME } from '../sidebar/FolderTree';

export interface AssetCardProps {
  asset: AssetRecord;
  selected: boolean;
  orderedIds: string[];
  width: number;
  height: number;
  style?: React.CSSProperties;
}

/**
 * Borderless gallery-first AssetCard (DESIGN.md §1, §3.2, §6.2):
 * - Zero permanent chrome; media occupies full card area
 * - Fine-pointer hover scale (`1.02`) + strictly `cachedOnly=1` muted video/GIF hover preview
 * - Full context menu with Safe-Triangle hierarchical folder move submenu
 */
export const AssetCard: React.FC<AssetCardProps> = ({
  asset,
  selected,
  orderedIds,
  width,
  height,
  style,
}) => {
  const cardRef = useRef<HTMLDivElement | null>(null);
  const [hovered, setHovered] = useState(false);
  const [hoverPreviewFailed, setHoverPreviewFailed] = useState(false);
  const [menuPoint, setMenuPoint] = useState<{ x: number; y: number } | null>(null);
  const [moveSubOpen, setMoveSubOpen] = useState(false);

  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const selectAsset = useCoordinatorStore((s) => s.selectAsset);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);

  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const transport = getTransport();
  const thumbUrl = transport.thumbnailUrl(asset.id, 'grid520');
  const canHoverLivePreview =
    hovered &&
    !hoverPreviewFailed &&
    asset.isLocalOriginalCached &&
    (asset.mediaKind === 'video' || asset.mediaKind === 'animatedImage');
  const cachedOriginalUrl = canHoverLivePreview
    ? transport.originalUrl(asset.id, { cachedOnly: true })
    : null;

  const targetIds =
    selected && selectedAssetIds.length > 1 ? selectedAssetIds : [asset.id];

  const handleOpenQuickLook = () => {
    const rect = cardRef.current?.getBoundingClientRect();
    openQuickLook(
      asset.id,
      rect
        ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
        : null,
    );
  };

  const gh = asset.richMetadata?.githubRepo;
  const social = asset.richMetadata?.socialPost;
  const isAudio = asset.mediaKind === 'audio';
  const isMarkdownDoc = asset.mediaKind === 'document' && Boolean(asset.richMetadata?.textExcerpt);

  return (
    <>
      <div
        ref={cardRef}
        role="button"
        tabIndex={0}
        aria-selected={selected}
        data-asset-id={asset.id}
        draggable
        onDragStart={(e) => {
          e.dataTransfer.setData(ASSET_DRAG_MIME, JSON.stringify(targetIds));
          e.dataTransfer.effectAllowed = 'move';
        }}
        onMouseEnter={() => {
          setHovered(true);
          setHoverPreviewFailed(false);
        }}
        onMouseLeave={() => setHovered(false)}
        onClick={(e) => {
          e.stopPropagation();
          selectAsset(asset.id, orderedIds, {
            multi: e.ctrlKey || e.metaKey,
            range: e.shiftKey,
          });
        }}
        onDoubleClick={(e) => {
          e.stopPropagation();
          selectAsset(asset.id, orderedIds);
          handleOpenQuickLook();
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          e.stopPropagation();
          if (!selected) {
            selectAsset(asset.id, orderedIds);
          }
          setMoveSubOpen(false);
          setMenuPoint({ x: e.clientX, y: e.clientY });
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            handleOpenQuickLook();
          }
        }}
        style={{
          width,
          height,
          ...style,
        }}
        className={[
          'group relative overflow-hidden rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] select-none cursor-pointer outline-none',
          'transition-shadow duration-150',
          selected
            ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-gallery)]'
            : 'ring-1 ring-[var(--border-hairline)] hover:ring-[var(--border-strong)]',
        ].join(' ')}
      >
        {/* Primary media stage */}
        {gh ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-start justify-between gap-2">
              <div className="flex items-center gap-1.5 text-[11px] font-medium text-[var(--text-secondary)]">
                <Code2 size={13.5} />
                <span className="truncate">{gh.owner}</span>
              </div>
              {gh.language && (
                <span className="inline-flex items-center gap-1 text-[11px] text-[var(--text-secondary)] shrink-0">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: getGitHubLanguageColor(gh.language) }}
                  />
                  {gh.language}
                </span>
              )}
            </div>
            <div className="my-auto">
              <div className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
                {gh.repo}
              </div>
              {gh.description && (
                <p className="mt-1 text-[12px] text-[var(--text-secondary)] line-clamp-3 leading-relaxed">
                  {gh.description}
                </p>
              )}
            </div>
            <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)] charkle-tabular">
              <span>★ {gh.stars.toLocaleString()}</span>
              {gh.license && <span className="truncate max-w-[110px]">{gh.license}</span>}
            </div>
          </div>
        ) : social ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-center justify-between gap-2">
              <span className="text-[12px] font-semibold text-[var(--text-primary)] truncate">
                {social.authorName}
              </span>
              <MessageSquare size={13} className="text-[var(--text-tertiary)] shrink-0" />
            </div>
            <p className="text-[12px] text-[var(--text-secondary)] line-clamp-4 leading-relaxed my-auto charkle-prose">
              {social.bodyText}
            </p>
            <div className="text-[11px] text-[var(--text-tertiary)] truncate">
              {social.authorHandle}
            </div>
          </div>
        ) : isAudio ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-secondary)]">
              <span className="inline-flex items-center gap-1">
                <AudioWaveform size={13.5} className="text-[var(--accent)]" />
                音频
              </span>
              {asset.durationSeconds ? (
                <span className="charkle-tabular">{formatDuration(asset.durationSeconds)}</span>
              ) : null}
            </div>
            <div className="flex items-end gap-[3px] h-12 px-1">
              {(asset.waveformPeaks.length > 0
                ? asset.waveformPeaks.slice(0, 28)
                : [0.3, 0.55, 0.8, 0.45, 0.9, 0.65, 0.4, 0.72, 0.6, 0.35, 0.78, 0.5, 0.62, 0.85, 0.48, 0.32]
              ).map((peak, i) => (
                <span
                  key={i}
                  className="flex-1 rounded-full bg-[var(--accent)]/60"
                  style={{ height: `${Math.max(16, Math.round(peak * 100))}%` }}
                />
              ))}
            </div>
            <div className="text-[12.5px] font-medium text-[var(--text-primary)] truncate">
              {asset.title}
            </div>
          </div>
        ) : isMarkdownDoc ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)]">
              <span className="inline-flex items-center gap-1">
                <FileText size={13} />
                {asset.richMetadata?.isMarkdown ? 'Markdown' : '文档'}
              </span>
            </div>
            <div className="my-1.5 flex-1 min-h-0 overflow-hidden">
              <div className="text-[13px] font-semibold text-[var(--text-primary)] truncate mb-1">
                {asset.title}
              </div>
              <p className="text-[11.5px] text-[var(--text-secondary)] line-clamp-5 leading-relaxed whitespace-pre-wrap">
                {asset.richMetadata?.textExcerpt}
              </p>
            </div>
          </div>
        ) : (
          <div className="w-full h-full relative bg-[var(--bg-subtle)]">
            <img
              src={thumbUrl}
              alt={asset.title}
              loading="lazy"
              decoding="async"
              draggable={false}
              className="w-full h-full object-cover charkle-media-zoom"
            />

            {/* Strictly cached-only hover live preview for video / GIF */}
            {canHoverLivePreview && cachedOriginalUrl && asset.mediaKind === 'video' && (
              <video
                src={cachedOriginalUrl}
                muted
                loop
                autoPlay
                playsInline
                onError={() => setHoverPreviewFailed(true)}
                className="absolute inset-0 w-full h-full object-cover"
              />
            )}
            {canHoverLivePreview && cachedOriginalUrl && asset.mediaKind === 'animatedImage' && (
              <img
                src={cachedOriginalUrl}
                alt={asset.title}
                onError={() => setHoverPreviewFailed(true)}
                className="absolute inset-0 w-full h-full object-cover"
              />
            )}
          </div>
        )}

        {/* Top-left selection checkbox (appears on hover or when selected) */}
        <button
          type="button"
          aria-label={selected ? '取消选中' : '选中素材'}
          onClick={(e) => {
            e.stopPropagation();
            selectAsset(asset.id, orderedIds, { multi: true });
          }}
          className={[
            'charkle-pressable absolute top-2 left-2 h-5 w-5 rounded-[6px] inline-flex items-center justify-center cursor-pointer',
            selected
              ? 'bg-[var(--accent)] text-white opacity-100 charkle-micro-pop'
              : 'bg-black/45 text-white opacity-0 group-hover:opacity-100',
          ].join(' ')}
        >
          {selected && <Check size={12.5} strokeWidth={2.6} />}
        </button>

        {/* Top-right compact media/status pills */}
        <div className="pointer-events-none absolute top-2 right-2 flex items-center gap-1">
          {asset.pinnedOffline && (
            <span className="h-5 px-1.5 rounded-[var(--radius-card-inner)] bg-black/55 text-white inline-flex items-center">
              <Pin size={10.5} />
            </span>
          )}
          {asset.mediaKind === 'video' && asset.durationSeconds ? (
            <span className="h-5 px-1.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[10.5px] inline-flex items-center charkle-tabular">
              {formatDuration(asset.durationSeconds)}
            </span>
          ) : null}
          {asset.mediaKind === 'animatedImage' && (
            <span className="h-5 px-1.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[10px] font-semibold inline-flex items-center">
              GIF
            </span>
          )}
          {asset.mediaKind === 'model3D' && (
            <span className="h-5 px-1.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[10px] font-semibold inline-flex items-center gap-0.5">
              <Box size={10.5} />
              3D
            </span>
          )}
        </div>

        {/* Bottom calm gradient title overlay on hover (keeps borderless media hero clean) */}
        {!gh && !social && !isAudio && !isMarkdownDoc && (
          <div className="pointer-events-none absolute inset-x-0 bottom-0 px-2.5 pt-6 pb-2 bg-gradient-to-t from-black/65 via-black/25 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-150 flex items-end justify-between gap-2">
            <span className="text-[12px] font-medium text-white truncate">{asset.title}</span>
            {asset.rating > 0 && (
              <span className="inline-flex items-center gap-0.5 text-[10.5px] text-amber-300 shrink-0 charkle-tabular">
                <Star size={10.5} className="fill-current" />
                {asset.rating}
              </span>
            )}
          </div>
        )}
      </div>

      {/* Right-click context menu */}
      <Popover
        open={menuPoint !== null}
        onOpenChange={(open) => {
          if (!open) {
            setMenuPoint(null);
            setMoveSubOpen(false);
          }
        }}
        anchorPoint={menuPoint}
        className="w-[216px] p-1.5"
      >
        <div className="flex flex-col gap-0.5 text-[12.5px]">
          <button
            type="button"
            onClick={() => {
              setMenuPoint(null);
              handleOpenQuickLook();
            }}
            className="w-full flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <span className="inline-flex items-center gap-2">
              <Eye size={14} className="text-[var(--text-secondary)]" />
              快速预览
            </span>
            <kbd className="text-[10.5px] text-[var(--text-tertiary)]">Space</kbd>
          </button>

          <button
            type="button"
            onClick={() => {
              setMenuPoint(null);
              void transport.revealInExplorer(asset.id);
            }}
            className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <FolderOpen size={14} className="text-[var(--text-secondary)]" />
            在资源管理器中显示
          </button>

          <button
            type="button"
            onClick={() => {
              setMenuPoint(null);
              void transport.startOutboundDrag(targetIds);
            }}
            className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <Share2 size={14} className="text-[var(--text-secondary)]" />
            拖出原文件到外部应用
          </button>

          {asset.sourceURL && (
            <button
              type="button"
              onClick={() => {
                setMenuPoint(null);
                if (asset.sourceURL) void transport.openExternalUrl(asset.sourceURL);
              }}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <ExternalLink size={14} className="text-[var(--text-secondary)]" />
              打开来源链接
            </button>
          )}

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          {/* Hierarchical folder move submenu */}
          <div className="relative">
            <button
              type="button"
              onClick={() => setMoveSubOpen((v) => !v)}
              className="w-full flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <span className="inline-flex items-center gap-2">
                <FolderInput size={14} className="text-[var(--text-secondary)]" />
                移至文件夹
              </span>
              <span className="text-[11px] text-[var(--text-tertiary)]">▸</span>
            </button>
            {moveSubOpen && (
              <div className="mt-1 pl-1 border-t border-[var(--border-hairline)] pt-1">
                <FolderMoveMenu
                  folders={folders}
                  currentFolderId={asset.folderID ?? null}
                  onSelectFolder={(folderId) => {
                    setMenuPoint(null);
                    setMoveSubOpen(false);
                    void updateAssets(
                      {
                        assetIDs: targetIds,
                        folderAssignment: folderId ? { folder: folderId } : 'inbox',
                      },
                      destination,
                      {
                        undoMessage: `已移动 ${targetIds.length} 项素材`,
                        undoPatch: {
                          assetIDs: targetIds,
                          folderAssignment: asset.folderID ? { folder: asset.folderID } : 'inbox',
                        },
                      },
                    );
                  }}
                />
              </div>
            )}
          </div>

          <button
            type="button"
            onClick={() => {
              setMenuPoint(null);
              void updateAssets(
                { assetIDs: targetIds, pinnedOffline: !asset.pinnedOffline },
                destination,
              );
            }}
            className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <Pin size={14} className="text-[var(--text-secondary)]" />
            {asset.pinnedOffline ? '取消离线常驻' : '设为离线常驻'}
          </button>

          {boards.length > 0 && (
            <button
              type="button"
              onClick={() => {
                setMenuPoint(null);
                const boardId = activeMoodboardId ?? boards[0]?.id;
                if (boardId) void addAssetsToBoard(boardId, targetIds);
              }}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <LayoutGrid size={14} className="text-[var(--text-secondary)]" />
              发送至情绪板
            </button>
          )}

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          {asset.isTrashed ? (
            <>
              <button
                type="button"
                onClick={() => {
                  setMenuPoint(null);
                  void updateAssets({ assetIDs: targetIds, isTrashed: false }, destination);
                }}
                className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <RotateCcw size={14} className="text-[var(--text-secondary)]" />
                还原素材
              </button>
              <button
                type="button"
                onClick={() => {
                  setMenuPoint(null);
                  void permanentlyDeleteAssets(targetIds, destination);
                }}
                className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
              >
                <Trash2 size={14} />
                永久删除
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={() => {
                setMenuPoint(null);
                void updateAssets({ assetIDs: targetIds, isTrashed: true }, destination, {
                  undoMessage: `已将 ${targetIds.length} 项移入回收站`,
                  undoPatch: { assetIDs: targetIds, isTrashed: false },
                });
              }}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
            >
              <Trash2 size={14} />
              移入回收站
            </button>
          )}
        </div>
      </Popover>
    </>
  );
};
