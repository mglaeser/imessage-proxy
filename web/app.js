const STORAGE_KEY = "imessage-proxy.admin-key";
const MAX_RENDERED_RESPONSE_CHARACTERS = 100000;
// What the service appends before the identifier. SMS is GSM-7, where a single
// character outside that alphabet would cut the segment from 160 to 70; iMessage
// pays nothing for the clearer glyph.
const SEND_MARKERS = new Map([["imessage", "\u{1F516}"], ["sms", "^"]]);
const SENDER_IDENTIFIER_PATTERN = /^[a-z]{2,8}$/;

const elements = {
  auditFields: document.querySelector("#audit-fields"),
  auditLimit: document.querySelector("#audit-limit"),
  cancelSend: document.querySelector("#cancel-send"),
  cancelRevoke: document.querySelector("#cancel-revoke"),
  chatFields: document.querySelector("#chat-fields"),
  chatMessagesFields: document.querySelector("#chat-messages-fields"),
  chatsFields: document.querySelector("#chats-fields"),
  chatsLimit: document.querySelector("#chats-limit"),
  chatsUnread: document.querySelector("#chats-unread"),
  closeKeyDialog: document.querySelector("#close-key-dialog"),
  connectionChip: document.querySelector("#connection-chip"),
  connectionLabel: document.querySelector("#connection-label"),
  confirmRevoke: document.querySelector("#confirm-revoke"),
  confirmSend: document.querySelector("#confirm-send"),
  consoleView: document.querySelector("#console-view"),
  copyKeyButton: document.querySelector("#copy-key-button"),
  copyStatus: document.querySelector("#copy-status"),
  createButton: document.querySelector("#create-button"),
  createError: document.querySelector("#create-error"),
  createForm: document.querySelector("#create-form"),
  createdKey: document.querySelector("#created-key"),
  createdKeyDialog: document.querySelector("#created-key-dialog"),
  keyCount: document.querySelector("#key-count"),
  keyFields: document.querySelector("#key-fields"),
  keyIdentifier: document.querySelector("#key-identifier"),
  keysPanel: document.querySelector("#keys-panel"),
  keysTab: document.querySelector("#keys-tab"),
  keysBody: document.querySelector("#keys-body"),
  keysEmpty: document.querySelector("#keys-empty"),
  logoutButton: document.querySelector("#logout-button"),
  messagesDetail: document.querySelector("#messages-detail"),
  messagesEnd: document.querySelector("#messages-end"),
  messagesLimit: document.querySelector("#messages-limit"),
  messagesParticipant: document.querySelector("#messages-participant"),
  messagesStart: document.querySelector("#messages-start"),
  messagesStatus: document.querySelector("#messages-status"),
  openPlayground: document.querySelector("#open-playground"),
  operationChat: document.querySelector("#operation-chat"),
  operationChatBackground: document.querySelector("#operation-chat-background"),
  operationChatMessages: document.querySelector("#operation-chat-messages"),
  operationChats: document.querySelector("#operation-chats"),
  operationMessageStatistics: document.querySelector("#operation-message-statistics"),
  operationScheduledMessages: document.querySelector("#operation-scheduled-messages"),
  overviewPanel: document.querySelector("#overview-panel"),
  overviewTab: document.querySelector("#overview-tab"),
  playgroundChatID: document.querySelector("#playground-chat-id"),
  playgroundDuration: document.querySelector("#playground-duration"),
  playgroundError: document.querySelector("#playground-error"),
  playgroundForm: document.querySelector("#playground-form"),
  playgroundHTTPStatus: document.querySelector("#playground-http-status"),
  playgroundKeyID: document.querySelector("#playground-key-id"),
  playgroundMeta: document.querySelector("#playground-meta"),
  playgroundOperation: document.querySelector("#playground-operation"),
  playgroundOutput: document.querySelector("#playground-output"),
  playgroundPanel: document.querySelector("#playground-panel"),
  playgroundPreview: document.querySelector("#playground-preview"),
  playgroundRequestID: document.querySelector("#playground-request-id"),
  playgroundRun: document.querySelector("#playground-run"),
  playgroundStatus: document.querySelector("#playground-status"),
  playgroundTab: document.querySelector("#playground-tab"),
  readDisabledNotice: document.querySelector("#read-disabled-notice"),
  refreshButton: document.querySelector("#refresh-button"),
  revokeDialog: document.querySelector("#revoke-dialog"),
  revokeForm: document.querySelector("#revoke-form"),
  revokeKeyName: document.querySelector("#revoke-key-name"),
  scheduledFields: document.querySelector("#scheduled-fields"),
  scheduledLimit: document.querySelector("#scheduled-limit"),
  sendConfirmForm: document.querySelector("#send-confirm-form"),
  sendDialog: document.querySelector("#send-dialog"),
  sendDialogTarget: document.querySelector("#send-dialog-target"),
  sendFields: document.querySelector("#send-fields"),
  sendService: document.querySelector("#send-service"),
  sendSignature: document.querySelector("#send-signature"),
  sendTarget: document.querySelector("#send-target"),
  sendTargetChat: document.querySelector("#send-target-chat"),
  sendTargetKind: document.querySelector("#send-target-kind"),
  sendText: document.querySelector("#send-text"),
  serviceDetail: document.querySelector("#service-detail"),
  serviceStatus: document.querySelector("#service-status"),
  serviceUptime: document.querySelector("#service-uptime"),
  serviceVersion: document.querySelector("#service-version"),
  signinButton: document.querySelector("#signin-button"),
  signinError: document.querySelector("#signin-error"),
  signinForm: document.querySelector("#signin-form"),
  signinKey: document.querySelector("#signin-key"),
  signinView: document.querySelector("#signin-view"),
  statisticsChatID: document.querySelector("#statistics-chat-id"),
  statisticsFields: document.querySelector("#statistics-fields"),
  statisticsMedia: document.querySelector("#statistics-media"),
  statisticsTimeZone: document.querySelector("#statistics-time-zone"),
  statusUpdated: document.querySelector("#status-updated"),
  allowButton: document.querySelector("#allow-button"),
  allowError: document.querySelector("#allow-error"),
  allowForm: document.querySelector("#allow-form"),
  allowKind: document.querySelector("#allow-kind"),
  allowValue: document.querySelector("#allow-value"),
  allowValueHelp: document.querySelector("#allow-value-help"),
  allowValueLabel: document.querySelector("#allow-value-label"),
  cancelRemoveTarget: document.querySelector("#cancel-remove-target"),
  confirmRemoveTarget: document.querySelector("#confirm-remove-target"),
  removeTargetDialog: document.querySelector("#remove-target-dialog"),
  removeTargetForm: document.querySelector("#remove-target-form"),
  removeTargetName: document.querySelector("#remove-target-name"),
  targetCount: document.querySelector("#target-count"),
  targetsBody: document.querySelector("#targets-body"),
  targetsEmpty: document.querySelector("#targets-empty"),
  targetsPanel: document.querySelector("#targets-panel"),
  targetsTab: document.querySelector("#targets-tab"),
  toast: document.querySelector("#toast"),
  toggleKey: document.querySelector("#toggle-key"),
};

