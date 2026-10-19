"use strict";

const $ = (selector) => document.querySelector(selector);
const MAX_LOG_LINES = 2000;

const state = {
  status: null,
  lists: { whitelist: [], ops: [], bans: [] },
  tab: "whitelist",
  restart: null, // null | "requested" | "down"
  history: [],
  historyIndex: 0,
  events: null,
  timers: [],
  menuFor: null,
};

// --- API --------------------------------------------------------------------

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

async function api(path, { method = "GET", body } = {}) {
  let res;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError("Can't reach the admin panel. Check that this computer is on the server's network.", 0);
  }
  let data = {};
  try { data = await res.json(); } catch { /* empty body */ }
  if (res.status === 401 && path !== "/api/login") {
    showLogin();
    throw new ApiError("Sign in to continue.", 401);
  }
  if (!res.ok) {
    const detail = typeof data.detail === "string" ? data.detail : "That didn't go through. Check the form and try again.";
    throw new ApiError(detail, res.status);
  }
  return data;
}

// --- Small helpers ----------------------------------------------------------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(label, className = "mc-button small") {
  const b = el("button", className, label);
  b.type = "button";
  return b;
}

const FALLBACK_HEAD = "data:image/svg+xml," + encodeURIComponent(
  "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8' shape-rendering='crispEdges'>" +
  "<rect width='8' height='8' fill='#b98a6b'/><rect width='8' height='2' fill='#3b2a1e'/>" +
  "<rect y='2' width='1' height='1' fill='#3b2a1e'/><rect x='7' y='2' width='1' height='1' fill='#3b2a1e'/>" +
  "<rect x='1' y='4' width='2' height='1' fill='#fff'/><rect x='2' y='4' width='1' height='1' fill='#3c4fa8'/>" +
  "<rect x='5' y='4' width='2' height='1' fill='#fff'/><rect x='5' y='4' width='1' height='1' fill='#3c4fa8'/>" +
  "<rect x='3' y='6' width='2' height='1' fill='#6b4329'/></svg>"
);

function head(name) {
  const img = el("img", "head");
  img.alt = "";
  img.loading = "lazy";
  img.src = `https://mc-heads.net/avatar/${encodeURIComponent(name)}/64`;
  img.addEventListener("error", () => { img.src = FALLBACK_HEAD; }, { once: true });
  return img;
}

function toast(message, kind = "info") {
  const node = el("div", `tooltip toast ${kind}`, message);
  $("#toasts").append(node);
  setTimeout(() => node.remove(), kind === "error" ? 7000 : 4000);
}

// Two-step confirm for destructive buttons: first click arms, second click runs.
function confirmThen(btn, armedLabel, action) {
  if (btn.dataset.armed) {
    clearTimeout(btn._disarm);
    delete btn.dataset.armed;
    btn.textContent = btn.dataset.label;
    action();
    return;
  }
  btn.dataset.label = btn.textContent;
  btn.dataset.armed = "true";
  btn.textContent = armedLabel;
  btn._disarm = setTimeout(() => {
    delete btn.dataset.armed;
    btn.textContent = btn.dataset.label;
  }, 4000);
}

function formatSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
}

function formatTime(seconds, withDate = true) {
  const d = new Date(seconds * 1000);
  return withDate
    ? d.toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
    : d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function isOp(name) {
  return state.lists.ops.some((o) => o.name && o.name.toLowerCase() === name.toLowerCase());
}

// --- Sign in / out ----------------------------------------------------------

function showLogin(message = "") {
  stopApp();
  $("#app").hidden = true;
  $("#login").hidden = false;
  $("#login-error").textContent = message;
  $("#password").focus();
}

$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = event.submitter || $("#login-form button");
  submit.disabled = true;
  $("#login-error").textContent = "";
  try {
    await api("/api/login", { method: "POST", body: { password: $("#password").value } });
    $("#password").value = "";
    startApp();
  } catch (err) {
    $("#login-error").textContent = err.message;
    $("#password").select();
  } finally {
    submit.disabled = false;
  }
});

$("#logout").addEventListener("click", async () => {
  try { await api("/api/logout", { method: "POST" }); } catch { /* signing out anyway */ }
  showLogin();
});

