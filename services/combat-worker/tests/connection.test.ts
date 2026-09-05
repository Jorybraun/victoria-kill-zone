import { describe, expect, it } from "vitest";
import { Connection } from "../src/connection.js";

function connection(): { sender: Connection; receiver: WebSocket } {
  const pair = new WebSocketPair();
  pair[0].accept(); pair[1].accept();
  return { sender: new Connection(pair[1], "host", 0, 0), receiver: pair[0] };
}

describe("cumulative socket receipt accounting", () => {
  it("retains later unacknowledged bytes after a partial receipt", () => {
    const { sender, receiver } = connection();
    expect(sender.sendSerialized("x".repeat(100 * 1024), 1)).toBe(true);
    expect(sender.sendSerialized("x".repeat(100 * 1024), 2)).toBe(true);
    expect(sender.acknowledge(1)).toBe(true);
    expect(sender.sendSerialized("x".repeat(100 * 1024), 3)).toBe(true);
    expect(sender.sendSerialized("x".repeat(70 * 1024), 4)).toBe(false);
    receiver.close();
  });

  it("releases repeated same-cursor snapshots without requiring a gameplay event", () => {
    const { sender, receiver } = connection();
    for (let index = 0; index < 10; index += 1) {
      expect(sender.sendSerialized("x".repeat(100 * 1024), 0)).toBe(true);
      expect(sender.acknowledge(0)).toBe(true);
    }
    expect(sender.acknowledge(1)).toBe(false);
    sender.close(1000, "test-complete"); receiver.close();
  });
});