let activeKey = "";
let copyTimer = null;
let allowedTargets = [];
let senderIdentifiers = new Map();
let signedInKeyID = "";
let pendingPlaygroundRequest = null;
let pendingRevocation = null;
let pendingTargetRemoval = null;
let playgroundController = new AbortController();
let playgroundGeneration = 0;
let sendAttempt = null;
let sessionController = new AbortController();
let sessionGeneration = 0;
let toastTimer = null;

class RequestError extends Error {
  constructor(message, status, payload = null, requestID = "") {
    super(message);
    this.name = "RequestError";
    this.payload = payload;
    this.requestID = requestID;
    this.status = status;
  }
}

class SessionEndedError extends Error {
  constructor() {
    super("The authenticated session ended.");
    this.name = "SessionEndedError";
  }
}

function beginSession(key) {
  sessionController.abort();
  playgroundController.abort();
  sessionController = new AbortController();
  playgroundController = new AbortController();
  playgroundGeneration += 1;
  sessionGeneration += 1;
  activeKey = key;
  return sessionGeneration;
}

function invalidateSession() {
  sessionController.abort();
  playgroundController.abort();
  sessionController = new AbortController();
  playgroundController = new AbortController();
  playgroundGeneration += 1;
  sessionGeneration += 1;
  activeKey = "";
}

function requireCurrentSession(generation) {
  if (generation !== sessionGeneration || sessionController.signal.aborted || !activeKey) {
    throw new SessionEndedError();
  }
}

function sessionEnded(error) {
  return error instanceof SessionEndedError;
}

function sessionKey() {
  try {
    return sessionStorage.getItem(STORAGE_KEY) || "";
  } catch {
    return "";
  }
}

function persistSessionKey(value) {
  try {
    if (value) {
      sessionStorage.setItem(STORAGE_KEY, value);
    } else {
      sessionStorage.removeItem(STORAGE_KEY);
    }
  } catch {
    // The console still works for this page lifetime when storage is unavailable.
  }
}

function setFormError(element, message = "") {
  element.textContent = message;
  element.hidden = !message;
}

function showToast(message) {
  if (toastTimer !== null) {
    window.clearTimeout(toastTimer);
  }
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  toastTimer = window.setTimeout(() => {
    elements.toast.hidden = true;
    elements.toast.textContent = "";
    toastTimer = null;
  }, 4200);
}

function setConnection(state, label) {
  elements.connectionChip.dataset.state = state;
  elements.connectionLabel.textContent = label;
}

const consoleSections = [
  { panel: elements.overviewPanel, tab: elements.overviewTab },
  { panel: elements.playgroundPanel, tab: elements.playgroundTab },
  { panel: elements.targetsPanel, tab: elements.targetsTab },
  { panel: elements.keysPanel, tab: elements.keysTab },
];

function activateConsoleSection(tab, focus = false) {
  for (const section of consoleSections) {
    const selected = section.tab === tab;
    section.tab.setAttribute("aria-selected", String(selected));
    section.tab.setAttribute("tabindex", selected ? "0" : "-1");
    section.panel.hidden = !selected;
  }
  if (focus) {
    tab.focus();
  }
}

function handleTabKeydown(event) {
  const current = consoleSections.findIndex((section) => section.tab === event.currentTarget);
  if (current < 0) {
    return;
  }
  let next = current;
  if (event.key === "ArrowRight") {
    next = (current + 1) % consoleSections.length;
  } else if (event.key === "ArrowLeft") {
    next = (current + consoleSections.length - 1) % consoleSections.length;
  } else if (event.key === "Home") {
    next = 0;
  } else if (event.key === "End") {
    next = consoleSections.length - 1;
  } else {
    return;
  }
  event.preventDefault();
  activateConsoleSection(consoleSections[next].tab, true);
}

function showSignin(message = "") {
  elements.consoleView.hidden = true;
  elements.signinView.hidden = false;
  setConnection("signed-out", "Signed out");
  setFormError(elements.signinError, message);
  window.setTimeout(() => elements.signinKey.focus(), 0);
}

function clearCreatedKey() {
  if (copyTimer !== null) {
    window.clearTimeout(copyTimer);
    copyTimer = null;
  }
  elements.createdKey.value = "";
  elements.copyKeyButton.textContent = "Copy key";
  elements.copyStatus.textContent = "";
}

function resetPlaygroundResponse() {
  playgroundController.abort();
  playgroundController = new AbortController();
  playgroundGeneration += 1;
  pendingPlaygroundRequest = null;
  elements.playgroundForm.setAttribute("aria-busy", "false");
  elements.playgroundRun.disabled = false;
  elements.playgroundMeta.hidden = true;
  elements.playgroundHTTPStatus.textContent = "—";
  elements.playgroundDuration.textContent = "—";
  elements.playgroundRequestID.textContent = "—";
  elements.playgroundStatus.textContent = "Not run yet";
  elements.playgroundStatus.dataset.state = "idle";
  elements.playgroundOutput.textContent = "Select an endpoint and run it to see bounded JSON here.";
  setFormError(elements.playgroundError);
}

function clearPlayground() {
  resetPlaygroundResponse();
  sendAttempt = null;
  elements.playgroundForm.reset();
  elements.playgroundOperation.value = "status";
  elements.chatsLimit.value = "20";
  elements.messagesLimit.value = "50";
  elements.scheduledLimit.value = "50";
  elements.statisticsTimeZone.value = "UTC";
  elements.auditLimit.value = "100";
  elements.playgroundKeyID.value = "";
  elements.sendService.value = "imessage";
  elements.sendTargetKind.value = "recipient";
  updatePlaygroundOperation();
}

function clearConsoleData() {
  signedInKeyID = "";
  senderIdentifiers = new Map();
  applyMessagesReadState(false, "");
  elements.keysBody.replaceChildren();
  elements.keyCount.textContent = "0 keys";
  elements.keysEmpty.hidden = true;
  allowedTargets = [];
  elements.targetsBody.replaceChildren();
  elements.targetCount.textContent = "0 recipients";
  elements.targetsEmpty.hidden = true;
  elements.allowForm.reset();
  elements.allowButton.disabled = false;
  elements.confirmRemoveTarget.disabled = false;
  updateAllowKind();
  elements.serviceStatus.textContent = "Signed out";
  elements.messagesStatus.textContent = "—";
  elements.serviceVersion.textContent = "—";
  elements.serviceUptime.textContent = "—";
  elements.serviceDetail.textContent = "Secure endpoint";
  elements.statusUpdated.textContent = "Waiting for the first status check.";
  elements.createForm.reset();
  elements.createForm.elements.expires_in_days.value = "90";
  setFormError(elements.createError);
  elements.keyIdentifier.setAttribute("aria-invalid", "false");
  elements.createButton.disabled = false;
  elements.refreshButton.disabled = false;
  elements.confirmRevoke.disabled = false;
  elements.confirmSend.disabled = false;
  activateConsoleSection(elements.overviewTab);
  clearPlayground();
  if (toastTimer !== null) {
    window.clearTimeout(toastTimer);
    toastTimer = null;
  }
  elements.toast.hidden = true;
  elements.toast.textContent = "";
}

