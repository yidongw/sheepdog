import { describe, expect, it } from "vitest";

import { reviewerErrorSummary, withReviewerActivityTail } from "../src/reviewer.ts";

describe("reviewerErrorSummary (codex banner hid 'model at capacity', 2026-10-05)", () => {
  it("leads with the ERROR lines, not the stdin banner", () => {
    const stderr = "Reading additional input from stdin...\nOpenAI Codex v0.154.0\n--------\nworkdir: /x\nERROR: Selected model is at capacity. Please try a different model.\nERROR: Selected model is at capacity. Please try a different model.\n";
    const s = reviewerErrorSummary(stderr);
    expect(s.startsWith("ERROR: Selected model is at capacity")).toBe(true);
    expect(s).not.toMatch(/Reading additional input/);
    expect(s.match(/at capacity/g)).toHaveLength(1);
  });
  it("falls back to the last non-banner line", () => {
    expect(reviewerErrorSummary("Reading additional input from stdin...\nsomething broke here\n")).toBe("something broke here");
  });
  it("empty stderr stays empty (caller substitutes 'exited N')", () => {
    expect(reviewerErrorSummary("  \n")).toBe("");
  });
});

describe("withReviewerActivityTail (ephemeral codex timeouts had no trace, 2026-10-24)", () => {
  it("keeps the stop reason and appends the last stderr activity without the banner", () => {
    const stderr = "OpenAI Codex v0.154.0\n--------\nworkdir: /x\nexec npx vitest run\nwaiting on test/narrative-pack.test.ts\n";
    expect(withReviewerActivityTail("codex timed out after 3600000ms", stderr))
      .toBe("codex timed out after 3600000ms | last activity: exec npx vitest run\nwaiting on test/narrative-pack.test.ts");
  });
  it("bounds the tail and leaves a bare message when stderr is empty", () => {
    expect(withReviewerActivityTail("codex timed out after 1ms", "")).toBe("codex timed out after 1ms");
    expect(withReviewerActivityTail("t", "x".repeat(5000), 100).length).toBeLessThanOrEqual("t | last activity: ".length + 100);
    expect(withReviewerActivityTail("t", `old\n${"y".repeat(200)}\nnewest step`, 50)).toMatch(/newest step$/);
  });
});
