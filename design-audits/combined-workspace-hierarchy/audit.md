# Combined Workspace Hierarchy Audit

## Audit scope

- Surface: Snap-O combined Capture + Network Inspector workspace.
- Evidence: `01-combined-capture-network.png`, supplied by the user on 2026-06-23.
- Goal: make two product areas read clearly even though Network Inspector contains a request list and request detail pane.
- Mode: focused UX and visual hierarchy audit.
- Historical context supplied by the user: Snap-O's capture titlebar/toolbar used a darker background before Network Inspector was merged back from the Electron app.

## Step 1 — Combined workspace

Health: Needs hierarchy clarification.

### Strengths

- Capture remains edge-to-edge and preserves the tight presentation used in capture-only mode.
- The request list and detail view use a familiar master-detail arrangement.
- Capture and network controls already occupy separate toolbar regions.
- The full-height capture boundary is correctly positioned to act as the primary workspace split.

### UX risks

1. The screen reads as three peer columns because the capture/list and list/detail boundaries have similar visual weight.
2. The request list has a noticeably different background from the detail pane, so the two Network Inspector panes feel detached.
3. The centered `Snap-O` title does not identify the right-hand region as Network Inspector.
4. The app selector is visually associated mostly with the request-list column instead of the entire Network Inspector area.
5. Toolbar ownership is inferred from position rather than made explicit through shared chrome or labeling.

### Accessibility risks

- The grouping currently depends heavily on subtle color and divider differences. Users with reduced contrast sensitivity may perceive three unrelated panes.
- Screenshot evidence cannot confirm semantic grouping, VoiceOver landmarks, keyboard traversal order, focus indicators, or divider accessibility.

## Recommended direction

Treat the layout as a nested split:

1. **Primary split: Capture | Network Inspector**
   - Keep the capture content edge-to-edge.
   - Restore the capture titlebar/toolbar's darker adaptive gray identity. In combined mode, stop that tint exactly at the Capture/Network Inspector boundary and keep the Network Inspector chrome white across both of its subpanes.
   - Do not carry the gray tint into the captured screen content, and keep it subtle enough that Capture does not appear disabled.
   - Use the full-height separator plus a very subtle right-only shadow at the capture boundary.
   - Change the right-region title from `Snap-O` to `Network Inspector` when both areas are visible.

2. **Secondary split inside Network Inspector: Requests | Detail**
   - Use a lower-contrast 1 px divider with no shadow.
   - Start this divider below the shared Network Inspector toolbar rather than extending it through the window chrome.
   - Keep list and detail backgrounds closer in tone; use only a slight navigator tint for the list.

3. **Shared Network Inspector chrome**
   - Let a single toolbar/header span both the request list and detail panes.
   - Put the app selector first as the area identity, then request actions such as clear, sort, and search.
   - Keep export/open actions aligned to the far right of the same area.

4. **Master-detail continuity**
   - Add a concise `Requests` label above the list if the shared toolbar still does not make the relationship clear.
   - Reuse method, status, and URL typography between the selected row and the detail header.
   - Keep the selected-row treatment restrained so it points to the detail pane without creating another strong surface.

## Alternative if grouping remains unclear

In combined mode only, make the request list a collapsible navigator inside Network Inspector. This produces two dominant visual regions while preserving the list on demand, but it adds interaction cost and should be attempted only after the lighter hierarchy changes.

## Evidence limits

- This audit covers one populated combined-workspace state.
- Capture-only, network-only, narrow-window, dark-mode, empty, loading, hover, focus, and resizing states were not visible.
- No claims are made about full accessibility compliance.
