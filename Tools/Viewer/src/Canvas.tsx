import { useEffect, useMemo, useRef, useState } from "react";
import { formatListAlias, type Entry, type Frame, type Screen } from "./types";

interface Props {
  screen: Screen;
  entries: Entry[];
  selectedAt: number | null;
  onSelect: (at: number | null) => void;
  matchIds: Set<number> | null;
  /// `"android"` switches the platform-conditional geometry knobs
  /// (y-band inset, label-visibility floor) to their pixel-scale
  /// values. Falls back to the iOS-points convention when absent
  /// or unknown.
  platform?: string;
}

// AX-declared region kinds (per DESCRIBE_UI_OUTLINE.md §3.1). Y-band
// fallback kinds (Top/Content/Bottom) are handled separately via the
// horizontal divider lines and never show as overlays.
const DECLARED_REGION_COLORS: Record<string, string> = {
  NavBar: "#26a69a",
  TabBar: "#9b59b6",
  Toolbar: "#00acc1",
  Scroll: "#e67e22",
  Group: "#7f8c8d",
};

interface GroupBox {
  key: string;
  kind: string;
  label: string;
  color: string;
  bbox: Frame;
  count: number;
}

// The `ExecutionResult` JSON doesn't carry the declared-group frames
// directly — we only know which region each entry belongs to. Union
// the entry frames to approximate the group's visible extent. This is
// a small under-estimate vs the AX node's own frame, but close enough
// for a visual hint and avoids a schema change upstream.
function deriveGroups(entries: Entry[]): GroupBox[] {
  const map = new Map<string, GroupBox>();
  for (const e of entries) {
    const color = DECLARED_REGION_COLORS[e.region.kind];
    if (!color || !e.region.label) continue;
    const key = `${e.region.kind}|${e.region.label}`;
    const f = e.frame;
    const cur = map.get(key);
    if (!cur) {
      map.set(key, {
        key,
        kind: e.region.kind,
        label: e.region.label,
        color,
        bbox: { ...f },
        count: 1,
      });
    } else {
      const x1 = Math.min(cur.bbox.x, f.x);
      const y1 = Math.min(cur.bbox.y, f.y);
      const x2 = Math.max(cur.bbox.x + cur.bbox.width, f.x + f.width);
      const y2 = Math.max(cur.bbox.y + cur.bbox.height, f.y + f.height);
      cur.bbox = { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
      cur.count += 1;
    }
  }
  // Paint larger regions first so smaller ones sit on top in case of
  // visual overlap. Per §3.1 AX nesting rule this is defensive, not
  // load-bearing.
  return [...map.values()].sort(
    (a, b) => b.bbox.width * b.bbox.height - a.bbox.width * a.bbox.height,
  );
}

function GroupOverlay({
  group,
  screen,
  pixelScale,
}: {
  group: GroupBox;
  screen: Screen;
  pixelScale: number;
}) {
  // Chrome sizes are authored in CSS px (what you'd want on screen) and
  // multiplied by pixelScale to land in viewBox units, so an Android
  // 1080×2400 viewBox doesn't squash the chip to invisibility.
  const PAD = 3 * pixelScale;
  const x = Math.max(0, group.bbox.x - PAD);
  const y = Math.max(0, group.bbox.y - PAD);
  const w = Math.min(screen.width - x, group.bbox.width + PAD * 2);
  const h = Math.min(screen.height - y, group.bbox.height + PAD * 2);

  const chipText = `${group.kind} "${group.label}"`;
  // Width estimate: CJK glyphs average ~8 CSS px at fontSize 8, ASCII ~5.
  // 6.5 splits the difference for the mixed strings common in LINE UIs.
  // The * pixelScale at the end converts the CSS-px estimate to viewBox.
  const chipW = (10 + chipText.length * 6.5) * pixelScale;
  const chipH = 12 * pixelScale;
  const chipX = x;
  const chipY = y >= chipH + pixelScale ? y - chipH - pixelScale : y + 2 * pixelScale;
  const chipFontSize = 8 * pixelScale;
  const chipTextPadX = 4 * pixelScale;
  const chipTextBaseline = chipH - 3.5 * pixelScale;

  return (
    <g className="group-overlay" pointerEvents="none">
      <rect
        x={x}
        y={y}
        width={w}
        height={h}
        fill="none"
        stroke={group.color}
        strokeWidth={1.25}
        strokeDasharray="6 4"
        opacity={0.55}
        rx={4}
        ry={4}
        vectorEffect="non-scaling-stroke"
      />
      <g transform={`translate(${chipX}, ${chipY})`}>
        <rect
          x={0}
          y={0}
          width={Math.min(chipW, screen.width - chipX)}
          height={chipH}
          fill={group.color}
          opacity={0.85}
          rx={2 * pixelScale}
          ry={2 * pixelScale}
        />
        <text
          x={chipTextPadX}
          y={chipTextBaseline}
          fontSize={chipFontSize}
          fontFamily="ui-monospace, SFMono-Regular, Menlo, monospace"
          fill="#fff"
        >
          {chipText}
        </text>
      </g>
    </g>
  );
}

// An element the agent cannot address: no uniqueId AND no label text.
// Containers (entries with children in the outline tree) and full-screen
// wrappers (>= 33% of screen area) are excluded — they're structural,
// not actionable blind spots.
function isBlindSpot(entry: Entry, isContainer: boolean, screen: Screen): boolean {
  if (entry.uniqueId || entry.label) return false;
  if (isContainer || entry.role === "Group" || entry.role === "Image" || entry.role === "ViewGroup") return false;
  const area = entry.frame.width * entry.frame.height;
  const screenArea = screen.width * screen.height;
  return area < screenArea * 0.33;
}

// Stroke / fill rules per §visual-conventions in the plan. Colors live here
// rather than in CSS so they can be derived per-entry and applied inline to
// SVG attributes (stroke-dasharray, opacity) without global selector churn.
function styleFor(entry: Entry, isSelected: boolean, isContainer: boolean, screen: Screen) {
  const hasId = !!entry.uniqueId;
  const isDisabled = entry.states.includes("disabled");
  const isAxSelected = entry.states.includes("selected");
  const blindSpot = isBlindSpot(entry, isContainer, screen);

  let stroke: string;
  let strokeDasharray: string | undefined;
  let strokeWidth = 1;
  let fill = "transparent";
  let opacity = 1;

  if (blindSpot) {
    stroke = "#d94040";
    strokeWidth = 1.5;
    fill = "url(#hatch-blind)";
  } else if (hasId) {
    stroke = "#2ecc71";
  } else {
    stroke = "#4a90e2";
    strokeDasharray = "4 3";
  }

  if (isDisabled) {
    stroke = "#888";
    fill = "rgba(136,136,136,0.08)";
    opacity = 0.55;
  }
  if (isAxSelected) {
    stroke = "#f1c40f";
    strokeWidth = 2;
    strokeDasharray = undefined;
  }
  if (isSelected) {
    stroke = "#8b6fc0";
    strokeWidth = 2.5;
    fill = "rgba(139,111,192,0.12)";
    strokeDasharray = undefined;
    opacity = 1;
  }

  return { stroke, strokeDasharray, strokeWidth, fill, opacity, blindSpot };
}

// Badge lives at the top-left outside the box. When the box hugs the canvas
// edge the badge would clip, so in that case flip it back inside. Badge
// sizing is authored in CSS px (target on-screen size) and converted to
// viewBox units via pixelScale, so an iPhone-shaped viewBox and an Android
// 1080×2400 viewBox render badges at the same on-screen size.
function badgePosition(entry: Entry, screen: Screen, pixelScale: number) {
  const { x, y } = entry.frame;
  const BADGE_H = 11 * pixelScale;
  const BADGE_W_MIN = 18 * pixelScale;
  const outsideY = y - BADGE_H - pixelScale;
  const outsideX = x;
  const useInside = outsideY < 0 || outsideX < 0;
  return {
    x: useInside ? x + 2 * pixelScale : outsideX,
    y: useInside ? y + 2 * pixelScale : outsideY,
    h: BADGE_H,
    wMin: BADGE_W_MIN,
    inside: useInside,
    clampRight: screen.width,
  };
}

function labelFontSize(frameHeight: number, pixelScale: number) {
  // Tight clamp at the CSS-px layer: icon-sized 30pt buttons land at
  // ~8px on screen, full-width cells stop at 10px. The clamp is on the
  // *visible* size (frameHeight / pixelScale), then we multiply back
  // up so the returned value is in viewBox units the SVG can consume.
  const cssTarget = Math.max(
    7,
    Math.min(10, Math.round((frameHeight / pixelScale) * 0.28)),
  );
  return cssTarget * pixelScale;
}

function ElementBox({
  entry,
  screen,
  isSelected,
  isContainer,
  isMuted,
  onSelect,
  pixelScale,
}: {
  entry: Entry;
  screen: Screen;
  isSelected: boolean;
  isContainer: boolean;
  isMuted: boolean;
  onSelect: (at: number | null) => void;
  pixelScale: number;
}) {
  const { x, y, width, height } = entry.frame;
  const s = styleFor(entry, isSelected, isContainer, screen);
  const badge = badgePosition(entry, screen, pixelScale);
  const fontSize = labelFontSize(height, pixelScale);
  // Visibility floor: skip labels for frames smaller than ~10
  // CSS pixels (the size below which a label is unreadable at
  // the rendered scale, regardless of platform). Multiply by
  // `pixelScale` to convert into the viewBox units the frame
  // is sized in — on iOS (points, 1:1) that's still 10; on
  // Android (~3x density pixels) it scales up to ~30, matching
  // the same on-screen visual minimum.
  const floor = 10 * pixelScale;
  const showLabel = height >= floor && width >= floor && !!entry.label;
  // Muted entries stay clickable but fade hard so matches pop visually.
  // Applied as a group-level opacity so rect, label, and badge all dim
  // together; selection still wins the stroke treatment.
  const groupOpacity = isMuted && !isSelected ? 0.15 : 1;

  // Tag for aria only; the full label appears in the label block and in the
  // side panel, so no need to duplicate it in a <title>.
  const aliasText = entry.aliases.list != null
    ? `@${entry.aliases.at} ${formatListAlias(entry.aliases.list)}`
    : `@${entry.aliases.at}`;
  // Badge width in CSS px, then converted to viewBox. Per-char width ~5
  // CSS px at fontSize 8 monospace; 6 CSS px of horizontal padding.
  const badgeWidth = Math.max(badge.wMin, (6 + aliasText.length * 5) * pixelScale);
  const badgeFontSize = 8 * pixelScale;
  const badgeTextPadX = 3 * pixelScale;
  const badgeTextBaseline = badge.h - 3 * pixelScale;

  return (
    <g
      className={`element ${isSelected ? "selected" : ""} ${isMuted ? "muted" : ""}`}
      opacity={groupOpacity}
      onClick={(e) => {
        e.stopPropagation();
        onSelect(entry.aliases.at);
      }}
    >
      <rect
        x={x}
        y={y}
        width={width}
        height={height}
        fill={s.fill}
        stroke={s.stroke}
        strokeWidth={s.strokeWidth}
        strokeDasharray={s.strokeDasharray}
        opacity={s.opacity}
        vectorEffect="non-scaling-stroke"
      />
      {showLabel && (
        <foreignObject x={x} y={y} width={width} height={height} pointerEvents="none">
          <div
            className="box-label"
            style={{
              fontSize: `${fontSize}px`,
              opacity: s.opacity,
              color: entry.uniqueId ? "#145a32" : "#1b3a5b",
            }}
          >
            <span>{entry.label}</span>
          </div>
        </foreignObject>
      )}

      <g className="alias-badge" transform={`translate(${badge.x}, ${badge.y})`}>
        <rect
          x={0}
          y={0}
          width={Math.min(badgeWidth, badge.clampRight - badge.x)}
          height={badge.h}
          rx={3 * pixelScale}
          ry={3 * pixelScale}
          fill={isSelected ? "#8b6fc0" : s.blindSpot ? "#d94040" : entry.uniqueId ? "#2ecc71" : "#4a90e2"}
        />
        <text
          x={badgeTextPadX}
          y={badgeTextBaseline}
          fontSize={badgeFontSize}
          fontFamily="ui-monospace, SFMono-Regular, Menlo, monospace"
          fill="#fff"
        >
          {aliasText}
        </text>
      </g>
    </g>
  );
}

export default function Canvas({ screen, entries, selectedAt, onSelect, matchIds, platform }: Props) {
  const sorted = useMemo(() => {
    // Larger boxes first so smaller inner elements render on top and stay
    // clickable. Tie-breaking on alias keeps render order deterministic.
    return [...entries].sort((a, b) => {
      const areaA = a.frame.width * a.frame.height;
      const areaB = b.frame.width * b.frame.height;
      if (areaA !== areaB) return areaB - areaA;
      return a.aliases.at - b.aliases.at;
    });
  }, [entries]);

  const groups = useMemo(() => deriveGroups(entries), [entries]);

  // Entries whose next sibling in outline order has a greater depth are
  // containers (they have children). Containers are structural wrappers
  // and should never be flagged as blind spots.
  const containerAts = useMemo(() => {
    const set = new Set<number>();
    for (let i = 0; i < entries.length - 1; i++) {
      const cur = entries[i].depth ?? 0;
      const next = entries[i + 1].depth ?? 0;
      if (next > cur) set.add(entries[i].aliases.at);
    }
    return set;
  }, [entries]);

  // Observe the canvas-host's CSS size so we can scale chrome (labels,
  // badges, region chips) inversely to the viewBox→CSS shrink factor.
  // Without this, an Android 1080×2400 viewBox squashes 10-unit fonts
  // into ~3 CSS px on a 400px-wide viewport — illegible.
  const hostRef = useRef<HTMLDivElement | null>(null);
  const [hostSize, setHostSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    // Seed synchronously so the first paint already has a sensible scale
    // (ResizeObserver fires async, so without this every fresh mount
    // would render once with pixelScale=1 and flicker into the correct
    // scale on the next tick).
    setHostSize({ width: el.clientWidth, height: el.clientHeight });
    const observer = new ResizeObserver((records) => {
      const rect = records[0]?.contentRect;
      if (!rect) return;
      setHostSize({ width: rect.width, height: rect.height });
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // SVG with preserveAspectRatio="meet" fits inside the container,
  // picking the smaller scale (the one limited by the most-constrained
  // dimension). The inverse — viewBox units per CSS px — is therefore
  // the *larger* ratio. That's the multiplier we apply to chrome sizes
  // so they end up at the authored CSS-px size on screen.
  const pixelScale = useMemo(() => {
    if (hostSize.width <= 0 || hostSize.height <= 0) return 1;
    return Math.max(
      screen.width / hostSize.width,
      screen.height / hostSize.height,
    );
  }, [screen.width, screen.height, hostSize.width, hostSize.height]);

  // y-band insets match the CLI renderers' platform-specific
  // values: 120 points on iOS (`OutlineFormatter.yBandInset`) and
  // 280 pixels on Android (`AndroidOutlineRenderer.yBandInset`).
  // The 5× ratio mirrors the device-coord-unit difference; using
  // 120 unconditionally would have placed the Android divider
  // inside the system status bar.
  const bandInset = platform === "android" ? 280 : 120;
  const topBand = bandInset;
  const bottomBand = Math.max(0, screen.height - bandInset);

  return (
    <div className="canvas-host" ref={hostRef} onClick={() => onSelect(null)}>
      <svg
        viewBox={`0 0 ${screen.width} ${screen.height}`}
        preserveAspectRatio="xMidYMid meet"
        className="canvas-svg"
      >
        <defs>
          <pattern
            id="hatch-blind"
            patternUnits="userSpaceOnUse"
            width={6 * pixelScale}
            height={6 * pixelScale}
            patternTransform="rotate(45)"
          >
            <rect width={6 * pixelScale} height={6 * pixelScale} fill="rgba(220,60,60,0.05)" />
            <line
              x1={0} y1={0} x2={0} y2={6 * pixelScale}
              stroke="rgba(220,60,60,0.28)"
              strokeWidth={2.2 * pixelScale}
            />
          </pattern>
        </defs>
        <rect x={0} y={0} width={screen.width} height={screen.height} className="canvas-bg" />

        <line
          x1={0}
          y1={topBand}
          x2={screen.width}
          y2={topBand}
          className="region-divider"
          vectorEffect="non-scaling-stroke"
        />
        <line
          x1={0}
          y1={bottomBand}
          x2={screen.width}
          y2={bottomBand}
          className="region-divider"
          vectorEffect="non-scaling-stroke"
        />

        {groups.map((group) => (
          <GroupOverlay key={group.key} group={group} screen={screen} pixelScale={pixelScale} />
        ))}

        {sorted.map((entry) => (
          <ElementBox
            key={entry.aliases.at}
            entry={entry}
            screen={screen}
            isSelected={entry.aliases.at === selectedAt}
            isContainer={containerAts.has(entry.aliases.at)}
            isMuted={matchIds !== null && !matchIds.has(entry.aliases.at)}
            onSelect={onSelect}
            pixelScale={pixelScale}
          />
        ))}
      </svg>
    </div>
  );
}
