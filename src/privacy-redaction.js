const TOKEN_PREFIX = "[redacted:";

function token(category) {
  return `${TOKEN_PREFIX} ${category}]`;
}

function note(counts, category) {
  if (counts) counts[category] = (counts[category] ?? 0) + 1;
  return token(category);
}

function luhnValid(candidate) {
  const digits = candidate.replace(/\D/g, "");
  if (digits.length < 13 || digits.length > 19 || /^(\d)\1+$/.test(digits)) return false;
  let sum = 0;
  let double = false;
  for (let index = digits.length - 1; index >= 0; index -= 1) {
    let digit = Number(digits[index]);
    if (double) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    double = !double;
  }
  return sum % 10 === 0;
}

function validIPv4(candidate) {
  const parts = candidate.split(".");
  return parts.length === 4 && parts.every((part) => Number(part) >= 0 && Number(part) <= 255);
}

export function redactSensitiveText(value, { counts } = {}) {
  if (typeof value !== "string" || !value) return value;
  let output = value;

  // Remove links wholesale. Query strings commonly contain invitation tokens,
  // coordinates, email addresses, document IDs, and other identifiers that a
  // domain-only or query-stripped URL can still accidentally preserve.
  output = output.replace(/\b(?:https?:\/\/|www\.)[^\s<>"']+/giu, () => note(counts, "link"));
  output = output.replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/giu, () => note(counts, "email address"));

  // Common bearer credentials and provider-shaped secrets.
  output = output.replace(/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, () => note(counts, "access token"));
  output = output.replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16})\b/g, () => note(counts, "access token"));
  output = output.replace(
    /\b(password|passcode|verification\s+code|one[- ]time\s+(?:password|code)|otp|security\s+code|pin)\s*(?:is|:|=)\s*["']?[^\s,"']{4,128}["']?/giu,
    (_match, label) => `${label}: ${note(counts, "credential")}`,
  );

  // Government and financial identifiers. Card candidates are only labeled as
  // payment cards when they pass Luhn; other long digit strings are caught by
  // the conservative phone/account-number rules below.
  output = output.replace(/\b\d{3}-\d{2}-\d{4}\b/g, () => note(counts, "government identifier"));
  output = output.replace(
    /\b(passport|driver'?s?\s+license|license|tax\s+id)\s*(?:number|no\.?|#)?\s*(?:is|:|=)?\s*[A-Z0-9-]{5,24}\b/giu,
    (_match, label) => `${label}: ${note(counts, "government identifier")}`,
  );
  output = output.replace(/\b(?:\d[ -]?){12,18}\d\b/g, (candidate) => (
    luhnValid(candidate) ? note(counts, "payment card") : candidate
  ));
  output = output.replace(
    /\b(?:routing|aba)\s*(?:number|no\.?|#)?\s*(?:is|:|=)?\s*\d{9}\b/giu,
    () => `routing number: ${note(counts, "bank identifier")}`,
  );
  output = output.replace(
    /\b(?:account|acct)\s*(?:number|no\.?|#)\s*(?:is|:|=)?\s*[A-Z0-9-]{6,24}\b/giu,
    () => `account number: ${note(counts, "bank identifier")}`,
  );

  // Precise network and physical location indicators.
  output = output.replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, (candidate) => (
    validIPv4(candidate) ? note(counts, "IP address") : candidate
  ));
  output = output.replace(
    /(?<![\d.])-?(?:[1-8]?\d(?:\.\d{4,})|90(?:\.0+)?)[,\s]+-?(?:1[0-7]\d(?:\.\d{4,})|(?:\d?\d)(?:\.\d{4,})|180(?:\.0+)?)(?![\d.])/g,
    () => note(counts, "precise location"),
  );
  output = output.replace(/\bP\.?\s*O\.?\s+Box\s+\d+[A-Z]?\b/giu, () => note(counts, "postal address"));
  output = output.replace(
    /\b\d{1,6}\s+(?:(?:N|S|E|W|NE|NW|SE|SW)\.?\s+)?(?:[\p{L}0-9.'’-]+\s+){1,7}(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Boulevard|Blvd\.?|Lane|Ln\.?|Drive|Dr\.?|Court|Ct\.?|Circle|Cir\.?|Highway|Hwy\.?|Parkway|Pkwy\.?|Place|Pl\.?|Terrace|Ter\.?)(?:\s+(?:Apt\.?|Apartment|Unit|Suite|Ste\.?)\s*[A-Z0-9-]+)?\b/giu,
    () => note(counts, "street address"),
  );

  output = output.replace(
    /\b(?:date\s+of\s+birth|dob)\s*(?:is|:|=)?\s*(?:\d{1,2}[\/-]){2}\d{2,4}\b/giu,
    () => `date of birth: ${note(counts, "birth date")}`,
  );

  // Phone-shaped strings are last so ISO dates and already-redacted financial
  // values are not misclassified.
  output = output.replace(/(?:\+?\d[\d().\-\s]{5,}\d)/g, (candidate) => {
    const trimmed = candidate.trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return candidate;
    return (trimmed.match(/\d/g)?.length ?? 0) >= 7
      ? note(counts, "phone number")
      : candidate;
  });
  return output;
}

export function privateAttachmentName(value) {
  if (typeof value !== "string" || !value.trim()) return null;
  const extension = value.trim().match(/\.[A-Za-z0-9]{1,10}$/u)?.[0]?.toLowerCase() ?? "";
  return `[attachment]${extension}`;
}

export function sanitizeForCloud(value) {
  const counts = {};
  const walk = (item) => {
    if (typeof item === "string") return redactSensitiveText(item, { counts });
    if (Array.isArray(item)) return item.map(walk);
    if (!item || typeof item !== "object") return item;
    return Object.fromEntries(Object.entries(item).map(([key, child]) => [key, walk(child)]));
  };
  const sanitized = walk(value);
  return {
    value: sanitized,
    summary: {
      total: Object.values(counts).reduce((sum, count) => sum + count, 0),
      categories: Object.keys(counts).sort(),
    },
  };
}