function signOut(message = "") {
  invalidateSession();
  pendingPlaygroundRequest = null;
  pendingRevocation = null;
  pendingTargetRemoval = null;
  sendAttempt = null;
  persistSessionKey("");
  elements.signinKey.value = "";
  clearCreatedKey();
  if (elements.createdKeyDialog.open) {
    elements.createdKeyDialog.close();
  }
  if (elements.revokeDialog.open) {
    elements.revokeDialog.close();
  }
  if (elements.sendDialog.open) {
    elements.sendDialog.close();
  }
  if (elements.removeTargetDialog.open) {
    elements.removeTargetDialog.close();
  }
  clearConsoleData();
  showSignin(message);
}

function responseMessage(payload, fallback) {
  if (payload && typeof payload.detail === "string" && payload.detail) {
    return payload.detail;
  }
  return fallback;
}

async function apiExchange(path, options = {}, generation = sessionGeneration, signal = sessionController.signal) {
  requireCurrentSession(generation);
  const key = activeKey;
  const headers = new Headers(options.headers || {});
  headers.set("Accept", "application/json, application/problem+json");
  headers.set("Authorization", `Bearer ${key}`);
  if (options.body !== undefined) {
    headers.set("Content-Type", "application/json");
  }

  let response;
  try {
    response = await fetch(path, {
      ...options,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      cache: "no-store",
      credentials: "omit",
      headers,
      referrerPolicy: "no-referrer",
      signal,
    });
  } catch (error) {
    if (error?.name === "AbortError" || generation !== sessionGeneration || signal.aborted) {
      throw new SessionEndedError();
    }
    throw new RequestError("The service could not be reached.", 0);
  }
  requireCurrentSession(generation);

  let payload = null;
  const contentType = (response.headers.get("content-type") || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  const hasJsonBody = contentType === "application/json" || contentType.endsWith("+json");
  if (response.status !== 204 && !hasJsonBody) {
    throw new RequestError("The service returned an unexpected response type.", response.status);
  }
  if (response.status !== 204 && hasJsonBody) {
    try {
      payload = await response.json();
    } catch {
      throw new RequestError("The service returned an invalid JSON response.", response.status);
    }
  }
  requireCurrentSession(generation);

  const requestID = response.headers.get("x-request-id") ||
    (payload && typeof payload.request_id === "string" ? payload.request_id : "");

  if (response.status === 401) {
    if (generation === sessionGeneration) {
      signOut("The API key is invalid, expired, or revoked.");
    }
    throw new RequestError("Authentication is required.", 401, payload, requestID);
  }
  return {
    ok: response.ok,
    payload,
    requestID,
    status: response.status,
  };
}

async function apiRequest(path, options = {}, generation = sessionGeneration) {
  const exchange = await apiExchange(path, options, generation);
  if (!exchange.ok) {
    throw new RequestError(
      responseMessage(exchange.payload, `Request failed with status ${exchange.status}.`),
      exchange.status,
      exchange.payload,
      exchange.requestID,
    );
  }
  return exchange.payload;
}

function titleCaseStatus(value) {
  const normalized = String(value || "unknown").trim().toLowerCase();
  if (normalized === "ok" || normalized === "healthy" || normalized === "ready") {
    return "Healthy";
  }
  if (normalized === "degraded") {
    return "Degraded";
  }
  if (normalized === "unavailable" || normalized === "down" || normalized === "error") {
    return "Unavailable";
  }
  return normalized ? normalized.charAt(0).toUpperCase() + normalized.slice(1) : "Unknown";
}

function formatUptime(rawValue) {
  if (!Number.isSafeInteger(rawValue) || rawValue < 0) {
    return "—";
  }
  const seconds = rawValue;
  if (seconds < 60) {
    return `${Math.floor(seconds)}s`;
  }
  if (seconds < 3600) {
    return `${Math.floor(seconds / 60)}m`;
  }
  if (seconds < 86400) {
    return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  }
  return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}

function parseDate(value) {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  if (typeof value !== "string") {
    return null;
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function formatDate(value, fallback = "Never") {
  const date = parseDate(value);
  if (!date) {
    return fallback;
  }
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

// Full Disk Access is the one macOS permission that is never prompted for, so an
// installation may legitimately decline it and only send. Everything the service
// would then refuse with messages-read-disabled is greyed rather than hidden, and
// the command that turns reading back on travels with it: only the operator at
// that machine can act on it, and a dead control teaches them nothing.
function applyMessagesReadState(disabled, command) {
  for (const [operation, option] of MESSAGES_READ_OPTIONS) {
    const { preview } = PLAYGROUND_OPERATIONS.get(operation);
    option.disabled = disabled;
    option.textContent = disabled ? `${preview} · reading Messages is off` : preview;
  }
  elements.sendTargetChat.disabled = disabled;
  elements.sendTargetChat.textContent = disabled ? "Chat ID · reading Messages is off" : "Chat ID";

  const refused = "Reading Messages is turned off for this installation, so chats, scheduled " +
    "messages, statistics, and sending to a chat ID are refused. Sending to a recipient still works.";
  const enable = command ? ` Turn it on with: ${command}` : "";
  elements.readDisabledNotice.hidden = !disabled;
  elements.readDisabledNotice.textContent = disabled ? `${refused}${enable}` : "";
  elements.messagesDetail.textContent = disabled
    ? (command ? `Turn on with: ${command}` : "Reading is turned off")
    : "Native service";

  // A refresh can turn reading off while a now-refused choice is selected, and a
  // disabled option keeps its selection in the browser.
  if (disabled && elements.sendTargetKind.value === "chat_id") {
    elements.sendTargetKind.value = "recipient";
    updateSendTargetHint();
  }
  if (disabled && MESSAGES_READ_OPTIONS.has(elements.playgroundOperation.value)) {
    elements.playgroundOperation.value = "status";
    updatePlaygroundOperation();
  }
}

function renderStatus(payload) {
  const serviceRaw = payload?.status || "unknown";
  const messagesRaw = payload?.messages?.status || "unknown";
  const serviceLabel = titleCaseStatus(serviceRaw);
  const messagesLabel = titleCaseStatus(messagesRaw);
  const healthy = serviceLabel === "Healthy";
  const enableWith = typeof payload?.messages?.enable_with === "string" ? payload.messages.enable_with : "";

  signedInKeyID = typeof payload?.key?.id === "string" ? payload.key.id : "";
  applyMessagesReadState(String(messagesRaw).toLowerCase() === "disabled", enableWith);
  elements.serviceStatus.textContent = serviceLabel;
  elements.messagesStatus.textContent = messagesLabel;
  elements.serviceVersion.textContent = String(payload?.version || "—");
  elements.serviceUptime.textContent = formatUptime(payload?.uptime_seconds);
  elements.serviceDetail.textContent = healthy
    ? "All checks passed"
    : String(payload?.detail || "Review service health");
  elements.statusUpdated.textContent = `Last checked ${new Intl.DateTimeFormat(undefined, { timeStyle: "medium" }).format(new Date())}`;
  setConnection(healthy ? "online" : "degraded", serviceLabel);
}

function normalizedKeys(payload) {
  if (!payload || !Array.isArray(payload.keys)) {
    throw new RequestError("The service returned an invalid API-key list.", 502);
  }
  return payload.keys;
}

function appendText(parent, className, value) {
  const element = document.createElement("span");
  element.className = className;
  element.textContent = value;
  parent.append(element);
  return element;
}

function renderPlaygroundKeyChoices(keys) {
  const current = elements.playgroundKeyID.value;
  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = keys.length === 0 ? "No API keys available" : "Select a key";
  elements.playgroundKeyID.replaceChildren(placeholder);
  for (const key of keys) {
    const id = String(key?.id || "");
    if (!id) {
      continue;
    }
    const option = document.createElement("option");
    option.value = id;
    option.textContent = `${String(key?.name || "Unnamed key")} · ${String(key?.key_prefix || id)}`;
    elements.playgroundKeyID.append(option);
  }
  if (keys.some((key) => String(key?.id || "") === current)) {
    elements.playgroundKeyID.value = current;
  }
}

function renderKeys(payload) {
  const keys = normalizedKeys(payload);
  elements.keysBody.replaceChildren();
  elements.keyCount.textContent = `${keys.length} ${keys.length === 1 ? "key" : "keys"}`;
  elements.keysEmpty.hidden = keys.length !== 0;
  renderPlaygroundKeyChoices(keys);
  senderIdentifiers = new Map();

  for (const key of keys) {
    const row = document.createElement("tr");
    const nameCell = document.createElement("td");
    const identifierCell = document.createElement("td");
    const scopesCell = document.createElement("td");
    const expiryCell = document.createElement("td");
    const lastUsedCell = document.createElement("td");
    const actionCell = document.createElement("td");
    const revokedAt = key?.revoked_at ?? null;
    const keyID = String(key?.id || "");
    const keyName = String(key?.name || "Unnamed key");

    appendText(nameCell, "key-name", keyName);
    appendText(nameCell, "key-prefix", String(key?.key_prefix || "prefix unavailable"));
    if (revokedAt) {
      appendText(nameCell, "state-badge", "Revoked");
    }

    const identifier = typeof key?.sender_identifier === "string" ? key.sender_identifier : "";
    const assigned = key?.sender_identifier_assigned === true;
    if (keyID && identifier) {
      senderIdentifiers.set(keyID, identifier);
    }
    appendText(identifierCell, "sender-tag", identifier || "unavailable");
    const originBadge = appendText(identifierCell, "origin-badge", assigned ? "Service-assigned" : "Operator-chosen");
    originBadge.dataset.origin = assigned ? "assigned" : "chosen";

    const scopeList = document.createElement("div");
    scopeList.className = "scope-list";
    const scopes = Array.isArray(key?.scopes) ? key.scopes : [];
    if (scopes.length === 0) {
      appendText(scopeList, "scope-badge", "No scopes");
    } else {
      for (const scope of scopes) {
        appendText(scopeList, "scope-badge", String(scope));
      }
    }
    scopesCell.append(scopeList);

    expiryCell.textContent = revokedAt
      ? `Revoked ${formatDate(revokedAt, "")}`
      : formatDate(key?.expires_at);
    lastUsedCell.textContent = formatDate(key?.last_used_at, "Not yet");

    const revokeButton = document.createElement("button");
    revokeButton.className = "revoke-button";
    revokeButton.type = "button";
    revokeButton.textContent = revokedAt ? "Revoked" : "Revoke";
    revokeButton.disabled = Boolean(revokedAt) || !keyID;
    revokeButton.addEventListener("click", () => openRevokeDialog(keyID, keyName));
    actionCell.append(revokeButton);

    row.append(nameCell, identifierCell, scopesCell, expiryCell, lastUsedCell, actionCell);
    elements.keysBody.append(row);
  }
  updateSendSignature();
}

// The allowlist is the send-authorisation boundary. The service exposes it only
// to an admin key, which is also the only key that can reach this console at
// all, so a stolen messages:send credential can never widen the set of people
// it may write to - it can only use the destinations an operator approved here.
function normalizedTargets(payload) {
  if (!payload || !Array.isArray(payload.targets)) {
    throw new RequestError("The service returned an invalid recipient list.", 502);
  }
  return payload.targets.map((entry) => String(entry ?? ""));
}

// Kept in step with IsDirectMessageRecipient in src/imessage-proxy-server.m and
// target_is_valid in bin/imessage-proxy, so a rejection is explained inline
// instead of arriving as an opaque 400.
function targetProblem(value) {
  if (value.startsWith("chat_id:")) {
    return /^chat_id:[1-9][0-9]{0,17}$/.test(value)
      ? ""
      : "A chat must be chat_id: followed by the chat's number, such as chat_id:42.";
  }
  if (!value) {
    return "Enter a phone number or handle.";
  }
  if (Array.from(value).length > 256) {
    return "A recipient may be at most 256 characters.";
  }
  if (value.startsWith("-")) {
    return "A recipient may not start with a dash.";
  }
  if (/[\s\p{Cc}\p{Cf}]/u.test(value)) {
    return "A recipient may not contain spaces or control characters.";
  }
  if (value.startsWith("+")) {
    return /^\+[1-9][0-9]{6,14}$/.test(value)
      ? ""
      : "A phone number must be + followed by 7 to 15 digits, with no leading zero, such as +15551234567.";
  }
  const at = value.indexOf("@");
  if (at <= 0 || at !== value.lastIndexOf("@") || at === value.length - 1) {
    return "A handle must contain exactly one @, with text on both sides.";
  }
  return "";
}

function describeTargetKind(value) {
  if (value.startsWith("chat_id:")) {
    return "Chat";
  }
  return value.startsWith("+") ? "Phone number" : "Handle";
}

function renderTargets(payload) {
  const targets = normalizedTargets(payload).slice().sort((left, right) => left.localeCompare(right));
  allowedTargets = targets;
  elements.targetsBody.replaceChildren();
  elements.targetCount.textContent =
    `${targets.length} ${targets.length === 1 ? "recipient" : "recipients"}`;
  elements.targetsEmpty.hidden = targets.length !== 0;

  for (const target of targets) {
    const row = document.createElement("tr");
    const valueCell = document.createElement("td");
    const kindCell = document.createElement("td");
    const actionCell = document.createElement("td");

    appendText(valueCell, "key-name", target);
    kindCell.textContent = describeTargetKind(target);

    const removeButton = document.createElement("button");
    removeButton.className = "revoke-button";
    removeButton.type = "button";
    removeButton.textContent = "Remove";
    removeButton.addEventListener("click", () => openRemoveTargetDialog(target));
    actionCell.append(removeButton);

    row.append(valueCell, kindCell, actionCell);
    elements.targetsBody.append(row);
  }
}

// One endpoint replaces the whole list, so both add and remove send the full set
// and re-render from what the service actually stored. That keeps the table
// honest when another operator, or the CLI, changed the file underneath.
async function replaceTargets(targets, generation) {
  const saved = await apiRequest("/api/targets", {
    body: { targets },
    method: "PUT",
  }, generation);
  requireCurrentSession(generation);
  renderTargets(saved);
}

function updateAllowKind() {
  const chat = elements.allowKind.value === "chat_id";
  elements.allowValueLabel.textContent = chat ? "Chat number" : "Phone number or handle";
  elements.allowValue.placeholder = chat ? "42" : "person@example.net";
  elements.allowValueHelp.textContent = chat
    ? "The numeric id of an existing conversation, as listed by GET /api/chats."
    : "A phone number in + international form, or a handle containing one @.";
  elements.allowValue.value = "";
  setFormError(elements.allowError);
  elements.allowValue.setAttribute("aria-invalid", "false");
}

async function handleAllowTarget(event) {
  event.preventDefault();
  setFormError(elements.allowError);
  elements.allowValue.setAttribute("aria-invalid", "false");

  const raw = String(elements.allowValue.value || "").trim();
  const target = elements.allowKind.value === "chat_id" ? `chat_id:${raw}` : raw;
  const problem = targetProblem(target);
  if (problem) {
    elements.allowValue.setAttribute("aria-invalid", "true");
    setFormError(elements.allowError, problem);
    elements.allowValue.focus();
    return;
  }
  if (allowedTargets.includes(target)) {
    elements.allowValue.setAttribute("aria-invalid", "true");
    setFormError(elements.allowError, `${target} is already allowed.`);
    elements.allowValue.focus();
    return;
  }

  const generation = sessionGeneration;
  elements.allowButton.disabled = true;
  try {
    await replaceTargets(allowedTargets.concat([target]), generation);
    elements.allowValue.value = "";
    showToast(`${target} can now be messaged.`);
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      setFormError(elements.allowError, error.message);
    }
  } finally {
    elements.allowButton.disabled = false;
  }
}

function openRemoveTargetDialog(target) {
  pendingTargetRemoval = target;
  elements.removeTargetName.textContent = target;
  elements.removeTargetDialog.showModal();
  window.setTimeout(() => elements.confirmRemoveTarget.focus(), 0);
}

function closeRemoveTargetDialog() {
  pendingTargetRemoval = null;
  elements.removeTargetName.textContent = "This recipient";
  elements.removeTargetDialog.close();
}

async function handleRemoveTarget(event) {
  event.preventDefault();
  if (!pendingTargetRemoval) {
    return;
  }
  const target = pendingTargetRemoval;
  const generation = sessionGeneration;
  elements.confirmRemoveTarget.disabled = true;
  try {
    await replaceTargets(allowedTargets.filter((entry) => entry !== target), generation);
    closeRemoveTargetDialog();
    showToast(`${target} can no longer be messaged.`);
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      showToast(error.message);
    }
  } finally {
    elements.confirmRemoveTarget.disabled = false;
  }
}

class PlaygroundValidationError extends Error {
  constructor(message, field = null) {
    super(message);
    this.name = "PlaygroundValidationError";
    this.field = field;
  }
}

function codePointLength(value) {
  return Array.from(value).length;
}

function requiredInteger(field, label, minimum, maximum = Number.MAX_SAFE_INTEGER, optional = false) {
  field.setAttribute("aria-invalid", "false");
  const raw = String(field.value || "").trim();
  if (optional && !raw) {
    return null;
  }
  const value = Number(raw);
  if (!raw || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    field.setAttribute("aria-invalid", "true");
    const range = maximum === Number.MAX_SAFE_INTEGER
      ? `${minimum} or greater`
      : `between ${minimum} and ${maximum}`;
    throw new PlaygroundValidationError(`${label} must be a whole number ${range}.`, field);
  }
  return value;
}

function addQuery(path, values) {
  const query = new URLSearchParams();
  for (const [name, value] of values) {
    if (value !== null && value !== undefined && value !== "") {
      query.append(name, String(value));
    }
  }
  const serialized = query.toString();
  return serialized ? `${path}?${serialized}` : path;
}

function chatID() {
  return requiredInteger(elements.playgroundChatID, "Chat ID", 1);
}

function buildStatusRequest() {
  return { method: "GET", path: "/api/status" };
}

function buildChatsRequest() {
  const limit = requiredInteger(elements.chatsLimit, "Chat limit", 1, 100);
  return {
    method: "GET",
    path: addQuery("/api/chats", [
      ["limit", limit],
      ["unread_only", elements.chatsUnread.checked ? "true" : null],
    ]),
  };
}

function buildChatRequest() {
  return { method: "GET", path: `/api/chats/${chatID()}` };
}

function validateOptionalDate(field, label) {
  field.setAttribute("aria-invalid", "false");
  const value = String(field.value || "").trim();
  if (!value) {
    return "";
  }
  const pattern = /^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))$/;
  const match = pattern.exec(value);
  if (!match) {
    field.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError(`${label} must use strict RFC 3339 format.`, field);
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysByMonth = [0, 31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || day > daysByMonth[month]) {
    field.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError(`${label} must contain a valid Gregorian calendar date.`, field);
  }
  return value;
}

function buildChatMessagesRequest() {
  const id = chatID();
  const limit = requiredInteger(elements.messagesLimit, "Message limit", 1, 200);
  const participant = String(elements.messagesParticipant.value || "");
  elements.messagesParticipant.setAttribute("aria-invalid", "false");
  if (participant && (
    codePointLength(participant) > 256 ||
    participant.startsWith("-") ||
    participant.includes(",") ||
    /[\u0000-\u001F\u007F-\u009F]/u.test(participant)
  )) {
    elements.messagesParticipant.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("Participant must be one exact handle without commas or control characters.", elements.messagesParticipant);
  }
  const start = validateOptionalDate(elements.messagesStart, "Start");
  const end = validateOptionalDate(elements.messagesEnd, "End");
  if (start && end && Date.parse(end) <= Date.parse(start)) {
    elements.messagesEnd.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("End must be later than start.", elements.messagesEnd);
  }
  return {
    method: "GET",
    path: addQuery(`/api/chats/${id}/messages`, [
      ["limit", limit],
      ["participant", participant],
      ["start", start],
      ["end", end],
    ]),
  };
}

function buildChatBackgroundRequest() {
  return { method: "GET", path: `/api/chats/${chatID()}/background` };
}

function buildScheduledRequest() {
  const limit = requiredInteger(elements.scheduledLimit, "Scheduled-message limit", 1, 100);
  return { method: "GET", path: addQuery("/api/scheduled-messages", [["limit", limit]]) };
}

function buildStatisticsRequest() {
  const id = requiredInteger(elements.statisticsChatID, "Statistics chat ID", 1, Number.MAX_SAFE_INTEGER, true);
  const timeZone = String(elements.statisticsTimeZone.value || "").trim();
  elements.statisticsTimeZone.setAttribute("aria-invalid", "false");
  if (!timeZone || new TextEncoder().encode(timeZone).length > 64 || /[\u0000-\u001F\u007F-\u009F]/u.test(timeZone)) {
    elements.statisticsTimeZone.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("Time zone must contain 1–64 UTF-8 bytes without control characters.", elements.statisticsTimeZone);
  }
  return {
    method: "GET",
    path: addQuery("/api/statistics/messages", [
      ["chat_id", id],
      ["time_zone", timeZone],
      ["include_media", elements.statisticsMedia.checked ? "true" : null],
    ]),
  };
}

function buildAuditRequest() {
  const limit = requiredInteger(elements.auditLimit, "Audit-event limit", 1, 1000);
  return { method: "GET", path: addQuery("/api/audit-events", [["limit", limit]]) };
}

function buildKeysRequest() {
  return { method: "GET", path: "/api/keys" };
}

function buildKeyRequest() {
  const id = String(elements.playgroundKeyID.value || "");
  elements.playgroundKeyID.setAttribute("aria-invalid", "false");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    elements.playgroundKeyID.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("Select an API key from the loaded list.", elements.playgroundKeyID);
  }
  return { method: "GET", path: `/api/keys/${id.toLowerCase()}` };
}

