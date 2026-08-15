import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const appSource = await readFile(new URL("../web/app.js", import.meta.url), "utf8");
const markup = await readFile(new URL("../web/index.html", import.meta.url), "utf8");
const storageKey = "imessage-proxy.admin-key";

class FakeElement {
  constructor(ownerDocument, tagName, id = "") {
    this.ownerDocument = ownerDocument;
    this.tagName = tagName.toUpperCase();
    this.id = id;
    this.attributes = new Map();
    this.children = [];
    this.controls = [];
    this.dataset = {};
    this.defaultChecked = false;
    this.defaultValue = "";
    this.disabled = false;
    this.hidden = false;
    this.listeners = new Map();
    this.open = false;
    this.parentNode = null;
    this.selected = false;
    this.type = this.tagName === "INPUT" ? "text" : "";
    this.value = "";
    this.checked = false;
    this.className = "";
    this._textContent = "";
    this.elements = {};
  }

  get textContent() {
    return this._textContent + this.children.map((child) => child.textContent).join("");
  }

  set textContent(value) {
    this._textContent = String(value);
    this.children = [];
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  append(...children) {
    for (const child of children) {
      child.parentNode = this;
      this.children.push(child);
    }
  }

  close() {
    this.open = false;
    this.emitSync("close");
  }

  emitSync(type) {
    const event = new Event(type, { cancelable: true });
    for (const listener of this.listeners.get(type) || []) {
      listener.call(this, event);
    }
    return event;
  }

  async emit(type) {
    const event = new Event(type, { cancelable: true });
    for (const listener of this.listeners.get(type) || []) {
      await listener.call(this, event);
    }
    return event;
  }

  async emitKey(key) {
    const event = {
      currentTarget: this,
      defaultPrevented: false,
      key,
      preventDefault() {
        this.defaultPrevented = true;
      },
    };
    for (const listener of this.listeners.get("keydown") || []) {
      await listener.call(this, event);
    }
    return event;
  }

  focus() {
    this.ownerDocument.activeElement = this;
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  querySelectorAll(selector) {
    assert.equal(selector, 'input[name="scope[]"]:checked');
    return this.controls.filter((control) => control.name === "scope[]" && control.checked);
  }

  replaceChildren(...children) {
    this.children = [];
    this.append(...children);
  }

  reset() {
    for (const control of this.controls) {
      control.value = control.defaultValue;
      control.checked = control.defaultChecked;
    }
  }

  select() {
    this.selected = true;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  showModal() {
    this.open = true;
  }
}

class FakeDocument {
  constructor() {
    this.activeElement = null;
    this.elements = new Map();
    this.cookieWrites = [];
  }

  createElement(tagName) {
    return new FakeElement(this, tagName);
  }

  querySelector(selector) {
    assert.match(selector, /^#[a-z0-9-]+$/);
    return this.elements.get(selector.slice(1)) || null;
  }

  register(element) {
    this.elements.set(element.id, element);
    return element;
  }

  get cookie() {
    return "";
  }

  set cookie(value) {
    this.cookieWrites.push(value);
  }
}

class StorageSpy {
  constructor(initial = {}) {
    this.values = new Map(Object.entries(initial));
    this.operations = [];
  }

  getItem(key) {
    this.operations.push(["get", key]);
    return this.values.get(key) ?? null;
  }

  removeItem(key) {
    this.operations.push(["remove", key]);
    this.values.delete(key);
  }

  setItem(key, value) {
    this.operations.push(["set", key, String(value)]);
    this.values.set(key, String(value));
  }
}

class ForbiddenStorage {
  getItem() {
    throw new Error("localStorage must not be read");
  }

  removeItem() {
    throw new Error("localStorage must not be changed");
  }

  setItem() {
    throw new Error("localStorage must not be changed");
  }
}

class FakeFormData {
  constructor(form) {
    this.form = form;
  }

  get(name) {
    const control = this.form.controls.find((candidate) => candidate.name === name);
    return control ? control.value : null;
  }
}

class FetchMock {
  constructor() {
    this.requests = [];
    this.responses = [];
  }

  enqueue(status, payload = null, contentType = "application/json", headers = {}) {
    this.responses.push({ contentType, headers, payload, status });
  }

  enqueueFailure(message = "network unavailable") {
    this.responses.push(new TypeError(message));
  }

  async fetch(path, options) {
    this.requests.push({ options, path });
    assert.notEqual(this.responses.length, 0, `unexpected request: ${path}`);
    const response = this.responses.shift();
    if (response instanceof Error) {
      throw response;
    }
    return {
      headers: new Headers({
        ...(response.contentType ? { "content-type": response.contentType } : {}),
        ...response.headers,
      }),
      json: async () => response.payload,
      ok: response.status >= 200 && response.status < 300,
      status: response.status,
    };
  }
}

function attribute(attributes, name) {
  const match = attributes.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`, "i"));
  return match ? match[1] : null;
}

function elementFromMarkup(document, id) {
  const escapedID = id.replaceAll("-", "\\-");
  const match = markup.match(new RegExp(`<([a-z][a-z0-9-]*)\\b([^>]*\\bid="${escapedID}"[^>]*)>`, "i"));
  assert.ok(match, `#${id} must exist in web/index.html`);
  const element = new FakeElement(document, match[1], id);
  const attributes = match[2];
  element.hidden = /(?:^|\s)hidden(?:\s|$)/i.test(attributes);
  element.disabled = /(?:^|\s)disabled(?:\s|$)/i.test(attributes);
  element.checked = /(?:^|\s)checked(?:\s|$)/i.test(attributes);
  element.defaultChecked = element.checked;
  for (const name of [
    "aria-busy",
    "aria-controls",
    "aria-describedby",
    "aria-live",
    "aria-labelledby",
    "aria-pressed",
    "aria-selected",
    "role",
    "tabindex",
  ]) {
    const value = attribute(attributes, name);
    if (value !== null) {
      element.setAttribute(name, value);
    }
  }
  const type = attribute(attributes, "type");
  if (type !== null) {
    element.type = type;
  }
  const name = attribute(attributes, "name");
  if (name !== null) {
    element.name = name;
  }
  const value = attribute(attributes, "value");
  if (value !== null) {
    element.value = value;
    element.defaultValue = value;
  }
  const state = attribute(attributes, "data-state");
  if (state !== null) {
    element.dataset.state = state;
  }
  return document.register(element);
}

// A browser selects the first option of a select that marks none as selected.
// elementFromMarkup builds every element childless, so those defaults are
// restored here: no real select starts with an empty value, and the console
// reads send-service before anything has changed it.
function applySelectDefaults(document) {
  for (const match of markup.matchAll(/<select\b([^>]*)>([\s\S]*?)<\/select>/gi)) {
    const id = attribute(match[1], "id");
    const firstOption = match[2].match(/<option\b[^>]*\bvalue="([^"]*)"/i);
    if (id === null || firstOption === null) {
      continue;
    }
    const element = document.elements.get(id);
    element.value = firstOption[1];
    element.defaultValue = firstOption[1];
  }
}

function anonymousScopeControls(document) {
  return Array.from(markup.matchAll(/<input\b([^>]*\bname="scope\[\]"[^>]*)>/gi), (match) => {
    const control = new FakeElement(document, "input");
    control.type = "checkbox";
    control.name = "scope[]";
    control.value = attribute(match[1], "value") || "";
    return control;
  });
}

// secureContext: false drops crypto.randomUUID and leaves getRandomValues, which
// is the shape a browser has at http://192.168.0.10:8765 - randomUUID and
// crypto.subtle are secure-context only, getRandomValues is not.
function createHarness({ initialResponses = [], storedKey = "", secureContext = true } = {}) {
  const document = new FakeDocument();
  const ids = Array.from(markup.matchAll(/\bid="([a-z0-9-]+)"/g), (match) => match[1]);
  for (const id of ids) {
    elementFromMarkup(document, id);
  }
  applySelectDefaults(document);

  const textDefaults = {
    "connection-label": "Signed out",
    "copy-key-button": "Copy key",
    "key-count": "0 keys",
    "messages-status": "Checking",
    "revoke-key-name": "This key",
    "service-detail": "Secure endpoint",
    "service-status": "Checking",
    "service-uptime": "—",
    "service-version": "—",
    "status-updated": "Waiting for the first status check.",
    "toggle-key": "Show",
  };
  for (const [id, textContent] of Object.entries(textDefaults)) {
    document.elements.get(id).textContent = textContent;
  }

  const signinForm = document.elements.get("signin-form");
  const signinKey = document.elements.get("signin-key");
  signinForm.controls = [signinKey];
  signinForm.elements = { key: signinKey };

  const createForm = document.elements.get("create-form");
  const keyName = document.elements.get("key-name");
  const keyIdentifier = document.elements.get("key-identifier");
  const keyExpiry = document.elements.get("key-expiry");
  const scopes = anonymousScopeControls(document);
  createForm.controls = [keyName, keyIdentifier, ...scopes, keyExpiry];
  createForm.elements = { expires_in_days: keyExpiry, name: keyName };

  const playgroundForm = document.elements.get("playground-form");
  const playgroundControls = [
    "playground-operation",
    "chats-limit",
    "chats-unread",
    "playground-chat-id",
    "messages-limit",
    "messages-participant",
    "messages-start",
    "messages-end",
    "scheduled-limit",
    "statistics-chat-id",
    "statistics-time-zone",
    "statistics-media",
    "audit-limit",
    "playground-key-id",
    "send-service",
    "send-target-kind",
    "send-target",
    "send-text",
  ].map((id) => document.elements.get(id));
  playgroundForm.controls = playgroundControls;

  const sessionStorage = new StorageSpy(storedKey ? { [storageKey]: storedKey } : {});
  const clipboardWrites = [];
  let clipboardError = null;
  let nextTimerID = 1;
  let nextUUID = 1;
  const timers = new Map();
  const window = {
    clearTimeout(timerID) {
      timers.delete(timerID);
    },
    setTimeout(callback) {
      const timerID = nextTimerID;
      nextTimerID += 1;
      timers.set(timerID, callback);
      return timerID;
    },
  };
  const fetchMock = new FetchMock();
  for (const [status, payload, contentType] of initialResponses) {
    fetchMock.enqueue(status, payload, contentType);
  }
  const navigator = {
    clipboard: {
      async writeText(value) {
        if (clipboardError) {
          throw clipboardError;
        }
        clipboardWrites.push(value);
      },
    },
  };
  const crypto = {
    getRandomValues(target) {
      // Deterministic, so the assertions can name the bytes; the layout the
      // console applies over the top is what is being tested, not the source.
      for (let index = 0; index < target.length; index += 1) {
        target[index] = (nextUUID * 7 + index * 31) % 256;
      }
      nextUUID += 1;
      return target;
    },
  };
  if (secureContext) {
    crypto.randomUUID = () => {
      const suffix = String(nextUUID).padStart(12, "0");
      nextUUID += 1;
      return `00000000-0000-4000-8000-${suffix}`;
    };
  }
  const context = vm.createContext({
    AbortController,
    Date,
    Event,
    FormData: FakeFormData,
    Headers,
    Intl,
    TextEncoder,
    URLSearchParams,
    crypto,
    document,
    fetch: fetchMock.fetch.bind(fetchMock),
    localStorage: new ForbiddenStorage(),
    navigator,
    sessionStorage,
    window,
  });
  window.document = document;
  window.navigator = navigator;
  vm.runInContext(appSource, context, { filename: "web/app.js" });

  return {
    clipboardWrites,
    context,
    document,
    fetchMock,
    scopes,
    sessionStorage,
    setClipboardError(error) {
      clipboardError = error;
    },
    timers,
    crypto,
    element(id) {
      return document.elements.get(id);
    },
  };
}

function json(status, payload, headers = {}) {
  return [status, payload, "application/json", headers];
}

function enqueue(fetchMock, ...responses) {
  for (const response of responses) {
    fetchMock.enqueue(...response);
  }
}

// Sign-in loads status, keys, and the recipient allowlist together, so every
// authenticated test starts three responses deep. AUTHENTICATED_REQUESTS keeps
// the index arithmetic in the tests below honest if that ever changes again.
const AUTHENTICATED_REQUESTS = 3;

async function authenticate(harness, key = "admin-test-key", keys = [], targets = [], status = {}) {
  enqueue(
    harness.fetchMock,
    json(200, {
      messages: { status: "ready" },
      status: "ok",
      uptime_seconds: 7322,
      version: "1.0.0",
      ...status,
    }),
    json(200, { keys }),
    json(200, { targets }),
  );
  harness.element("signin-key").value = key;
  await harness.element("signin-form").emit("submit");
}

async function settle() {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    await Promise.resolve();
  }
  await new Promise((resolve) => setImmediate(resolve));
}

function bearerValue(key) {
  return `${"Bear"}${"er"} ${key}`;
}

async function runPlayground(harness, operation, setup, response = json(200, { ok: true })) {
  harness.element("playground-operation").value = operation;
  await harness.element("playground-operation").emit("change");
  setup?.();
  enqueue(harness.fetchMock, response);
  const before = harness.fetchMock.requests.length;
  await harness.element("playground-form").emit("submit");
  await settle();
  assert.equal(harness.fetchMock.requests.length, before + 1, `${operation} should make one request`);
  return harness.fetchMock.requests.at(-1);
}

test("markup and interactive controls retain their accessibility contracts", async () => {
  const queriedIDs = Array.from(appSource.matchAll(/document\.querySelector\("#([a-z0-9-]+)"\)/g), (match) => match[1]);
  assert.ok(queriedIDs.length > 0);
  for (const id of queriedIDs) {
    assert.equal(markup.match(new RegExp(`\\bid="${id}"`, "g"))?.length, 1, `unique markup for #${id}`);
  }
  assert.match(markup, /<html lang="en">/);
  assert.match(markup, /<label for="signin-key">API key<\/label>/);
  assert.match(markup, /id="signin-error" role="alert" hidden/);
  assert.match(markup, /id="create-error" role="alert" hidden/);
  assert.match(markup, /id="toast" role="status" aria-live="polite" hidden/);
  assert.match(markup, /<dialog[^>]*id="created-key-dialog"[^>]*aria-labelledby="created-key-title"/);
  assert.match(markup, /<dialog[^>]*id="revoke-dialog"[^>]*aria-labelledby="revoke-title"/);
  assert.match(markup, /<dialog[^>]*id="remove-target-dialog"[^>]*aria-labelledby="remove-target-title"/);
  assert.match(markup, /id="targets-panel"[\s\S]*role="tabpanel"[\s\S]*aria-labelledby="targets-tab"/);
  assert.match(markup, /id="allow-error" role="alert" hidden/);
  assert.match(markup, /<label for="allow-value" id="allow-value-label">/);
  assert.match(markup, /role="tablist" aria-label="Management console"/);
  assert.match(markup, /id="overview-tab"[\s\S]*role="tab"[\s\S]*aria-controls="overview-panel"/);
  assert.match(markup, /id="playground-panel"[\s\S]*role="tabpanel"[\s\S]*aria-labelledby="playground-tab"/);
  assert.match(markup, /<label for="playground-operation">Endpoint<\/label>/);
  assert.match(markup, /<label for="key-identifier">Sender identifier/);
  assert.match(markup, /<label for="send-service">Service<\/label>/);
  assert.match(markup, /id="read-disabled-notice" role="status" hidden/);
  assert.match(markup, /id="playground-error" role="alert" hidden/);
  assert.match(markup, /id="playground-status" role="status" aria-live="polite"/);
  assert.match(markup, /id="playground-output" tabindex="0"/);
  assert.match(markup, /<dialog[\s\S]*id="send-dialog"[\s\S]*aria-describedby="send-dialog-description"/);

  const harness = createHarness();
  const signinKey = harness.element("signin-key");
  const toggle = harness.element("toggle-key");
  assert.equal(toggle.getAttribute("aria-pressed"), "false");
  await toggle.emit("click");
  assert.equal(signinKey.type, "text");
  assert.equal(toggle.textContent, "Hide");
  assert.equal(toggle.getAttribute("aria-pressed"), "true");
  assert.equal(harness.document.activeElement, signinKey);

  const createdKeyDialog = harness.element("created-key-dialog");
  createdKeyDialog.showModal();
  const cancelEvent = await createdKeyDialog.emit("cancel");
  assert.equal(cancelEvent.defaultPrevented, true);
  assert.equal(createdKeyDialog.open, true, "Escape cannot discard a one-time secret");
});

test("sign-in authenticates status and key loading and persists only in session storage", async () => {
  const harness = createHarness();
  const adminKey = "admin-test-key";
  await authenticate(harness, adminKey, [{
    expires_at: "2030-01-01T00:00:00Z",
    id: "key-1",
    key_prefix: "imp_example",
    last_used_at: null,
    name: "Example client",
    revoked_at: null,
    scopes: ["messages:send"],
  }]);

  assert.equal(harness.fetchMock.requests.length, AUTHENTICATED_REQUESTS);
  assert.deepEqual(harness.fetchMock.requests.map((request) => request.path),
    ["/api/status", "/api/keys", "/api/targets"]);
  for (const request of harness.fetchMock.requests) {
    assert.equal(request.options.headers.get("Authorization"), bearerValue(adminKey));
    assert.equal(request.options.headers.get("Accept"), "application/json, application/problem+json");
    assert.equal(request.options.body, undefined);
    assert.equal(request.options.cache, "no-store");
    assert.equal(request.options.credentials, "omit");
    assert.equal(request.options.referrerPolicy, "no-referrer");
    assert.equal(request.options.signal.aborted, false);
  }
  assert.equal(harness.sessionStorage.getItem(storageKey), adminKey);
  assert.deepEqual(Array.from(harness.sessionStorage.values.entries()), [[storageKey, adminKey]]);
  assert.deepEqual(harness.document.cookieWrites, []);
  assert.equal(harness.element("signin-key").value, "");
  assert.equal(harness.element("signin-view").hidden, true);
  assert.equal(harness.element("console-view").hidden, false);
  assert.equal(harness.element("connection-label").textContent, "Healthy");
  assert.equal(harness.element("connection-chip").dataset.state, "online");
  assert.equal(harness.element("service-status").textContent, "Healthy");
  assert.equal(harness.element("messages-status").textContent, "Healthy");
  assert.equal(harness.element("service-version").textContent, "1.0.0");
  assert.equal(harness.element("service-uptime").textContent, "2h 2m");
  assert.equal(harness.element("key-count").textContent, "1 key");
  assert.match(harness.element("keys-body").textContent, /Example client/);
  assert.doesNotMatch(harness.element("console-view").textContent, new RegExp(adminKey));
});

test("a tab-scoped session key restores authenticated state without another sign-in", async () => {
  const adminKey = "restored-admin-key";
  const harness = createHarness({
    initialResponses: [
      json(200, {
        messages: { status: "ready" },
        status: "ok",
        uptime_seconds: 5,
        version: "1.0.0",
      }),
      json(200, { keys: [] }),
      json(200, { targets: [] }),
    ],
    storedKey: adminKey,
  });
  await settle();

  assert.deepEqual(harness.sessionStorage.operations, [["get", storageKey]]);
  assert.equal(harness.fetchMock.requests.length, AUTHENTICATED_REQUESTS);
  for (const request of harness.fetchMock.requests) {
    assert.equal(request.options.headers.get("Authorization"), bearerValue(adminKey));
  }
  assert.equal(harness.element("signin-view").hidden, true);
  assert.equal(harness.element("console-view").hidden, false);
  assert.equal(harness.element("connection-label").textContent, "Healthy");
});

test("tabs expose every read endpoint through exact same-origin requests", async () => {
  const keyID = "123e4567-e89b-42d3-a456-426614174000";
  const harness = createHarness();
  await authenticate(harness, "admin-playground-key", [{
    created_at: "2026-08-01T10:00:00Z",
    expires_at: "2026-09-01T10:00:00Z",
    id: keyID,
    key_prefix: "imp_test",
    last_used_at: null,
    name: "Playground key",
    revoked_at: null,
    scopes: ["admin"],
  }]);

  harness.element("playground-tab").emitSync("click");
  assert.equal(harness.element("playground-panel").hidden, false);
  assert.equal(harness.element("overview-panel").hidden, true);
  assert.equal(harness.element("playground-tab").getAttribute("aria-selected"), "true");
  const keyboardEvent = await harness.element("playground-tab").emitKey("ArrowRight");
  assert.equal(keyboardEvent.defaultPrevented, true);
  assert.equal(harness.element("targets-panel").hidden, false);
  assert.equal(harness.document.activeElement, harness.element("targets-tab"));
  await harness.element("targets-tab").emitKey("ArrowRight");
  assert.equal(harness.element("keys-panel").hidden, false);
  assert.equal(harness.document.activeElement, harness.element("keys-tab"));
  await harness.element("keys-tab").emitKey("Home");
  assert.equal(harness.element("overview-panel").hidden, false);
  assert.equal(harness.document.activeElement, harness.element("overview-tab"));
  harness.element("playground-tab").emitSync("click");

  const cases = [
    ["status", () => {}, "/api/status"],
    ["chats", () => {
      harness.element("chats-limit").value = "25";
      harness.element("chats-unread").checked = true;
    }, "/api/chats?limit=25&unread_only=true"],
    ["chat", () => {
      harness.element("playground-chat-id").value = "42";
    }, "/api/chats/42"],
    ["chat-messages", () => {
      harness.element("playground-chat-id").value = "42";
      harness.element("messages-limit").value = "10";
      harness.element("messages-participant").value = "+14155551212";
      harness.element("messages-start").value = "2026-08-01T00:00:00Z";
      harness.element("messages-end").value = "2026-08-10T00:00:00Z";
    }, "/api/chats/42/messages?limit=10&participant=%2B14155551212&start=2026-08-01T00%3A00%3A00Z&end=2026-08-10T00%3A00%3A00Z"],
    ["chat-background", () => {
      harness.element("playground-chat-id").value = "43";
    }, "/api/chats/43/background"],
    ["scheduled-messages", () => {
      harness.element("scheduled-limit").value = "12";
    }, "/api/scheduled-messages?limit=12"],
    ["message-statistics", () => {
      harness.element("statistics-chat-id").value = "44";
      harness.element("statistics-time-zone").value = "Europe/Vienna";
      harness.element("statistics-media").checked = true;
    }, "/api/statistics/messages?chat_id=44&time_zone=Europe%2FVienna&include_media=true"],
    ["audit-events", () => {
      harness.element("audit-limit").value = "150";
    }, "/api/audit-events?limit=150"],
    ["keys", () => {}, "/api/keys"],
    ["key", () => {
      harness.element("playground-key-id").value = keyID;
    }, `/api/keys/${keyID}`],
  ];

  for (const [operation, setup, expectedPath] of cases) {
    const request = await runPlayground(
      harness,
      operation,
      setup,
      json(200, { endpoint: operation }, { "x-request-id": `request-${operation}` }),
    );
    assert.equal(request.path, expectedPath);
    assert.equal(request.options.method, "GET");
    assert.equal(request.options.body, undefined);
    assert.equal(request.options.headers.get("Authorization"), bearerValue("admin-playground-key"));
    assert.equal(request.options.headers.get("Accept"), "application/json, application/problem+json");
    assert.equal(request.options.headers.get("Idempotency-Key"), null);
    assert.equal(request.options.cache, "no-store");
    assert.equal(request.options.credentials, "omit");
    assert.equal(request.options.referrerPolicy, "no-referrer");
    assert.equal(request.options.signal.aborted, false);
  }
  assert.equal(harness.element("playground-request-id").textContent, "request-key");
  assert.equal(harness.element("playground-status").textContent, "Completed: HTTP 200");
  assert.doesNotMatch(harness.element("playground-panel").textContent, /admin-playground-key/);
});

test("the playground rejects tampered operations and renders response text literally", async () => {
  const harness = createHarness();
  await authenticate(harness);
  const requestCount = harness.fetchMock.requests.length;

  for (const operation of ["https://evil.invalid/api", "//evil.invalid", "../api/status", "__proto__", "toString"]) {
    harness.element("playground-operation").value = operation;
    await harness.element("playground-operation").emit("change");
    await harness.element("playground-form").emit("submit");
    assert.equal(harness.fetchMock.requests.length, requestCount);
    assert.equal(harness.element("playground-error").hidden, false);
  }

  harness.element("playground-operation").value = "chat";
  await harness.element("playground-operation").emit("change");
  harness.element("playground-chat-id").value = "0";
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.fetchMock.requests.length, requestCount);
  assert.equal(harness.document.activeElement, harness.element("playground-chat-id"));
  assert.equal(harness.element("playground-chat-id").getAttribute("aria-invalid"), "true");

  harness.element("playground-operation").value = "chat-messages";
  await harness.element("playground-operation").emit("change");
  assert.equal(harness.element("playground-chat-id").getAttribute("aria-invalid"), "false");
  harness.element("playground-chat-id").value = "42";
  harness.element("messages-limit").value = "20";
  harness.element("messages-start").value = "2026-02-31T00:00:00Z";
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.fetchMock.requests.length, requestCount);
  assert.match(harness.element("playground-error").textContent, /Gregorian calendar date/);
  assert.equal(harness.document.activeElement, harness.element("messages-start"));

  const hostile = "<img src=x onerror=alert(1)><script>not code</script>";
  await runPlayground(harness, "status", null, json(200, { detail: hostile }));
  assert.match(harness.element("playground-output").textContent, /<script>not code<\/script>/);
  assert.equal(harness.element("playground-output").children.length, 0);
  assert.doesNotMatch(harness.element("playground-preview").textContent, /Bearer|admin-test-key/);
});

