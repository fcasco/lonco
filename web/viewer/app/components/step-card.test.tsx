import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { StepContent } from "~/components/step-card";
import type { NormalizedStep } from "~/lib/types";

globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as unknown as typeof ResizeObserver;

describe("step card", () => {
  it("renders a message's body and parties", () => {
    const step: NormalizedStep = {
      step_id: "m2",
      ts: "2026-09-03T12:00:01Z",
      type: "message",
      source: "chat",
      preview: "done",
      raw: {
        from: "audel",
        to: "nick",
        content: "done",
      },
      run_id: null,
    };

    render(<StepContent step={step} expandAll />);

    expect(screen.getByText("done")).toBeTruthy();
    expect(screen.getByText(/audel/)).toBeTruthy();
    expect(screen.getByText(/nick/)).toBeTruthy();
  });
});