function startApp() {
  stopApp();
  $("#login").hidden = true;
  $("#app").hidden = false;
  refreshStatus();
  refreshPlayers();
  refreshBackups();
  openConsole();
  state.timers.push(setInterval(refreshStatus, 5000));
  state.timers.push(setInterval(refreshPlayers, 15000));
  state.timers.push(setInterval(refreshBackups, 10000));
}

function stopApp() {
  state.timers.forEach(clearInterval);
  state.timers = [];
  if (state.events) state.events.close();
  state.events = null;
  closeMenu();
}

// --- Status & hotbar ----------------------------------------------------------

async function refreshStatus() {
  let s;
  try { s = await api("/api/status"); } catch { return; }
  state.status = s;

  $("#motd").textContent = s.motd || "Minecraft server";
  document.title = `${s.motd || "Minecraft server"} admin`;
  $("#address").textContent = s.address ? `Players join through ${s.address}` : "";

  if (state.restart === "requested" && !s.online) state.restart = "down";
  if (state.restart === "down" && s.online) {
    state.restart = null;
    toast("The server is back online.");
  }
  const status = $("#status");
  const label = state.restart ? "Restarting" : s.online ? "Online" : "Offline";
  status.textContent = label;
  status.dataset.state = state.restart ? "restarting" : s.online ? "online" : "offline";
  status.title = !s.online && s.error ? s.error : "";

  $("#stat-players").textContent = s.online ? `${s.players.length} of ${s.max_players}` : "–";
  const tps = $("#stat-tps");
  tps.className = "";
  if (s.online && s.tps) {
    const now = s.tps[0];
    tps.textContent = `${Math.min(now, 20).toFixed(1)} TPS`;
    tps.title = `Last 1, 5 and 15 minutes: ${s.tps.map((t) => t.toFixed(1)).join(", ")}. 20 is full speed.`;
    if (now < 15) tps.className = "bad";
    else if (now < 18) tps.className = "warn";
  } else {
    tps.textContent = "–";
  }
  $("#stat-version").textContent = s.version || "–";
  renderHotbar(s.online ? s.players : []);
  $("#restart").disabled = !s.online || !!state.restart;
  $("#broadcast-open").disabled = !s.online;
}

function renderHotbar(players) {
  // Rebuild only when something changed, so keyboard focus on a slot survives polling
  const key = players.map((p) => `${p}:${isOp(p)}`).join(",");
  if (key === state.hotbarKey) return;
  state.hotbarKey = key;

  const bar = $("#hotbar");
  const slots = Math.max(9, Math.ceil(players.length / 9) * 9);
  const openFor = state.menuFor;
  const focused = document.activeElement?.dataset?.player;
  bar.replaceChildren();
  for (let i = 0; i < slots; i++) {
    const name = players[i];
    let slot;
    if (name) {
      slot = el("button", "slot");
      slot.type = "button";
      slot.setAttribute("aria-label", `${name}${isOp(name) ? ", operator" : ""}. Open actions`);
      slot.setAttribute("aria-haspopup", "menu");
      slot.setAttribute("aria-expanded", String(openFor === name));
      slot.title = name;
      slot.dataset.player = name;
      slot.append(head(name));
      slot.addEventListener("click", (e) => {
        e.stopPropagation();
        state.menuFor === name ? closeMenu() : openMenu(name, slot);
      });
    } else {
      slot = el("div", "slot");
      slot.setAttribute("aria-hidden", "true");
    }
    bar.append(slot);
  }
  if (focused) bar.querySelector(`[data-player="${CSS.escape(focused)}"]`)?.focus();
  // Keep the menu attached if its player is still online
  if (openFor) {
    const anchor = bar.querySelector(`[data-player="${CSS.escape(openFor)}"]`);
    anchor ? positionMenu(anchor) : closeMenu();
  }
  $("#hotbar-hint").hidden = players.length > 0;
}

// --- Player menu (tooltip) ----------------------------------------------------