test("message sending requires confirmation and safely reuses one idempotency key per logical attempt", async () => {
  const harness = createHarness();
  await authenticate(harness);
  harness.element("playground-operation").value = "send-message";
  await harness.element("playground-operation").emit("change");
  harness.element("send-target-kind").value = "recipient";
  harness.element("send-target").value = "first-last@example.net";
  harness.element("send-text").value = "Hello from the playground";

  const before = harness.fetchMock.requests.length;
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.fetchMock.requests.length, before, "confirmation must precede the send");
  assert.equal(harness.element("send-dialog").open, true);
  assert.equal(harness.element("send-dialog-target").textContent, "first-last@example.net");

  harness.fetchMock.enqueueFailure();
  await harness.element("send-confirm-form").emit("submit");
  await settle();
  const first = harness.fetchMock.requests.at(-1);
  const firstIdempotencyKey = first.options.headers.get("Idempotency-Key");
  assert.equal(first.path, "/api/messages");
  assert.equal(first.options.method, "POST");
  assert.deepEqual(JSON.parse(first.options.body), {
    recipient: "first-last@example.net",
    service: "imessage",
    text: "Hello from the playground",
  });
  assert.match(firstIdempotencyKey, /^[0-9a-f-]{36}$/);
  assert.equal(harness.element("playground-status").textContent, "Failed: HTTP 0");
  assert.match(harness.element("playground-output").textContent, /could not be reached/i);

  await harness.element("playground-form").emit("submit");
  assert.equal(harness.element("confirm-send").textContent, "Retry same attempt");
  enqueue(harness.fetchMock, json(202, { operation_id: "accepted-one", state: "accepted" }));
  await harness.element("send-confirm-form").emit("submit");
  harness.element("send-text").value = "A draft typed while the first request finishes";
  await settle();
  const retry = harness.fetchMock.requests.at(-1);
  assert.equal(retry.options.headers.get("Idempotency-Key"), firstIdempotencyKey);
  assert.equal(harness.element("send-text").value, "A draft typed while the first request finishes");

  harness.element("send-text").value = "A separate message";
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.element("confirm-send").textContent, "Send iMessage");
  enqueue(harness.fetchMock, json(202, { operation_id: "accepted-two", state: "accepted" }));
  await harness.element("send-confirm-form").emit("submit");
  await settle();
  const separate = harness.fetchMock.requests.at(-1);
  assert.notEqual(separate.options.headers.get("Idempotency-Key"), firstIdempotencyKey);
  assert.equal(separate.options.headers.get("Authorization"), bearerValue("admin-test-key"));
  assert.doesNotMatch(harness.element("playground-preview").textContent, /admin-test-key|Idempotency-Key/);
});

