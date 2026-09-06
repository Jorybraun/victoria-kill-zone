import {LIMITS, type AuthenticatedCommand, type CombatEvent, type CombatPlayerState, type CombatSnapshot, type PhonePose,
  type ProjectileState, type RefusalReason} from "@vkz/combat-protocol";
import {add, distance, dot, finiteVector, length, mul, phoneForward} from "./geometry.js";
import {bodyMovementValid, colliderPairs, phoneAt, phoneMovementValid} from "./history.js";
import {integrateFlight, resolveFlights, terminal, timeScaleAt, type FlightPath} from "./flight.js";
import {clone, parseCheckpoint, validateConfiguration, validObservation, validPhone, type SimulationCheckpoint, type SimulationConfiguration} from "./state.js";

export type {SimulationCheckpoint, SimulationConfiguration} from "./state.js";
export {parseCheckpoint} from "./state.js";

const changed = (player: CombatPlayerState): CombatEvent => ({kind: "playerChanged", player: clone(player)});
const ordered = (a: AuthenticatedCommand, b: AuthenticatedCommand): number => a.sentAtMs - b.sentAtMs || a.playerId.localeCompare(b.playerId)
  || a.clientSequence - b.clientSequence || a.commandId.localeCompare(b.commandId);

/** One deterministic authority; the host adapter authenticates, deduplicates and
 * durably commits a fork before acknowledging or broadcasting its events.
 */
export class CombatSimulation {
  private recoveryEvents: CombatEvent[] = [];
  private constructor(private state: SimulationCheckpoint) {}

  static create(configuration: SimulationConfiguration): CombatSimulation {
    validateConfiguration(configuration);
    const config = clone(configuration);
    const snapshot: CombatSnapshot = {matchId: config.matchId, authorityEpoch: config.authorityEpoch, frameEpoch: config.frameEpoch,
      tick: 0, matchTimeMs: 0, roundStartedAtMs: null, phase: "calibrating", rules: config.rules, projectiles: [], slowFields: [], phonePoses: [],
      players: [...config.players].sort((a, b) => a.playerId.localeCompare(b.playerId)).map(p => ({...p,
        health: 100, ammo: config.rules.weapon.magazine, kills: 0, deaths: 0, connected: false, frameReady: false,
        lastFireAtMs: null, reloadEndsAtMs: null, respawnAtMs: null, protectedUntilMs: null,
        shield: {activeUntilMs: null, cooldownUntilMs: 0, energy: config.rules.shield.energy}, slowFieldReadyAtMs: 0}))};
    return new CombatSimulation({version: 1, snapshot, startedAtMs: null, phones: [], bodies: []});
  }
  static restore(checkpoint: unknown, epochs: {authorityEpoch: number; frameEpoch: number}): CombatSimulation {
    const state = parseCheckpoint(checkpoint);
    if (!Number.isSafeInteger(epochs.authorityEpoch) || epochs.authorityEpoch <= state.snapshot.authorityEpoch
      || !Number.isSafeInteger(epochs.frameEpoch) || epochs.frameEpoch < state.snapshot.frameEpoch) throw new Error("Recovery requires a new authority epoch and a nondecreasing frame epoch");
    const simulation = new CombatSimulation(state);
    state.snapshot.authorityEpoch = epochs.authorityEpoch; state.snapshot.frameEpoch = epochs.frameEpoch;
    simulation.cancelFlight(simulation.recoveryEvents);
    simulation.expireAbilities(simulation.recoveryEvents);
    state.phones = []; state.bodies = []; state.snapshot.phonePoses = [];
    for (const player of state.snapshot.players) {
      player.connected = false; player.frameReady = false;
      simulation.recoveryEvents.push(changed(player));
    }
    if (state.snapshot.phase !== "finished") simulation.setPhase("paused", "authorityRecovered", simulation.recoveryEvents);
    return simulation;
  }
  fork(): CombatSimulation {
    // Stored samples are immutable after admission. Share those values while
    // copying history containers; accepting a sample replaces its array.
    return new CombatSimulation({...this.state, snapshot: clone(this.state.snapshot),
      phones: this.state.phones.map(h => ({...h, samples: [...h.samples]})),
      bodies: this.state.bodies.map(h => ({...h, samples: [...h.samples]}))});
  }
  snapshot(): CombatSnapshot { return clone(this.state.snapshot); }
  checkpoint(options: {includeTracking?: boolean} = {}): SimulationCheckpoint {
    if (options.includeTracking === false) return clone({...this.state,
      snapshot: {...this.state.snapshot, phonePoses: []}, phones: [], bodies: []});
    return clone(this.state);
  }
  takeRecoveryEvents(): CombatEvent[] { const events = this.recoveryEvents; this.recoveryEvents = []; return clone(events); }

