export const state = {
  log: [],
  streamingMsgEl: null,
  streamingMsgText: "",
  // Keyed by tool_use_id — each value is { el, name, argsText }
  toolBubbles: {},
  // Delta counter resets per turn and is shown in the header.
  deltaCount: 0,
  // rAF-batched render flags for expensive operations only.
  pendingFrame: null,
  dirtyTools: false,
  dirtyStrip: false,
  dirtyStats: false,
  config: null,
  pendingPermissionId: null,
  // Transient timeline rows are Observation-only UI artifacts.
  transientRows: [],
  // Streaming scratchpad used by the strip builders.
  streamingTurn: {
    active: false,
    asstChars: 0,
    toolUses: {}
  }
};

export function resetStreamingTurn(active = false) {
  state.streamingTurn = { active, asstChars: 0, toolUses: {} };
}