test("the send form picks a transport and previews the exact suffix the recipient will read", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [{
    expires_at: null,
    id: "signed-in-key",
    key_prefix: "imp_console",
    last_used_at: null,
    name: "Console key",
    revoked_at: null,
    scopes: ["admin"],
    sender_identifier: "kle",
    sender_identifier_assigned: false,
  }], [], { key: { id: "signed-in-key" } });

  harness.element("playground-operation").value = "send-message";
  await harness.element("playground-operation").emit("change");
  assert.equal(harness.element("send-signature").textContent, " \u{1F516}kle");
  harness.element("send-service").value = "sms";
  await harness.element("send-service").emit("change");
  assert.equal(harness.element("send-signature").textContent, " ^kle");

  harness.element("send-target").value = "+15551234567";
  harness.element("send-text").value = "Meeting moved to 15:00";
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.element("send-dialog").open, true);
  assert.equal(harness.element("confirm-send").textContent, "Send SMS");
  harness.fetchMock.enqueueFailure();
  await harness.element("send-confirm-form").emit("submit");
  await settle();
  const smsRequest = harness.fetchMock.requests.at(-1);
  assert.deepEqual(JSON.parse(smsRequest.options.body), {
    recipient: "+15551234567",
    service: "sms",
    text: "Meeting moved to 15:00",
  });
  const smsAttemptKey = smsRequest.options.headers.get("Idempotency-Key");

  // The service is part of what the send was, so changing it is a new attempt:
  // replaying the SMS key on an iMessage body is an idempotency conflict.
  harness.element("send-service").value = "imessage";
  await harness.element("send-service").emit("change");
  assert.equal(harness.element("send-signature").textContent, " \u{1F516}kle");
  await harness.element("playground-form").emit("submit");
  assert.equal(harness.element("confirm-send").textContent, "Send iMessage");
  enqueue(harness.fetchMock, json(202, { operation_id: "accepted-imessage", state: "accepted" }));
  await harness.element("send-confirm-form").emit("submit");
  await settle();
  const iMessageRequest = harness.fetchMock.requests.at(-1);
  assert.equal(JSON.parse(iMessageRequest.options.body).service, "imessage");
  assert.notEqual(iMessageRequest.options.headers.get("Idempotency-Key"), smsAttemptKey);
});

