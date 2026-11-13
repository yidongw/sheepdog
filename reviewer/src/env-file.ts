/**
 * Load the reviewer's settings from a KEY=VALUE file (SHEEPDOG_ENV_FILE) without overriding variables that are already
 * set. The file lives on the review runner (e.g. which codex home, which effort); it never comes from the reviewed
 * repository. Lines: `KEY=value`, `export KEY=value`, `# comments`; values may be single- or double-quoted.
 */
import { readFileSync } from "node:fs";

export function parseEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"') && v.length >= 2) || (v.startsWith("'") && v.endsWith("'") && v.length >= 2)) v = v.slice(1, -1);
    else v = v.replace(/\s+#.*$/, "");
    out[m[1]] = v;
  }
  return out;
}

export function loadEnvFile(file: string | undefined, env: NodeJS.ProcessEnv = process.env): void {
  if (!file) return;
  const text = readFileSync(file, "utf8"); // a named file that cannot be read is an error, not a silent default
  for (const [k, v] of Object.entries(parseEnvFile(text))) if (!(k in env)) env[k] = v;
}
