import React, { useMemo, useState } from 'react';
import { Trash2 } from 'lucide-react';
import type {
  BoardConnector,
  BoardNode,
  BoardPoint,
  ConnectorAnchor,
  ConnectorStyle,
  UUID,
} from '@charkle/shared';
import { SegmentedControl } from '../../design-system';
import { Popover } from '../../design-system/Popover';
import {
  buildConnectorGeometry,
  buildConnectorPathPoints,
} from './geometry';
import { CONNECTOR_SWATCHES } from './palettes';

const CONNECTOR_STYLE_OPTIONS: ReadonlyArray<{ id: ConnectorStyle; label: string }> = [
  { id: 'curved', label: '曲线' },
  { id: 'elbow', label: '折线' },
  { id: 'straight', label: '直线' },
];

const CONNECTOR_LINE_OPTIONS: ReadonlyArray<{ id: 'solid' | 'dashed'; label: string }> = [
  { id: 'solid', label: '实线' },
  { id: 'dashed', label: '虚线' },
];

export interface PendingConnectorPreview {
  fromNodeID: UUID;
  fromAnchor: ConnectorAnchor;
  startWorld: BoardPoint;
  cursorWorld: BoardPoint;
  style: ConnectorStyle;
  dashed: boolean;
  colorHex: string;
}

export interface ConnectorLayerProps {
  connectors: readonly BoardConnector[];
  nodesByID: ReadonlyMap<UUID, BoardNode>;
  selectedConnectorID: UUID | null;
  pendingConnector: PendingConnectorPreview | null;
  exitingNodeIDs?: ReadonlySet<UUID>;
  zoom: number;
  interactive: boolean;
  onSelectConnector: (id: UUID | null) => void;
  onUpdateConnector: (id: UUID, patch: Partial<BoardConnector>) => void;
  onDeleteConnector: (id: UUID) => void;
}

function buildArrowHeadPoints(end: BoardPoint, angleRad: number, size: number): string {
  const spread = 0.45;
  const p1 = {
    x: end.x - size * Math.cos(angleRad - spread),
    y: end.y - size * Math.sin(angleRad - spread),
  };
  const p2 = {
    x: end.x - size * Math.cos(angleRad + spread),
    y: end.y - size * Math.sin(angleRad + spread),
  };
  return `${p1.x.toFixed(1)},${p1.y.toFixed(1)} ${end.x.toFixed(1)},${end.y.toFixed(1)} ${p2.x.toFixed(1)},${p2.y.toFixed(1)}`;
}