test("key creation sends the simple API payload and clears the one-time secret after copying", async () => {
  const harness = createHarness();
  await authenticate(harness);
  enqueue(
    harness.fetchMock,
    json(201, { key: "new-secret-value" }),
    json(200, {
      keys: [{
        expires_at: "2030-01-01T00:00:00Z",
        id: "created-key",
        key_prefix: "imp_created",
        last_used_at: null,
        name: "Notification client",
        revoked_at: null,
        scopes: ["messages:read", "messages:send"],
      }],
    }),
  );
  harness.element("key-name").value = "  Notification client  ";
  harness.element("key-expiry").value = "30";
  harness.scopes[0].checked = true;
  harness.scopes[1].checked = true;

  await harness.element("create-form").emit("submit");

  const createRequest = harness.fetchMock.requests[AUTHENTICATED_REQUESTS];
  assert.equal(createRequest.path, "/api/keys");
  assert.equal(createRequest.options.method, "POST");
  assert.equal(createRequest.options.headers.get("Content-Type"), "application/json");
  assert.deepEqual(JSON.parse(createRequest.options.body), {
    expires_in_days: 30,
    name: "Notification client",
    scopes: ["messages:read", "messages:send"],
  });
  assert.equal(harness.element("created-key-dialog").open, true);
  assert.equal(harness.element("created-key").value, "new-secret-value");
  assert.equal(harness.sessionStorage.getItem(storageKey), "admin-test-key");
  assert.equal(Array.from(harness.sessionStorage.values.values()).includes("new-secret-value"), false);

  await harness.element("copy-key-button").emit("click");
  assert.deepEqual(harness.clipboardWrites, ["new-secret-value"]);
  assert.equal(harness.element("copy-status").textContent, "Copied to the clipboard.");
  assert.equal(harness.element("copy-key-button").textContent, "Copied");

  await harness.element("close-key-dialog").emit("click");
  await settle();
  assert.equal(harness.element("created-key-dialog").open, false);
  assert.equal(harness.element("created-key").value, "");
  assert.equal(harness.element("copy-status").textContent, "");
  assert.equal(harness.element("copy-key-button").textContent, "Copy key");
  assert.equal(harness.fetchMock.requests[AUTHENTICATED_REQUESTS + 1].path, "/api/keys");
  assert.equal(harness.element("key-count").textContent, "1 key");
  assert.match(harness.element("keys-body").textContent, /Notification client/);
});

