import assert from "node:assert/strict";
import test from "node:test";
import {
  privateAttachmentName,
  redactSensitiveText,
  sanitizeForCloud,
} from "./privacy-redaction.js";

test("redacts direct identifiers with typed irreversible tokens", () => {
  const source = [
    "Email me at alex@example.com or call +1 (415) 555-0123.",
    "Meet at 1234 Pine Street Apt 5 and use https://maps.example.test/?token=secret.",
    "Card 4111 1111 1111 1111, SSN 123-45-6789, passport AB1234567, IP 192.168.1.20.",
    "The verification code is 839201.",
  ].join(" ");
  const output = redactSensitiveText(source);
  for (const secret of [
    "alex@example.com", "415", "Pine", "token=secret", "4111", "123-45-6789",
    "AB1234567", "192.168.1.20", "839201",
  ]) assert.equal(output.includes(secret), false, secret);
  for (const category of [
    "email address", "phone number", "street address", "link", "payment card",
    "government identifier", "IP address", "credential",
  ]) assert.match(output, new RegExp(`\\[redacted: ${category}\\]`));
});

test("preserves ordinary dates and non-sensitive prose", () => {
  const source = "We met on 2026-07-20 and talked for 45 minutes about the project.";
  assert.equal(redactSensitiveText(source), source);
});

test("sanitizes nested outbound structures and reports local removals", () => {
  const result = sanitizeForCloud({ messages: [{ text: "Send it to me@example.com" }] });
  assert.equal(result.value.messages[0].text, "Send it to [redacted: email address]");
  assert.deepEqual(result.summary, { total: 1, categories: ["email address"] });
});

test("attachment names expose only a normalized extension", () => {
  assert.equal(privateAttachmentName("Alice Passport 123 Main St.PDF"), "[attachment].pdf");
  assert.equal(privateAttachmentName("family-photo"), "[attachment]");
  assert.equal(privateAttachmentName(null), null);
});