export const ConnectorLayer: React.FC<ConnectorLayerProps> = ({
  connectors,
  nodesByID,
  selectedConnectorID,
  pendingConnector,
  exitingNodeIDs,
  zoom,
  interactive,
  onSelectConnector,
  onUpdateConnector,
  onDeleteConnector,
}) => {
  const [editingID, setEditingID] = useState<UUID | null>(null);
  const [popoverPoint, setPopoverPoint] = useState<{ x: number; y: number } | null>(null);

  const editingConnector = useMemo(
    () => (editingID ? connectors.find((c) => c.id === editingID) ?? null : null),
    [connectors, editingID],
  );

  const rendered = useMemo(() => {
    return connectors
      .map((conn) => {
        const fromNode = nodesByID.get(conn.fromNodeID);
        const toNode = nodesByID.get(conn.toNodeID);
        if (!fromNode || !toNode) return null;
        const geom = buildConnectorGeometry(conn, fromNode, toNode);
        return { conn, geom };
      })
      .filter((x): x is NonNullable<typeof x> => x !== null);
  }, [connectors, nodesByID]);

  const pendingGeom = useMemo(() => {
    if (!pendingConnector) return null;
    const dx = pendingConnector.cursorWorld.x - pendingConnector.startWorld.x;
    const dy = pendingConnector.cursorWorld.y - pendingConnector.startWorld.y;
    const fromAnchor: Exclude<ConnectorAnchor, 'auto'> =
      pendingConnector.fromAnchor !== 'auto'
        ? pendingConnector.fromAnchor
        : Math.abs(dx) >= Math.abs(dy)
          ? dx >= 0
            ? 'trailing'
            : 'leading'
          : dy >= 0
            ? 'bottom'
            : 'top';
    const toAnchor: Exclude<ConnectorAnchor, 'auto'> =
      Math.abs(dx) >= Math.abs(dy)
        ? dx >= 0
          ? 'leading'
          : 'trailing'
        : dy >= 0
          ? 'top'
          : 'bottom';
    return buildConnectorPathPoints(
      pendingConnector.startWorld,
      pendingConnector.cursorWorld,
      fromAnchor,
      toAnchor,
      pendingConnector.style,
    );
  }, [pendingConnector]);

  const strokeWidth = Math.max(1.5, 2.2 / Math.sqrt(Math.max(0.25, zoom)));
  const arrowSize = Math.max(8, 11 / Math.sqrt(Math.max(0.25, zoom)));

  return (
    <>
      <svg
        className="absolute inset-0 overflow-visible pointer-events-none"
        width="1"
        height="1"
      >
        {rendered.map(({ conn, geom }) => {
          const isSelected = selectedConnectorID === conn.id;
          const color = conn.colorHex || '#5C6672';
          const isExiting = Boolean(
            exitingNodeIDs && (exitingNodeIDs.has(conn.fromNodeID) || exitingNodeIDs.has(conn.toNodeID)),
          );

          return (
            <g
              key={conn.id}
              style={{
                opacity: isExiting ? 0 : 1,
                transition: 'opacity 150ms var(--ease-out)',
              }}
            >
              {/* Wide invisible hit target for easy selection */}
              <path
                d={geom.d}
                fill="none"
                stroke="transparent"
                strokeWidth={Math.max(14, 16 / Math.max(0.3, zoom))}
                className={interactive ? 'pointer-events-auto cursor-pointer' : 'pointer-events-none'}
                onPointerDown={(e) => {
                  if (!interactive) return;
                  e.stopPropagation();
                  onSelectConnector(conn.id);
                }}
                onDoubleClick={(e) => {
                  if (!interactive) return;
                  e.stopPropagation();
                  onSelectConnector(conn.id);
                  setEditingID(conn.id);
                  setPopoverPoint({ x: e.clientX, y: e.clientY });
                }}
              />

              {/* Selection glow halo */}
              {isSelected && (
                <path
                  d={geom.d}
                  fill="none"
                  stroke="var(--accent)"
                  strokeOpacity={0.28}
                  strokeWidth={strokeWidth * 3.4}
                  strokeLinecap="round"
                />
              )}

              {/* Visible stroke */}
              <path
                d={geom.d}
                fill="none"
                stroke={isSelected ? 'var(--accent)' : color}
                strokeWidth={isSelected ? strokeWidth * 1.25 : strokeWidth}
                strokeDasharray={conn.dashed ? '6 5' : undefined}
                strokeLinecap="round"
                strokeLinejoin="round"
              />

              {/* Pinpoint target halo + dot OR directional arrowhead */}
              {geom.toIsPinpoint ? (
                <g>
                  <circle
                    cx={geom.end.x}
                    cy={geom.end.y}
                    r={9 / Math.max(0.35, Math.sqrt(zoom))}
                    fill={color}
                    fillOpacity={0.18}
                    stroke={color}
                    strokeWidth={1.6}
                  />
                  <circle
                    cx={geom.end.x}
                    cy={geom.end.y}
                    r={3.6 / Math.max(0.35, Math.sqrt(zoom))}
                    fill={color}
                  />
                </g>
              ) : (
                <polyline
                  points={buildArrowHeadPoints(geom.end, geom.endAngleRad, arrowSize)}
                  fill="none"
                  stroke={isSelected ? 'var(--accent)' : color}
                  strokeWidth={isSelected ? strokeWidth * 1.25 : strokeWidth}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              )}

              {/* Start dot */}
              <circle
                cx={geom.start.x}
                cy={geom.start.y}
                r={geom.fromIsPinpoint ? 4 : 3}
                fill={isSelected ? 'var(--accent)' : color}
              />
            </g>
          );
        })}

        {/* Live pending connector drag line */}
        {pendingConnector && pendingGeom && (
          <g>
            <path
              d={pendingGeom.d}
              fill="none"
              stroke="var(--accent)"
              strokeWidth={strokeWidth}
              strokeDasharray="6 4"
              strokeLinecap="round"
            />
            <polyline
              points={buildArrowHeadPoints(pendingGeom.end, pendingGeom.endAngleRad, arrowSize)}
              fill="none"
              stroke="var(--accent)"
              strokeWidth={strokeWidth}
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </g>
        )}
      </svg>

      {/* Connector Label Pills (HTML overlay in world coordinates so text stays crisp) */}
      {rendered.map(({ conn, geom }) => {
        const isSelected = selectedConnectorID === conn.id;
        if (!conn.label && !isSelected) return null;
        return (
          <button
            key={`label-${conn.id}`}
            type="button"
            onPointerDown={(e) => {
              if (!interactive) return;
              e.stopPropagation();
              onSelectConnector(conn.id);
            }}
            onClick={(e) => {
              if (!interactive) return;
              e.stopPropagation();
              setEditingID(conn.id);
              setPopoverPoint({ x: e.clientX, y: e.clientY });
            }}
            className="absolute -translate-x-1/2 -translate-y-1/2 px-2 py-0.5 rounded-full text-[11px] font-medium whitespace-nowrap shadow-xs border cursor-pointer"
            style={{
              left: geom.midpoint.x,
              top: geom.midpoint.y,
              backgroundColor: 'var(--bg-elevated)',
              borderColor: isSelected ? 'var(--accent)' : 'var(--border-strong)',
              color: conn.label ? 'var(--text-primary)' : 'var(--text-tertiary)',
              pointerEvents: interactive ? 'auto' : 'none',
            }}
          >
            {conn.label || '+ 添加连线标签'}
          </button>
        );
      })}

      {/* Connector Style & Label Editor Popover */}
      <Popover
        open={Boolean(editingConnector)}
        onOpenChange={(open) => {
          if (!open) setEditingID(null);
        }}
        anchorPoint={popoverPoint}
        className="w-64 p-3"
      >
        {editingConnector && (
          <div
            onPointerDown={(e) => e.stopPropagation()}
            onDoubleClick={(e) => e.stopPropagation()}
            className="flex flex-col gap-3 text-[12px]"
          >
            <div className="flex items-center justify-between">
              <span className="font-semibold text-[var(--text-primary)]">编辑连线标注</span>
              <button
                type="button"
                onClick={() => {
                  const id = editingConnector.id;
                  setEditingID(null);
                  onDeleteConnector(id);
                }}
                className="charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-[6px] text-[11px] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
              >
                <Trash2 size={12} /> 删除
              </button>
            </div>

            <input
              type="text"
              autoFocus
              value={editingConnector.label ?? ''}
              placeholder="输入连线标签…"
              onChange={(e) =>
                onUpdateConnector(editingConnector.id, { label: e.target.value || null })
              }
              className="w-full px-2.5 py-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />

            {/* Curve style */}
            <div className="flex items-center justify-between gap-2">
              <span className="text-[11px] text-[var(--text-secondary)]">线型</span>
              <SegmentedControl
                ariaLabel="连线线型"
                size="sm"
                options={CONNECTOR_STYLE_OPTIONS}
                value={editingConnector.style}
                onChange={(style) => onUpdateConnector(editingConnector.id, { style })}
              />
            </div>

            {/* Dashed toggle */}
            <div className="flex items-center justify-between gap-2">
              <span className="text-[11px] text-[var(--text-secondary)]">样式</span>
              <SegmentedControl
                ariaLabel="实线或虚线"
                size="sm"
                options={CONNECTOR_LINE_OPTIONS}
                value={editingConnector.dashed ? 'dashed' : 'solid'}
                onChange={(next) =>
                  onUpdateConnector(editingConnector.id, { dashed: next === 'dashed' })
                }
              />
            </div>

            {/* Color picker */}
            <div className="flex items-center justify-between">
              <span className="text-[11px] text-[var(--text-secondary)]">颜色</span>
              <div className="flex items-center gap-1.5">
                {CONNECTOR_SWATCHES.map((s) => (
                  <button
                    key={s.hex}
                    type="button"
                    title={s.name}
                    onClick={() => onUpdateConnector(editingConnector.id, { colorHex: s.hex })}
                    className="w-4 h-4 rounded-full cursor-pointer transition-transform duration-[var(--duration-press,120ms)] ease-[var(--ease-out)] [@media(hover:hover)_and_(pointer:fine)]:hover:scale-110"
                    style={{
                      backgroundColor: s.hex,
                      boxShadow:
                        editingConnector.colorHex.toUpperCase() === s.hex.toUpperCase()
                          ? '0 0 0 2px var(--bg-elevated), 0 0 0 3.5px var(--accent)'
                          : undefined,
                    }}
                  />
                ))}
              </div>
            </div>
          </div>
        )}
      </Popover>
    </>
  );
};