function openMenu(name, anchor) {
  const menu = $("#player-menu");
  state.menuFor = name;
  menu.replaceChildren();
  const op = isOp(name);
  menu.append(el("p", "tip-name", name), el("p", `tip-role${op ? " op" : ""}`, op ? "Operator" : "Player"));

  const actions = el("div", "tip-actions");
  const kick = button("Kick", "mc-button small");
  kick.setAttribute("role", "menuitem");
  kick.addEventListener("click", () => { closeMenu(); playerAction("kick", name); });

  const ban = button("Ban", "mc-button small");
  ban.setAttribute("role", "menuitem");
  ban.addEventListener("click", () => confirmThen(ban, `Click again to ban ${name}`, () => {
    closeMenu();
    playerAction("ban", name);
  }));

  const opToggle = button(op ? "Remove operator" : "Make operator", "mc-button small");
  opToggle.setAttribute("role", "menuitem");
  opToggle.addEventListener("click", () => { closeMenu(); playerAction(op ? "deop" : "op", name); });

  actions.append(kick, ban, opToggle);
  menu.append(actions);
  menu.hidden = false;
  positionMenu(anchor);
  document.querySelectorAll(".slot[aria-expanded]").forEach((s) => s.setAttribute("aria-expanded", String(s === anchor)));
  kick.focus();
}

function positionMenu(anchor) {
  const menu = $("#player-menu");
  const rect = anchor.getBoundingClientRect();
  const width = menu.offsetWidth;
  const left = Math.min(rect.left + window.scrollX, window.scrollX + document.documentElement.clientWidth - width - 16);
  menu.style.left = `${Math.max(16, left)}px`;
  menu.style.top = `${rect.bottom + window.scrollY + 8}px`;
}

function closeMenu() {
  const menu = $("#player-menu");
  if (menu.hidden) return;
  const name = state.menuFor;
  menu.hidden = true;
  state.menuFor = null;
  const anchor = name && document.querySelector(`.slot[data-player="${CSS.escape(name)}"]`);
  if (anchor) {
    anchor.setAttribute("aria-expanded", "false");
    if (menu.contains(document.activeElement)) anchor.focus();
  }
}

document.addEventListener("click", (e) => {
  if (!$("#player-menu").contains(e.target)) closeMenu();
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") closeMenu();
});

window.addEventListener("resize", () => {
  if (!state.menuFor) return;
  const anchor = document.querySelector(`.slot[data-player="${CSS.escape(state.menuFor)}"]`);
  if (anchor) positionMenu(anchor);
});

// --- Players panel --------------------------------------------------------------

const TABS = {
  whitelist: {
    add: "Add to whitelist", addAction: "whitelist-add",
    remove: "Remove", removeAction: "whitelist-remove",
    empty: "The whitelist is empty, so nobody can join. Add your players' usernames above.",
  },
  ops: {
    add: "Make operator", addAction: "op",
    remove: "Remove operator", removeAction: "deop",
    empty: "No operators yet. Operators can run commands from inside the game.",
  },
  bans: {
    add: "Ban player", addAction: "ban",
    remove: "Unban", removeAction: "unban",
    empty: "Nobody is banned.",
    reason: true,
  },
};

async function refreshPlayers() {
  try { state.lists = await api("/api/players"); } catch { return; }
  renderRoster();
}

function renderRoster() {
  const tab = TABS[state.tab];
  for (const key of Object.keys(TABS)) {
    $(`#count-${key}`).textContent = state.lists[key].length ? `(${state.lists[key].length})` : "";
  }
  $("#add-button").textContent = tab.add;
  $("#add-reason").hidden = !tab.reason;

  const roster = $("#roster");
  roster.setAttribute("aria-labelledby", `tab-${state.tab}`);
  roster.replaceChildren();
  const entries = [...state.lists[state.tab]].sort((a, b) => (a.name || "").localeCompare(b.name || ""));
  if (!entries.length) {
    roster.append(el("li", "empty", tab.empty));
    return;
  }
  for (const entry of entries) {
    const name = entry.name || entry.uuid;
    const li = el("li");
    const who = el("div", "who");
    who.append(el("strong", "", name));
    if (state.tab === "bans") who.append(el("small", "", entry.reason || "No reason given"));
    if (state.tab === "ops" && entry.level) who.append(el("small", "", `Permission level ${entry.level}`));
    const remove = button(tab.remove);
    remove.setAttribute("aria-label", `${tab.remove} ${name}`);
    remove.addEventListener("click", () => playerAction(tab.removeAction, entry.name));
    li.append(head(name), who, remove);
    roster.append(li);
  }
}