  setConnected(playerId: string, connected: boolean): CombatEvent[] {
    const player = this.player(playerId);
    if (!player) throw new Error("Unknown roster member");
    if (player.connected === connected) return [];
    player.connected = connected;
    const events: CombatEvent[] = [];
    if (!connected) { player.frameReady = false; this.clearHistory(playerId); }
    events.push(changed(player));
    if (!connected && this.state.snapshot.phase === "running") this.pause("playerDisconnected", events);
    return events;
  }

  advance(commands: readonly AuthenticatedCommand[]): CombatEvent[] {
    if (commands.length > LIMITS.commandsPerTick) throw new Error("Command tick limit exceeded");
    const batch = clone([...commands]).sort(ordered), events: CombatEvent[] = [];
    const previousMs = this.now;
    this.state.snapshot.tick++; this.state.snapshot.matchTimeMs = this.state.snapshot.tick * LIMITS.tickMs;
    const controls: AuthenticatedCommand[] = [];
    // Current samples are available before sweeping the just-finished interval.
    for (const envelope of batch) {
      const invalid = this.envelopeRefusal(envelope);
      if (invalid) { this.result(envelope, invalid, events); continue; }
      if (envelope.command.kind === "pose") this.result(envelope, this.acceptPose(envelope, events), events);
      else if (envelope.command.kind === "frameReady") this.result(envelope, this.acceptFrame(envelope, events), events);
      else controls.push(envelope);
    }
    const running = this.state.snapshot.phase === "running";
    if (running && !this.coverage(previousMs, this.now, this.state.snapshot.projectiles.length > 0)) this.pause("spatialCoverageLost", events);
    if (this.state.snapshot.phase === "paused" && this.state.startedAtMs !== null && this.coverage(this.now, this.now)) this.setPhase("running", "spatialCoverageRestored", events);
    // No advancement through unobserved paused intervals or new-shot retroactive flight.
    if (running && this.state.snapshot.phase === "running" && this.state.snapshot.projectiles.length) {
      const end = Math.min(this.now, this.state.startedAtMs! + this.state.snapshot.rules.durationMs);
      if (end > previousMs) {
        const paths = this.state.snapshot.projectiles.map(p => integrateFlight(this.state, p, previousMs, end));
        const resolved = resolveFlights(this.state, paths);
        this.state.snapshot.projectiles = resolved.survivors; events.push(...resolved.events);
      }
    }
    this.settleTimers(events);
    if (this.state.snapshot.phase === "running" && !this.coverage(this.now, this.now)) this.pause("spatialCoverageLost", events);
    if (this.state.startedAtMs !== null && this.now >= this.state.startedAtMs + this.state.snapshot.rules.durationMs && this.state.snapshot.phase !== "finished") {
      this.cancelFlight(events); this.expireAbilities(events); this.setPhase("finished", "durationElapsed", events);
    }
    for (const envelope of controls) this.result(envelope, this.control(envelope, events), events);
    return events;
  }

