import { Check, Copy } from "lucide-react";
import { useMemo } from "react";
import {
  bodyMetadata as payloadMetadata,
  dataUrlForImage,
  isImagePayload,
  parseJsonNode,
  type BodyPayload,
  type JsonNode
} from "../../../network/payload";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";
import { copyImageToClipboard, downloadDataUrl, imageFileName } from "../lib/imageActions";

export function BodySection({
  payload,
  storageKey,
  uiState
}: {
  payload: BodyPayload;
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  if (isImagePayload(payload)) return <ImagePreview payload={payload} />;
  return <PayloadView payload={payload} storageKey={storageKey} uiState={uiState} prettyInitiallyExpanded />;
}

export function PayloadView({
  payload,
  storageKey,
  uiState,
  showsToggle = true,
  showsCopyButton = true,
  prettyInitiallyExpanded = true
}: {
  payload: BodyPayload;
  storageKey: string;
  uiState: PersistentInspectorUiState;
  showsToggle?: boolean;
  showsCopyButton?: boolean;
  prettyInitiallyExpanded?: boolean;
}): JSX.Element {
  const defaultPretty = payload.prettyText != null;
  const pretty = uiState.prettyEnabled(storageKey, defaultPretty);
  const displayText = pretty && payload.prettyText != null ? payload.prettyText : payload.rawText;
  const jsonRoot = useMemo(
    () => (pretty && payload.prettyText != null ? parseJsonNode(payload.prettyText) : null),
    [payload.prettyText, pretty]
  );
  const copyFeedback = useCopyFeedback(displayText);
  const hasToggle = showsToggle && payload.prettyText != null;
  const hasCopy = showsCopyButton && displayText.length > 0;

  return (
    <div className="payload-card">
      {hasToggle || hasCopy ? (
        <div className="payload-controls">
          {hasToggle ? (
            <InlineTextToggle label={pretty ? "PRETTY" : "RAW"} onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)} />
          ) : null}
          {hasCopy ? <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} /> : null}
        </div>
      ) : null}
      {payload.prettyText == null && payload.isLikelyJson ? (
        <div className="json-parse-hint">Unable to pretty print (invalid or truncated JSON)</div>
      ) : null}
      {jsonRoot == null ? (
        <pre>{displayText}</pre>
      ) : (
        <JsonOutline node={jsonRoot} storageKey={`${storageKey}:json`} uiState={uiState} initiallyExpanded={prettyInitiallyExpanded} />
      )}
    </div>
  );
}

export function InlineTextToggle({ label, onClick }: { label: string; onClick: () => void }): JSX.Element {
  return (
    <button className="inline-text-toggle" type="button" onClick={onClick}>
      {label}
    </button>
  );
}

export function InlineCopyButton({
  copied,
  onCopy,
  label = "Copy"
}: {
  copied: boolean;
  onCopy: () => void;
  label?: string;
}): JSX.Element {
  return (
    <button className="inline-action" type="button" onClick={onCopy}>
      {copied ? <Check size={14} /> : <Copy size={14} />}
      {copied ? "Copied" : label}
    </button>
  );
}

export { payloadMetadata };

function JsonOutline({
  node,
  storageKey,
  uiState,
  depth = 0,
  initiallyExpanded
}: {
  node: JsonNode;
  storageKey: string;
  uiState: PersistentInspectorUiState;
  depth?: number;
  initiallyExpanded: boolean;
}): JSX.Element {
  const expandable = node.children.length > 0;
  const rowKey = `${storageKey}:${node.key}`;
  const expanded = expandable ? uiState.jsonExpanded(rowKey, depth === 0 ? initiallyExpanded : false) : false;
  return (
    <div className="json-outline">
      <div className="json-row" style={{ paddingLeft: `${depth * 14}px` }}>
        {expandable ? (
          <button
            className="json-toggle"
            type="button"
            onClick={() => uiState.setJsonExpanded(rowKey, !expanded)}
            aria-label={expanded ? "Collapse JSON node" : "Expand JSON node"}
          >
            <span className={expanded ? "triangle expanded" : "triangle"} />
          </button>
        ) : (
          <span className="json-toggle-spacer" />
        )}
        <span className="json-key">{node.label}</span>
        {node.valuePreview == null ? null : <span className="json-preview">{node.valuePreview}</span>}
      </div>
      {expanded
        ? node.children.map((child) => (
            <JsonOutline
              key={child.key}
              node={child}
              storageKey={storageKey}
              uiState={uiState}
              depth={depth + 1}
              initiallyExpanded={false}
            />
          ))
        : null}
    </div>
  );
}

function ImagePreview({ payload }: { payload: BodyPayload }): JSX.Element | null {
  const dataUrl = dataUrlForImage(payload);
  const copyFeedback = useCopyFeedback("image");
  const saveFeedback = useCopyFeedback("save-image");
  if (dataUrl == null) return null;
  return (
    <div className="image-preview-card">
      <div className="image-preview-header">
        <span>Image preview</span>
        <span className="image-content-type">{payload.contentType?.toUpperCase() ?? ""}</span>
      </div>
      <div className="image-actions">
        <InlineCopyButton
          copied={copyFeedback.copied}
          label="Copy Image"
          onCopy={() => {
            copyFeedback.copyWithoutClipboard();
            void copyImageToClipboard(dataUrl, payload.contentType ?? "image/png");
          }}
        />
        <InlineTextToggle
          label={saveFeedback.copied ? "SAVED" : "SAVE AS..."}
          onClick={() => {
            saveFeedback.copyWithoutClipboard();
            downloadDataUrl(dataUrl, imageFileName(payload.contentType));
          }}
        />
      </div>
      <img className="image-preview" src={dataUrl} alt="" />
    </div>
  );
}
