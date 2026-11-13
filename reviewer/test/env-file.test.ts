import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, it } from "vitest";
import { loadEnvFile, parseEnvFile } from "../src/env-file.ts";

it("parses KEY=value lines, export, quotes and comments", () => {
  expect(parseEnvFile('# c\nA=1\nexport B="two words"\nC=\'x # y\'\nD=v # note\nnot a line\n')).toEqual({ A: "1", B: "two words", C: "x # y", D: "v" });
});

it("never overrides a variable that is already set; a missing named file is an error", () => {
  const f = path.join(mkdtempSync(path.join(tmpdir(), "sheepdog-env-")), "review.env");
  writeFileSync(f, "CODEREVIEW_EFFORT=high\nCODEREVIEW_BACKEND=codex\n");
  const env: NodeJS.ProcessEnv = { CODEREVIEW_EFFORT: "low" };
  loadEnvFile(f, env);
  expect(env).toEqual({ CODEREVIEW_EFFORT: "low", CODEREVIEW_BACKEND: "codex" });
  loadEnvFile(undefined, env); // none named: nothing
  expect(() => loadEnvFile(f + ".missing", env)).toThrow();
});