  private get now(): number { return this.state.snapshot.matchTimeMs; }
  private player(id: string): CombatPlayerState | undefined { return this.state.snapshot.players.find(p => p.playerId === id); }
  private setPhase(phase: CombatSnapshot["phase"], reason: string, events: CombatEvent[]): void {
    if (this.state.snapshot.phase !== phase) { this.state.snapshot.phase = phase; events.push({kind: "phaseChanged", phase, reason}); }
  }
  private clearHistory(playerId: string): void {
    this.state.phones = this.state.phones.filter(h => h.playerId !== playerId);
    this.state.snapshot.phonePoses = this.state.snapshot.phonePoses.filter(p => p.playerId !== playerId);
    this.state.bodies = this.state.bodies.filter(h => h.observerId !== playerId && h.targetId !== playerId);
  }
  private cancelFlight(events: CombatEvent[]): void {
    events.push(...this.state.snapshot.projectiles.map(p => terminal(p, "cancelled", this.now, p.position)));
    this.state.snapshot.projectiles = [];
  }
  private expireAbilities(events: CombatEvent[]): void {
    for (const field of this.state.snapshot.slowFields) events.push({kind: "slowFieldChanged", field: {...clone(field), endsAtMs: this.now}});
    this.state.snapshot.slowFields = [];
    for (const p of this.state.snapshot.players) if (p.shield.activeUntilMs !== null) { p.shield.activeUntilMs = null; events.push(changed(p)); }
  }
  private pause(reason: string, events: CombatEvent[]): void {
    this.cancelFlight(events); this.expireAbilities(events); this.setPhase("paused", reason, events);
  }
  private coverage(fromMs: number, toMs: number, interval = false): boolean {
    return this.state.snapshot.players.every(p => p.connected && p.frameReady && (p.health <= 0 || (
      phoneAt(this.state, p.playerId, toMs) !== null && colliderPairs(this.state, p.playerId, interval ? fromMs : toMs, toMs) !== null)));
  }
  private envelopeRefusal(e: AuthenticatedCommand): RefusalReason | null {
    if (!this.player(e.playerId)) return "unknownPlayer";
    if (e.v !== 1 || e.authorityEpoch !== this.state.snapshot.authorityEpoch || e.frameEpoch !== this.state.snapshot.frameEpoch
      || !Number.isSafeInteger(e.clientSequence) || e.clientSequence < 0 || typeof e.commandId !== "string" || !e.commandId.length || e.commandId.length > 128
      || !Number.isFinite(e.sentAtMs) || e.sentAtMs < 0) return "invalidInput";
    if (e.sentAtMs > this.now) return "futureInput";
    if (this.now - e.sentAtMs > LIMITS.rewindMs) return "tooLate";
    if (!this.player(e.playerId)!.connected && e.command.kind !== "leave") return "notReady";
    return null;
  }
  private result(e: AuthenticatedCommand, reason: RefusalReason | null, events: CombatEvent[]): void {
    if (reason && e.command.kind === "fire") events.push({kind: "fireRefused", commandId: e.commandId, shotId: e.command.shotId, playerId: e.playerId, reason});
    events.push({kind: "commandResult", commandId: e.commandId, clientSequence: e.clientSequence, playerId: e.playerId, accepted: reason === null, reason});
  }
  private acceptPose(e: AuthenticatedCommand, events: CombatEvent[]): RefusalReason | null {
    if (e.command.kind !== "pose") return "invalidInput";
    const {pose, observations} = e.command;
    if (!validPhone(pose) || !Array.isArray(observations) || observations.length > 3 || !observations.every(validObservation)) return "invalidInput";
    if (pose.capturedAtMs > this.now || observations.some(o => o.capturedAtMs > this.now)) return "futureInput";
    if (this.now - pose.capturedAtMs > LIMITS.poseAgeMs || observations.some(o => this.now - o.capturedAtMs > LIMITS.poseAgeMs)) return "poseStale";
    const quaternionLength = Math.sqrt(pose.orientation.reduce((n, v) => n + v * v, 0));
    pose.orientation = [pose.orientation[0] / quaternionLength, pose.orientation[1] / quaternionLength, pose.orientation[2] / quaternionLength, pose.orientation[3] / quaternionLength];
    const history = this.state.phones.find(h => h.playerId === e.playerId);
    if (!phoneMovementValid(history?.samples.at(-1), pose)) return "poseMismatch";
    if (new Set(observations.map(o => o.targetPlayerId)).size !== observations.length
      || observations.some(o => o.targetPlayerId === e.playerId || !this.player(o.targetPlayerId))) return "invalidInput";
    // Whole-packet validation avoids a rejected command partially mutating poses.
    for (const observation of observations) {
      const h = this.state.bodies.find(b => b.observerId === e.playerId && b.targetId === observation.targetPlayerId);
      const previous = h?.samples.at(-1);
      if (previous?.capturedAtMs === observation.capturedAtMs && JSON.stringify(previous) === JSON.stringify(observation)) continue;
      if (!bodyMovementValid(previous, observation)) return "poseMismatch";
    }
    if (history) history.samples = [...history.samples, clone(pose)].slice(-16);
    else this.state.phones.push({playerId: e.playerId, samples: [clone(pose)]});
    this.state.snapshot.phonePoses = [...this.state.snapshot.phonePoses.filter(p => p.playerId !== e.playerId), {playerId: e.playerId, pose: clone(pose)}]
      .sort((a, b) => a.playerId.localeCompare(b.playerId));
    events.push({kind: "poseChanged", playerId: e.playerId, pose: clone(pose)});
    for (const observation of observations) {
      const h = this.state.bodies.find(b => b.observerId === e.playerId && b.targetId === observation.targetPlayerId);
      if (observation.associationConfidence < 0.8 || observation.uncertaintyMeters > 0.1 || pose.tracking !== "normal") {
        this.state.bodies = this.state.bodies.filter(b => b !== h); continue;
      }
      if (h?.samples.at(-1)?.capturedAtMs === observation.capturedAtMs) continue;
      if (h) h.samples = [...h.samples, clone(observation)].slice(-16);
      else this.state.bodies.push({observerId: e.playerId, targetId: observation.targetPlayerId, samples: [clone(observation)]});
    }
    return null;
  }
  private acceptFrame(e: AuthenticatedCommand, events: CombatEvent[]): RefusalReason | null {
    const command = e.command;
    if (command.kind !== "frameReady") return "invalidInput";
    if (![command.residualMeters, command.residualDegrees, command.clockUncertaintyMs].every(n => Number.isFinite(n) && n >= 0)
      || typeof command.ready !== "boolean") return "invalidInput";
    const p = this.player(e.playerId)!;
    const ready = command.ready && command.residualMeters <= 0.1 && command.residualDegrees <= 0.5 && command.clockUncertaintyMs <= LIMITS.clockUncertaintyMs;
    if (!ready) this.clearHistory(e.playerId);
    p.frameReady = ready; events.push(changed(p));
    return command.ready && !ready ? "notReady" : null;
  }
  private actionRefusal(player: CombatPlayerState): RefusalReason | null {
    if (this.state.snapshot.phase !== "running") return "notRunning";
    if (!player.connected || !player.frameReady) return "notReady";
    if (player.health <= 0) return "notAlive";
    if (player.protectedUntilMs !== null && player.protectedUntilMs > this.now) return "protected";
    if (!phoneAt(this.state, player.playerId, this.now)) return "trackingLost";
    return null;
  }
  private firingPose(playerId: string, sequence: number): PhonePose | RefusalReason {
    const pose = this.state.phones.find(h => h.playerId === playerId)?.samples.find(p => p.sequence === sequence);
    if (!pose) return "poseMismatch";
    if (this.now - pose.capturedAtMs > LIMITS.poseAgeMs) return "poseStale";
    if (pose.tracking !== "normal") return "trackingLost";
    return pose;
  }
  private control(e: AuthenticatedCommand, events: CombatEvent[]): RefusalReason | null {
    const p = this.player(e.playerId)!, command = e.command, rules = this.state.snapshot.rules;
    if (command.kind === "leave") { events.push(...this.setConnected(e.playerId, false)); return null; }
    if (command.kind === "start") {
      if (p.role !== "host") return "notHost";
      if (this.state.snapshot.phase === "finished") return "notRunning";
      if (!this.coverage(this.now, this.now)) return "notReady";
      if (this.state.startedAtMs === null) { this.state.startedAtMs = this.now; this.state.snapshot.roundStartedAtMs = this.now; }
      this.setPhase("running", "hostStarted", events); return null;
    }
    if (command.kind === "shield" && !command.active) {
      p.shield.activeUntilMs = null; events.push(changed(p)); return null;
    }
    const refusal = this.actionRefusal(p);
    if (refusal) return refusal;
    if (command.kind === "reload") {
      if (p.reloadEndsAtMs !== null) return "reloading";
      if (p.ammo === rules.weapon.magazine) return "invalidInput";
      if (p.shield.activeUntilMs !== null) return "shieldActive";
      p.reloadEndsAtMs = this.now + rules.weapon.reloadMs; events.push(changed(p)); return null;
    }
    if (command.kind !== "fire" && command.kind !== "shield" && command.kind !== "slowField") return "invalidInput";
    const pose = this.firingPose(p.playerId, command.poseSequence);
    if (typeof pose === "string") return pose;
    if (command.kind === "shield") {
      if (p.reloadEndsAtMs !== null) return "reloading";
      if (p.shield.activeUntilMs !== null || p.shield.cooldownUntilMs > this.now) return "abilityCooldown";
      p.shield = {energy: rules.shield.energy, activeUntilMs: this.now + rules.shield.durationMs, cooldownUntilMs: this.now + rules.shield.cooldownMs};
      events.push(changed(p)); return null;
    }
    if (command.kind === "slowField") {
      if (p.slowFieldReadyAtMs > this.now) return "abilityCooldown";
      const field = {fieldId: `f:${this.state.snapshot.authorityEpoch}:${this.state.snapshot.players.indexOf(p)}:${e.clientSequence}`, ownerId: p.playerId, center: pose.position, radius: rules.slowField.radius,
        startsAtMs: this.now, endsAtMs: this.now + rules.slowField.durationMs, scale: rules.slowField.scale};
      this.state.snapshot.slowFields = [...this.state.snapshot.slowFields, field];
      p.slowFieldReadyAtMs = this.now + rules.slowField.cooldownMs;
      events.push({kind: "slowFieldChanged", field: clone(field)}, changed(p)); return null;
    }
    if (!finiteVector(command.origin) || !finiteVector(command.direction) || Math.abs(length(command.direction) - 1) > 0.001
      || distance(command.origin, pose.position) > 0.5 || dot(command.direction, phoneForward(pose.orientation)) < Math.cos(Math.PI / 12)) return "invalidRay";
    if (typeof command.shotId !== "string" || !command.shotId.length || command.shotId.length > 128) return "invalidInput";
    if (p.shield.activeUntilMs !== null) return "shieldActive";
    if (p.reloadEndsAtMs !== null) return "reloading";
    if (p.ammo <= 0) return "outOfAmmo";
    if (p.lastFireAtMs !== null && this.now - p.lastFireAtMs < rules.weapon.cooldownMs) return "cooldown";
    if (this.state.snapshot.projectiles.length >= LIMITS.projectiles) return "projectileLimit";
    const projectileId = `p:${this.state.snapshot.authorityEpoch}:${this.state.snapshot.players.indexOf(p)}:${e.clientSequence}`;
    if (this.state.snapshot.projectiles.some(projectile => projectile.shooterId === p.playerId && projectile.shotId === command.shotId)) return "invalidInput";
    if (rules.weapon.kind === "hitscan" && !this.coverage(e.sentAtMs, e.sentAtMs)) return "poseStale";
    p.ammo--; p.lastFireAtMs = this.now;
    const projectile: ProjectileState = {projectileId, shotId: command.shotId, shooterId: p.playerId, spawnedAtMs: this.now, position: command.origin,
      direction: command.direction, speed: rules.weapon.speed, segmentStartedAtMs: this.now, segmentOrigin: command.origin,
      timeScale: rules.weapon.kind === "hitscan" ? 1 : timeScaleAt(this.state, command.origin, command.direction, this.now), radius: rules.weapon.projectileRadius,
      expiresAtMs: this.now + rules.weapon.lifetimeMs, distanceTravelled: 0};
    events.push({kind: "projectileSpawn", projectile: clone(projectile)}, changed(p));
    if (rules.weapon.kind === "projectile") this.state.snapshot.projectiles = [...this.state.snapshot.projectiles, projectile];
    else {
      const end = add(command.origin, mul(command.direction, rules.weapon.rangeMeters));
      const path: FlightPath = {projectile: {...projectile, position: end, distanceTravelled: rules.weapon.rangeMeters}, changes: [], expires: true, endTimeMs: this.now,
        segments: [{fromMs: this.now, toMs: this.now, geometryFromMs: e.sentAtMs, geometryToMs: e.sentAtMs, start: command.origin, end, scale: 1}]};
      events.push(...resolveFlights(this.state, [path]).events);
    }
    return null;
  }
  private settleTimers(events: CombatEvent[]): void {
    for (const p of this.state.snapshot.players) {
      let dirty = false;
      if (p.health <= 0 && p.respawnAtMs !== null && p.respawnAtMs <= this.now && this.state.snapshot.phase !== "finished") {
        p.health = 100; p.ammo = this.state.snapshot.rules.weapon.magazine; p.respawnAtMs = null;
        p.protectedUntilMs = this.now + this.state.snapshot.rules.protectionMs; p.lastFireAtMs = null; dirty = true;
      }
      if (p.reloadEndsAtMs !== null && p.reloadEndsAtMs <= this.now) { if (p.health > 0) p.ammo = this.state.snapshot.rules.weapon.magazine; p.reloadEndsAtMs = null; dirty = true; }
      if (p.protectedUntilMs !== null && p.protectedUntilMs <= this.now) { p.protectedUntilMs = null; dirty = true; }
      if (p.shield.activeUntilMs !== null && p.shield.activeUntilMs <= this.now) { p.shield.activeUntilMs = null; dirty = true; }
      if (p.shield.cooldownUntilMs <= this.now && p.shield.energy < this.state.snapshot.rules.shield.energy) { p.shield.energy = this.state.snapshot.rules.shield.energy; dirty = true; }
      if (dirty) events.push(changed(p));
    }
    for (const field of this.state.snapshot.slowFields) if (field.endsAtMs <= this.now) events.push({kind: "slowFieldChanged", field: clone(field)});
    this.state.snapshot.slowFields = this.state.snapshot.slowFields.filter(f => f.endsAtMs > this.now);
  }
}
