import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Canvas from "./Canvas";
import Details from "./Details";
import type { Device, Snapshot } from "./types";

export default function App() {
  const [devices, setDevices] = useState<Device[]>([]);
  const [deviceId, setDeviceId] = useState<string>("");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [selectedAt, setSelectedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [intervalMs, setIntervalMs] = useState<number>(2000);
  const [playing, setPlaying] = useState<boolean>(false);
  const [searchTerm, setSearchTerm] = useState<string>("");
  const [onlyWithId, setOnlyWithId] = useState<boolean>(false);
  const [regionKey, setRegionKey] = useState<string>("");
  const [tapping, setTapping] = useState<boolean>(false);
  const [tapStatus, setTapStatus] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const refreshDevices = useCallback(async () => {
    try {
      const res = await fetch("/api/devices");
      const body = await res.json();
      if (!body.ok) throw new Error(body.error ?? "devices fetch failed");
      setDevices(body.devices as Device[]);
      setDeviceId((current) => {
        if (current && body.devices.some((d: Device) => d.deviceId === current)) return current;
        return body.devices[0]?.deviceId ?? "";
      });
    } catch (err) {
      setError(String((err as Error).message));
    }
  }, []);

  const fetchSnapshot = useCallback(async () => {
    if (!deviceId) return;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setError(null);
    try {
      const res = await fetch(`/api/snapshot?deviceId=${encodeURIComponent(deviceId)}`, {
        signal: controller.signal,
      });
      const body = await res.json();
      if (!body.ok) throw new Error(body.error ?? "snapshot fetch failed");
      setSnapshot(body as Snapshot);
    } catch (err) {
      if ((err as Error).name === "AbortError") return;
      setError(String((err as Error).message));
    }
  }, [deviceId]);

  useEffect(() => {
    refreshDevices();
  }, [refreshDevices]);

  // Changing simulators invalidates any prior tap feedback.
  useEffect(() => {
    setTapStatus(null);
  }, [deviceId]);

  // Sequential sampler: each tick awaits the previous fetch before
  // scheduling the next, so a single describe-ui that takes longer than
  // `intervalMs` slows the cadence instead of piling new sim-use processes
  // on the simulator. Think "self-applying back-pressure" — `intervalMs`
  // is the *floor* between ticks, not a hard rate.
  useEffect(() => {
    if (!playing) return;
    let cancelled = false;
    let timerId: number | undefined;
    const tick = async () => {
      if (cancelled) return;
      await fetchSnapshot();
      if (cancelled) return;
      timerId = window.setTimeout(tick, intervalMs);
    };
    timerId = window.setTimeout(tick, intervalMs);
    return () => {
      cancelled = true;
      if (timerId != null) window.clearTimeout(timerId);
    };
  }, [playing, intervalMs, fetchSnapshot]);

  const togglePlay = useCallback(() => {
    if (playing) {
      setPlaying(false);
      return;
    }
    if (!deviceId) return;
    setPlaying(true);
    // Fire the first shot immediately so the canvas isn't blank until
    // the first interval tick lands (which on 5s feels like forever).
    fetchSnapshot();
  }, [playing, deviceId, fetchSnapshot]);

  // Switching simulators or clearing the selected UDID must stop the
  // sampler — the in-flight fetch targets the old UDID and the new one
  // hasn't been primed yet.
  useEffect(() => {
    if (!deviceId) setPlaying(false);
  }, [deviceId]);

  const tapSelected = useCallback(async () => {
    if (!deviceId || selectedAt == null) return;
    setTapping(true);
    setTapStatus(null);
    try {
      const res = await fetch("/api/tap", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deviceId, at: selectedAt }),
      });
      const body = await res.json();
      if (!body.ok) throw new Error(body.error ?? "tap failed");
      setTapStatus(`Tapped @${selectedAt}`);
      // Alias @N is snapshot-local — once the tree refreshes the old
      // @N points at a different element, so carrying the selection
      // forward would silently mis-highlight. Drop it.
      setSelectedAt(null);
      // Tap almost always mutates the UI. Re-snapshot so the canvas
      // reflects the post-tap state even when auto-poll is off.
      fetchSnapshot();
    } catch (err) {
      setTapStatus(`Tap failed: ${(err as Error).message}`);
    } finally {
      setTapping(false);
    }
  }, [deviceId, selectedAt, fetchSnapshot]);

  // matchIds is null when no filter is active — downstream components
  // treat null as "everything passes" which keeps the default-happy path
  // free of per-element set lookups. Declared above the keyboard handler
  // so arrow navigation can restrict itself to filtered entries.
  const matchIds = useMemo<Set<number> | null>(() => {
    if (!snapshot) return null;
    const needle = searchTerm.trim().toLowerCase();
    const hasFilter = needle !== "" || onlyWithId || regionKey !== "";
    if (!hasFilter) return null;
    const ids = new Set<number>();
    for (const e of snapshot.entries) {
      if (onlyWithId && !e.uniqueId) continue;
      if (regionKey) {
        const key = e.region.label ? `${e.region.kind}|${e.region.label}` : e.region.kind;
        if (key !== regionKey) continue;
      }
      if (needle) {
        const hay = `${e.role} ${e.label} ${e.uniqueId ?? ""}`.toLowerCase();
        if (!hay.includes(needle)) continue;
      }
      ids.add(e.aliases.at);
    }
    return ids;
  }, [snapshot, searchTerm, onlyWithId, regionKey]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      const tag = target?.tagName;
      const inTextEditing = tag === "INPUT" || tag === "TEXTAREA";

      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        // Hijack arrows for outline navigation. Textareas and native
        // <select> pickers keep their default behavior so the search
        // input (single-line, no native arrow meaning) stays usable.
        if (tag === "TEXTAREA" || tag === "SELECT") return;
        if (!snapshot || snapshot.entries.length === 0) return;
        const navEntries =
          matchIds !== null
            ? snapshot.entries.filter((ent) => matchIds.has(ent.aliases.at))
            : snapshot.entries;
        if (navEntries.length === 0) return;
        e.preventDefault();
        const currentIdx = navEntries.findIndex((ent) => ent.aliases.at === selectedAt);
        let nextIdx: number;
        if (currentIdx < 0) {
          nextIdx = e.key === "ArrowDown" ? 0 : navEntries.length - 1;
        } else {
          nextIdx =
            e.key === "ArrowDown"
              ? Math.min(currentIdx + 1, navEntries.length - 1)
              : Math.max(currentIdx - 1, 0);
        }
        setSelectedAt(navEntries[nextIdx].aliases.at);
        return;
      }

      if (inTextEditing) return;
      if (e.key === "t") {
        if (selectedAt == null || tapping) return;
        tapSelected();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tapSelected, selectedAt, tapping, snapshot, matchIds]);

  const selectedEntry = snapshot?.entries.find((e) => e.aliases.at === selectedAt) ?? null;

  // Available regions for the filter dropdown. AX-declared ones carry a
  // label; y-band fallbacks are tagged by kind alone. Key uses both so
  // "TabBar" regions from different screens don't alias each other.
  const regionOptions = useMemo(() => {
    if (!snapshot) return [] as { key: string; display: string }[];
    const seen = new Map<string, string>();
    for (const e of snapshot.entries) {
      const key = e.region.label ? `${e.region.kind}|${e.region.label}` : e.region.kind;
      if (seen.has(key)) continue;
      seen.set(key, e.region.label ? `${e.region.kind} "${e.region.label}"` : e.region.kind);
    }
    return [...seen.entries()].map(([key, display]) => ({ key, display }));
  }, [snapshot]);

  return (
    <div className="app">
      <header className="toolbar">
        <div className="toolbar-group">
          <label>
            Device
            <select
              value={deviceId}
              onChange={(e) => {
                setDeviceId(e.target.value);
                setSnapshot(null);
                setSelectedAt(null);
                setPlaying(false);
              }}
            >
              {devices.length === 0 && <option value="">(no booted device)</option>}
              {devices.map((d) => {
                // iOS UDIDs are 36-char GUIDs; the leading 8 chars are
                // enough to disambiguate at a glance. Android serials
                // (e.g. `emulator-5554`) are already short, so show them
                // in full.
                // Pattern-match on the canonical values explicitly
                // so a future "unknown" / "web" platform doesn't
                // silently fall into the Android branch (the old
                // code's `?:` did that).
                const isIos = d.platform === "ios";
                const isAndroid = d.platform === "android";
                const shortId = isIos ? d.deviceId.slice(0, 8) : d.deviceId;
                const tag = isIos ? "iOS" : isAndroid ? "Android" : d.platform;
                return (
                  <option key={d.deviceId} value={d.deviceId}>
                    [{tag}] {d.name} — {shortId}
                  </option>
                );
              })}
            </select>
          </label>
          <button onClick={refreshDevices} title="Reload booted device list (iOS Simulators + Android emulators)">
            ↻ devices
          </button>
        </div>

        <div className="toolbar-group">
          <button
            className={`primary play-button ${playing ? "stop" : ""}`}
            onClick={togglePlay}
            disabled={!deviceId}
            title={playing ? "Stop sampling" : `Start sampling every ${intervalMs / 1000}s`}
          >
            {playing ? (
              <svg className="play-icon" viewBox="0 0 10 10" aria-hidden="true">
                <rect x="1" y="1" width="8" height="8" fill="currentColor" />
              </svg>
            ) : (
              <svg className="play-icon" viewBox="0 0 10 10" aria-hidden="true">
                <polygon points="2,1 9,5 2,9" fill="currentColor" />
              </svg>
            )}
            {playing ? "Stop" : "Play"}
          </button>
          <label>
            {playing && <span className="live-dot" aria-label="live" />}
            <select
              value={intervalMs}
              onChange={(e) => setIntervalMs(Number(e.target.value))}
            >
              <option value={1000}>1s</option>
              <option value={2000}>2s</option>
              <option value={5000}>5s</option>
            </select>
          </label>
        </div>

        <div className="toolbar-group filter">
          <input
            type="search"
            placeholder="Filter label / role / id"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
          <label className="checkbox">
            <input
              type="checkbox"
              checked={onlyWithId}
              onChange={(e) => setOnlyWithId(e.target.checked)}
            />
            has id
          </label>
          {regionOptions.length > 0 && (
            <label>
              Region
              <select value={regionKey} onChange={(e) => setRegionKey(e.target.value)}>
                <option value="">all</option>
                {regionOptions.map((r) => (
                  <option key={r.key} value={r.key}>
                    {r.display}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>

        <div className="toolbar-group meta">
          {snapshot?.capturedAt && (
            <span>captured {new Date(snapshot.capturedAt).toLocaleTimeString()}</span>
          )}
          {snapshot?.screen && (
            <span>
              {snapshot.screen.width}×{snapshot.screen.height} ·{" "}
              {matchIds
                ? `${matchIds.size} / ${snapshot.entries.length} match`
                : `${snapshot.entries.length} elements`}
            </span>
          )}
        </div>
      </header>

      {error && <div className="banner error">{error}</div>}

      <main className="main">
        <div className="canvas-pane">
          {snapshot?.screen ? (
            <Canvas
              screen={snapshot.screen}
              entries={snapshot.entries}
              selectedAt={selectedAt}
              onSelect={setSelectedAt}
              matchIds={matchIds}
              platform={snapshot.platform}
            />
          ) : (
            <div className="placeholder">
              {deviceId
                ? "No snapshot yet. Click ▶ Play to start sampling."
                : "Boot a simulator or attach an Android device, then select it above."}
            </div>
          )}
        </div>

        <aside className="side-pane">
          <Details
            snapshot={snapshot}
            selected={selectedEntry}
            onSelect={setSelectedAt}
            matchIds={matchIds}
            onTap={tapSelected}
            tapping={tapping}
            tapStatus={tapStatus}
          />
        </aside>
      </main>
    </div>
  );
}