function buildSendRequest() {
  const kind = elements.sendTargetKind.value;
  const service = elements.sendService.value;
  const rawTarget = String(elements.sendTarget.value || "").trim();
  const message = String(elements.sendText.value || "");
  elements.sendService.setAttribute("aria-invalid", "false");
  elements.sendTarget.setAttribute("aria-invalid", "false");
  elements.sendText.setAttribute("aria-invalid", "false");
  if (!SEND_MARKERS.has(service)) {
    elements.sendService.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("Select iMessage or SMS as the service.", elements.sendService);
  }
  let target;
  if (kind === "chat_id") {
    const value = Number(rawTarget);
    if (!rawTarget || !Number.isSafeInteger(value) || value < 1) {
      elements.sendTarget.setAttribute("aria-invalid", "true");
      throw new PlaygroundValidationError("Destination must be a positive whole chat ID.", elements.sendTarget);
    }
    target = { chat_id: value };
  } else if (kind === "recipient") {
    const phone = /^\+[1-9][0-9]{6,14}$/;
    const emailLike = /^[^-\s@\u0000-\u001F\u007F-\u009F][^\s@\u0000-\u001F\u007F-\u009F]*@[^\s@\u0000-\u001F\u007F-\u009F]+$/u;
    if (codePointLength(rawTarget) > 256 || (!phone.test(rawTarget) && !emailLike.test(rawTarget))) {
      elements.sendTarget.setAttribute("aria-invalid", "true");
      throw new PlaygroundValidationError("Destination must be an exact +phone number or email-like handle.", elements.sendTarget);
    }
    target = { recipient: rawTarget };
  } else {
    throw new PlaygroundValidationError("Select a supported destination type.", elements.sendTargetKind);
  }
  if (
    codePointLength(message) < 1 ||
    codePointLength(message) > 4000 ||
    message.startsWith("-") ||
    /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u.test(message)
  ) {
    elements.sendText.setAttribute("aria-invalid", "true");
    throw new PlaygroundValidationError("Message must contain 1–4000 characters, may not start with a hyphen, and may not contain control characters.", elements.sendText);
  }
  const body = { ...target, text: message, service };
  return {
    body,
    method: "POST",
    path: "/api/messages",
    service,
    signature: JSON.stringify(body),
    target: rawTarget,
  };
}

