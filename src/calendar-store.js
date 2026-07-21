import { createHmac } from "node:crypto";
import { readFileSync, statSync } from "node:fs";

function parseBound(value, name) {
  if (value == null || value === "") return null;
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) throw new Error(`${name} must be an ISO-8601 date`);
  return timestamp;
}

function normalizeLimit(value, fallback, maximum) {
  const limit = value == null ? fallback : Number(value);
  if (!Number.isInteger(limit) || limit < 1 || limit > maximum) {
    throw new Error(`limit must be between 1 and ${maximum}`);
  }
  return limit;
}

export class CalendarStore {
  constructor({ snapshotPath, identitySecret }) {
    this.snapshotPath = snapshotPath;
    this.identitySecret = identitySecret;
    this.snapshot = null;
    this.modifiedAt = null;
  }

  opaqueId(kind, sourceId) {
    const digest = createHmac("sha256", this.identitySecret)
      .update(`${kind}:${sourceId}`)
      .digest("base64url")
      .slice(0, 22);
    return `${kind}_${digest}`;
  }

  reload() {
    let modifiedAt;
    try {
      modifiedAt = statSync(this.snapshotPath).mtimeMs;
    } catch {
      this.snapshot = null;
      this.modifiedAt = null;
      return null;
    }
    if (this.snapshot && modifiedAt === this.modifiedAt) return this.snapshot;
    const parsed = JSON.parse(readFileSync(this.snapshotPath, "utf8"));
    if (parsed?.format_version !== 1 || !Array.isArray(parsed.events)) {
      throw new Error("Atlas's local calendar snapshot is invalid; reconnect Calendar in Settings");
    }
    this.snapshot = parsed;
    this.modifiedAt = modifiedAt;
    return parsed;
  }

  status() {
    const snapshot = this.reload();
    if (!snapshot) {
      return {
        connected: false,
        event_count: 0,
        calendars: [],
        updated_at: null,
        range_start: null,
        range_end: null,
      };
    }
    const calendars = new Map();
    for (const event of snapshot.events) {
      const sourceId = event.calendar_id || event.calendar || "calendar";
      const entry = calendars.get(sourceId) ?? {
        calendar_id: this.opaqueId("calendar", sourceId),
        name: event.calendar || "Calendar",
        event_count: 0,
      };
      entry.event_count += 1;
      calendars.set(sourceId, entry);
    }
    return {
      connected: true,
      event_count: snapshot.events.length,
      calendars: [...calendars.values()].sort((left, right) => left.name.localeCompare(right.name)),
      updated_at: snapshot.updated_at,
      range_start: snapshot.range_start,
      range_end: snapshot.range_end,
    };
  }

  eventResult(event, { fullDetails = false } = {}) {
    const calendarSourceId = event.calendar_id || event.calendar || "calendar";
    return {
      event_id: this.opaqueId("event", event.source_id),
      title: event.title || "Untitled event",
      start_at: event.start_at,
      end_at: event.end_at,
      is_all_day: event.is_all_day === true,
      calendar: {
        calendar_id: this.opaqueId("calendar", calendarSourceId),
        name: event.calendar || "Calendar",
      },
      location: event.location || null,
      ...(fullDetails
        ? { notes: event.notes ? String(event.notes).slice(0, 10_000) : null }
        : { notes_preview: event.notes ? String(event.notes).slice(0, 280) : null }),
      status: event.status || "none",
      availability: event.availability || "not_supported",
    };
  }

  searchEvents({ query, calendar_ids: calendarIds, since, until, limit } = {}) {
    const snapshot = this.reload();
    if (!snapshot) throw new Error("Calendar is not connected. Connect it in Atlas Settings first.");
    const normalizedQuery = typeof query === "string" ? query.trim().toLocaleLowerCase() : "";
    let start = parseBound(since, "since");
    let end = parseBound(until, "until");
    if (start != null && end != null && end <= start) throw new Error("until must be after since");
    if (!normalizedQuery && start == null && end == null) {
      const now = new Date();
      now.setHours(0, 0, 0, 0);
      start = now.getTime();
      end = new Date(now.getFullYear() + 1, now.getMonth(), now.getDate()).getTime();
    }
    const selectedCalendars = Array.isArray(calendarIds) && calendarIds.length
      ? new Set(calendarIds)
      : null;
    const maximum = normalizeLimit(limit, 100, 1_000);
    const matches = snapshot.events.filter((event) => {
      const eventStart = Date.parse(event.start_at);
      const eventEnd = Date.parse(event.end_at);
      if (!Number.isFinite(eventStart) || !Number.isFinite(eventEnd)) return false;
      if (start != null && eventEnd < start) return false;
      if (end != null && eventStart >= end) return false;
      const calendarSourceId = event.calendar_id || event.calendar || "calendar";
      if (selectedCalendars
          && !selectedCalendars.has(this.opaqueId("calendar", calendarSourceId))) return false;
      if (!normalizedQuery) return true;
      return [event.title, event.calendar, event.location, event.notes]
        .filter(Boolean)
        .some((value) => String(value).toLocaleLowerCase().includes(normalizedQuery));
    }).sort((left, right) => Date.parse(left.start_at) - Date.parse(right.start_at));
    return {
      events: matches.slice(0, maximum).map((event) => this.eventResult(event)),
      total_matches: matches.length,
      returned: Math.min(matches.length, maximum),
      snapshot_updated_at: snapshot.updated_at,
      snapshot_range: { since: snapshot.range_start, until: snapshot.range_end },
    };
  }

  readEvents({ event_ids: eventIds } = {}) {
    const snapshot = this.reload();
    if (!snapshot) throw new Error("Calendar is not connected. Connect it in Atlas Settings first.");
    if (!Array.isArray(eventIds) || eventIds.length < 1 || eventIds.length > 100) {
      throw new Error("event_ids must contain between 1 and 100 opaque event IDs");
    }
    const requested = new Set(eventIds);
    const events = snapshot.events
      .filter((event) => requested.has(this.opaqueId("event", event.source_id)))
      .map((event) => this.eventResult(event, { fullDetails: true }));
    return { events, requested: requested.size, found: events.length };
  }
}
