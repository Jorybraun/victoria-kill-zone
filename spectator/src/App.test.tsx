import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import { App } from "./App";

describe("App route and demo integration", () => {
  it("starts with no selected duel", () => {
    render(<App />);
    expect(screen.getByText("VICTORIA PEW PEW")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: "NO DUEL SELECTED" }),
    ).toBeInTheDocument();
  });

  it("opens the deterministic G2 active fixture from the duel route", async () => {
    window.history.replaceState({}, "", "/?match=VKZ001&demo=active");
    render(<App />);

    expect(await screen.findByTestId("match-code")).toHaveTextContent("VKZ001");
    expect(screen.getByText("DEMO FIXTURE")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "LIVE DUEL" })).toBeInTheDocument();
    expect(screen.queryByText(/radar|kills|deaths|winner/i)).not.toBeInTheDocument();
  });

  it("keeps duel selection in the shareable URL", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.type(screen.getByLabelText("6-CHARACTER DUEL CODE"), "vkz001");
    await user.click(screen.getByRole("button", { name: "WATCH DUEL" }));

    expect(await screen.findByTestId("match-code")).toHaveTextContent("VKZ001");
    expect(new URL(window.location.href).searchParams.get("match")).toBe("VKZ001");
  });

  it("maps initial feed failures to frozen safe copy", async () => {
    window.history.replaceState({}, "", "/?match=ERR001&demo=error");
    render(<App />);

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "CAN’T REACH THE DUEL",
    );
    expect(screen.queryByText(/deterministic feed is unavailable/i)).not.toBeInTheDocument();
  });

  it("retains the live fixture when its feed becomes degraded", async () => {
    window.history.replaceState({}, "", "/?match=STALE1&demo=degraded");
    render(<App />);

    expect(await screen.findByText("LIVE FEED INTERRUPTED")).toBeInTheDocument();
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 66 of 100" }),
    ).toHaveValue(66);
  });
});