test("sender identifiers are validated before any request and their origin is visible", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [{
    expires_at: "2030-01-01T00:00:00Z",
    id: "key-assigned",
    key_prefix: "imp_assigned",
    last_used_at: null,
    name: "Assigned client",
    revoked_at: null,
    scopes: ["messages:send"],
    sender_identifier: "abc",
    sender_identifier_assigned: true,
  }, {
    expires_at: "2030-01-01T00:00:00Z",
    id: "key-chosen",
    key_prefix: "imp_chosen",
    last_used_at: null,
    name: "Chosen client",
    revoked_at: null,
    scopes: ["messages:send"],
    sender_identifier: "kle",
    sender_identifier_assigned: false,
  }]);

  const [assignedRow, chosenRow] = harness.element("keys-body").children;
  assert.equal(assignedRow.children[1].children[0].textContent, "abc");
  assert.equal(assignedRow.children[1].children[1].textContent, "Service-assigned");
  assert.equal(assignedRow.children[1].children[1].dataset.origin, "assigned");
  assert.equal(chosenRow.children[1].children[0].textContent, "kle");
  assert.equal(chosenRow.children[1].children[1].textContent, "Operator-chosen");
  assert.equal(chosenRow.children[1].children[1].dataset.origin, "chosen");

  const before = harness.fetchMock.requests.length;
  harness.element("key-name").value = "Notifier";
  harness.scopes[1].checked = true;
  for (const candidate of ["k", "toolongtag", "kl3", "kl-e", "kl e"]) {
    harness.element("key-identifier").value = candidate;
    await harness.element("create-form").emit("submit");
    assert.equal(harness.element("create-error").hidden, false, candidate);
    assert.match(harness.element("create-error").textContent, /2 to 8 roman letters/, candidate);
    assert.equal(harness.element("key-identifier").getAttribute("aria-invalid"), "true", candidate);
    assert.equal(harness.document.activeElement, harness.element("key-identifier"), candidate);
  }
  assert.equal(harness.fetchMock.requests.length, before, "local validation performs no request");

  // The service stores the tag lowercased, so a typed capital is normalized.
  enqueue(harness.fetchMock, json(201, { key: "chosen-secret", sender_identifier: "kle" }));
  harness.element("key-identifier").value = "  KLE  ";
  await harness.element("create-form").emit("submit");
  assert.deepEqual(JSON.parse(harness.fetchMock.requests.at(-1).options.body), {
    expires_in_days: 90,
    name: "Notifier",
    scopes: ["messages:send"],
    sender_identifier: "kle",
  });
  assert.equal(harness.element("create-error").hidden, true);
  assert.equal(harness.element("key-identifier").value, "");

  // An empty field is left out of the body, which is what asks the service to
  // assign one; an explicit empty string would be refused.
  enqueue(harness.fetchMock, json(201, { key: "assigned-secret", sender_identifier: "def" }));
  harness.element("key-name").value = "Assigned notifier";
  harness.scopes[1].checked = true;
  await harness.element("create-form").emit("submit");
  const assignedBody = JSON.parse(harness.fetchMock.requests.at(-1).options.body);
  assert.equal(Object.hasOwn(assignedBody, "sender_identifier"), false);
  assert.equal(assignedBody.name, "Assigned notifier");
});

