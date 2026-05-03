export function showPermissionRequest(msg, { $, state }) {
  state.pendingPermissionId = msg.id;
  const toolUse = (msg.tool_use && msg.tool_use.payload) || {};
  $("permission-title").textContent = "Allow " + (toolUse.name || "tool") + "?";
  $("permission-body").textContent = JSON.stringify(toolUse.arguments || {}, null, 2);
  $("permission-modal").classList.add("active");
}

export function answerPermission(allow, { $, state, ws }) {
  if (!state.pendingPermissionId || ws.readyState !== WebSocket.OPEN) return;
  ws.sendJSON({
    kind: "permission_decision",
    id: state.pendingPermissionId,
    allow
  });
  closePermission($);
  state.pendingPermissionId = null;
}

export function closePermission($) {
  $("permission-modal").classList.remove("active");
}

export function bindPermissionControls({ $, state, ws }) {
  $("permission-allow").addEventListener("click", () => answerPermission(true, { $, state, ws }));
  $("permission-deny").addEventListener("click", () => answerPermission(false, { $, state, ws }));
}
