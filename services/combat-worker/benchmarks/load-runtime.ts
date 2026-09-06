import type {CombatSnapshot, CombatTicketClaims} from "@vkz/combat-protocol";
import type {LoadSocket} from "./load-client.js";
import type {RuntimeProfile} from "./runtime-profile.js";

export type DurableLoadState = {
  epoch: number;
  sequence: number;
  snapshot: CombatSnapshot;
  ledger: {sequence: number; payload: string}[];
  bullets: number;
  unresolved: number;
  commands: number;
  projectionRows: number;
  projectionProgress: {queued_sequence: number; delivered_sequence: number};
  checkpointBytes: number;
  databaseBytes: number | null;
};

export interface LoadRuntime {
  environment: "workerd-test-client" | "node-client-workerd-authority";
  clockMode: "receiveAnchor" | "native";
  upgrade(ticket: CombatTicketClaims): Promise<{status: number; webSocket: LoadSocket | null}>;
  readDurable(matchId: string): Promise<DurableLoadState>;
  installProfile?(matchId: string): Promise<RuntimeProfile>;
}
