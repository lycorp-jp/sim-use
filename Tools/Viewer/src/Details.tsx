import { useEffect, useMemo, useRef } from "react";
import { formatListAlias, type Entry, type Snapshot } from "./types";

interface Props {
  snapshot: Snapshot | null;
  selected: Entry | null;
  onSelect: (at: number | null) => void;
  matchIds: Set<number> | null;
  onTap: () => void;
  tapping: boolean;
  tapStatus: string | null;
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="kv">
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}

export default function Details({
  snapshot,
  selected,
  onSelect,
  matchIds,
  onTap,
  tapping,
  tapStatus,
}: Props) {
  const outlineRef = useRef<HTMLPreElement | null>(null);

  const outlineLines = useMemo(() => (snapshot?.outline ?? "").split("\n"), [snapshot?.outline]);

  // Map the outline lines to their `@N` so clicks on a line select the entry
  // and selection scrolls the line into view. The grammar guarantees the
  // alias appears as a leading token after whitespace; anything without one
  // (headers, blank lines, app line) maps to null.
  const lineAliasIndex = useMemo(() => {
    return outlineLines.map((line) => {
      const match = line.match(/^\s+@(\d+)\b/);
      return match ? Number(match[1]) : null;
    });
  }, [outlineLines]);

  useEffect(() => {
    if (selected == null || !outlineRef.current) return;
    const idx = lineAliasIndex.findIndex((at) => at === selected.aliases.at);
    if (idx < 0) return;
    const el = outlineRef.current.querySelector<HTMLSpanElement>(`[data-line="${idx}"]`);
    el?.scrollIntoView({ block: "nearest" });
  }, [selected, lineAliasIndex]);

  if (!snapshot) {
    return <div className="details empty">Take a snapshot to inspect elements.</div>;
  }

  return (
    <div className="details">
      <section className="detail-section">
        <h2>{selected ? `@${selected.aliases.at}` : "Select an element"}</h2>
        {tapStatus && (
          <div
            className={`tap-status ${tapStatus.startsWith("Tap failed") ? "error" : "ok"}`}
          >
            {tapStatus}
          </div>
        )}
        {selected ? (
          <>
            <div className="detail-actions">
              <button
                className="primary tap-button"
                onClick={onTap}
                disabled={tapping}
                title="Replay sim-use tap (T)"
              >
                {tapping ? "Tapping…" : `Tap @${selected.aliases.at} (T)`}
              </button>
              <code
                className="copyable"
                title="Copy CLI command"
                onClick={() =>
                  navigator.clipboard?.writeText(
                    `sim-use tap @${selected.aliases.at} --udid ${snapshot.udid}`,
                  )
                }
              >
                copy cmd
              </code>
            </div>
            <dl className="kv-list">
              <Row label="role">{selected.role}</Row>
              <Row label="label">
                <span className="mono">{JSON.stringify(selected.label)}</span>
              </Row>
              <Row label="frame">
                <span className="mono">
                  ({selected.frame.x},{selected.frame.y} {selected.frame.width}×
                  {selected.frame.height})
                </span>
              </Row>
              <Row label="region">
                {selected.region.label
                  ? `${selected.region.kind} "${selected.region.label}"`
                  : selected.region.kind}
              </Row>
              {selected.uniqueId && (
                <Row label="uniqueId">
                  <span className="mono">#{selected.uniqueId}</span>
                </Row>
              )}
              {selected.states.length > 0 && (
                <Row label="states">
                  <span className="mono">{selected.states.join(", ")}</span>
                </Row>
              )}
              {selected.aliases.list != null && (
                <Row label="list alias">
                  <span className="mono">{formatListAlias(selected.aliases.list)}</span>
                </Row>
              )}
            </dl>
          </>
        ) : (
          <p className="hint">Click any box on the left, or any @N line below.</p>
        )}
      </section>

      <section className="detail-section outline-section">
        <h3>Outline</h3>
        <pre ref={outlineRef} className="outline">
          {outlineLines.map((line, idx) => {
            const at = lineAliasIndex[idx];
            const isSelected = at != null && selected?.aliases.at === at;
            // Only dim lines that actually carry an alias — region headers,
            // the App: header, and blank lines stay full brightness so the
            // outline structure remains legible even under tight filters.
            const isMuted = matchIds !== null && at != null && !matchIds.has(at);
            return (
              <span
                key={idx}
                data-line={idx}
                className={`outline-line ${isSelected ? "selected" : ""} ${at != null ? "clickable" : ""} ${isMuted ? "muted" : ""}`}
                onClick={() => {
                  if (at != null) onSelect(at);
                }}
              >
                {line}
                {"\n"}
              </span>
            );
          })}
        </pre>
      </section>
    </div>
  );
}
