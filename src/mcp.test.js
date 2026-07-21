import assert from "node:assert/strict";
import test from "node:test";
import { mountMcp } from "./mcp.js";

function mockApp() {
  let middleware;
  return {
    use(path, handler) {
      assert.equal(path, "/mcp");
      middleware = handler;
    },
    post() {},
    get() {},
    delete() {},
    middleware: () => middleware,
  };
}

test("MCP rejects message access until the disclosure is accepted", async () => {
  const app = mockApp();
  const close = mountMcp(app, {
    store: {},
    token: "private-token",
    semanticIndex: {},
    sentimentIndex: {},
    consentProvider: () => false,
  });
  let status;
  let body;
  let continued = false;
  const response = {
    status(value) { status = value; return this; },
    set() { return this; },
    send(value) { body = value; return this; },
  };
  app.middleware()(
    { headers: { authorization: "Bearer private-token" } },
    response,
    () => { continued = true; },
  );
  assert.equal(status, 428);
  assert.match(body, /data disclosure/);
  assert.equal(continued, false);
  await close();
});

test("MCP remains unavailable when no Atlas window is active", async () => {
  const app = mockApp();
  const close = mountMcp(app, {
    store: {},
    token: "private-token",
    semanticIndex: {},
    sentimentIndex: {},
    consentProvider: () => true,
    activityProvider: () => false,
  });
  let status;
  let continued = false;
  const response = {
    status(value) { status = value; return this; },
    set() { return this; },
    send() { return this; },
  };
  app.middleware()(
    { headers: { authorization: "Bearer private-token" } },
    response,
    () => { continued = true; },
  );
  assert.equal(status, 409);
  assert.equal(continued, false);
  await close();
});