const playgroundFieldGroups = [
  elements.chatsFields,
  elements.chatFields,
  elements.chatMessagesFields,
  elements.scheduledFields,
  elements.statisticsFields,
  elements.auditFields,
  elements.keyFields,
  elements.sendFields,
];

const playgroundValidationFields = [
  elements.auditLimit,
  elements.chatsLimit,
  elements.messagesEnd,
  elements.messagesLimit,
  elements.messagesParticipant,
  elements.messagesStart,
  elements.playgroundChatID,
  elements.playgroundKeyID,
  elements.scheduledLimit,
  elements.sendService,
  elements.sendTarget,
  elements.sendTargetKind,
  elements.sendText,
  elements.statisticsChatID,
  elements.statisticsTimeZone,
];

const PLAYGROUND_OPERATIONS = new Map([
  ["status", { build: buildStatusRequest, groups: [], preview: "GET /api/status" }],
  ["chats", { build: buildChatsRequest, groups: [elements.chatsFields], preview: "GET /api/chats" }],
  ["chat", { build: buildChatRequest, groups: [elements.chatFields], preview: "GET /api/chats/{chat_id}" }],
  ["chat-messages", { build: buildChatMessagesRequest, groups: [elements.chatFields, elements.chatMessagesFields], preview: "GET /api/chats/{chat_id}/messages" }],
  ["chat-background", { build: buildChatBackgroundRequest, groups: [elements.chatFields], preview: "GET /api/chats/{chat_id}/background" }],
  ["scheduled-messages", { build: buildScheduledRequest, groups: [elements.scheduledFields], preview: "GET /api/scheduled-messages" }],
  ["message-statistics", { build: buildStatisticsRequest, groups: [elements.statisticsFields], preview: "GET /api/statistics/messages" }],
  ["send-message", { build: buildSendRequest, groups: [elements.sendFields], preview: "POST /api/messages" }],
  ["audit-events", { build: buildAuditRequest, groups: [elements.auditFields], preview: "GET /api/audit-events" }],
  ["keys", { build: buildKeysRequest, groups: [], preview: "GET /api/keys" }],
  ["key", { build: buildKeyRequest, groups: [elements.keyFields], preview: "GET /api/keys/{key_id}" }],
]);

