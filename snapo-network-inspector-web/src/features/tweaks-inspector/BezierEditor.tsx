import { createPortal } from "react-dom";
import { useId, useLayoutEffect, useRef, useState } from "react";
import { RotateCcw, X } from "lucide-react";
import type { BezierValue, TweakValueDescriptor } from "../../network/bridge-types";
import { bezierPresets, bezierValue, moveBezier, readBezier, type BezierCoordinates } from "./bezier";
import "./bezier.css";

const graphInset = 20;
const graphExtent = 240;
const graphSize = graphExtent + 2 * graphInset;
const graphViewBox = `0 0 ${graphSize} ${graphSize}`;
const arrowDirections: Record<string, readonly [number, number]> = {
  ArrowLeft: [-1, 0],
  ArrowRight: [1, 0],
  ArrowUp: [0, 1],
  ArrowDown: [0, -1]
};

function graphPoint(x: number, y: number): readonly [number, number] {
  return [graphInset + x * graphExtent, graphInset + (1 - y) * graphExtent];
}

function curvePath([x1, y1, x2, y2]: BezierCoordinates): string {
  return `M${graphPoint(0, 0)} C${graphPoint(x1, y1)} ${graphPoint(x2, y2)} ${graphPoint(1, 1)}`;
}

export function BezierEditor({
  tweak,
  onChange,
  onReset
}: {
  tweak: TweakValueDescriptor;
  onChange(value: BezierValue): void;
  onReset?(): void;
}): JSX.Element {
  const panel = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panelId = useId();
  const [open, setOpen] = useState(false);
  const close = () => {
    setOpen(false);
    trigger.current?.focus();
  };
  useLayoutEffect(() => {
    if (!open) return;
    const position = () => {
      const anchor = trigger.current?.getBoundingClientRect();
      const element = panel.current;
      if (!anchor || !element) return;
      const { width, height } = element.getBoundingClientRect();
      const left = Math.max(8, Math.min(anchor.right - width, window.innerWidth - width - 8));
      const top = Math.max(8, Math.min(anchor.bottom + 6, window.innerHeight - height - 8));
      element.style.left = `${left}px`;
      element.style.top = `${top}px`;
    };
    const dismiss = (event: PointerEvent) => {
      if (!panel.current?.contains(event.target as Node) && !trigger.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setOpen(false);
        trigger.current?.focus();
      }
    };
    position();
    panel.current?.focus();
    window.addEventListener("resize", position);
    window.addEventListener("scroll", position, true);
    window.addEventListener("pointerdown", dismiss);
    window.addEventListener("keydown", escape);
    return () => {
      window.removeEventListener("resize", position);
      window.removeEventListener("scroll", position, true);
      window.removeEventListener("pointerdown", dismiss);
      window.removeEventListener("keydown", escape);
    };
  }, [open]);
  const value = readBezier(tweak.value);
  const drag = useRef<{ index: number; pointerId: number } | null>(null);
  if (!value) return <span>Invalid curve</span>;
  const start = graphPoint(0, 0),
    end = graphPoint(1, 1),
    p1 = graphPoint(value[0], value[1]),
    p2 = graphPoint(value[2], value[3]);
  const emit = (next: BezierCoordinates) => onChange(bezierValue(next));
  const finish = () => {
    drag.current = null;
  };
  return (
    <span>
      <button
        type="button"
        className="bezier-open"
        ref={trigger}
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        aria-label={`Edit ${tweak.name}`}
        aria-haspopup="dialog"
        title={`Edit ${tweak.name}`}
        onClick={() => setOpen((current) => !current)}
      >
        <svg viewBox={graphViewBox} aria-hidden="true">
          <path d={curvePath(value)} vectorEffect="non-scaling-stroke" />
        </svg>
      </button>
      {open &&
        typeof document !== "undefined" &&
        createPortal(
          <div
            ref={panel}
            id={panelId}
            role="dialog"
            tabIndex={-1}
            className="bezier-panel"
            aria-label={`Edit ${tweak.name}`}
          >
            <div className="bezier-heading">
              <strong>{tweak.name.split("/").pop()}</strong>
              {onReset && (
                <button
                  type="button"
                  className="toolbar-icon-button"
                  aria-label="Reset curve"
                  title="Reset curve"
                  onClick={onReset}
                >
                  <RotateCcw size={13} />
                </button>
              )}
              <button
                type="button"
                className="toolbar-icon-button"
                aria-label="Close curve editor"
                title="Close"
                onClick={close}
              >
                <X size={14} />
              </button>
            </div>
            <div className="bezier-workspace">
              <svg
                className="bezier-graph"
                viewBox={graphViewBox}
                aria-label={`${tweak.name} curve`}
                onPointerMove={(event) => {
                  const active = drag.current;
                  if (!active || active.pointerId !== event.pointerId) return;
                  const matrix = event.currentTarget.getScreenCTM();
                  if (!matrix) return;
                  const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
                  emit(
                    moveBezier(
                      value,
                      active.index,
                      (p.x - graphInset) / graphExtent,
                      1 - (p.y - graphInset) / graphExtent
                    )
                  );
                }}
                onPointerUp={finish}
                onPointerCancel={finish}
                onLostPointerCapture={finish}
              >
                <path
                  className="bezier-grid"
                  d={`M${graphPoint(0, 1)} L${start} L${graphPoint(1, 0)} M${graphPoint(0, 0.5)} L${graphPoint(1, 0.5)} M${graphPoint(0.5, 1)} L${graphPoint(0.5, 0)}`}
                />
                <path className="bezier-arm" d={`M${start} L${p1} M${end} L${p2}`} />
                <path className="bezier-line" d={curvePath(value)} />
                {[p1, p2].map((p, index) => (
                  <circle
                    key={index}
                    className={`bezier-handle bezier-handle-${index}`}
                    cx={p[0]}
                    cy={p[1]}
                    r={8}
                    tabIndex={0}
                    role="button"
                    aria-label={`${tweak.name} handle ${index + 1}: ${value[index * 2]}, ${value[index * 2 + 1]}. Use arrow keys to move.`}
                    onPointerDown={(event) => {
                      if (event.button !== 0) return;
                      event.preventDefault();
                      event.currentTarget.focus();
                      drag.current = { index, pointerId: event.pointerId };
                      event.currentTarget.ownerSVGElement?.setPointerCapture(event.pointerId);
                    }}
                    onKeyDown={(event) => {
                      const direction = arrowDirections[event.key];
                      if (!direction) return;
                      event.preventDefault();
                      const step = event.shiftKey ? 0.1 : 0.01;
                      emit(
                        moveBezier(
                          value,
                          index,
                          value[index * 2] + direction[0] * step,
                          value[index * 2 + 1] + direction[1] * step
                        )
                      );
                    }}
                  />
                ))}
              </svg>
              <div className="bezier-presets" role="group" aria-label="Curve presets">
                {Object.entries(bezierPresets).map(([name, preset]) => (
                  <button
                    key={name}
                    type="button"
                    className="bezier-preset"
                    title={name}
                    aria-label={name}
                    aria-pressed={preset.every((coordinate, index) => Math.abs(coordinate - value[index]) < 0.00001)}
                    onClick={() => emit(preset)}
                  >
                    <svg viewBox={graphViewBox} aria-hidden="true">
                      <path d={curvePath(preset)} vectorEffect="non-scaling-stroke" />
                    </svg>
                  </button>
                ))}
              </div>
              <div className="bezier-coordinates">
                {(["X1", "Y1", "X2", "Y2"] as const).map((label, i) => (
                  <label key={label} className={`bezier-coordinate-${Math.floor(i / 2)}`}>
                    {label}
                    <BezierCoordinate
                      label={`${tweak.name} ${label}`}
                      min={0}
                      max={1}
                      value={value[i]}
                      onChange={(coordinate) => {
                        const next = [...value] as [number, number, number, number];
                        next[i] = coordinate;
                        emit(next);
                      }}
                    />
                  </label>
                ))}
              </div>
            </div>
          </div>,
          document.body
        )}
    </span>
  );
}

function BezierCoordinate({
  label,
  value,
  min,
  max,
  onChange
}: {
  label: string;
  value: number;
  min?: number;
  max?: number;
  onChange(value: number): void;
}): JSX.Element {
  const [draft, setDraft] = useState({ committed: value, text: String(value) });
  const text = draft.committed === value ? draft.text : String(value);
  return (
    <input
      className="tweaks-number"
      type="number"
      aria-label={label}
      step="any"
      min={min}
      max={max}
      value={text}
      onChange={(event) => {
        const next = event.currentTarget.valueAsNumber;
        const valid = event.currentTarget.validity.valid && Number.isFinite(Math.fround(next));
        setDraft({ committed: valid ? next : value, text: event.currentTarget.value });
        if (valid) onChange(next);
      }}
      onBlur={() => setDraft({ committed: value, text: String(value) })}
    />
  );
}
