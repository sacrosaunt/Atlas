import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CalendarStore } from "./calendar-store.js";

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "atlas-calendar-"));
  const snapshotPath = join(directory, "calendar-events.json");
  writeFileSync(snapshotPath, JSON.stringify({
    format_version: 1,
    updated_at: "2026-07-20T20:00:00Z",
    range_start: "2020-01-01T00:00:00Z",
    range_end: "2030-01-01T00:00:00Z",
    events: [
      {
        source_id: "private-event-id-1",
        calendar_id: "private-calendar-id-1",
        calendar: "Work",
        title: "Design review",
        start_at: "2026-07-21T17:00:00Z",
        end_at: "2026-07-21T18:00:00Z",
        is_all_day: false,
        location: "Studio",
        notes: "Discuss Atlas",
        status: "confirmed",
        availability: "busy",
      },
      {
        source_id: "private-event-id-2",
        calendar_id: "private-calendar-id-2",
        calendar: "Personal",
        title: "Dentist",
        start_at: "2026-08-02T18:00:00Z",
        end_at: "2026-08-02T19:00:00Z",
        is_all_day: false,
        location: null,
        notes: null,
        status: "confirmed",
        availability: "busy",
      },
    ],
  }));
  return {
    directory,
    store: new CalendarStore({ snapshotPath, identitySecret: "test-secret" }),
  };
}

test("calendar status exposes opaque calendar IDs without source identifiers", () => {
  const { directory, store } = fixture();
  try {
    const status = store.status();
    assert.equal(status.connected, true);
    assert.equal(status.event_count, 2);
    assert.match(status.calendars[0].calendar_id, /^calendar_/);
    assert.doesNotMatch(JSON.stringify(status), /private-calendar-id/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("calendar search applies text and date bounds and returns opaque event IDs", () => {
  const { directory, store } = fixture();
  try {
    const result = store.searchEvents({
      query: "atlas",
      since: "2026-07-01",
      until: "2026-08-01",
      limit: 10,
    });
    assert.equal(result.total_matches, 1);
    assert.equal(result.events[0].title, "Design review");
    assert.match(result.events[0].event_id, /^event_/);
    assert.doesNotMatch(JSON.stringify(result), /private-event-id/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("calendar events can be read back by opaque ID", () => {
  const { directory, store } = fixture();
  try {
    const match = store.searchEvents({ query: "Dentist", limit: 10 }).events[0];
    const result = store.readEvents({ event_ids: [match.event_id] });
    assert.equal(result.found, 1);
    assert.equal(result.events[0].title, "Dentist");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("calendar tools report a disconnected snapshot clearly", () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-calendar-empty-"));
  try {
    const store = new CalendarStore({
      snapshotPath: join(directory, "missing.json"),
      identitySecret: "test-secret",
    });
    assert.equal(store.status().connected, false);
    assert.throws(() => store.searchEvents(), /not connected/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