document.querySelectorAll("[role=tab]").forEach((tabButton) => {
  tabButton.addEventListener("click", () => selectTab(tabButton.dataset.tab));
  tabButton.addEventListener("keydown", (e) => {
    const keys = Object.keys(TABS);
    const i = keys.indexOf(state.tab);
    if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
      e.preventDefault();
      const next = keys[(i + (e.key === "ArrowRight" ? 1 : keys.length - 1)) % keys.length];
      selectTab(next);
      $(`#tab-${next}`).focus();
    }
  });
});

function selectTab(name) {
  state.tab = name;
  document.querySelectorAll("[role=tab]").forEach((t) => {
    const selected = t.dataset.tab === name;
    t.setAttribute("aria-selected", String(selected));
    t.tabIndex = selected ? 0 : -1;
  });
  renderRoster();
}

$("#add-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("#add-name").value.trim();
  const reason = TABS[state.tab].reason ? $("#add-reason").value : "";
  if (await playerAction(TABS[state.tab].addAction, name, reason)) {
    $("#add-name").value = "";
    $("#add-reason").value = "";
  }
});

async function playerAction(action, name, reason = "") {
  try {
    const { reply } = await api(`/api/players/${action}`, { method: "POST", body: { name, reason } });
    toast(reply || "Done.");
    await Promise.all([refreshPlayers(), refreshStatus()]);
    return true;
  } catch (err) {
    toast(err.message, "error");
    return false;
  }
}

// --- Console -----------------------------------------------------------------

const LOG_RE = /^(\[\d{2}:\d{2}:\d{2}\]) (\[[^\]]*\]:)? ?(.*)$/;

function openConsole() {
  const es = new EventSource("/api/console");
  state.events = es;
  // The server resends recent history on every (re)connect
  es.addEventListener("open", () => $("#console").replaceChildren());
  es.addEventListener("message", (e) => appendLog(JSON.parse(e.data)));
  es.addEventListener("rotate", () => appendLine(el("div", "line divider", "The server restarted. New log starts here.")));
  es.addEventListener("error", () => {
    // EventSource retries on its own; a status call shows the sign-in screen if the session ended
    api("/api/status").catch(() => {});
  });
}

function appendLog(text) {
  const line = el("div", "line");
  const m = LOG_RE.exec(text);
  if (m) {
    line.append(el("span", "ts", `${m[1]} `));
    if (m[2]) line.append(el("span", "src", `${m[2]} `));
    line.append(el("span", "msg", m[3]));
    if (/\/(WARN)\]/.test(m[2] || "")) line.classList.add("warn");
    else if (/\/(ERROR|FATAL)\]/.test(m[2] || "")) line.classList.add("error");
    else if (/ (joined|left) the game$/.test(m[3])) line.classList.add("join");
  } else {
    line.append(el("span", "msg", text));
    if (/^\s+at |^Caused by|Exception/.test(text)) line.classList.add("error");
  }
  appendLine(line);
}

function appendLine(line) {
  const box = $("#console");
  box.append(line);
  while (box.childElementCount > MAX_LOG_LINES) box.firstElementChild.remove();
  if ($("#follow").checked) box.scrollTop = box.scrollHeight;
}

$("#console").addEventListener("scroll", () => {
  const box = $("#console");
  $("#follow").checked = box.scrollHeight - box.scrollTop - box.clientHeight < 24;
});

$("#follow").addEventListener("change", () => {
  if ($("#follow").checked) $("#console").scrollTop = $("#console").scrollHeight;
});

$("#command-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#command");
  const command = input.value.trim().replace(/^\//, "");
  if (!command) return;
  state.history.push(command);
  state.historyIndex = state.history.length;
  input.value = "";
  $("#follow").checked = true;
  appendLine(el("div", "line echo", `> /${command}`));
  try {
    const { reply } = await api("/api/command", { method: "POST", body: { command } });
    appendLine(el("div", "line reply", reply || "(no reply)"));
  } catch (err) {
    appendLine(el("div", "line reply failed", err.message));
  }
});

