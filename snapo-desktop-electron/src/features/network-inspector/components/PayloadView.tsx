import { Check, Copy } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import {
  bodyMetadata as payloadMetadata,
  dataUrlForImage,
  isImagePayload,
  parseJsonNode,
  type BodyPayload,
  type JsonNode
} from "../../../network/payload";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { copyImageToClipboard, downloadDataUrl, imageFileName } from "../lib/imageActions";
import { ContextMenu, type ContextMenuItem, type ContextMenuState } from "./ContextMenu";

export function BodySection({
  payload,
  storageKey,
  uiState
}: {
  payload: BodyPayload;
  storageKey: string;
  uiState: InspectorUiState;
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
  prettyInitiallyExpanded = true,
  embedded = false
}: {
  payload: BodyPayload;
  storageKey: string;
  uiState: InspectorUiState;
  showsToggle?: boolean;
  showsCopyButton?: boolean;
  prettyInitiallyExpanded?: boolean;
  embedded?: boolean;
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
  const controls =
    hasToggle || hasCopy ? (
      <>
        {hasToggle ? (
          <InlineTextToggle
            label={pretty ? "PRETTY" : "RAW"}
            onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)}
          />
        ) : null}
        {hasCopy ? <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} /> : null}
      </>
    ) : null;

  return (
    <div className={embedded ? "payload-view embedded" : "payload-card"}>
      {payload.prettyText == null && payload.isLikelyJson ? (
        <div className="json-parse-hint">Unable to pretty print (invalid or truncated JSON)</div>
      ) : null}
      <div className="payload-scroll">
        {jsonRoot == null ? (
          controls == null ? (
            <pre>{displayText}</pre>
          ) : (
            <div className="raw-payload-row">
              <pre>{displayText}</pre>
              <span className="raw-payload-controls">{controls}</span>
            </div>
          )
        ) : (
          <JsonOutline
            node={jsonRoot}
            storageKey={`${storageKey}:json`}
            uiState={uiState}
            initiallyExpanded={prettyInitiallyExpanded}
            trailing={controls == null ? null : <span className="json-row-trailing">{controls}</span>}
          />
        )}
      </div>
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
  label = "Copy",
  iconOnly = false
}: {
  copied: boolean;
  onCopy: () => void;
  label?: string;
  iconOnly?: boolean;
}): JSX.Element {
  const accessibleLabel = copied ? "Copied" : label;
  return (
    <button
      className={iconOnly ? "inline-action inline-action-icon" : "inline-action"}
      type="button"
      onClick={onCopy}
      aria-label={iconOnly ? accessibleLabel : undefined}
      title={iconOnly ? accessibleLabel : undefined}
    >
      {copied ? <Check size={14} /> : <Copy size={14} />}
      {iconOnly ? null : copied ? "Copied" : label}
    </button>
  );
}

export { payloadMetadata };

function JsonOutline({
  node,
  storageKey,
  uiState,
  depth = 0,
  initiallyExpanded,
  trailing
}: {
  node: JsonNode;
  storageKey: string;
  uiState: InspectorUiState;
  depth?: number;
  initiallyExpanded: boolean;
  trailing?: React.ReactNode;
}): JSX.Element {
  const [menu, setMenu] = useState<ContextMenuState | null>(null);
  const expandable = node.children.length > 0;
  const rowKey = `${storageKey}:${node.key}`;
  const expanded = expandable ? uiState.jsonExpanded(rowKey, depth === 0 ? initiallyExpanded : false) : false;
  const descendantRowKeys = useMemo(() => collectDescendantRowKeys(node, storageKey), [node, storageKey]);
  const closingSymbol = node.type === "array" ? "]" : "}";

  useEffect(() => {
    if (menu == null) return;
    const close = () => setMenu(null);
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", close);
    };
  }, [menu]);

  return (
    <div className="json-outline">
      <div
        className={trailing == null ? "json-row" : "json-row json-row-with-trailing"}
        style={{ paddingLeft: `${depth * 14}px` }}
        onContextMenu={(event) => {
          event.preventDefault();
          setMenu({
            x: event.clientX,
            y: event.clientY,
            items: jsonContextMenuItems({
              node,
              rowKey,
              descendantRowKeys,
              expanded,
              expandable,
              uiState
            })
          });
        }}
      >
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
        <JsonNodeLine node={node} expanded={expanded} />
        {trailing}
      </div>
      {menu == null ? null : <ContextMenu menu={menu} onClose={() => setMenu(null)} />}
      {expanded ? (
        <>
          {node.children.map((child) => (
            <JsonOutline
              key={child.key}
              node={child}
              storageKey={storageKey}
              uiState={uiState}
              depth={depth + 1}
              initiallyExpanded={false}
            />
          ))}
          <div className="json-row json-closing-row" style={{ paddingLeft: `${depth * 14}px` }}>
            <span className="json-toggle-spacer" />
            <span className="json-punctuation">{closingSymbol}</span>
          </div>
        </>
      ) : null}
    </div>
  );
}

function JsonNodeLine({ node, expanded }: { node: JsonNode; expanded: boolean }): JSX.Element {
  return (
    <span className="json-line">
      {node.label.length === 0 ? null : (
        <>
          <span className="json-key">{node.label}</span>
          <span className="json-punctuation json-property-separator">:</span>
        </>
      )}
      <JsonNodeValue node={node} expanded={expanded} />
    </span>
  );
}