// Every operation answered out of the Messages database, kept in step with
// RequestReadsMessages in src/imessage-proxy-server.m. Sending is absent: it uses
// Apple Events and works without Full Disk Access, except when a chat_id has to
// be resolved, which is why the chat destination is greyed separately.
const MESSAGES_READ_OPTIONS = new Map([
  ["chats", elements.operationChats],
  ["chat", elements.operationChat],
  ["chat-messages", elements.operationChatMessages],
  ["chat-background", elements.operationChatBackground],
  ["scheduled-messages", elements.operationScheduledMessages],
  ["message-statistics", elements.operationMessageStatistics],
]);

function selectedPlaygroundOperation() {
  return PLAYGROUND_OPERATIONS.get(elements.playgroundOperation.value) || null;
}

function updatePlaygroundOperation() {
  resetPlaygroundResponse();
  for (const field of playgroundValidationFields) {
    field.setAttribute("aria-invalid", "false");
  }
  for (const group of playgroundFieldGroups) {
    group.hidden = true;
  }
  const operation = selectedPlaygroundOperation();
  if (!operation) {
    elements.playgroundPreview.textContent = "Unsupported endpoint";
    setFormError(elements.playgroundError, "Select one of the reviewed API endpoints.");
    return;
  }
  for (const group of operation.groups) {
    group.hidden = false;
  }
  elements.playgroundPreview.textContent = operation.preview;
  updateSendSignature();
  if (elements.playgroundOperation.value === "send-message") {
    updateSendTargetHint();
  }
}

function updateSendTargetHint() {
  const chat = elements.sendTargetKind.value === "chat_id";
  elements.sendTarget.type = chat ? "number" : "text";
  elements.sendTarget.setAttribute("placeholder", chat ? "42" : "person@example.net");
}

function sendServiceLabel(service) {
  return service === "sms" ? "SMS" : "iMessage";
}

// GET /api/status names the signed-in key but not its sender identifier, so the
// suffix shown here is matched out of the key list that loads beside it. Showing
// it before the send is the point: the operator sees the exact characters the
// recipient will read, including which transport they were chosen for.
function updateSendSignature() {
  const identifier = senderIdentifiers.get(signedInKeyID) || "";
  const marker = SEND_MARKERS.get(elements.sendService.value) || "";
  elements.sendSignature.textContent = identifier && marker
    ? ` ${marker}${identifier}`
    : "unavailable until the status check succeeds";
}

function renderPlaygroundBody(payload) {
  let rendered;
  if (payload === null || payload === undefined) {
    rendered = "No response body.";
  } else {
    try {
      rendered = JSON.stringify(payload, null, 2);
    } catch {
      rendered = "The response could not be displayed.";
    }
  }
  if (rendered.length > MAX_RENDERED_RESPONSE_CHARACTERS) {
    return `${rendered.slice(0, MAX_RENDERED_RESPONSE_CHARACTERS)}\n\n… response display truncated`;
  }
  return rendered;
}