$("#command").addEventListener("keydown", (e) => {
  if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
  if (!state.history.length) return;
  e.preventDefault();
  state.historyIndex = Math.max(0, Math.min(state.history.length, state.historyIndex + (e.key === "ArrowUp" ? -1 : 1)));
  e.target.value = state.history[state.historyIndex] || "";
});

// --- Broadcast & restart --------------------------------------------------------

const dialog = $("#broadcast-dialog");

$("#broadcast-open").addEventListener("click", () => {
  dialog.showModal();
  $("#broadcast-message").focus();
});

$("#broadcast-cancel").addEventListener("click", () => dialog.close());

$("#broadcast-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const message = $("#broadcast-message").value;
  try {
    await api("/api/broadcast", { method: "POST", body: { message } });
    dialog.close();
    $("#broadcast-message").value = "";
    toast("Message sent to everyone online.");
  } catch (err) {
    toast(err.message, "error");
  }
});

$("#restart").addEventListener("click", (e) => {
  confirmThen(e.currentTarget, "Click again to restart", async () => {
    try {
      await api("/api/restart", { method: "POST" });
      state.restart = "requested";
      toast("Restarting. Players are disconnected and can rejoin in about a minute.");
      refreshStatus();
    } catch (err) {
      toast(err.message, "error");
    }
  });
});

// --- Backups -------------------------------------------------------------------

let backupWasRunning = false;

async function refreshBackups() {
  let b;
  try { b = await api("/api/backups"); } catch { return; }

  if (backupWasRunning && !b.running) {
    b.error ? toast(`Backup failed: ${b.error}`, "error") : toast("Backup finished.");
  }
  backupWasRunning = b.running;

  const now = $("#backup-now");
  now.disabled = b.running || !b.writable;
  now.textContent = b.running ? "Backing up…" : "Back up now";

  const hint = $("#backup-hint");
  hint.classList.toggle("error", !b.writable || !!b.error);
  if (!b.writable) {
    hint.textContent = "The panel can't write to the backups folder. On the server, run: chown 1000:1000 /opt/minecraft/backups";
  } else if (b.error) {
    hint.textContent = `The last backup failed: ${b.error}`;
  } else if (b.interval_hours > 0) {
    const every = b.interval_hours === 24 ? "once a day" : `every ${b.interval_hours} hours`;
    const next = b.next ? ` Next one ${formatTime(b.next)}.` : "";
    hint.textContent = `Backs up automatically ${every} and keeps the newest ${b.keep}.${next}`;
  } else {
    hint.textContent = "Automatic backups are off. Set BACKUP_INTERVAL_HOURS in .env to turn them on.";
  }

  const list = $("#backup-list");
  list.replaceChildren();
  if (!b.backups.length) {
    list.append(el("li", "empty", "No backups yet."));
    return;
  }
  for (const backup of b.backups) {
    const li = el("li");
    const who = el("div", "who");
    who.append(el("strong", "", formatTime(backup.created)), el("small", "", formatSize(backup.size)));
    const actions = el("div", "actions");
    const download = el("a", "mc-button small", "Download");
    download.href = `/api/backups/${encodeURIComponent(backup.name)}`;
    download.setAttribute("download", backup.name);
    const del = button("Delete");
    del.setAttribute("aria-label", `Delete backup from ${formatTime(backup.created)}`);
    del.addEventListener("click", () => confirmThen(del, "Click again", async () => {
      try {
        await api(`/api/backups/${encodeURIComponent(backup.name)}`, { method: "DELETE" });
        toast("Backup deleted.");
        refreshBackups();
      } catch (err) {
        toast(err.message, "error");
      }
    }));
    actions.append(download, del);
    li.append(who, actions);
    list.append(li);
  }
}

$("#backup-now").addEventListener("click", async () => {
  try {
    await api("/api/backups", { method: "POST" });
    toast("Backup started. The world keeps running while it saves.");
    backupWasRunning = true;
    refreshBackups();
  } catch (err) {
    toast(err.message, "error");
  }
});

// --- Start ---------------------------------------------------------------------

selectTab(state.tab);
api("/api/status")
  .then(startApp)
  .catch((err) => { if (err.status !== 401) showLogin(err.message); });
