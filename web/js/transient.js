export function createTransientHandlers(deps) {
  const {
    $, state, colors, chat,
    ensureStreamingBubble, ensureToolBubble, flushStreamingBubble,
    formatToolUseBody, makeMessageNode, scheduleRender, scheduleScroll, scrollChat,
    resetStreamingTurn
  } = deps;

  function appendTransientTimelineRow(evt) {
    const list = document.getElementById("list-timeline");
    if (!list) return;

    const row = document.createElement("div");
    row.className = "evt-row is-transient";

    const bar = document.createElement("div");
    bar.className = "evt-bar";
    bar.style.background = colors[evt.type] || "#cccac2";

    const seq = document.createElement("div");
    seq.className = "evt-seq";
    seq.textContent = "—";

    const type = document.createElement("div");
    type.className = "evt-type";
    const typeName = document.createElement("span");
    typeName.textContent = evt.type;
    const tag = document.createElement("span");
    tag.className = "tag tag-transient";
    tag.textContent = "transient";
    type.appendChild(typeName);
    type.appendChild(tag);

    const body = document.createElement("div");
    body.className = "evt-body";
    if (evt.type === "assistant_text_delta" || evt.type === "tool_use_argument_delta") {
      body.textContent = (evt.payload && evt.payload.chunk) || "";
    } else if (evt.type === "assistant_turn_started") {
      body.textContent = "turn " + ((evt.payload && evt.payload.turn_id) || "");
    } else if (evt.type === "assistant_turn_completed") {
      const usage = (evt.payload && evt.payload.usage) || {};
      body.textContent =
        "stop=" + ((evt.payload && evt.payload.stop_reason) || "?") +
        " · in=" + (usage.input_tokens || 0) +
        " out=" + (usage.output_tokens || 0);
    }

    row.appendChild(bar);
    row.appendChild(seq);
    row.appendChild(type);
    row.appendChild(body);

    list.appendChild(row);
    state.transientRows.push(row);
  }

  function clearTransientTimelineRows() {
    state.transientRows.forEach(row => row.remove());
    state.transientRows = [];
  }

  function appendTransientEvent(evt) {
    if (evt.type === "assistant_text_delta") {
      ensureStreamingBubble();
      const chunk = evt.payload.chunk || "";
      state.streamingMsgText += chunk;
      state.streamingMsgEl.querySelector(".body")
        .appendChild(document.createTextNode(chunk));
      scheduleScroll();
      state.deltaCount += 1;
      $("meta-deltas").textContent = "δ " + state.deltaCount;
      appendTransientTimelineRow(evt);
      state.streamingTurn.asstChars += chunk.length;
      scheduleRender({ strip: true });
      return;
    }
    if (evt.type === "assistant_turn_started") {
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      state.deltaCount = 0;
      $("meta-deltas").textContent = "δ 0";
      clearTransientTimelineRows();
      appendTransientTimelineRow(evt);
      resetStreamingTurn(true);
      scheduleRender({ strip: true });
      return;
    }
    if (evt.type === "assistant_turn_completed") {
      flushStreamingBubble();
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      appendTransientTimelineRow(evt);
      return;
    }
    if (evt.type === "assistant_turn_failed") {
      const node = makeMessageNode("error", (evt.payload && evt.payload.error) || "turn failed");
      chat.appendChild(node);
      scrollChat();
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      clearTransientTimelineRows();
      state.streamingTurn.active = false;
      scheduleRender({ strip: true });
      return;
    }
    if (evt.type === "tool_use_begin") {
      ensureToolBubble(evt.payload.tool_use_id, evt.payload.name);
      state.streamingTurn.toolUses[evt.payload.tool_use_id] = {
        name: evt.payload.name || "",
        chars: (evt.payload.name || "").length
      };
      scheduleRender({ strip: true });
      return;
    }
    if (evt.type === "tool_use_argument_delta") {
      const tool = ensureToolBubble(evt.payload.tool_use_id, null);
      tool.argsText += (evt.payload.chunk || "");
      const tracker = state.streamingTurn.toolUses[evt.payload.tool_use_id];
      if (tracker) tracker.chars += (evt.payload.chunk || "").length;
      scheduleRender({ strip: true });
      return;
    }
    if (evt.type === "tool_use_end") {
      const tool = state.toolBubbles[evt.payload.tool_use_id];
      if (tool) {
        tool.argsText = JSON.stringify(evt.payload.arguments || {});
        tool.el.querySelector(".body").textContent =
          formatToolUseBody(tool.name, tool.argsText);
      }
    }
  }

  function appendStreamingTurnBlocks(result) {
    if (!state.streamingTurn.active) return;
    const turn = state.streamingTurn;
    if (turn.asstChars > 0) {
      result.push({
        type: "assistant_message",
        tokens: Math.max(1, Math.ceil(turn.asstChars / 4)),
        streaming: true
      });
    }
    Object.values(turn.toolUses).forEach(toolUse => {
      result.push({
        type: "tool_use",
        tokens: Math.max(1, Math.ceil(toolUse.chars / 4)),
        streaming: true
      });
    });
  }

  return {
    appendTransientEvent,
    clearTransientTimelineRows,
    appendStreamingTurnBlocks
  };
}