test("declining Full Disk Access greys every refused control and shows how to turn reading on", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [], [], {
    messages: {
      dependency_version: "1.0.0",
      enable_with: "imessage-proxy enable-messages-read",
      status: "disabled",
    },
  });

  assert.equal(harness.element("messages-status").textContent, "Disabled");
  assert.equal(
    harness.element("messages-detail").textContent,
    "Turn on with: imessage-proxy enable-messages-read",
  );
  assert.equal(harness.element("read-disabled-notice").hidden, false);
  assert.match(harness.element("read-disabled-notice").textContent, /Reading Messages is turned off/);
  assert.match(harness.element("read-disabled-notice").textContent, /Sending to a recipient still works/);
  assert.match(
    harness.element("read-disabled-notice").textContent,
    /Turn it on with: imessage-proxy enable-messages-read/,
  );

  for (const id of [
    "operation-chats",
    "operation-chat",
    "operation-chat-messages",
    "operation-chat-background",
    "operation-scheduled-messages",
    "operation-message-statistics",
    "send-target-chat",
  ]) {
    assert.equal(harness.element(id).disabled, true, id);
    assert.match(harness.element(id).textContent, /reading Messages is off/, id);
  }

  // Nothing is hidden, and the endpoints that never touch the database still run.
  assert.equal(harness.element("operation-chats").hidden, false);
  const statusRequest = await runPlayground(harness, "status", null, json(200, { status: "ok" }));
  assert.equal(statusRequest.path, "/api/status");
  assert.equal(
    harness.element("send-signature").textContent,
    "unavailable until the status check succeeds",
  );

  // A refresh that turns reading off moves the selection off a now-refused
  // endpoint, because a disabled option keeps its selection in the browser.
  const live = createHarness();
  await authenticate(live);
  assert.equal(live.element("read-disabled-notice").hidden, true);
  assert.equal(live.element("operation-chats").disabled, false);
  live.element("playground-operation").value = "chats";
  await live.element("playground-operation").emit("change");
  live.element("send-target-kind").value = "chat_id";
  enqueue(
    live.fetchMock,
    json(200, {
      messages: { enable_with: "imessage-proxy enable-messages-read", status: "disabled" },
      status: "ok",
      version: "1.0.0",
    }),
    json(200, { keys: [] }),
    json(200, { targets: [] }),
  );
  await live.element("refresh-button").emit("click");
  await settle();
  assert.equal(live.element("playground-operation").value, "status");
  assert.equal(live.element("send-target-kind").value, "recipient");
  assert.equal(live.element("read-disabled-notice").hidden, false);

  // Granting the permission puts every control back as it was.
  enqueue(
    live.fetchMock,
    json(200, { messages: { status: "ready" }, status: "ok", version: "1.0.0" }),
    json(200, { keys: [] }),
    json(200, { targets: [] }),
  );
  await live.element("refresh-button").emit("click");
  await settle();
  assert.equal(live.element("read-disabled-notice").hidden, true);
  assert.equal(live.element("read-disabled-notice").textContent, "");
  assert.equal(live.element("operation-chats").disabled, false);
  assert.equal(live.element("operation-chats").textContent, "GET /api/chats");
  assert.equal(live.element("send-target-chat").textContent, "Chat ID");
  assert.equal(live.element("messages-detail").textContent, "Native service");
});

