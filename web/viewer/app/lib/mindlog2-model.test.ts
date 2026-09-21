import { describe, expect, it } from "vitest";

import { toCard } from "~/lib/mindlog2-model";
import type { NormalizedStep } from "~/lib/types";

function message(
  step_id: string,
  raw: Record<string, unknown>
): NormalizedStep {
  return {
    step_id,
    ts: "2026-09-03T12:00:00Z",
    type: "message",
    source: "chat",
    preview: String(raw.content ?? ""),
    raw,
    run_id: null,
  };
}

describe("mind log cards", () => {
  it("renders an inbound message card", () => {
    const card = toCard(
      message("m1", {
        from: "nick",
        to: "audel",
        content: "please check this",
      }),
      "audel"
    );
    expect(card).not.toBeNull();
    expect(card?.kind).toBe("inbound");
    expect(card?.label).toBe("Nick replied");
    expect(card?.body).toBe("please check this");
    expect(card?.step_id).toBe("m1");
  });

  it("renders an outbound message card", () => {
    const card = toCard(
      message("m2", {
        from: "audel",
        to: "nick",
        content: "done",
        reply_to: "m1",
      }),
      "audel"
    );
    expect(card?.kind).toBe("outbound");
    expect(card?.label).toBe("sent to Nick");
  });
});