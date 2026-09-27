import { describe, expect, it } from "vitest";
import { Connection } from "../src/connection.js";

function connection(): { sender: Connection; receiver: WebSocket } {
  const pair = new WebSocketPair();
  pair[0].accept(); pair[1].accept();
  return { sender: new Connection(pair[1], "host", 0, 0), receiver: pair[0] };
}

describe("cumulative socket receipt accounting", () => {
  it("accounts shared UTF-8 broadcasts independently for each recipient", () => {
    const fast = connection(), slow = connection();
    const data = "骨".repeat(40 * 1024);
    const message = {data, bytes: new TextEncoder().encode(data).byteLength};
    try {
      expect(message.bytes).toBe(120 * 1024);
      for (const client of [fast, slow]) {
        expect(client.sender.sendEncoded(message, 1)).toBe(true);
        expect(client.sender.sendEncoded(message, 2)).toBe(true);
      }
      expect(fast.sender.acknowledge(1)).toBe(true);
      expect(fast.sender.sendEncoded(message, 3)).toBe(true);
      expect(slow.sender.sendEncoded(message, 3)).toBe(false);
    } finally {
      for (const client of [fast, slow]) {client.sender.close(1000, "test-complete"); client.receiver.close();}
    }
  });

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

  it("budgets command admission independently from other players' receipt traffic", () => {
    const { sender, receiver } = connection();
    for (let second = 0; second < 5; second += 1) {
      for (let message = 0; message < 200; message += 1) {
        const now = second * 1000 + message * 5;
        expect(sender.admit(now, 240)).toBe(true);
        if (message % 5 === 0) expect(sender.admitCommand(now)).toBe(true);
      }
    }
    // A command or ping flood cannot borrow the receipt lane's allowance.
    for (let index = 0; index < 91; index += 1) sender.admitCommand(5000);
    expect(sender.admitCommand(5000)).toBe(false);
    for (let index = 0; index < 5; index += 1) expect(sender.admitPing(5000)).toBe(true);
    expect(sender.admitPing(5000)).toBe(false);
    sender.close(1000, "test-complete"); receiver.close();
  });
});