test("revocation requires confirmation, calls the encoded resource, and refreshes the list", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [{
    expires_at: null,
    id: "client/key 1",
    key_prefix: "imp_client",
    last_used_at: null,
    name: "Client one",
    revoked_at: null,
    scopes: ["messages:read"],
  }]);
  const revokeButton = harness.element("keys-body").children[0].children[5].children[0];

  await revokeButton.emit("click");
  assert.equal(harness.element("revoke-dialog").open, true);
  assert.equal(harness.element("revoke-key-name").textContent, "Client one");
  assert.equal(harness.fetchMock.requests.length, AUTHENTICATED_REQUESTS,
    "opening confirmation performs no request");
  await harness.element("cancel-revoke").emit("click");
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.fetchMock.requests.length, AUTHENTICATED_REQUESTS);

  await revokeButton.emit("click");
  harness.fetchMock.enqueue(204, null, "");
  enqueue(harness.fetchMock, json(200, { keys: [] }));
  await harness.element("revoke-form").emit("submit");

  const revokeRequest = harness.fetchMock.requests[AUTHENTICATED_REQUESTS];
  assert.equal(revokeRequest.path, "/api/keys/client%2Fkey%201");
  assert.equal(revokeRequest.options.method, "DELETE");
  assert.equal(revokeRequest.options.headers.get("Authorization"), bearerValue("admin-test-key"));
  assert.equal(harness.fetchMock.requests[AUTHENTICATED_REQUESTS + 1].path, "/api/keys");
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.element("key-count").textContent, "0 keys");
  assert.equal(harness.element("keys-empty").hidden, false);
  assert.equal(harness.element("toast").textContent, "Client one was revoked.");
  assert.equal(harness.element("confirm-revoke").disabled, false);
});

test("the recipient allowlist is edited whole, validated locally, and confirmed before removal", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [], ["chat_id:42", "+15551234567"]);

  // The allowlist loads with the console and is presented in a stable order.
  assert.equal(harness.fetchMock.requests[2].path, "/api/targets");
  assert.equal(harness.fetchMock.requests[2].options.method, undefined, "listing is a plain GET");
  assert.equal(harness.element("target-count").textContent, "2 recipients");
  assert.deepEqual(
    harness.element("targets-body").children.map((row) => row.children[0].textContent),
    ["+15551234567", "chat_id:42"],
  );
  assert.deepEqual(
    harness.element("targets-body").children.map((row) => row.children[1].textContent),
    ["Phone number", "Chat"],
  );

  // A malformed recipient is refused in the browser, so nothing is sent.
  const before = harness.fetchMock.requests.length;
  for (const [candidate, fragment] of [
    ["not-a-recipient", "exactly one @"],
    ["+0155512345", "no leading zero"],
    ["two@at@signs", "exactly one @"],
    ["has space@example.net", "spaces or control characters"],
    ["@example.net", "exactly one @"],
  ]) {
    harness.element("allow-value").value = candidate;
    await harness.element("allow-form").emit("submit");
    assert.equal(harness.element("allow-error").hidden, false, candidate);
    assert.match(harness.element("allow-error").textContent, new RegExp(fragment), candidate);
    assert.equal(harness.element("allow-value").getAttribute("aria-invalid"), "true", candidate);
  }
  harness.element("allow-value").value = "+15551234567";
  await harness.element("allow-form").emit("submit");
  assert.match(harness.element("allow-error").textContent, /already allowed/);
  assert.equal(harness.fetchMock.requests.length, before, "local validation performs no request");

  // Adding sends the whole list and re-renders from what the service stored.
  enqueue(harness.fetchMock, json(200, { targets: ["chat_id:42", "+15551234567", "person@example.net"] }));
  harness.element("allow-value").value = "  person@example.net  ";
  await harness.element("allow-form").emit("submit");
  await settle();
  const addRequest = harness.fetchMock.requests.at(-1);
  assert.equal(addRequest.path, "/api/targets");
  assert.equal(addRequest.options.method, "PUT");
  assert.equal(addRequest.options.headers.get("Content-Type"), "application/json");
  assert.deepEqual(JSON.parse(addRequest.options.body), {
    targets: ["+15551234567", "chat_id:42", "person@example.net"],
  });
  assert.equal(harness.element("target-count").textContent, "3 recipients");
  assert.equal(harness.element("allow-value").value, "");
  assert.equal(harness.element("toast").textContent, "person@example.net can now be messaged.");

  // A chat is composed from the numeric id rather than typed as a prefix.
  harness.element("allow-kind").value = "chat_id";
  await harness.element("allow-kind").emit("change");
  harness.element("allow-value").value = "7";
  enqueue(harness.fetchMock, json(200, { targets: ["chat_id:7"] }));
  await harness.element("allow-form").emit("submit");
  await settle();
  assert.deepEqual(JSON.parse(harness.fetchMock.requests.at(-1).options.body).targets.at(-1), "chat_id:7");

  // Removal is confirmed first, and cancelling changes nothing.
  const removeButton = harness.element("targets-body").children[0].children[2].children[0];
  await removeButton.emit("click");
  assert.equal(harness.element("remove-target-dialog").open, true);
  assert.equal(harness.element("remove-target-name").textContent, "chat_id:7");
  const beforeCancel = harness.fetchMock.requests.length;
  await harness.element("cancel-remove-target").emit("click");
  assert.equal(harness.element("remove-target-dialog").open, false);
  assert.equal(harness.fetchMock.requests.length, beforeCancel, "cancelling performs no request");
  assert.equal(harness.element("target-count").textContent, "1 recipient");

  await removeButton.emit("click");
  enqueue(harness.fetchMock, json(200, { targets: [] }));
  await harness.element("remove-target-form").emit("submit");
  await settle();
  const removeRequest = harness.fetchMock.requests.at(-1);
  assert.equal(removeRequest.options.method, "PUT");
  assert.deepEqual(JSON.parse(removeRequest.options.body), { targets: [] });
  assert.equal(harness.element("remove-target-dialog").open, false);
  assert.equal(harness.element("targets-empty").hidden, false);
  assert.equal(harness.element("target-count").textContent, "0 recipients");
  assert.equal(harness.element("toast").textContent, "chat_id:7 can no longer be messaged.");
  assert.equal(harness.element("confirm-remove-target").disabled, false);

  // A rejected write leaves the table showing what the service still holds.
  enqueue(harness.fetchMock, json(200, { targets: ["a@b.example"] }));
  harness.element("allow-kind").value = "recipient";
  await harness.element("allow-kind").emit("change");
  harness.element("allow-value").value = "a@b.example";
  await harness.element("allow-form").emit("submit");
  await settle();
  enqueue(harness.fetchMock, json(400, { detail: "Provide up to 500 unique targets." }));
  harness.element("allow-value").value = "c@d.example";
  await harness.element("allow-form").emit("submit");
  await settle();
  assert.equal(harness.element("allow-error").textContent, "Provide up to 500 unique targets.");
  assert.equal(harness.element("target-count").textContent, "1 recipient");
  assert.equal(harness.element("targets-body").children[0].children[0].textContent, "a@b.example");
  assert.equal(harness.element("allow-button").disabled, false);
});

