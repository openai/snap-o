import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent,
  type RefObject
} from "react";

const sidebarWidthStorageKey = "snapo.networkInspector.sidebarWidth.v1";
const defaultSidebarWidthRatio = 0.28;
const keyboardResizeStepPx = 16;

export const minSidebarWidthPx = 260;
export const minDetailPaneWidthPx = 360;
export const splitterWidthPx = 12;

export interface PersistentSplitPane {
  containerRef: RefObject<HTMLDivElement>;
  sidebarWidth: number;
  minSidebarWidth: number;
  maxSidebarWidth: number;
  beginResize(event: PointerEvent<HTMLDivElement>): void;
  continueResize(event: PointerEvent<HTMLDivElement>): void;
  endResize(event: PointerEvent<HTMLDivElement>): void;
  resizeWithKeyboard(event: KeyboardEvent<HTMLDivElement>): void;
}

export function usePersistentSplitPane(): PersistentSplitPane {
  const containerRef = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState(() => window.innerWidth);
  const [preferredSidebarWidth, setPreferredSidebarWidth] = useState(loadSidebarWidth);

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (container == null) return;

    const observer = new ResizeObserver((entries) => {
      const width = entries[0]?.contentRect.width;
      if (width != null) setContainerWidth(width);
    });
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    saveSidebarWidth(preferredSidebarWidth);
  }, [preferredSidebarWidth]);

  useEffect(
    () => () => {
      document.body.classList.remove("split-pane-resizing");
    },
    []
  );

  const maxSidebarWidth = useMemo(() => maxSidebarWidthFor(containerWidth), [containerWidth]);
  const sidebarWidth = clamp(preferredSidebarWidth, minSidebarWidthPx, maxSidebarWidth);

  const resizeTo = useCallback(
    (nextWidth: number) => setPreferredSidebarWidth(clamp(nextWidth, minSidebarWidthPx, maxSidebarWidth)),
    [maxSidebarWidth]
  );

  const resizeFromClientX = useCallback(
    (clientX: number) => {
      const rect = containerRef.current?.getBoundingClientRect();
      if (rect == null) return;
      resizeTo(clientX - rect.left - splitterWidthPx / 2);
    },
    [resizeTo]
  );

  const beginResize = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);
      document.body.classList.add("split-pane-resizing");
      resizeFromClientX(event.clientX);
    },
    [resizeFromClientX]
  );

  const continueResize = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      if (!event.currentTarget.hasPointerCapture(event.pointerId)) return;
      resizeFromClientX(event.clientX);
    },
    [resizeFromClientX]
  );

  const endResize = useCallback((event: PointerEvent<HTMLDivElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    document.body.classList.remove("split-pane-resizing");
  }, []);

  const resizeWithKeyboard = useCallback(
    (event: KeyboardEvent<HTMLDivElement>) => {
      switch (event.key) {
        case "ArrowLeft":
          event.preventDefault();
          resizeTo(sidebarWidth - keyboardResizeStepPx);
          break;
        case "ArrowRight":
          event.preventDefault();
          resizeTo(sidebarWidth + keyboardResizeStepPx);
          break;
        case "Home":
          event.preventDefault();
          resizeTo(minSidebarWidthPx);
          break;
        case "End":
          event.preventDefault();
          resizeTo(maxSidebarWidth);
          break;
      }
    },
    [maxSidebarWidth, resizeTo, sidebarWidth]
  );

  return {
    containerRef,
    sidebarWidth,
    minSidebarWidth: minSidebarWidthPx,
    maxSidebarWidth,
    beginResize,
    continueResize,
    endResize,
    resizeWithKeyboard
  };
}

function loadSidebarWidth(): number {
  try {
    const raw = window.localStorage.getItem(sidebarWidthStorageKey);
    const parsed = raw == null ? Number.NaN : Number.parseFloat(raw);
    if (Number.isFinite(parsed)) return parsed;
  } catch {
    // Ignore storage failures and keep the layout usable.
  }

  return defaultSidebarWidthFor(window.innerWidth);
}

function saveSidebarWidth(width: number): void {
  try {
    window.localStorage.setItem(sidebarWidthStorageKey, String(width));
  } catch {
    // Ignore storage failures and keep the layout usable.
  }
}

function defaultSidebarWidthFor(containerWidth: number): number {
  return clamp(
    Math.round(containerWidth * defaultSidebarWidthRatio),
    minSidebarWidthPx,
    maxSidebarWidthFor(containerWidth)
  );
}

function maxSidebarWidthFor(containerWidth: number): number {
  return Math.max(minSidebarWidthPx, Math.floor(containerWidth - splitterWidthPx - minDetailPaneWidthPx));
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}
