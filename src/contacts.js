import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const ADDRESS_BOOK_ROOT = join(homedir(), "Library", "Application Support", "AddressBook");

function normalize(value) {
  const raw = value?.trim().toLowerCase();
  if (!raw) return "";
  if (raw.includes("@")) return raw;
  const digits = raw.replace(/\D/g, "");
  return digits.length === 10 ? `1${digits}` : digits;
}

function tableColumns(db, table) {
  return new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
}

function ownerExpression(columns, alias) {
  if (columns.has("ZOWNER") && columns.has("Z22_OWNER")) {
    return `COALESCE(${alias}.ZOWNER, ${alias}.Z22_OWNER)`;
  }
  if (columns.has("ZOWNER")) return `${alias}.ZOWNER`;
  if (columns.has("Z22_OWNER")) return `${alias}.Z22_OWNER`;
  return null;
}

export class ContactIndex {
  constructor({ root = ADDRESS_BOOK_ROOT } = {}) {
    this.byIdentifier = new Map();
    this.load(root);
  }

  load(root) {
    if (!existsSync(root)) return;
    const paths = [join(root, "AddressBook-v22.abcddb")];
    const sources = join(root, "Sources");
    if (existsSync(sources)) {
      for (const entry of readdirSync(sources, { withFileTypes: true })) {
        if (entry.isDirectory()) paths.push(join(sources, entry.name, "AddressBook-v22.abcddb"));
      }
    }

    for (const path of paths) {
      if (!existsSync(path)) continue;
      let db;
      try {
        db = new DatabaseSync(path, { readOnly: true, timeout: 2_000 });
        const recordColumns = tableColumns(db, "ZABCDRECORD");
        const optionalColumn = (column, alias) => recordColumns.has(column)
          ? `${column} AS ${alias}`
          : `NULL AS ${alias}`;
        const people = new Map(db.prepare(`
          SELECT Z_PK AS id, ZFIRSTNAME AS first_name, ZLASTNAME AS last_name,
                 ${optionalColumn("ZNICKNAME", "nickname")},
                 ${optionalColumn("ZORGANIZATION", "organization")},
                 ${optionalColumn("ZJOBTITLE", "job_title")},
                 ${optionalColumn("ZDEPARTMENT", "department")}
          FROM ZABCDRECORD
        `).all().map((row) => {
          const full = [row.first_name, row.last_name].filter(Boolean).join(" ").trim();
          return [row.id, {
            name: full || row.nickname || row.organization || null,
            nickname: row.nickname || null,
            company: row.organization || null,
            job_title: row.job_title || null,
            department: row.department || null,
          }];
        }));

        for (const [table, valueColumn] of [
          ["ZABCDPHONENUMBER", "ZFULLNUMBER"],
          ["ZABCDEMAILADDRESS", "ZADDRESS"],
        ]) {
          const columns = tableColumns(db, table);
          const owner = ownerExpression(columns, "v");
          if (!owner || !columns.has(valueColumn)) continue;
          for (const row of db.prepare(`
            SELECT ${owner} AS owner_id, v.${valueColumn} AS value FROM ${table} v
            WHERE v.${valueColumn} IS NOT NULL
          `).all()) {
            const profile = people.get(row.owner_id);
            const key = normalize(row.value);
            if (profile?.name && key && !this.byIdentifier.has(key)) {
              this.byIdentifier.set(key, profile);
            }
          }
        }
      } catch {
        // Contacts are a best-effort enhancement; Messages access remains usable without them.
      } finally {
        db?.close();
      }
    }
  }

  nameFor(identifier) {
    return this.profileFor(identifier)?.name ?? null;
  }

  profileFor(identifier) {
    return this.byIdentifier.get(normalize(identifier)) ?? null;
  }

  matches(identifier, query) {
    const profile = this.profileFor(identifier);
    const needle = query.toLocaleLowerCase();
    return Boolean(profile && Object.values(profile).some(
      (value) => value?.toLocaleLowerCase().includes(needle),
    ));
  }
}