test("sign-out removes credentials, aborts the session, and clears sensitive UI state", async () => {
  const harness = createHarness();
  await authenticate(harness, "admin-test-key", [{
    id: "key-1",
    name: "Client",
    scopes: ["admin"],
  }]);
  const authenticatedSignal = harness.fetchMock.requests[0].options.signal;
  harness.element("created-key").value = "ephemeral-secret";
  harness.element("created-key-dialog").showModal();
  harness.element("revoke-dialog").showModal();
  harness.element("send-dialog").showModal();
  harness.element("send-target").value = "private@example.net";
  harness.element("send-text").value = "sensitive draft";
  harness.element("playground-output").textContent = '{"private":"response"}';

  await harness.element("logout-button").emit("click");

  assert.equal(authenticatedSignal.aborted, true);
  assert.equal(harness.sessionStorage.getItem(storageKey), null);
  assert.deepEqual(Array.from(harness.sessionStorage.values.entries()), []);
  assert.equal(harness.element("created-key").value, "");
  assert.equal(harness.element("created-key-dialog").open, false);
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.element("send-dialog").open, false);
  assert.equal(harness.element("send-target").value, "");
  assert.equal(harness.element("send-text").value, "");
  assert.doesNotMatch(harness.element("playground-output").textContent, /private|sensitive/);
  assert.equal(harness.element("signin-view").hidden, false);
  assert.equal(harness.element("console-view").hidden, true);
  assert.equal(harness.element("connection-label").textContent, "Signed out");
  assert.equal(harness.element("service-status").textContent, "Signed out");
  assert.equal(harness.element("key-count").textContent, "0 keys");
  assert.equal(harness.element("keys-body").children.length, 0);
  assert.equal(harness.element("remove-target-dialog").open, false);
  assert.equal(harness.element("target-count").textContent, "0 recipients");
  assert.equal(harness.element("targets-body").children.length, 0);
});

test("network, API, clipboard, and authentication failures remain actionable and safe", async () => {
  const emptyHarness = createHarness();
  await emptyHarness.element("signin-form").emit("submit");
  assert.equal(emptyHarness.element("signin-error").hidden, false);
  assert.equal(emptyHarness.element("signin-error").textContent, "Enter an API key to continue.");
  assert.equal(emptyHarness.document.activeElement, emptyHarness.element("signin-key"));
  assert.equal(emptyHarness.fetchMock.requests.length, 0);

  const forbiddenHarness = createHarness();
  enqueue(
    forbiddenHarness.fetchMock,
    json(200, { messages: { status: "ready" }, status: "ok" }),
    json(403, { detail: "scope denied" }),
    json(403, { detail: "scope denied" }),
  );
  forbiddenHarness.element("signin-key").value = "read-only-key";
  await forbiddenHarness.element("signin-form").emit("submit");
  assert.equal(forbiddenHarness.element("signin-view").hidden, false);
  assert.equal(forbiddenHarness.element("signin-error").textContent, "This key does not include the admin scope.");
  assert.equal(forbiddenHarness.sessionStorage.getItem(storageKey), null);

  const harness = createHarness();
  harness.fetchMock.enqueueFailure();
  enqueue(harness.fetchMock, json(200, { keys: [] }), json(200, { targets: [] }));
  harness.element("signin-key").value = "admin-test-key";
  await harness.element("signin-form").emit("submit");
  assert.equal(harness.element("console-view").hidden, false, "status failure does not hide key management");
  assert.equal(harness.element("service-status").textContent, "Degraded");
  assert.equal(harness.element("messages-status").textContent, "Unavailable");
  assert.equal(harness.element("service-detail").textContent, "The service could not be reached.");

  enqueue(harness.fetchMock, json(422, { detail: "name is already in use" }));
  harness.element("key-name").value = "Duplicate";
  harness.scopes[2].checked = true;
  await harness.element("create-form").emit("submit");
  assert.equal(harness.element("create-error").hidden, false);
  assert.equal(harness.element("create-error").textContent, "name is already in use");
  assert.equal(harness.element("create-button").disabled, false);

  enqueue(harness.fetchMock, json(201, { key: "manual-copy-secret" }));
  harness.element("key-name").value = "Manual copy";
  await harness.element("create-form").emit("submit");
  harness.setClipboardError(new Error("clipboard blocked"));
  await harness.element("copy-key-button").emit("click");
  assert.equal(harness.element("created-key").selected, true);
  assert.equal(
    harness.element("copy-status").textContent,
    "Clipboard access was blocked. Copy the selected key manually.",
  );

  enqueue(
    harness.fetchMock,
    json(401, { detail: "expired" }),
    json(401, { detail: "expired" }),
  );
  await harness.element("refresh-button").emit("click");
  assert.equal(harness.element("signin-view").hidden, false);
  assert.equal(harness.element("signin-error").textContent, "The API key is invalid, expired, or revoked.");
  assert.equal(harness.sessionStorage.getItem(storageKey), null);
  assert.equal(harness.element("created-key").value, "");
});

test("a console reached over the network can still send", async () => {
  // Serving an address other than loopback puts the console on an origin that is
  // not a secure context, where crypto.randomUUID does not exist. Refusing to
  // send there declared the browser incapable of something it can do: only the
  // convenience wrapper is gated, and crypto.getRandomValues - the same CSPRNG -
  // is not. This is what an operator hits opening the console from another
  // machine on their network.
  const harness = createHarness({ secureContext: false });
  await authenticate(harness);
  harness.element("playground-operation").value = "send-message";
  await harness.element("playground-operation").emit("change");
  harness.element("send-target-kind").value = "recipient";
  harness.element("send-target").value = "first-last@example.net";
  harness.element("send-text").value = "Hello from the network";

  await harness.element("playground-form").emit("submit");
  assert.equal(harness.element("send-dialog").open, true);
  await harness.element("send-confirm-form").emit("submit");
  await settle();

  const sent = harness.fetchMock.requests.at(-1);
  assert.equal(sent.path, "/api/messages", "the send must reach the API");
  const key = sent.options.headers.get("Idempotency-Key");
  assert.match(key, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    "the fallback must be a real version-4 UUID, not random hex shaped like one");
  assert.equal(harness.element("playground-error").textContent, "",
    "no error may be shown when the key could be generated");

  // A second logical send must not reuse the first key, or a retry of one
  // message would be treated as a replay of the other.
  harness.element("send-text").value = "A different message";
  await harness.element("playground-form").emit("submit");
  await harness.element("send-confirm-form").emit("submit");
  await settle();
  assert.notEqual(harness.fetchMock.requests.at(-1).options.headers.get("Idempotency-Key"), key);
});
