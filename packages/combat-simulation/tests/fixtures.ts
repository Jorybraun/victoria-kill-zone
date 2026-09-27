import {DEFAULT_RULES, type AuthenticatedCommand, type BodyCollider, type CombatCommand, type CombatEvent, type CombatRules, type Quaternion, type Vec3} from "@vkz/combat-protocol";
import {CombatSimulation} from "../src/index.js";

export const RIGHT: Quaternion = [0, -Math.SQRT1_2, 0, Math.SQRT1_2];
export const LEFT: Quaternion = [0, Math.SQRT1_2, 0, Math.SQRT1_2];
export const sphere = (center: Vec3, radius = 0.1): BodyCollider => ({id: "torso", kind: "sphere", zone: "torso", center, radius});
export function rules(overrides: Partial<CombatRules> = {}): CombatRules { return {...structuredClone(DEFAULT_RULES), ...overrides}; }
export class Fixture {
  simulation: CombatSimulation;
  ids: string[];
  phone: Record<string, Vec3> = {};
  body: Record<string, BodyCollider[]> = {};
  orientation: Record<string, Quaternion> = {};
  private sequence = 0;
  constructor(public config = rules(), count = 2) {
    this.ids = ["a", "b", "c", "d"].slice(0, count);
    for (const [i, id] of this.ids.entries()) {
      this.phone[id] = [i * 3, 0, 0]; this.body[id] = [sphere(this.phone[id]!)]; this.orientation[id] = RIGHT;
    }
    this.simulation = CombatSimulation.create({matchId: "fixture", authorityEpoch: 1, frameEpoch: 1, rules: config,
      players: this.ids.map((playerId, i) => ({playerId, displayName: playerId, role: i === 0 ? "host" : "player"}))});
    this.ids.forEach(id => this.simulation.setConnected(id, true));
  }
  envelope(playerId: string, command: CombatCommand, sentAtMs = this.now + 50): AuthenticatedCommand {
    const clientSequence = ++this.sequence;
    return {v: 1, commandId: `command-${clientSequence}`, playerId, clientSequence, authorityEpoch: 1, frameEpoch: 1, sentAtMs, command};
  }
  get now(): number { return this.simulation.snapshot().matchTimeMs; }
  poseCommands(): AuthenticatedCommand[] {
    const at = this.now + 50;
    return this.ids.map(id => this.envelope(id, {kind: "pose", pose: {sequence: at / 50, capturedAtMs: at,
      position: this.phone[id]!, orientation: this.orientation[id]!, tracking: "normal"}, observations: []}));
  }
  tick(extra: AuthenticatedCommand[] = []): CombatEvent[] { return this.simulation.advance([...this.poseCommands(), ...extra]); }
  /** Sighting needs no shared frame: one tick for coverage, then the host starts. */
  ready(): this {
    this.tick();
    this.tick([this.envelope("a", {kind: "start"})]);
    if (this.simulation.snapshot().phase !== "running") throw new Error("Fixture did not start");
    return this;
  }
  /** Default sighting verdict targets the single opponent's fixture body. */
  fire(id = "a", shotId = `shot-${this.now}`, sentAtMs = this.now + 50, withObservation = true): AuthenticatedCommand {
    const target = this.ids.find(other => other !== id)!;
    const observation = withObservation ? {targetPlayerId: target, capturedAtMs: this.now,
      associationConfidence: 1, uncertaintyMeters: 0.01, colliders: this.body[target]!} : undefined;
    return this.envelope(id, {kind: "fire", shotId, poseSequence: (this.now + 50) / 50, origin: this.phone[id]!, direction: [1, 0, 0],
      ...(observation === undefined ? {} : {observation})}, sentAtMs);
  }
  ability(kind: "shield" | "slowField", id = "b"): AuthenticatedCommand {
    return this.envelope(id, kind === "shield" ? {kind, active: true, poseSequence: (this.now + 50) / 50}
      : {kind, poseSequence: (this.now + 50) / 50});
  }
  player(id = "b") { return this.simulation.snapshot().players.find(p => p.playerId === id)!; }
}