function JsonNodeValue({ node, expanded }: { node: JsonNode; expanded: boolean }): JSX.Element {
  if (node.type === "object") {
    if (node.children.length === 0) return <span className="json-punctuation">{"{ }"}</span>;
    if (expanded) return <span className="json-punctuation">{"{"}</span>;
    return <JsonInlinePreview node={node} />;
  }
  if (node.type === "array") {
    if (node.children.length === 0) return <span className="json-punctuation">[ ]</span>;
    if (expanded) return <span className="json-punctuation">[</span>;
    return <JsonInlinePreview node={node} />;
  }
  if (node.type === "string") return <span className="json-string">{jsonQuoted(String(node.rawValue))}</span>;
  if (node.type === "number" || node.type === "boolean") {
    return <span className="json-number-bool">{String(node.rawValue)}</span>;
  }
  return <span className="json-null">null</span>;
}

function JsonInlinePreview({ node }: { node: JsonNode }): JSX.Element {
  return <span className="json-preview">{inlinePreviewParts(node, 120)}</span>;
}

function inlinePreviewParts(node: JsonNode, maxLength: number): React.ReactNode {
  const fullText = inlinePreviewText(node);
  if (fullText.length > maxLength)
    return <span className="json-punctuation">{`${fullText.slice(0, Math.max(0, maxLength - 3))}...`}</span>;
  return renderInlinePreviewNode(node);
}

function renderInlinePreviewNode(node: JsonNode): React.ReactNode {
  if (node.type === "object") {
    if (node.children.length === 0) return <span className="json-punctuation">{"{ }"}</span>;
    return (
      <>
        <span className="json-punctuation">{"{ "}</span>
        {node.children.map((child, index) => (
          <span key={child.key}>
            {index === 0 ? null : <span className="json-punctuation">, </span>}
            <span className="json-key">{jsonQuoted(child.label)}</span>
            <span className="json-punctuation">: </span>
            {renderInlinePreviewNode(child)}
          </span>
        ))}
        <span className="json-punctuation">{" }"}</span>
      </>
    );
  }
  if (node.type === "array") {
    if (node.children.length === 0) return <span className="json-punctuation">[ ]</span>;
    return (
      <>
        <span className="json-punctuation">[ </span>
        {node.children.map((child, index) => (
          <span key={child.key}>
            {index === 0 ? null : <span className="json-punctuation">, </span>}
            {renderInlinePreviewNode(child)}
          </span>
        ))}
        <span className="json-punctuation"> ]</span>
      </>
    );
  }
  if (node.type === "string") return <span className="json-string">{jsonQuoted(String(node.rawValue))}</span>;
  if (node.type === "number" || node.type === "boolean") {
    return <span className="json-number-bool">{String(node.rawValue)}</span>;
  }
  return <span className="json-null">null</span>;
}

function inlinePreviewText(node: JsonNode): string {
  if (node.type === "object") {
    if (node.children.length === 0) return "{ }";
    return `{ ${node.children.map((child) => `${jsonQuoted(child.label)}: ${inlinePreviewText(child)}`).join(", ")} }`;
  }
  if (node.type === "array") {
    if (node.children.length === 0) return "[ ]";
    return `[ ${node.children.map(inlinePreviewText).join(", ")} ]`;
  }
  if (node.type === "string") return jsonQuoted(String(node.rawValue));
  if (node.type === "number" || node.type === "boolean") return String(node.rawValue);
  return "null";
}

function jsonQuoted(value: string): string {
  return JSON.stringify(value);
}

function jsonContextMenuItems({
  node,
  rowKey,
  descendantRowKeys,
  expanded,
  expandable,
  uiState
}: {
  node: JsonNode;
  rowKey: string;
  descendantRowKeys: string[];
  expanded: boolean;
  expandable: boolean;
  uiState: InspectorUiState;
}): ContextMenuItem[] {
  const hasCollapsibleChildren = descendantRowKeys.length > 0;
  const showExpandAll =
    expandable &&
    (!expanded || descendantRowKeys.some((key) => !uiState.jsonExpanded(key, false)));
  const items: ContextMenuItem[] = [
    {
      label: "Copy Value",
      action: () => void navigator.clipboard.writeText(jsonNodeCopyText(node))
    }
  ];

  if (showExpandAll) {
    items.push({
      label: "Expand All",
      action: () => {
        uiState.setJsonExpanded(rowKey, true);
        for (const key of descendantRowKeys) uiState.setJsonExpanded(key, true);
      }
    });
  }

  if (expanded && hasCollapsibleChildren) {
    items.push({
      label: "Collapse Children",
      action: () => {
        for (const key of descendantRowKeys) uiState.setJsonExpanded(key, false);
      }
    });
  }

  return items;
}

function collectDescendantRowKeys(node: JsonNode, storageKey: string): string[] {
  const keys: string[] = [];
  for (const child of node.children) {
    if (child.children.length > 0) keys.push(`${storageKey}:${child.key}`);
    keys.push(...collectDescendantRowKeys(child, storageKey));
  }
  return keys;
}

function jsonNodeCopyText(node: JsonNode): string {
  if (node.type === "string") return String(node.rawValue);
  if (node.type === "number" || node.type === "boolean") return String(node.rawValue);
  if (node.type === "null") return "null";
  return JSON.stringify(node.rawValue, null, 2);
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
