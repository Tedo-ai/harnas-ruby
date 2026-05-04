  import { resetStreamingTurn, state } from "./state.js";
  import "./observation.js";
  import "./chat.js";
  import "./strip.js";
  import "./timeline.js";
  import "./config-panel.js";
  import {
    bindPermissionControls,
    closePermission,
    showPermissionRequest
  } from "./permission.js";
  import { createTransientHandlers } from "./transient.js";
  import { connectWebSocket } from "./ws.js";

  const COLORS = {
    user_message:            "#4a6da3",
    assistant_message:       "#8a6d3b",
    assistant_text_delta:    "#8a6d3b",
    tool_use:                "#a36b3a",
    tool_use_begin:          "#a36b3a",
    tool_use_argument_delta: "#a36b3a",
    tool_use_end:            "#a36b3a",
    tool_result:             "#4f8569",
    summary:                 "#8b8b85",
    annotation:              "#7b6f90",
    provider_error:          "#b04a3a",
    runtime_error:           "#b04a3a",
    fork:                    "#7b6f90",
    assistant_turn_started:  "#cccac2",
    assistant_turn_completed:"#cccac2",
    assistant_turn_failed:   "#b04a3a"
  };
  const MESSAGE_TYPES = new Set([
    "user_message", "assistant_message", "tool_use", "tool_result", "summary"
  ]);

  const $ = (id) => document.getElementById(id);
  const chat = $("chat");
  const events = $("events");
  const stripEl     = $("strip");
  const stripToggle = $("strip-toggle");
  // Which view the single strip is showing: "context" or "timeline".
  let stripView = "context";
  stripToggle.addEventListener("click", () => {
    stripView = stripView === "context" ? "timeline" : "context";
    stripToggle.textContent = stripView;
    redrawStrip();
  });
  const status = $("status");
  const input = $("input");
  const sendBtn = $("send");

  const wsUrl = (location.protocol === "https:" ? "wss" : "ws") + "://" + location.host + "/";
  function setStatus(cls, text) {
    status.className = "status " + cls;
    status.textContent = text;
  }

  const ws = connectWebSocket({ url: wsUrl, onMessage, setStatus });
  const transient = createTransientHandlers({
    $, state, colors: COLORS, chat,
    ensureStreamingBubble, ensureToolBubble, flushStreamingBubble,
    formatToolUseBody, makeMessageNode, scheduleRender, scheduleScroll, scrollChat,
    resetStreamingTurn
  });

  sendBtn.addEventListener("click", send);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      send();
    } else if (e.key === "Enter" && !e.shiftKey) {
      send();
    }
  });
  bindPermissionControls({ $, state, ws });
  $("help-close").addEventListener("click", closeHelp);
  document.addEventListener("keydown", handleKeybindings);

  // Main tab switcher.
  function switchTab(target, options = {}) {
    document.querySelectorAll("#main-tabs .tab").forEach(b => {
      b.classList.toggle("active", b.dataset.tab === target);
    });
    document.querySelectorAll(".tab-panel").forEach(p => {
      p.classList.toggle("active", p.dataset.panel === target);
    });
    if (options.highlightSeq != null) {
      highlightEventRow(target, options.highlightSeq);
    }
  }
  document.querySelectorAll("#main-tabs .tab").forEach(btn => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab));
  });

  function highlightEventRow(target, seq) {
    if (target !== "context" && target !== "timeline") return;
    const list = document.getElementById("list-" + target);
    if (!list) return;
    // Defer so the panel's display:flex has taken effect and layout is valid.
    requestAnimationFrame(() => {
      list.querySelectorAll(".evt-row.highlight").forEach(el => el.classList.remove("highlight"));
      const row = list.querySelector('.evt-row[data-seq="' + seq + '"]');
      if (row) {
        row.classList.add("highlight");
        row.scrollIntoView({ block: "center", behavior: "smooth" });
      }
    });
  }

  function send() {
    const text = input.value.trim();
    if (!text || ws.readyState !== WebSocket.OPEN) return;
    ws.sendJSON({ kind: "user_message", text });
    input.value = "";
  }

  function onMessage(msg) {
    if (msg.kind === "hello") {
      renderProviderSelect(msg.providers || [], msg.provider);
      $("meta-model").textContent = msg.model;
      renderConfig(msg.config);
      // Reset and replay the full log
      state.log = [];
      chat.innerHTML = "";
      msg.log.forEach(evt => appendLogEvent(evt));
      scheduleRender({ bubble: true, strip: true, stats: true });
      return;
    }
    if (msg.kind === "config_changed") {
      renderConfig(msg.config);
      addInspector("system", "configuration updated");
      return;
    }
    if (msg.kind === "permission_request") {
      showPermissionRequest(msg, { $, state });
      return;
    }
    if (msg.kind === "provider_changed") {
      // Server confirms the switch; reflect in the UI.
      $("meta-model").textContent = msg.model;
      $("provider-select").value = msg.provider;
      renderConfig(msg.config);
      addInspector("system", "provider → " + msg.label);
      return;
    }
    if (msg.kind === "system") { addInspector("system", msg.message); return; }
    if (msg.kind === "error")  { addInspector("error",  msg.message); showToast(msg.message, "error"); return; }
    if (msg.kind !== "observation") return;

    handleObservation(msg.event_name, msg.payload);
  }

  function handleKeybindings(e) {
    const mod = e.metaKey || e.ctrlKey;
    if (mod && e.key === "Enter") {
      e.preventDefault();
      send();
      return;
    }
    if (mod && e.key.toLowerCase() === "s") {
      e.preventDefault();
      saveSession();
      return;
    }
    if (mod && e.key.toLowerCase() === "k") {
      e.preventDefault();
      input.focus();
      return;
    }
    if (e.key === "Escape") {
      closePermission($);
      closeHelp();
      return;
    }
    if (e.key === "?" && !/input|textarea|select/i.test(document.activeElement.tagName)) {
      e.preventDefault();
      $("help-modal").classList.remove("hidden");
    }
  }

  function closeHelp() {
    $("help-modal").classList.add("hidden");
  }

  function showToast(message, kind = "system") {
    const root = $("toast-root");
    if (!root) return;
    const el = document.createElement("div");
    el.className = "toast " + kind;
    el.textContent = message;
    root.appendChild(el);
    setTimeout(() => el.remove(), 6000);
  }

  // ──── harness configuration panel ────
  const STRATEGIES = {
    "Compaction::MarkerTail": {
      title: "MarkerTail",
      family: "Compaction",
      description: "Replaces older messages with a compact marker once the message count crosses a limit.",
      when: "Use for cheap, deterministic context trimming when exact old content can be omitted.",
      help: "Spec §05 Compaction. Tail selection keeps the recent end of the conversation.",
      fields: [
        { key: "max_messages", label: "max messages", type: "int", value: 20, help: "Compact once visible messages exceed this count." },
        { key: "keep_recent", label: "keep recent", type: "int", value: 10, help: "Number of newest messages to keep verbatim." }
      ]
    },
    "Compaction::SummaryTail": {
      title: "SummaryTail",
      family: "Compaction",
      description: "Replaces older messages with an LLM-generated summary.",
      when: "Use when fidelity matters and you can afford an extra round-trip per compaction.",
      help: "Spec §05 Compaction. SummaryTail spawns a provider call to create the replacement summary.",
      fields: [
        { key: "max_messages", label: "max messages", type: "int", value: 24, help: "Summarize once visible messages exceed this count." },
        { key: "keep_recent", label: "keep recent", type: "int", value: 12, help: "Number of newest messages to keep verbatim." }
      ]
    },
    "Compaction::TokenMarkerTail": {
      title: "TokenMarkerTail",
      family: "Compaction",
      description: "Uses estimated token pressure rather than message count, then replaces older messages with a marker.",
      when: "Use for long mixed-size conversations where message count is a poor proxy for context cost.",
      help: "Spec §05 Compaction. The threshold is a fraction of max_tokens.",
      fields: [
        { key: "max_tokens", label: "max tokens", type: "int", value: 100000, help: "Nominal context budget used by the trigger." },
        { key: "threshold", label: "threshold", type: "threshold", value: 0.85, help: "Trigger when estimated tokens exceed this fraction of max_tokens." },
        { key: "keep_recent", label: "keep recent", type: "int", value: 10, help: "Number of newest messages to keep verbatim." }
      ]
    },
    "Compaction::ToolOutputCap": {
      title: "ToolOutputCap",
      family: "Compaction",
      description: "Caps oversized tool results while preserving a prefix for context.",
      when: "Use for coding agents that may read or generate very large files.",
      help: "Spec §05 Compaction. This strategy targets tool_result payload size.",
      fields: [
        { key: "max_bytes", label: "max bytes", type: "int", value: 4096, help: "Tool outputs larger than this are capped." },
        { key: "prefix_bytes", label: "prefix bytes", type: "int", value: 1024, help: "Bytes to keep from the beginning of capped output." }
      ]
    },
    "Permission::HumanApproval": {
      title: "HumanApproval",
      family: "Permission",
      description: "Pauses tool execution and asks the browser user to allow or deny selected tools.",
      when: "Use for destructive tools like shell commands or file writes.",
      help: "Permission strategy. The Log records the resulting tool_result decision.",
      fields: [{ key: "tools", label: "gated tools", type: "tools", value: "" }]
    }
  };

  const TOOL_GROUPS = [
    { label: "Read-only", names: ["read_file", "list_dir", "glob", "grep"], note: "Safe context gathering." },
    { label: "File-mutating", names: ["write_file", "edit_file"], note: "Gated by HumanApproval when active.", destructive: true },
    { label: "Shell", names: ["run_shell"], note: "Gated by HumanApproval when active.", destructive: true },
    { label: "Network", names: ["fetch_url"], note: "External reads." }
  ];
  const READ_ONLY_TOOLS = ["read_file", "list_dir", "glob", "grep"];
  const DESTRUCTIVE_TOOLS = ["run_shell", "write_file", "edit_file"];
  const SYSTEM_PROMPTS = {
    blank: "",
    coding: "You are a careful coding assistant. Inspect the repository before changing code, keep edits scoped, run the relevant checks, and explain the result clearly.",
    general: "You are a concise, helpful assistant. Answer directly, ask only when blocked, and keep enough context visible for the user to trust the result.",
    qa: "You are a code QA agent. Prioritize bugs, regressions, edge cases, missing tests, and concrete file/line findings over broad commentary."
  };
  let configPresets = null;

  function renderConfig(cfg) {
    state.config = cfg;
    const root = $("config");
    root.innerHTML = "";
    if (!cfg) return;

    renderConfigControls(root, cfg);
    ensurePresetsLoaded();
  }

  function renderConfigControls(root, cfg) {
    const enabledTools = (cfg.tools || []).filter(t => t.enabled).length;
    const strategies = strategiesFromConfig(cfg);
    const summary = document.createElement("div");
    summary.className = "cfg-summary";
    summary.textContent =
      `${cfg.provider.kind}/${cfg.provider.model} · ${enabledTools} tools · ` +
      `${strategies.length} strategies · system prompt: ${(cfg.system_prompt || "").length} chars`;
    root.appendChild(summary);

    const presets = section("Presets", "One-click starting points. You can adjust every choice after applying.");
    const presetRow = document.createElement("div");
    presetRow.className = "preset-row";
    (configPresets || fallbackPresets()).forEach(preset => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "preset-button";
      button.innerHTML = `<strong></strong><span></span>`;
      button.querySelector("strong").textContent = preset.label;
      button.querySelector("span").textContent = preset.description || "";
      button.onclick = () => applyPreset(preset);
      presetRow.appendChild(button);
    });
    presets.appendChild(presetRow);
    root.appendChild(presets);

    root.appendChild(renderProviderModelSection(cfg));
    root.appendChild(renderSystemSection(cfg));
    root.appendChild(renderToolsSection(cfg));
    root.appendChild(renderStrategiesSection(cfg, strategies));
    root.appendChild(renderSessionSection());

    $("cfg-save").onclick = saveSession;
    $("cfg-load").onchange = loadSession;
    loadSessionLibrary();
  }

  function renderProviderModelSection(cfg) {
    const box = section("Provider & Model", "Switch the provider for the next turn and override the model sent in projections.");
    box.innerHTML += `
      <div class="cfg-grid-two">
        <label>provider<select id="cfg-provider"></select></label>
        <label>model<input id="cfg-model" type="text"></label>
      </div>
      <button id="cfg-model-save" type="button">apply provider/model</button>`;
    const provider = box.querySelector("#cfg-provider");
    document.querySelectorAll("#provider-select option").forEach(opt => {
      const copy = opt.cloneNode(true);
      copy.selected = opt.value === cfg.provider.kind;
      provider.appendChild(copy);
    });
    box.querySelector("#cfg-model").value = cfg.provider.model || "";
    box.querySelector("#cfg-model-save").onclick = () => {
      const selected = box.querySelector("#cfg-provider").value;
      const model = box.querySelector("#cfg-model").value.trim();
      if (selected && selected !== cfg.provider.kind) ws.sendJSON({ kind: "set_provider", provider: selected });
      if (model) ws.sendJSON({ kind: "set_model", provider: selected || cfg.provider.kind, model });
      showToast("provider configuration queued");
    };
    return box;
  }

  function renderSystemSection(cfg) {
    const box = section("System prompt", "Set behavior that every provider projection includes with the conversation.");
    box.innerHTML += `
      <label>preset
        <select id="cfg-system-preset">
          <option value="">choose a prompt…</option>
          <option value="coding">coding assistant</option>
          <option value="general">general assistant</option>
          <option value="qa">QA agent</option>
          <option value="blank">blank</option>
        </select>
      </label>
      <label>prompt<textarea id="cfg-system"></textarea></label>
      <div class="cfg-inline-meta">
        <span id="cfg-system-count">0 chars</span>
        <span id="cfg-system-warning"></span>
      </div>
      <div class="cfg-actions">
        <button id="cfg-system-save" type="button">apply prompt</button>
        <button id="cfg-system-revert" type="button" class="secondary">revert to default</button>
      </div>`;
    const textarea = box.querySelector("#cfg-system");
    const count = box.querySelector("#cfg-system-count");
    const warning = box.querySelector("#cfg-system-warning");
    const updateCount = () => {
      const chars = textarea.value.length;
      count.textContent = `${chars} chars`;
      warning.textContent = chars >= 4000 ? "very long prompts increase per-turn token cost" : "";
    };
    textarea.value = cfg.system_prompt || "";
    textarea.addEventListener("input", updateCount);
    updateCount();
    box.querySelector("#cfg-system-preset").onchange = (e) => {
      if (!e.target.value) return;
      textarea.value = SYSTEM_PROMPTS[e.target.value] || "";
      updateCount();
    };
    box.querySelector("#cfg-system-save").onclick = () => {
      ws.sendJSON({ kind: "set_system_prompt", text: textarea.value });
      showToast("system prompt applied");
    };
    box.querySelector("#cfg-system-revert").onclick = () => {
      textarea.value = "";
      updateCount();
      ws.sendJSON({ kind: "set_system_prompt", text: "" });
      showToast("system prompt cleared");
    };
    return box;
  }

  function renderToolsSection(cfg) {
    const box = section("Tools", "Enable the tools this session may expose to the model.");
    const actions = document.createElement("div");
    actions.className = "cfg-actions";
    actions.appendChild(actionButton("enable all", () => setToolSet((cfg.tools || []).map(t => t.name))));
    actions.appendChild(actionButton("disable destructive", () => {
      const names = (cfg.tools || []).filter(t => !DESTRUCTIVE_TOOLS.includes(t.name)).map(t => t.name);
      setToolSet(names);
    }));
    actions.appendChild(actionButton("minimal read-only set", () => setToolSet(READ_ONLY_TOOLS)));
    box.appendChild(actions);

    const byName = Object.fromEntries((cfg.tools || []).map(t => [t.name, t]));
    TOOL_GROUPS.forEach(group => {
      const groupEl = document.createElement("div");
      groupEl.className = "tool-group";
      groupEl.innerHTML = `<div class="tool-group-head"><strong></strong><span></span></div>`;
      groupEl.querySelector("strong").textContent = group.label;
      groupEl.querySelector("span").textContent = group.note;
      group.names.forEach(name => {
        const t = byName[name];
        if (!t) return;
        const wrap = document.createElement("label");
        wrap.className = "tool-toggle";
        const enabled = document.createElement("input");
        enabled.type = "checkbox";
        enabled.checked = !!t.enabled;
        enabled.onchange = () => toggleTool(t.name, enabled.checked);
        const text = document.createElement("span");
        text.innerHTML = '<strong></strong> <span class="safety"></span><span class="detail"></span>';
        text.querySelector("strong").textContent = t.name;
        const safety = text.querySelector(".safety");
        if (t.approval_required) {
          safety.textContent = "gated";
          safety.title = "Permission::HumanApproval gates this tool.";
        } else if (t.destructive || group.destructive) {
          safety.textContent = "destructive";
          safety.classList.add("warn");
        }
        text.querySelector(".detail").textContent = t.description || "";
        wrap.appendChild(enabled);
        wrap.appendChild(text);
        groupEl.appendChild(wrap);
      });
      box.appendChild(groupEl);
    });
    return box;
  }

  function renderStrategiesSection(cfg, strategies) {
    const box = section("Strategies", "Install compaction and permission behavior on this Session.");
    const active = document.createElement("div");
    active.className = "active-strategies";
    active.innerHTML = "<div class=\"cfg-mini-title\">active</div>";
    if (strategies.length === 0) {
      const empty = document.createElement("p");
      empty.className = "cfg-note";
      empty.textContent = "No strategies installed.";
      active.appendChild(empty);
    } else {
      strategies.forEach(s => active.appendChild(strategyCard(s)));
    }
    box.appendChild(active);

    const install = document.createElement("div");
    install.className = "strategy-install";
    install.innerHTML = `
      <div class="cfg-mini-title">install strategy</div>
      <label>strategy<select id="cfg-strategy"></select></label>
      <div id="cfg-strategy-copy" class="strategy-copy"></div>
      <div id="cfg-strategy-fields" class="cfg-grid-two"></div>
      <div id="cfg-strategy-error" class="cfg-error"></div>
      <p class="cfg-note">Installing multiple strategies in the same family registers both on :pre_projection; the first-registered one wins on overlapping ranges. To compare, install one at a time.</p>
      <button id="cfg-install-strategy" type="button">install</button>`;
    box.appendChild(install);

    const select = install.querySelector("#cfg-strategy");
    Object.entries(STRATEGIES).forEach(([name, meta]) => {
      const opt = document.createElement("option");
      opt.value = name;
      opt.textContent = `${meta.family} · ${meta.title}`;
      select.appendChild(opt);
    });
    const refresh = () => renderStrategyFields(select.value, install);
    select.addEventListener("change", refresh);
    refresh();
    install.querySelector("#cfg-install-strategy").onclick = () => installStrategyFromForm();
    return box;
  }

  function renderSessionSection() {
    const box = section("Session", "Save the durable Log or load a previous web-monitor run.");
    box.innerHTML += `
      <div class="cfg-actions">
        <button id="cfg-save" type="button">save session</button>
        <input id="cfg-load" type="file" accept=".jsonl,application/jsonl,text/plain">
      </div>
      <div id="cfg-save-result" class="detail"></div>
      <div class="cfg-mini-title">session library</div>
      <div id="cfg-sessions" class="session-list empty">loading…</div>`;
    return box;
  }

  function installStrategyFromForm() {
    const name = $("cfg-strategy").value;
    if (!validateStrategyForm(name)) return;
    let config = {};
    STRATEGIES[name].fields.forEach(field => {
      if (field.type === "tools") {
        config.tools = checkedStrategyTools();
      } else {
        config[field.key] = field.type === "threshold"
          ? Number($(`cfg-field-${field.key}`).value)
          : Number.parseInt($(`cfg-field-${field.key}`).value, 10);
      }
    });
    if (name === "Permission::HumanApproval") {
      ws.sendJSON({ kind: "set_permission_tools", names: config.tools });
    }
    ws.sendJSON({ kind: "install_strategy", name: name, config: config });
    showToast(`installing ${STRATEGIES[name].title}`);
  }

  function section(title, description) {
    const box = document.createElement("section");
    box.className = "cfg-section";
    const header = document.createElement("div");
    header.className = "cfg-section-header";
    header.innerHTML = "<h3></h3><p></p>";
    header.querySelector("h3").textContent = title;
    header.querySelector("p").textContent = description;
    box.appendChild(header);
    return box;
  }

  function actionButton(label, fn) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.onclick = fn;
    return button;
  }

  function strategiesFromConfig(cfg) {
    return (cfg.strategies_installed || []).map((s, i) => {
      const label = typeof s === "string" ? s : (s.label || String(s));
      const name = Object.keys(STRATEGIES).find(key => label.startsWith(key)) || label.split("(")[0];
      return {
        index: typeof s === "object" && s.index != null ? s.index : i,
        label,
        name,
        title: STRATEGIES[name] ? STRATEGIES[name].title : name,
        configText: label.includes("(") ? label.slice(label.indexOf("(") + 1, -1) : ""
      };
    });
  }

  function strategyCard(strategy) {
    const card = document.createElement("div");
    card.className = "strategy-card";
    const meta = STRATEGIES[strategy.name] || {};
    card.innerHTML = `
      <div>
        <strong title=""></strong>
        <span></span>
      </div>
      <button type="button" title="uninstall strategy">×</button>`;
    card.querySelector("strong").textContent = strategy.name;
    card.querySelector("strong").title = meta.help || "";
    card.querySelector("span").textContent = strategy.configText || meta.description || "";
    card.querySelector("button").onclick = () => ws.sendJSON({
      kind: "uninstall_strategy",
      index: strategy.index
    });
    return card;
  }

  function renderStrategyFields(name, scope = document) {
    const meta = STRATEGIES[name];
    const copy = scope.querySelector("#cfg-strategy-copy");
    const fields = scope.querySelector("#cfg-strategy-fields");
    copy.innerHTML = `<p>${meta.description}</p><p><strong>When:</strong> ${meta.when} <span class="help-dot" tabindex="0" title="${meta.help}">?</span></p>`;
    fields.innerHTML = "";
    meta.fields.forEach(field => {
      if (field.type === "tools") {
        fields.appendChild(renderStrategyToolPicker());
        return;
      }
      const label = document.createElement("label");
      label.innerHTML = `<span></span><input id="cfg-field-${field.key}" type="${field.type === "threshold" ? "text" : "number"}" value="${field.value}"><small></small>`;
      label.querySelector("span").textContent = field.label;
      label.querySelector("span").title = field.help;
      label.querySelector("small").textContent = field.help;
      label.querySelector("input").addEventListener("input", () => validateStrategyForm(name));
      fields.appendChild(label);
    });
    validateStrategyForm(name, scope);
  }

  function renderStrategyToolPicker() {
    const wrap = document.createElement("div");
    wrap.className = "strategy-tool-picker";
    wrap.innerHTML = "<div class=\"cfg-mini-title\">tools to gate</div>";
    (state.config.tools || []).forEach(tool => {
      const label = document.createElement("label");
      label.className = "tool-toggle";
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.value = tool.name;
      checkbox.checked = tool.approval_required || DESTRUCTIVE_TOOLS.includes(tool.name);
      const span = document.createElement("span");
      span.textContent = tool.name;
      label.appendChild(checkbox);
      label.appendChild(span);
      wrap.appendChild(label);
    });
    return wrap;
  }

  function validateStrategyForm(name, scope = document) {
    const meta = STRATEGIES[name];
    const error = scope.querySelector("#cfg-strategy-error");
    const install = scope.querySelector("#cfg-install-strategy");
    if (!meta || !error || !install) return false;

    const messages = [];
    meta.fields.forEach(field => {
      if (field.type === "tools") {
        if (checkedStrategyTools().length === 0) messages.push("Choose at least one tool to gate.");
        return;
      }
      const input = scope.querySelector(`#cfg-field-${field.key}`);
      const value = Number(input.value);
      let ok = Number.isFinite(value);
      if (field.type === "threshold") ok = ok && value > 0 && value < 1;
      else ok = ok && Number.isInteger(value) && value > 0;
      input.classList.toggle("invalid", !ok);
      if (!ok) {
        messages.push(field.type === "threshold"
          ? `${field.label} must be greater than 0 and less than 1.`
          : `${field.label} must be a positive integer.`);
      }
    });
    error.textContent = messages.join(" ");
    install.disabled = messages.length > 0;
    return messages.length === 0;
  }

  function checkedStrategyTools() {
    return Array.from(document.querySelectorAll(".strategy-tool-picker input:checked"))
      .map(input => input.value);
  }

  function toggleTool(name, enabled) {
    if (state.streamingTurn.active) showToast("tool is in use, change will apply next turn");
    ws.sendJSON({ kind: "toggle_tool", name, enabled });
  }

  function setToolSet(names) {
    const wanted = new Set(names);
    if (state.streamingTurn.active) showToast("tool is in use, change will apply next turn");
    (state.config.tools || []).forEach(tool => {
      if (!!tool.enabled !== wanted.has(tool.name)) {
        ws.sendJSON({ kind: "toggle_tool", name: tool.name, enabled: wanted.has(tool.name) });
      }
    });
  }

  async function ensurePresetsLoaded() {
    if (configPresets) return;
    try {
      const res = await fetch("/presets.json");
      const data = await res.json();
      configPresets = data.presets || [];
      if (state.config) renderConfig(state.config);
    } catch (_e) {
      configPresets = fallbackPresets();
    }
  }

  function fallbackPresets() {
    return [
      {
        id: "coder", label: "Coder agent", description: "Coding prompt, all tools, approval on destructive tools.",
        system_prompt: SYSTEM_PROMPTS.coding,
        enabled_tools: "all",
        permission_tools: DESTRUCTIVE_TOOLS,
        strategies: [{ name: "Compaction::MarkerTail", config: { max_messages: 20, keep_recent: 10 } }]
      },
      {
        id: "conversation", label: "Conversation", description: "Small read-only surface for lightweight chat.",
        system_prompt: "",
        enabled_tools: ["read_file", "glob"],
        permission_tools: [],
        strategies: []
      },
      {
        id: "qa", label: "QA agent", description: "Read-only code review with summary compaction.",
        system_prompt: SYSTEM_PROMPTS.qa,
        enabled_tools: READ_ONLY_TOOLS,
        permission_tools: [],
        strategies: [{ name: "Compaction::SummaryTail", config: { max_messages: 24, keep_recent: 12 } }]
      },
      {
        id: "blank", label: "Blank", description: "Clear prompt, tools, and strategies.",
        system_prompt: "",
        enabled_tools: [],
        permission_tools: [],
        strategies: []
      }
    ];
  }

  function applyPreset(preset) {
    const tools = preset.enabled_tools === "all"
      ? (state.config.tools || []).map(t => t.name)
      : (preset.enabled_tools || []);
    strategiesFromConfig(state.config).slice().reverse().forEach(strategy => {
      ws.sendJSON({ kind: "uninstall_strategy", index: strategy.index });
    });
    ws.sendJSON({ kind: "set_system_prompt", text: preset.system_prompt || "" });
    (state.config.tools || []).forEach(tool => {
      ws.sendJSON({ kind: "toggle_tool", name: tool.name, enabled: tools.includes(tool.name) });
    });
    ws.sendJSON({ kind: "set_permission_tools", names: preset.permission_tools || [] });
    (preset.strategies || []).forEach(strategy => {
      ws.sendJSON({ kind: "install_strategy", name: strategy.name, config: strategy.config || {} });
    });
    if ((preset.permission_tools || []).length) {
      ws.sendJSON({ kind: "install_strategy", name: "Permission::HumanApproval", config: { tools: preset.permission_tools } });
    }
    showToast(`Applied preset: ${preset.label}`);
  }

  async function saveSession() {
    const btn = $("cfg-save");
    if (btn) {
      btn.disabled = true;
      btn.textContent = "saving…";
    }
    try {
      const res = await fetch("/save", { method: "POST" });
      const data = await res.json();
      $("cfg-save-result").textContent = data.path || "saved";
      showToast("session saved");
      loadSessionLibrary();
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = "save session";
      }
    }
  }

  async function loadSession(e) {
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    const body = await file.text();
    await fetch("/load", { method: "POST", body: body });
    e.target.value = "";
    showToast("session loaded");
    loadSessionLibrary();
  }

  async function loadSavedSession(path) {
    await fetch("/load", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path })
    });
    showToast("session loaded");
    loadSessionLibrary();
  }

  async function loadSessionLibrary() {
    const root = $("cfg-sessions");
    if (!root) return;
    try {
      const res = await fetch("/sessions");
      const data = await res.json();
      const sessions = data.sessions || [];
      root.innerHTML = "";
      root.classList.toggle("empty", sessions.length === 0);
      if (sessions.length === 0) {
        root.textContent = "no saved sessions yet";
        return;
      }
      sessions.slice(0, 12).forEach(s => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "session-item";
        button.innerHTML = '<span class="name"></span><span class="meta"></span>';
        button.querySelector(".name").textContent = s.name;
        button.querySelector(".meta").textContent =
          `${s.events || 0} events · ${Math.ceil((s.bytes || 0) / 1024)} KB`;
        button.onclick = () => loadSavedSession(s.path);
        root.appendChild(button);
      });
    } catch (e) {
      root.textContent = "could not load sessions";
    }
  }

  function row(root, k, v) {
    const el = document.createElement("div");
    el.className = "cfg-row";
    el.innerHTML = '<span class="k"></span><span class="v"></span>';
    el.querySelector(".k").textContent = k;
    el.querySelector(".v").textContent = v == null ? "" : String(v);
    root.appendChild(el);
  }

  function sub(root, label) {
    const el = document.createElement("div");
    el.className = "cfg-sub";
    el.textContent = label;
    root.appendChild(el);
  }

  function renderProviderSelect(providers, current) {
    const sel = $("provider-select");
    sel.innerHTML = "";
    providers.forEach(p => {
      const opt = document.createElement("option");
      opt.value = p.kind;
      opt.textContent = p.label;
      if (p.kind === current) opt.selected = true;
      sel.appendChild(opt);
    });
    sel.onchange = () => {
      if (ws.readyState !== WebSocket.OPEN) return;
      ws.sendJSON({ kind: "set_provider", provider: sel.value });
    };
  }

  function handleObservation(name, payload) {
    addInspector(name.replace(/_/g, " "), describe(name, payload));

    if (name === "event_appended") {
      const evt = payload.event;
      if (!evt) return;
      appendLogEvent(evt);
      scheduleRender({
        tools: evt.type === "tool_use_argument_delta",
        strip: true,
        stats: true
      });
    }
    if (name === "stream_event") {
      const evt = payload.event;
      if (!evt) return;
      renderTransientStreamEvent(evt);
      scheduleRender({ stats: true });
    }
  }

  function renderTransientStreamEvent(evt) {
    transient.appendTransientEvent(evt);
  }

  // Coalesce DOM updates into one per animation frame. Without this, a
  // burst of WebSocket messages (deltas tend to arrive in Nagle-batched
  // clumps) keeps the JS thread too busy to let the browser paint,
  // producing the "final state appears all at once" effect even when
  // state is being updated continuously.
  function scheduleRender({ tools, strip, stats }) {
    if (tools) state.dirtyTools = true;
    if (strip) state.dirtyStrip = true;
    if (stats) state.dirtyStats = true;
    if (state.pendingFrame !== null) return;
    state.pendingFrame = requestAnimationFrame(() => {
      state.pendingFrame = null;
      if (state.dirtyTools) { state.dirtyTools = false; flushToolBubbles(); }
      if (state.dirtyStats) { state.dirtyStats = false; recomputeStats();   }
      if (state.dirtyStrip) { state.dirtyStrip = false; redrawStrip();      }
    });
  }

  function flushStreamingBubble() {
    if (!state.streamingMsgEl) return;
    // The body text has been built up with appendChild(text-node)s
    // during streaming, so no reassignment is needed here. Just make
    // sure we're scrolled to the bottom.
    scrollChat();
  }

  // Debounce scrollChat calls to at most one per animation frame.
  // Reading chat.scrollHeight forces layout of the full chat column,
  // which gets expensive as the conversation grows.
  let scrollPending = false;
  function scheduleScroll() {
    if (scrollPending) return;
    scrollPending = true;
    requestAnimationFrame(() => { scrollPending = false; scrollChat(); });
  }

  function flushToolBubbles() {
    for (const id in state.toolBubbles) {
      const t = state.toolBubbles[id];
      if (!t.el) continue;
      t.el.querySelector(".body").textContent = formatToolUseBody(t.name, t.argsText);
    }
    scrollChat();
  }

  function formatToolUseBody(name, argsText) {
    return name + "(" + (argsText || "…") + ")";
  }

  // ──── stats: derived from the log so reconnects show correct values ────

  function recomputeStats() {
    let inTok = 0, outTok = 0, turns = 0, compactions = 0, tools = 0;
    state.log.forEach(e => {
      if (e.type === "assistant_message") {
        turns += 1;
        const u = (e.payload && e.payload.usage) || {};
        inTok  += Number(u.input_tokens)  || 0;
        outTok += Number(u.output_tokens) || 0;
      } else if (e.type === "compact") {
        compactions += 1;
      } else if (e.type === "tool_use") {
        tools += 1;
      }
    });
    $("stat-logsize").textContent     = state.log.length;
    $("stat-turns").textContent       = turns;
    $("stat-input").textContent       = inTok;
    $("stat-output").textContent      = outTok;
    $("stat-compactions").textContent = compactions;
    $("stat-tools").textContent       = tools;
    $("meta-tokens").textContent      = `in: ${inTok} · out: ${outTok}`;
  }

  // ──── chat rendering ────

  function appendLogEvent(evt) {
    state.log.push(evt);

    // The consolidated turn outputs (:assistant_message and :tool_use)
    // arrive on the durable Log path. Once they land, the transient
    // streaming rows in the timeline have served their purpose — clear
    // them so the consolidated row stands alone, and clear the
    // streamingTurn tracker so the strip stops drawing the synthetic
    // in-flight block (the real one is now in state.log).
    if (evt.type === "assistant_message" || evt.type === "tool_use") {
      transient.clearTransientTimelineRows();
      resetStreamingTurn(false);
    }

    // ── text streaming ───────────────────────────────────────────
    if (evt.type === "assistant_text_delta") {
      ensureStreamingBubble();
      const chunk = evt.payload.chunk || "";
      state.streamingMsgText += chunk;
      // Append only the new chunk as a text node instead of
      // reassigning textContent with the full accumulated string —
      // that was O(n²) on long messages and gave the browser less
      // paint budget as the chat grew taller.
      state.streamingMsgEl.querySelector(".body")
        .appendChild(document.createTextNode(chunk));
      // scrollChat reads scrollHeight which forces a full layout of
      // the chat container. On a tall chat that's expensive; batch
      // scroll updates to once per animation frame.
      scheduleScroll();
      state.deltaCount += 1;
      $("meta-deltas").textContent = "δ " + state.deltaCount;
      return;
    }
    if (evt.type === "assistant_turn_started") {
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      state.deltaCount = 0;
      $("meta-deltas").textContent = "δ 0";
      return;
    }
    if (evt.type === "assistant_turn_completed") {
      flushStreamingBubble();
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      return;
    }
    if (evt.type === "assistant_turn_failed") {
      // Surface the error as a visible chat entry so the user sees *why*
      // the turn produced nothing. Before this, these events only hit
      // the inspector panel where they were easy to miss.
      const node = makeMessageNode("error", (evt.payload && evt.payload.error) || "turn failed");
      chat.appendChild(node);
      scrollChat();
      state.streamingMsgEl = null;
      state.streamingMsgText = "";
      return;
    }
    if (evt.type === "provider_error" || evt.type === "runtime_error") {
      if (state.streamingMsgEl) {
        const body = state.streamingMsgEl.querySelector(".body");
        body.appendChild(document.createTextNode("\n[stream interrupted]"));
        state.streamingMsgEl.classList.add("error");
        state.streamingMsgEl = null;
        state.streamingMsgText = "";
      }
      const cls = evt.payload && evt.payload.terminal ? "fatal" : "retry";
      const node = makeMessageNode(evt.type + " " + cls, summarizeMessagePayload(evt));
      chat.appendChild(node);
      scrollChat();
      return;
    }
    if (evt.type === "annotation") {
      renderAnnotation(evt);
      return;
    }

    // ── tool-use streaming ───────────────────────────────────────
    // Same pattern as text: create a bubble on begin, accumulate
    // partial-JSON arg chunks into displayed args, finalize on end.
    if (evt.type === "tool_use_begin") {
      ensureToolBubble(evt.payload.tool_use_id, evt.payload.name);
      return;
    }
    if (evt.type === "tool_use_argument_delta") {
      const t = ensureToolBubble(evt.payload.tool_use_id, null);
      t.argsText += (evt.payload.chunk || "");
      return;
    }
    if (evt.type === "tool_use_end") {
      // Replace the streaming partial-JSON with the parsed-args
      // representation so the final display matches the consolidated
      // tool_use event.
      const t = state.toolBubbles[evt.payload.tool_use_id];
      if (t) {
        t.argsText = JSON.stringify(evt.payload.arguments || {});
        t.el.querySelector(".body").textContent = formatToolUseBody(t.name, t.argsText);
      }
      return;
    }

    // ── consolidated message events ──────────────────────────────
    if (MESSAGE_TYPES.has(evt.type)) {
      if (evt.type === "assistant_message") {
        // Already streamed via deltas? Don't duplicate.
        if (lastChildIsStreamedAssistant()) return;
        // No text and no tool use to narrate? Don't clutter the chat
        // with "(no text)" bubbles — they're just turn-bookkeeping.
        if (!(evt.payload.text || "").trim() && !hasReasoning(evt)) return;
      }
      if (evt.type === "tool_use") {
        const t = state.toolBubbles[evt.payload.id];
        if (t) {
          // Treat the consolidated event as authoritative: refresh the
          // streaming bubble's display with the fully parsed arguments.
          // Covers the case where streaming delta chunks were missing
          // or incomplete but the final :tool_use still has them.
          t.name = evt.payload.name || t.name;
          t.argsText = JSON.stringify(evt.payload.arguments || {});
          t.el.querySelector(".body").textContent = formatToolUseBody(t.name, t.argsText);
          return;
        }
      }
      renderMessageBubble(evt);
      scrollChat();
    }
  }

  function ensureToolBubble(id, name) {
    let t = state.toolBubbles[id];
    if (t) return t;
    const node = makeMessageNode("tool_use", "");
    chat.appendChild(node);
    t = { el: node, name: name || "tool", argsText: "" };
    state.toolBubbles[id] = t;
    node.querySelector(".body").textContent = formatToolUseBody(t.name, "");
    return t;
  }

  function ensureStreamingBubble() {
    if (state.streamingMsgEl) return;
    const node = makeMessageNode("assistant", "");
    chat.appendChild(node);
    state.streamingMsgEl = node;
  }

  function lastChildIsStreamedAssistant() {
    const last = chat.lastElementChild;
    return last && last.classList.contains("assistant");
  }

  function renderMessageBubble(evt) {
    if (evt.type === "assistant_message") {
      chat.appendChild(makeAssistantMessageNode(evt));
    } else {
      chat.appendChild(makeMessageNode(evt.type, summarizeMessagePayload(evt)));
    }
  }

  function renderAnnotation(evt) {
    const kind = (evt.payload && evt.payload.kind) || "annotation";
    const last = chat.lastElementChild;
    if (!last) return;
    if (kind === "gemini.thought_signature") {
      addPill(last, "signature attached");
      return;
    }
    if (kind.indexOf("stale_read_guard.") === 0) {
      last.classList.add("error");
      addPill(last, "stale read guard");
      return;
    }
    addPill(last, kind + " " + JSON.stringify((evt.payload && evt.payload.data) || {}).slice(0, 80));
  }

  function addPill(node, text) {
    const pill = document.createElement("span");
    pill.className = "pill";
    pill.textContent = text;
    node.appendChild(pill);
  }

  function makeMessageNode(type, text) {
    const node = document.createElement("div");
    node.className = "msg " + type;
    const who = document.createElement("div");
    who.className = "who";
    who.textContent = type.replace(/_/g, " ");
    const body = document.createElement("div");
    body.className = "body";
    appendExpandableText(body, text || "");
    node.appendChild(who);
    node.appendChild(body);
    return node;
  }

  function appendExpandableText(body, text) {
    if (text.length <= 2000) {
      body.textContent = text;
      return;
    }
    const preview = document.createElement("span");
    preview.textContent = text.slice(0, 1000) + "\n…";
    const rest = document.createElement("span");
    rest.textContent = text.slice(1000);
    rest.hidden = true;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "expander";
    btn.textContent = `show full text · ~${Math.ceil(text.length / 4)} tokens`;
    btn.onclick = () => {
      rest.hidden = !rest.hidden;
      btn.textContent = rest.hidden ? `show full text · ~${Math.ceil(text.length / 4)} tokens` : "collapse";
    };
    body.appendChild(preview);
    body.appendChild(rest);
    body.appendChild(document.createElement("br"));
    body.appendChild(btn);
  }

  function hasReasoning(evt) {
    return Array.isArray(evt.payload && evt.payload.reasoning) &&
           evt.payload.reasoning.length > 0;
  }

  function makeAssistantMessageNode(evt) {
    const node = makeMessageNode("assistant", "");
    const body = node.querySelector(".body");
    body.textContent = "";
    const reasoning = (evt.payload && evt.payload.reasoning) || [];
    if (reasoning.length) {
      const details = document.createElement("details");
      details.className = "reasoning";
      details.open = true;
      const summary = document.createElement("summary");
      summary.textContent = "thinking";
      details.appendChild(summary);
      reasoning.forEach(block => {
        const div = document.createElement("div");
        div.textContent = block.text || "";
        details.appendChild(div);
        if (block.signature) {
          const sig = document.createElement("div");
          sig.className = "sig";
          sig.textContent = "signature attached";
          details.appendChild(sig);
        }
      });
      body.appendChild(details);
    }
    const answer = document.createElement("div");
    appendExpandableText(answer, (evt.payload && evt.payload.text) || "");
    body.appendChild(answer);
    return node;
  }

  function summarizeMessagePayload(evt) {
    const p = evt.payload || {};
    if (evt.type === "user_message")      return p.text || "";
    if (evt.type === "assistant_message") return p.text || "(no text)";
    if (evt.type === "provider_error") {
      return `${p.terminal ? "fatal" : "retry"} attempt ${p.attempt || "?"}: ${p.message || ""}`;
    }
    if (evt.type === "runtime_error") {
      return `fatal runtime error in ${p.handler || p.source || "handler"}: ${p.message || ""}`;
    }
    if (evt.type === "tool_use") {
      return `${p.name}(${JSON.stringify(p.arguments || {})})`;
    }
    if (evt.type === "tool_result") {
      if (p.error)  return "error: " + p.error;
      if (p.output) return typeof p.output === "string" ? p.output : JSON.stringify(p.output);
      return "(empty result)";
    }
    if (evt.type === "summary") return p.text || "[compaction]";
    return JSON.stringify(p);
  }

  // ──── inspector event log ────

  function describe(name, payload) {
    if (name === "tokens_consumed") {
      return `${payload.provider} · in ${payload.input_tokens} out ${payload.output_tokens}`;
    }
    if (name === "tool_invoked") {
      return `${payload.tool || ""} · ${payload.outcome} · ${payload.duration_ms || 0}ms`;
    }
    if (name === "provider_called")    return `${payload.provider}`;
    if (name === "provider_responded") return `${payload.provider} · ${payload.duration_ms || 0}ms`;
    if (name === "event_appended" && payload.event) return `${payload.event.type}`;
    if (name === "turn_started" || name === "turn_ended") return `turn ${payload.turn}`;
    if (name === "session_started" || name === "session_ended") return payload.reason || "";
    return "";
  }

  function addInspector(cls, text) {
    const li = document.createElement("li");
    li.className = cls.replace(/[^\w-]/g, "");
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = cls;
    const meta = document.createElement("span");
    meta.className = "meta";
    meta.textContent = text || "";
    li.appendChild(name);
    li.appendChild(meta);
    events.insertBefore(li, events.firstChild);
    while (events.children.length > 80) events.removeChild(events.lastChild);
  }

  function scrollChat() { chat.scrollTop = chat.scrollHeight; }

  // ──── block-strips ────
  //
  // Two views of the same Log, answering two different questions:
  //
  //   context  — what will be sent to the provider on the next turn.
  //              Mutations applied. Streaming deltas (assistant_text_delta,
  //              tool_use_*_delta, turn brackets) are collapsed into
  //              their consolidated message / tool_use blocks. One block
  //              per effective message the Projection emits.
  //
  //   timeline — the literal Log in seq order. Every appended event is
  //              one block — mutations and consolidated semantic messages.
  //              Observation-only streaming deltas render live but do not
  //              persist into this durable timeline.
  //
  // The two strips are rendered stacked and update together.

  function redrawStrip() {
    const blocks = stripView === "context"
      ? buildContextBlocks(state.log)
      : buildTimelineBlocks(state.log);
    drawStrip(stripEl, blocks);
    renderDetailView("context",  buildContextBlocks(state.log));
    renderDetailView("timeline", buildTimelineBlocks(state.log));
    renderLegend("context",  contextLegend());
    renderLegend("timeline", timelineLegend());
  }

  // Clicking a block in the strip jumps to the matching tab and
  // highlights the event's row. If the block was built from a seq,
  // the row can be scrolled into view.
  stripEl.addEventListener("click", (e) => {
    const rect = e.target.closest("rect");
    if (!rect) return;
    const seq = rect.dataset.seq;
    if (seq === "") return;
    switchTab(stripView, { highlightSeq: seq });
  });

  // ──── context/timeline detail rendering ────

  const EVENT_TYPE_DESCRIPTIONS = {
    user_message:              "a message the user sent",
    assistant_message:         "consolidated assistant response (text + stop_reason + usage)",
    tool_use:                  "the assistant asked the harness to call a tool",
    tool_result:               "the harness executed the tool and appended the result",
    summary:                   "synthetic replacement emitted by a :compact mutation",
    compact:                   "mutation: hide a range of events behind a summary",
    revert:                    "mutation: undo an earlier compact",
    assistant_turn_started:    "streaming bracket: turn begins",
    assistant_text_delta:      "streaming chunk of assistant text",
    assistant_turn_completed:  "streaming bracket: turn ends successfully",
    assistant_turn_failed:     "streaming bracket: turn ends with an error",
    tool_use_begin:            "streaming bracket: tool-use block begins",
    tool_use_argument_delta:   "streaming chunk of tool-use JSON arguments",
    tool_use_end:              "streaming bracket: tool-use block ends with parsed args",
    provider_error:            "provider failure captured by retry policy",
    runtime_error:             "runtime failure captured by hook error policy",
    annotation:                "log-sourced derived state or opaque provider token",
    fork:                      "session fork lineage marker"
  };

  function contextLegend() {
    return [
      ["user_message",      "user message"],
      ["assistant_message", "assistant (grown as deltas arrive)"],
      ["tool_use",          "tool use"],
      ["tool_result",       "tool result"],
      ["provider_error",    "provider error"],
      ["runtime_error",     "runtime error"],
      ["annotation",        "annotation"],
      ["summary",           "synthetic compaction summary · replaces hidden events"],
      ["__dropped__",       "dimmed row = hidden from the projection by a :compact"]
    ];
  }

  function timelineLegend() {
    return [
      ["user_message",          "user message"],
      ["assistant_message",     "consolidated assistant message"],
      ["assistant_text_delta",  "text delta (streaming)"],
      ["tool_use",              "consolidated tool use"],
      ["tool_use_argument_delta","argument delta (streaming)"],
      ["tool_result",           "tool result"],
      ["provider_error",        "provider error"],
      ["runtime_error",         "runtime error"],
      ["annotation",            "annotation"],
      ["compact",               "mutation · hides a range of earlier events"],
      ["summary",               "synthetic block emitted by a :compact"],
      ["__dropped__",           "dimmed row = hidden by a :compact (still in the log)"]
    ];
  }

  function renderLegend(which, items) {
    const root = document.getElementById("legend-" + which);
    root.innerHTML = "";
    items.forEach(([type, label]) => {
      const item = document.createElement("div");
      item.className = "lg-item";
      const sw = document.createElement("span");
      sw.className = "lg-swatch";
      if (type === "__dropped__") {
        sw.style.background = "#cccac2";
        sw.style.opacity = 0.35;
        sw.style.border = "1px dashed var(--muted)";
      } else {
        sw.style.background = COLORS[type] || "#cccac2";
      }
      const name = document.createElement("span");
      name.className = "lg-name";
      name.textContent = type === "__dropped__" ? "dimmed" : type;
      const desc = document.createElement("span");
      desc.className = "lg-desc";
      desc.textContent = "— " + label;
      item.appendChild(sw);
      item.appendChild(name);
      item.appendChild(desc);
      root.appendChild(item);
    });
  }

  function renderDetailView(which, blocks) {
    const list = document.getElementById("list-" + which);
    list.innerHTML = "";
    blocks.forEach(b => list.appendChild(makeEventRow(b)));
    // Re-attach any in-flight transient streaming rows so they survive
    // a strip redraw that re-renders the durable list. They were
    // detached from the DOM by innerHTML = "" but the JS references
    // are still live; appending re-attaches the same nodes.
    if (which === "timeline" && state.transientRows.length) {
      state.transientRows.forEach(row => list.appendChild(row));
    }
  }

  function makeEventRow(block, ctx) {
    // ctx carries: compactBySeq (map seq -> compact event) so dropped
    // rows can point back at the compact that hid them.
    const row = document.createElement("div");
    row.className = "evt-row";
    if (block.seq != null) row.dataset.seq = block.seq;

    // Mutation-specific treatment:
    if (block.type === "summary")                     row.classList.add("is-summary");
    if (block.type === "compact")                     row.classList.add("is-compact");
    if (block.type === "annotation")                  row.classList.add("is-annotation");
    if (block.type === "provider_error" || block.type === "runtime_error") {
      row.classList.add("is-provider-error");
      row.classList.add(block.rawPayload && block.rawPayload.terminal ? "fatal" : "retry");
    }
    if (block.guardMarked)                            row.classList.add("guard-marked");
    if (block.dropped)                                row.classList.add("dropped");

    const bar = document.createElement("div");
    bar.className = "evt-bar";
    bar.style.background = COLORS[block.type] || "#cccac2";
    if (block.dropped) bar.style.opacity = 0.35;

    const seq = document.createElement("div");
    seq.className = "evt-seq";
    seq.textContent = block.seq != null ? "#" + block.seq : "—";

    const type = document.createElement("div");
    type.className = "evt-type";
    const tname = document.createElement("span");
    tname.textContent = block.type;
    const desc  = document.createElement("span");
    desc.className = "desc";
    desc.textContent = (block.streaming ? "(in flight) " : "") +
                       (EVENT_TYPE_DESCRIPTIONS[block.type] || "");
    type.appendChild(tname);

    // Tags to make the role of this row visually obvious:
    if (block.type === "summary") {
      const replaces = (block.replaces || []).join(", ");
      const tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = "synthetic · replaces [" + replaces + "]";
      type.appendChild(tag);
    }
    if (block.type === "compact") {
      const replaces = ((block.rawPayload || {}).replaces || []).join(", ");
      const tag = document.createElement("span");
      tag.className = "tag tag-mutation";
      tag.textContent = "mutation · hides [" + replaces + "]";
      type.appendChild(tag);
    }
    if (block.type === "annotation" && block.rawPayload) {
      const tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = block.rawPayload.kind || "annotation";
      type.appendChild(tag);
    }
    if ((block.type === "provider_error" || block.type === "runtime_error") && block.rawPayload) {
      const tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = block.rawPayload.terminal ? "fatal" : "retry";
      type.appendChild(tag);
    }
    if (block.dropped && block.hiddenBySeq != null) {
      const tag = document.createElement("span");
      tag.className = "tag tag-dropped";
      tag.textContent = "replaced by #" + block.hiddenBySeq;
      type.appendChild(tag);
    }

    type.appendChild(desc);

    const body = document.createElement("div");
    body.className = "evt-body";
    body.textContent = describeEventPayload(block);
    body.addEventListener("click", () => body.classList.toggle("expanded"));

    row.appendChild(bar);
    row.appendChild(seq);
    row.appendChild(type);
    row.appendChild(body);
    return row;
  }

  function describeEventPayload(block) {
    // Summary blocks in the context view are synthetic — they don't
    // have a seq in state.log (the compact event does). Render their
    // text directly.
    if (block.type === "summary" && block.synthetic) {
      return block.summaryText || "";
    }

    const raw = (block.seq != null && state.log) ? state.log.find(e => e.seq === block.seq) : null;
    if (raw) {
      if (raw.type === "user_message" || raw.type === "assistant_message" || raw.type === "summary") {
        let text = raw.payload.text || "";
        if (raw.type === "assistant_message" && Array.isArray(raw.payload.reasoning)) {
          const thinking = raw.payload.reasoning.map(r => {
            return "[thinking" + (r.signature ? " · signature attached" : "") + "]\n" + (r.text || "");
          }).join("\n\n");
          text = thinking + (text ? "\n\n[answer]\n" + text : "");
        }
        return text + (raw.payload.usage ? "\n\n(usage: in=" + raw.payload.usage.input_tokens +
                                           ", out=" + raw.payload.usage.output_tokens + ")" : "");
      }
      if (raw.type === "tool_use") return raw.payload.name + "(" + JSON.stringify(raw.payload.arguments || {}) + ")";
      if (raw.type === "tool_result") {
        if (raw.payload.error)  return "error: " + raw.payload.error;
        if (raw.payload.output) return String(raw.payload.output);
        return "(empty)";
      }
      if (raw.type === "annotation") {
        const kind = raw.payload.kind || "annotation";
        const data = JSON.stringify(raw.payload.data || {});
        if (kind === "gemini.thought_signature") return "Gemini thought signature attached";
        if (kind.indexOf("stale_read_guard.") === 0) return kind + "\n" + data;
        return kind + "\n" + data.slice(0, 500);
      }
      if (raw.type === "provider_error") {
        return `${raw.payload.terminal ? "fatal" : "retry"} provider error\n` +
               `provider: ${raw.payload.provider}\n` +
               `status: ${raw.payload.status || "(none)"}\n` +
               `attempt: ${raw.payload.attempt}\n` +
               `message: ${raw.payload.message || ""}`;
      }
      if (raw.type === "runtime_error") {
        return `fatal runtime error\n` +
               `source: ${raw.payload.source}\n` +
               `handler: ${raw.payload.handler}\n` +
               `class: ${raw.payload.error_class}\n` +
               `message: ${raw.payload.message || ""}`;
      }
      if (raw.type === "fork") {
        return "branched from seq " + (raw.payload && raw.payload.forked_at_seq);
      }
      if (raw.type === "compact") {
        return 'replaces: [' + (raw.payload.replaces || []).join(", ") + ']\n' +
               'summary : "' + (raw.payload.summary || "") + '"';
      }
      if (raw.type === "assistant_text_delta") return JSON.stringify(raw.payload.chunk || "");
      if (raw.type === "tool_use_argument_delta") return raw.payload.chunk;
      return JSON.stringify(raw.payload);
    }
    if (block.type === "assistant_message" && block.streaming) return "(streaming…)";
    return "";
  }

  function drawStrip(svgEl, blocks) {
    const total = blocks.reduce((s, b) => s + b.tokens, 0) || 1;
    let x = 0;
    const W = 1000, H = 18;
    const rects = blocks.map(b => {
      const w = (b.tokens / total) * W;
      const rect =
        '<rect x="' + x.toFixed(2) + '" y="2" ' +
        'width="' + Math.max(2, w - 1).toFixed(2) + '" height="' + (H - 4) + '" ' +
        'fill="' + (COLORS[b.type] || "#cccac2") + '" ' +
        'opacity="' + (b.dropped ? 0.18 : 0.85) + '" ' +
        'data-seq="' + (b.seq == null ? "" : b.seq) + '" ' +
        'data-type="' + b.type + '">' +
        '<title>' + b.type +
          (b.seq != null ? " · seq " + b.seq : "") +
          (b.streaming ? " · streaming" : "") +
        '</title></rect>';
      x += w;
      return rect;
    }).join("");
    svgEl.innerHTML = rects;
  }

  // Timeline: one block per log event, no collapsing. But we DO
  // annotate which events have been hidden by a later :compact so
  // the detail view can show "→ replaced by #5" on the dropped rows.
  function buildTimelineBlocks(log) {
    const compactBySeq = {};
    const guardMarked = {};
    log.forEach(e => {
      if (e.type === "compact") {
        (e.payload.replaces || []).forEach(s => { compactBySeq[s] = e.seq; });
      }
      if (e.type === "annotation" &&
          e.payload && String(e.payload.kind || "").indexOf("stale_read_guard.") === 0) {
        const prev = log.find(x => x.seq === e.seq - 1);
        if (prev && prev.type === "tool_result") guardMarked[prev.seq] = true;
      }
    });

    const blocks = log.map(evt => ({
      type: evt.type,
      tokens: tokenWidth(evt),
      seq: evt.seq,
      dropped: compactBySeq[evt.seq] != null,
      hiddenBySeq: compactBySeq[evt.seq],
      guardMarked: guardMarked[evt.seq],
      rawPayload: ["compact", "annotation", "provider_error", "runtime_error", "fork"].includes(evt.type)
        ? evt.payload
        : null
    }));
    transient.appendStreamingTurnBlocks(blocks);
    return blocks;
  }

  // Context: the projection. Apply :compact mutations. Collapse streaming
  // into synthetic growing blocks. Drop turn brackets entirely (they're
  // meta, not content).
  function buildContextBlocks(log) {
    const compactBySeq = {};
    log.forEach(e => {
      if (e.type === "compact") {
        (e.payload.replaces || []).forEach(s => { compactBySeq[s] = e; });
      }
    });

    const summaryEmittedFor = new Set();
    const result = [];
    let streamingAsst = null;       // { type: "assistant_message", tokens, streaming: true }
    const streamingTools = {};      // tool_use_id -> synthetic block

    log.forEach(evt => {
      const t = evt.type;

      // Mutation events and turn brackets don't appear in the projection.
      if (t === "compact") return;
      if (t === "assistant_turn_started" ||
          t === "assistant_turn_completed" ||
          t === "assistant_turn_failed") {
        return;
      }
      if (t === "provider_error" || t === "runtime_error" || t === "annotation" || t === "fork") {
        result.push({ type: t, tokens: tokenWidth(evt), seq: evt.seq, rawPayload: evt.payload });
        return;
      }

      // Compacted: emit the summary once, then show the original faded.
      const compactEvt = compactBySeq[evt.seq];
      if (compactEvt) {
        if (!summaryEmittedFor.has(compactEvt.seq)) {
          result.push({
            type: "summary",
            tokens: tokensFromString(compactEvt.payload.summary),
            seq: compactEvt.seq,
            synthetic: true,
            replaces: compactEvt.payload.replaces || [],
            summaryText: compactEvt.payload.summary
          });
          summaryEmittedFor.add(compactEvt.seq);
        }
        result.push({
          type: t, tokens: tokenWidth(evt), seq: evt.seq,
          dropped: true, hiddenBySeq: compactEvt.seq
        });
        return;
      }

      // Text deltas grow a single synthetic assistant_message block.
      if (t === "assistant_text_delta") {
        if (!streamingAsst) {
          streamingAsst = { type: "assistant_message", tokens: 0, streaming: true };
          result.push(streamingAsst);
        }
        streamingAsst.tokens += tokensFromString(evt.payload.chunk);
        return;
      }

      // Tool-use streaming: begin creates the block, argument_delta grows it,
      // end is a no-op for sizing (args already counted).
      if (t === "tool_use_begin") {
        const block = {
          type: "tool_use",
          tokens: Math.max(1, tokensFromString(evt.payload.name)),
          seq: evt.seq,
          streaming: true
        };
        streamingTools[evt.payload.tool_use_id] = block;
        result.push(block);
        return;
      }
      if (t === "tool_use_argument_delta") {
        const block = streamingTools[evt.payload.tool_use_id];
        if (block) block.tokens += tokensFromString(evt.payload.chunk);
        return;
      }
      if (t === "tool_use_end") {
        return;
      }

      // Consolidated assistant_message replaces any streaming block with
      // its authoritative token size.
      if (t === "assistant_message") {
        if (streamingAsst) {
          const idx = result.indexOf(streamingAsst);
          if (idx !== -1) {
            result[idx] = { type: t, tokens: tokenWidth(evt), seq: evt.seq };
          }
          streamingAsst = null;
        } else if ((evt.payload.text || "").length > 0) {
          result.push({ type: t, tokens: tokenWidth(evt), seq: evt.seq });
        }
        return;
      }

      // Consolidated tool_use replaces its streaming counterpart (by id).
      if (t === "tool_use") {
        const block = streamingTools[evt.payload.id];
        if (block) {
          const idx = result.indexOf(block);
          if (idx !== -1) {
            result[idx] = { type: t, tokens: tokenWidth(evt), seq: evt.seq };
          }
          delete streamingTools[evt.payload.id];
        } else {
          result.push({ type: t, tokens: tokenWidth(evt), seq: evt.seq });
        }
        return;
      }

      // Plain content types pass through.
      if (t === "user_message" || t === "tool_result" || t === "summary") {
        result.push({ type: t, tokens: tokenWidth(evt), seq: evt.seq });
      }
    });

    transient.appendStreamingTurnBlocks(result);
    return result;
  }

  function tokenWidth(evt) {
    if (!evt) return 1;
    const p = evt.payload || {};
    let text = "";
    if (typeof p.text === "string") {
      text = p.text;
    } else if (typeof p.output === "string") {
      text = p.output;
    } else if (typeof p.chunk === "string") {
      text = p.chunk;
    } else {
      text = JSON.stringify(p);
    }
    if (Array.isArray(p.reasoning)) {
      text += p.reasoning.map(r => r.text || "").join("");
    }
    return Math.max(1, Math.ceil(text.length / 4));
  }

  function tokensFromString(s) {
    return Math.max(1, Math.ceil(((s || "").length) / 4));
  }