function renderPlaygroundResult({ duration, ok, payload, requestID, status }) {
  elements.playgroundMeta.hidden = false;
  elements.playgroundHTTPStatus.textContent = String(status);
  elements.playgroundDuration.textContent = `${duration} ms`;
  elements.playgroundRequestID.textContent = requestID || "Not provided";
  elements.playgroundOutput.textContent = renderPlaygroundBody(payload);
  elements.playgroundStatus.textContent = `${ok ? "Completed" : "Failed"}: HTTP ${status}`;
  elements.playgroundStatus.dataset.state = ok ? "success" : "error";
}

async function executePlaygroundRequest(request) {
  playgroundController.abort();
  playgroundController = new AbortController();
  playgroundGeneration += 1;
  const requestGeneration = playgroundGeneration;
  const generation = sessionGeneration;
  const started = Date.now();
  setFormError(elements.playgroundError);
  elements.playgroundForm.setAttribute("aria-busy", "true");
  elements.playgroundRun.disabled = true;
  elements.playgroundStatus.textContent = "Request in progress";
  elements.playgroundStatus.dataset.state = "pending";
  try {
    const exchange = await apiExchange(
      request.path,
      {
        body: request.body,
        headers: request.headers,
        method: request.method,
      },
      generation,
      playgroundController.signal,
    );
    requireCurrentSession(generation);
    if (requestGeneration !== playgroundGeneration) {
      return;
    }
    renderPlaygroundResult({
      duration: Math.max(0, Date.now() - started),
      ok: exchange.ok,
      payload: exchange.payload,
      requestID: exchange.requestID,
      status: exchange.status,
    });
    if (request.method === "POST" && request.path === "/api/messages" && exchange.status === 202) {
      sendAttempt = null;
      if (currentSendDraftSignature() === request.signature) {
        elements.sendText.value = "";
      }
    }
  } catch (error) {
    if (sessionEnded(error) || error.status === 401 || requestGeneration !== playgroundGeneration) {
      return;
    }
    const status = Number.isInteger(error.status) ? error.status : 0;
    renderPlaygroundResult({
      duration: Math.max(0, Date.now() - started),
      ok: false,
      payload: error.payload || { detail: error.message },
      requestID: error.requestID || "",
      status,
    });
  } finally {
    if (requestGeneration === playgroundGeneration && generation === sessionGeneration) {
      elements.playgroundForm.setAttribute("aria-busy", "false");
      elements.playgroundRun.disabled = false;
    }
  }
}

function currentSendDraftSignature() {
  const kind = elements.sendTargetKind.value;
  const service = elements.sendService.value;
  const rawTarget = String(elements.sendTarget.value || "").trim();
  const text = String(elements.sendText.value || "");
  if (kind === "chat_id") {
    const chatIDValue = Number(rawTarget);
    return Number.isSafeInteger(chatIDValue) && chatIDValue > 0
      ? JSON.stringify({ chat_id: chatIDValue, text, service })
      : "";
  }
  if (kind === "recipient") {
    return JSON.stringify({ recipient: rawTarget, text, service });
  }
  return "";
}

function handlePlaygroundSubmit(event) {
  event.preventDefault();
  setFormError(elements.playgroundError);
  const operation = selectedPlaygroundOperation();
  if (!operation) {
    setFormError(elements.playgroundError, "Select one of the reviewed API endpoints.");
    return;
  }
  let request;
  try {
    request = operation.build();
  } catch (error) {
    if (error instanceof PlaygroundValidationError) {
      setFormError(elements.playgroundError, error.message);
      error.field?.focus();
      return;
    }
    throw error;
  }
  elements.playgroundPreview.textContent = `${request.method} ${request.path}`;
  if (request.method !== "POST") {
    void executePlaygroundRequest(request);
    return;
  }
  pendingPlaygroundRequest = request;
  elements.sendDialogTarget.textContent = request.target;
  elements.confirmSend.textContent = sendAttempt?.signature === request.signature
    ? "Retry same attempt"
    : `Send ${sendServiceLabel(request.service)}`;
  elements.sendDialog.showModal();
  window.setTimeout(() => elements.confirmSend.focus(), 0);
}

function closeSendDialog() {
  pendingPlaygroundRequest = null;
  elements.sendDialogTarget.textContent = "the selected destination";
  elements.sendDialog.close();
}

function handleSendConfirmation(event) {
  event.preventDefault();
  if (!pendingPlaygroundRequest) {
    return;
  }
  const request = pendingPlaygroundRequest;
  if (!sendAttempt || sendAttempt.signature !== request.signature) {
    if (typeof crypto.randomUUID !== "function") {
      closeSendDialog();
      setFormError(elements.playgroundError, "This browser cannot generate a secure idempotency key.");
      return;
    }
    sendAttempt = { key: crypto.randomUUID(), signature: request.signature };
  }
  request.headers = { "Idempotency-Key": sendAttempt.key };
  pendingPlaygroundRequest = null;
  elements.sendDialog.close();
  void executePlaygroundRequest(request);
}

async function loadConsole(generation = sessionGeneration) {
  requireCurrentSession(generation);
  const statusRequest = apiRequest("/api/status", {}, generation).catch((error) => {
    if (sessionEnded(error) || error.status === 401) {
      throw error;
    }
    return {
      detail: error.message,
      messages: { status: "unavailable" },
      status: "degraded",
    };
  });
  const [status, keys, targets] = await Promise.all([
    statusRequest,
    apiRequest("/api/keys", {}, generation),
    apiRequest("/api/targets", {}, generation),
  ]);
  requireCurrentSession(generation);
  renderStatus(status || {});
  renderKeys(keys);
  renderTargets(targets);
  elements.signinView.hidden = true;
  elements.consoleView.hidden = false;
}

async function handleSignin(event) {
  event.preventDefault();
  setFormError(elements.signinError);
  const candidate = elements.signinKey.value.trim();
  if (!candidate) {
    setFormError(elements.signinError, "Enter an API key to continue.");
    elements.signinKey.focus();
    return;
  }

  const generation = beginSession(candidate);
  elements.signinButton.disabled = true;
  try {
    await loadConsole(generation);
    requireCurrentSession(generation);
    persistSessionKey(candidate);
    elements.signinKey.value = "";
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      const message = error.status === 403
        ? "This key does not include the admin scope."
        : error.message;
      signOut(message);
    }
  } finally {
    elements.signinButton.disabled = false;
  }
}

async function handleRefresh() {
  const generation = sessionGeneration;
  elements.refreshButton.disabled = true;
  try {
    await loadConsole(generation);
    requireCurrentSession(generation);
    showToast("Status, recipients, and keys refreshed.");
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      showToast(error.message);
      setConnection("degraded", "Refresh failed");
    }
  } finally {
    elements.refreshButton.disabled = false;
  }
}

function selectedScopes() {
  return Array.from(elements.createForm.querySelectorAll('input[name="scope[]"]:checked'))
    .map((input) => input.value);
}

function showCreatedKey(key) {
  elements.createdKey.value = key;
  elements.copyStatus.textContent = "";
  elements.createdKeyDialog.showModal();
  window.setTimeout(() => elements.copyKeyButton.focus(), 0);
}

