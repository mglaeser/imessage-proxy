const STORAGE_KEY = "imessage-proxy.admin-key";

const elements = {
  cancelRevoke: document.querySelector("#cancel-revoke"),
  closeKeyDialog: document.querySelector("#close-key-dialog"),
  connectionChip: document.querySelector("#connection-chip"),
  connectionLabel: document.querySelector("#connection-label"),
  confirmRevoke: document.querySelector("#confirm-revoke"),
  consoleView: document.querySelector("#console-view"),
  copyKeyButton: document.querySelector("#copy-key-button"),
  copyStatus: document.querySelector("#copy-status"),
  createButton: document.querySelector("#create-button"),
  createError: document.querySelector("#create-error"),
  createForm: document.querySelector("#create-form"),
  createdKey: document.querySelector("#created-key"),
  createdKeyDialog: document.querySelector("#created-key-dialog"),
  keyCount: document.querySelector("#key-count"),
  keysBody: document.querySelector("#keys-body"),
  keysEmpty: document.querySelector("#keys-empty"),
  logoutButton: document.querySelector("#logout-button"),
  messagesStatus: document.querySelector("#messages-status"),
  refreshButton: document.querySelector("#refresh-button"),
  revokeDialog: document.querySelector("#revoke-dialog"),
  revokeForm: document.querySelector("#revoke-form"),
  revokeKeyName: document.querySelector("#revoke-key-name"),
  serviceDetail: document.querySelector("#service-detail"),
  serviceStatus: document.querySelector("#service-status"),
  serviceUptime: document.querySelector("#service-uptime"),
  serviceVersion: document.querySelector("#service-version"),
  signinButton: document.querySelector("#signin-button"),
  signinError: document.querySelector("#signin-error"),
  signinForm: document.querySelector("#signin-form"),
  signinKey: document.querySelector("#signin-key"),
  signinView: document.querySelector("#signin-view"),
  statusUpdated: document.querySelector("#status-updated"),
  toast: document.querySelector("#toast"),
  toggleKey: document.querySelector("#toggle-key"),
};

let activeKey = "";
let copyTimer = null;
let pendingRevocation = null;
let sessionController = new AbortController();
let sessionGeneration = 0;
let toastTimer = null;

class RequestError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "RequestError";
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
  sessionController = new AbortController();
  sessionGeneration += 1;
  activeKey = key;
  return sessionGeneration;
}

function invalidateSession() {
  sessionController.abort();
  sessionController = new AbortController();
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

function clearConsoleData() {
  elements.keysBody.replaceChildren();
  elements.keyCount.textContent = "0 keys";
  elements.keysEmpty.hidden = true;
  elements.serviceStatus.textContent = "Signed out";
  elements.messagesStatus.textContent = "—";
  elements.serviceVersion.textContent = "—";
  elements.serviceUptime.textContent = "—";
  elements.serviceDetail.textContent = "Secure endpoint";
  elements.statusUpdated.textContent = "Waiting for the first status check.";
  elements.createForm.reset();
  elements.createForm.elements.expires_in_days.value = "90";
  setFormError(elements.createError);
  elements.createButton.disabled = false;
  elements.refreshButton.disabled = false;
  elements.confirmRevoke.disabled = false;
  if (toastTimer !== null) {
    window.clearTimeout(toastTimer);
    toastTimer = null;
  }
  elements.toast.hidden = true;
  elements.toast.textContent = "";
}

function signOut(message = "") {
  invalidateSession();
  pendingRevocation = null;
  persistSessionKey("");
  elements.signinKey.value = "";
  clearCreatedKey();
  if (elements.createdKeyDialog.open) {
    elements.createdKeyDialog.close();
  }
  if (elements.revokeDialog.open) {
    elements.revokeDialog.close();
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

async function apiRequest(path, options = {}, generation = sessionGeneration) {
  requireCurrentSession(generation);
  const key = activeKey;
  const signal = sessionController.signal;
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
    if (error?.name === "AbortError" || generation !== sessionGeneration) {
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
  if (response.status !== 204 && hasJsonBody) {
    try {
      payload = await response.json();
    } catch {
      throw new RequestError("The service returned an invalid response.", response.status);
    }
  }
  requireCurrentSession(generation);

  if (response.status === 401) {
    if (generation === sessionGeneration) {
      signOut("The API key is invalid, expired, or revoked.");
    }
    throw new RequestError("Authentication is required.", 401);
  }
  if (!response.ok) {
    throw new RequestError(responseMessage(payload, `Request failed with status ${response.status}.`), response.status);
  }
  return payload;
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

function renderStatus(payload) {
  const serviceRaw = payload?.status || "unknown";
  const messagesRaw = payload?.messages?.status || "unknown";
  const serviceLabel = titleCaseStatus(serviceRaw);
  const messagesLabel = titleCaseStatus(messagesRaw);
  const healthy = serviceLabel === "Healthy";

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

function renderKeys(payload) {
  const keys = normalizedKeys(payload);
  elements.keysBody.replaceChildren();
  elements.keyCount.textContent = `${keys.length} ${keys.length === 1 ? "key" : "keys"}`;
  elements.keysEmpty.hidden = keys.length !== 0;

  for (const key of keys) {
    const row = document.createElement("tr");
    const nameCell = document.createElement("td");
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

    row.append(nameCell, scopesCell, expiryCell, lastUsedCell, actionCell);
    elements.keysBody.append(row);
  }
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
  const [status, keys] = await Promise.all([
    statusRequest,
    apiRequest("/api/keys", {}, generation),
  ]);
  requireCurrentSession(generation);
  renderStatus(status || {});
  renderKeys(keys);
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
    showToast("Status and keys refreshed.");
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
  return Array.from(elements.createForm.querySelectorAll('input[name="scope"]:checked'))
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
  const formData = new FormData(elements.createForm);
  const name = String(formData.get("name") || "").trim();
  const expiresInDays = Number(formData.get("expires_in_days"));
  const scopes = selectedScopes();
  const nameBytes = new TextEncoder().encode(name).length;
  const generation = sessionGeneration;

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
  if (scopes.length === 0) {
    setFormError(elements.createError, "Select at least one scope.");
    return;
  }
  if (!Number.isInteger(expiresInDays) || expiresInDays < 1 || expiresInDays > 365) {
    setFormError(elements.createError, "Expiry must be between 1 and 365 days.");
    elements.createForm.elements.expires_in_days.focus();
    return;
  }

  elements.createButton.disabled = true;
  try {
    const created = await apiRequest("/api/keys", {
      method: "POST",
      body: {
        expires_in_days: expiresInDays,
        name,
        scopes,
      },
    }, generation);
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
elements.createForm.addEventListener("submit", handleCreate);
elements.copyKeyButton.addEventListener("click", copyCreatedKey);
elements.closeKeyDialog.addEventListener("click", () => void closeCreatedKeyDialog());
elements.createdKeyDialog.addEventListener("cancel", (event) => event.preventDefault());
elements.createdKeyDialog.addEventListener("close", clearCreatedKey);
elements.cancelRevoke.addEventListener("click", closeRevokeDialog);
elements.revokeForm.addEventListener("submit", handleRevoke);

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
