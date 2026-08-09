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

  focus() {
    this.ownerDocument.activeElement = this;
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  querySelectorAll(selector) {
    assert.equal(selector, 'input[name="scope"]:checked');
    return this.controls.filter((control) => control.name === "scope" && control.checked);
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

  enqueue(status, payload = null, contentType = "application/json") {
    this.responses.push({ contentType, payload, status });
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
      headers: new Headers(response.contentType ? { "content-type": response.contentType } : {}),
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
  for (const name of ["aria-pressed", "aria-live", "aria-labelledby", "role"]) {
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

function anonymousScopeControls(document) {
  return Array.from(markup.matchAll(/<input\b([^>]*\bname="scope"[^>]*)>/gi), (match) => {
    const control = new FakeElement(document, "input");
    control.type = "checkbox";
    control.name = "scope";
    control.value = attribute(match[1], "value") || "";
    return control;
  });
}

function createHarness({ initialResponses = [], storedKey = "" } = {}) {
  const document = new FakeDocument();
  const ids = Array.from(markup.matchAll(/\bid="([a-z0-9-]+)"/g), (match) => match[1]);
  for (const id of ids) {
    elementFromMarkup(document, id);
  }

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
  const keyExpiry = document.elements.get("key-expiry");
  const scopes = anonymousScopeControls(document);
  createForm.controls = [keyName, ...scopes, keyExpiry];
  createForm.elements = { expires_in_days: keyExpiry, name: keyName };

  const sessionStorage = new StorageSpy(storedKey ? { [storageKey]: storedKey } : {});
  const clipboardWrites = [];
  let clipboardError = null;
  let nextTimerID = 1;
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
  const context = vm.createContext({
    AbortController,
    Date,
    Event,
    FormData: FakeFormData,
    Headers,
    Intl,
    TextEncoder,
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
    element(id) {
      return document.elements.get(id);
    },
  };
}

function json(status, payload) {
  return [status, payload, "application/json"];
}

function enqueue(fetchMock, ...responses) {
  for (const [status, payload, contentType] of responses) {
    fetchMock.enqueue(status, payload, contentType);
  }
}

async function authenticate(harness, key = "admin-test-key", keys = []) {
  enqueue(
    harness.fetchMock,
    json(200, {
      messages: { status: "ready" },
      status: "ok",
      uptime_seconds: 7322,
      version: "1.0.0",
    }),
    json(200, { keys }),
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

  assert.equal(harness.fetchMock.requests.length, 2);
  assert.deepEqual(harness.fetchMock.requests.map((request) => request.path), ["/api/status", "/api/keys"]);
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
    ],
    storedKey: adminKey,
  });
  await settle();

  assert.deepEqual(harness.sessionStorage.operations, [["get", storageKey]]);
  assert.equal(harness.fetchMock.requests.length, 2);
  assert.equal(harness.fetchMock.requests[0].options.headers.get("Authorization"), bearerValue(adminKey));
  assert.equal(harness.fetchMock.requests[1].options.headers.get("Authorization"), bearerValue(adminKey));
  assert.equal(harness.element("signin-view").hidden, true);
  assert.equal(harness.element("console-view").hidden, false);
  assert.equal(harness.element("connection-label").textContent, "Healthy");
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

  const createRequest = harness.fetchMock.requests[2];
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
  assert.equal(harness.fetchMock.requests[3].path, "/api/keys");
  assert.equal(harness.element("key-count").textContent, "1 key");
  assert.match(harness.element("keys-body").textContent, /Notification client/);
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
  const revokeButton = harness.element("keys-body").children[0].children[4].children[0];

  await revokeButton.emit("click");
  assert.equal(harness.element("revoke-dialog").open, true);
  assert.equal(harness.element("revoke-key-name").textContent, "Client one");
  assert.equal(harness.fetchMock.requests.length, 2, "opening confirmation performs no request");
  await harness.element("cancel-revoke").emit("click");
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.fetchMock.requests.length, 2);

  await revokeButton.emit("click");
  harness.fetchMock.enqueue(204, null, "");
  enqueue(harness.fetchMock, json(200, { keys: [] }));
  await harness.element("revoke-form").emit("submit");

  const revokeRequest = harness.fetchMock.requests[2];
  assert.equal(revokeRequest.path, "/api/keys/client%2Fkey%201");
  assert.equal(revokeRequest.options.method, "DELETE");
  assert.equal(revokeRequest.options.headers.get("Authorization"), bearerValue("admin-test-key"));
  assert.equal(harness.fetchMock.requests[3].path, "/api/keys");
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.element("key-count").textContent, "0 keys");
  assert.equal(harness.element("keys-empty").hidden, false);
  assert.equal(harness.element("toast").textContent, "Client one was revoked.");
  assert.equal(harness.element("confirm-revoke").disabled, false);
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

  await harness.element("logout-button").emit("click");

  assert.equal(authenticatedSignal.aborted, true);
  assert.equal(harness.sessionStorage.getItem(storageKey), null);
  assert.deepEqual(Array.from(harness.sessionStorage.values.entries()), []);
  assert.equal(harness.element("created-key").value, "");
  assert.equal(harness.element("created-key-dialog").open, false);
  assert.equal(harness.element("revoke-dialog").open, false);
  assert.equal(harness.element("signin-view").hidden, false);
  assert.equal(harness.element("console-view").hidden, true);
  assert.equal(harness.element("connection-label").textContent, "Signed out");
  assert.equal(harness.element("service-status").textContent, "Signed out");
  assert.equal(harness.element("key-count").textContent, "0 keys");
  assert.equal(harness.element("keys-body").children.length, 0);
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
  );
  forbiddenHarness.element("signin-key").value = "read-only-key";
  await forbiddenHarness.element("signin-form").emit("submit");
  assert.equal(forbiddenHarness.element("signin-view").hidden, false);
  assert.equal(forbiddenHarness.element("signin-error").textContent, "This key does not include the admin scope.");
  assert.equal(forbiddenHarness.sessionStorage.getItem(storageKey), null);

  const harness = createHarness();
  harness.fetchMock.enqueueFailure();
  enqueue(harness.fetchMock, json(200, { keys: [] }));
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