async function handleCreate(event) {
  event.preventDefault();
  setFormError(elements.createError);
  elements.keyIdentifier.setAttribute("aria-invalid", "false");
  const formData = new FormData(elements.createForm);
  const name = String(formData.get("name") || "").trim();
  const expiresInDays = Number(formData.get("expires_in_days"));
  const scopes = selectedScopes();
  const nameBytes = new TextEncoder().encode(name).length;
  const generation = sessionGeneration;
  // The service stores the identifier lowercased, so a typed capital is
  // normalized here rather than refused.
  const identifier = String(formData.get("sender_identifier") || "").trim().toLowerCase();

  if (!name) {
    setFormError(elements.createError, "Give this key a recognizable name.");
    elements.createForm.elements.name.focus();
    return;
  }
  if (nameBytes > 80) {
    setFormError(elements.createError, "The key name must be at most 80 UTF-8 bytes.");
    elements.createForm.elements.name.focus();
    return;
  }
  if (identifier && !SENDER_IDENTIFIER_PATTERN.test(identifier)) {
    setFormError(elements.createError, "The sender identifier must be 2 to 8 roman letters, such as kle.");
    elements.keyIdentifier.setAttribute("aria-invalid", "true");
    elements.keyIdentifier.focus();
    return;
  }
  if (scopes.length === 0) {
    setFormError(elements.createError, "Select at least one scope.");
    return;
  }
  if (!Number.isInteger(expiresInDays) || expiresInDays < 1 || expiresInDays > 365) {
    setFormError(elements.createError, "Expiry must be between 1 and 365 days.");
    elements.createForm.elements.expires_in_days.focus();
    return;
  }

  // An absent field asks the service to assign one; an empty string is refused.
  const body = { expires_in_days: expiresInDays, name, scopes };
  if (identifier) {
    body.sender_identifier = identifier;
  }

  elements.createButton.disabled = true;
  try {
    const created = await apiRequest("/api/keys", { body, method: "POST" }, generation);
    requireCurrentSession(generation);
    if (!created || typeof created.key !== "string" || !created.key) {
      throw new RequestError("The service did not return the new key.", 502);
    }
    showCreatedKey(created.key);
    elements.createForm.reset();
    elements.createForm.elements.expires_in_days.value = "90";
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      setFormError(elements.createError, error.message);
    }
  } finally {
    elements.createButton.disabled = false;
  }
}

async function copyCreatedKey() {
  const value = elements.createdKey.value;
  if (!value) {
    return;
  }
  try {
    await navigator.clipboard.writeText(value);
    elements.copyStatus.textContent = "Copied to the clipboard.";
    if (copyTimer !== null) {
      window.clearTimeout(copyTimer);
    }
    elements.copyKeyButton.textContent = "Copied";
    copyTimer = window.setTimeout(() => {
      elements.copyKeyButton.textContent = "Copy key";
      copyTimer = null;
    }, 1800);
  } catch {
    if (copyTimer !== null) {
      window.clearTimeout(copyTimer);
      copyTimer = null;
    }
    elements.copyKeyButton.textContent = "Copy key";
    elements.createdKey.focus();
    elements.createdKey.select();
    elements.copyStatus.textContent = "Clipboard access was blocked. Copy the selected key manually.";
  }
}

async function closeCreatedKeyDialog() {
  const generation = sessionGeneration;
  elements.createdKeyDialog.close();
  clearCreatedKey();
  showToast("The new key is active.");
  try {
    const keys = await apiRequest("/api/keys", {}, generation);
    requireCurrentSession(generation);
    renderKeys(keys);
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      showToast(`The key is active, but the list could not refresh: ${error.message}`);
    }
  }
}

function openRevokeDialog(id, name) {
  pendingRevocation = { id, name };
  elements.revokeKeyName.textContent = name;
  elements.revokeDialog.showModal();
  window.setTimeout(() => elements.confirmRevoke.focus(), 0);
}

function closeRevokeDialog() {
  pendingRevocation = null;
  elements.revokeKeyName.textContent = "This key";
  elements.revokeDialog.close();
}

async function handleRevoke(event) {
  event.preventDefault();
  if (!pendingRevocation) {
    return;
  }
  const { id, name } = pendingRevocation;
  const generation = sessionGeneration;
  const confirmButton = elements.confirmRevoke;
  confirmButton.disabled = true;
  try {
    await apiRequest(`/api/keys/${encodeURIComponent(id)}`, { method: "DELETE" }, generation);
    requireCurrentSession(generation);
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      showToast(error.message);
    }
    confirmButton.disabled = false;
    return;
  }

  closeRevokeDialog();
  showToast(`${name} was revoked.`);
  try {
    const keys = await apiRequest("/api/keys", {}, generation);
    requireCurrentSession(generation);
    renderKeys(keys);
  } catch (error) {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      showToast(`${name} was revoked, but the list could not refresh: ${error.message}`);
    }
  } finally {
    confirmButton.disabled = false;
  }
}

function toggleKeyVisibility() {
  const visible = elements.signinKey.type === "text";
  elements.signinKey.type = visible ? "password" : "text";
  elements.toggleKey.textContent = visible ? "Show" : "Hide";
  elements.toggleKey.setAttribute("aria-pressed", String(!visible));
  elements.signinKey.focus();
}

elements.signinForm.addEventListener("submit", handleSignin);
elements.toggleKey.addEventListener("click", toggleKeyVisibility);
elements.logoutButton.addEventListener("click", () => signOut());
elements.refreshButton.addEventListener("click", handleRefresh);
for (const section of consoleSections) {
  section.tab.addEventListener("click", () => activateConsoleSection(section.tab));
  section.tab.addEventListener("keydown", handleTabKeydown);
}
elements.openPlayground.addEventListener("click", () => activateConsoleSection(elements.playgroundTab, true));
elements.playgroundOperation.addEventListener("change", updatePlaygroundOperation);
elements.playgroundForm.addEventListener("submit", handlePlaygroundSubmit);
elements.sendService.addEventListener("change", updateSendSignature);
elements.sendTargetKind.addEventListener("change", updateSendTargetHint);
elements.cancelSend.addEventListener("click", closeSendDialog);
elements.sendConfirmForm.addEventListener("submit", handleSendConfirmation);
elements.sendDialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  closeSendDialog();
});
elements.createForm.addEventListener("submit", handleCreate);
elements.copyKeyButton.addEventListener("click", copyCreatedKey);
elements.closeKeyDialog.addEventListener("click", () => void closeCreatedKeyDialog());
elements.createdKeyDialog.addEventListener("cancel", (event) => event.preventDefault());
elements.createdKeyDialog.addEventListener("close", clearCreatedKey);
elements.cancelRevoke.addEventListener("click", closeRevokeDialog);
elements.revokeForm.addEventListener("submit", handleRevoke);
elements.allowKind.addEventListener("change", updateAllowKind);
elements.allowForm.addEventListener("submit", handleAllowTarget);
elements.cancelRemoveTarget.addEventListener("click", closeRemoveTargetDialog);
elements.removeTargetForm.addEventListener("submit", handleRemoveTarget);
elements.removeTargetDialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  closeRemoveTargetDialog();
});

const restoredKey = sessionKey();
if (restoredKey) {
  const generation = beginSession(restoredKey);
  loadConsole(generation).catch((error) => {
    if (!sessionEnded(error) && error.status !== 401 && generation === sessionGeneration) {
      signOut(error.message);
    }
  });
} else {
  showSignin();
}
