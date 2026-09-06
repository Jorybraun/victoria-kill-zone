import { randomBytes } from "@noble/hashes/utils.js";
import type { RegisteredMutation, RegisteredQuery } from "convex/server";
import { hashSecret, sessionSecretFromBytes } from "../domain/session.js";
import type { Doc, Id, MutationCtx, QueryCtx, TableName } from "../functions/lib/server.js";
import { match, player, T0 } from "./factories.js";

type Row = Record<string, unknown>;
interface IndexBuilder {
  eq: (field: string, value: unknown) => IndexBuilder;
}

/** Convex exposes this runtime seam but strips it from its public declarations. */
export function mutationHandler<
  Visibility extends "public" | "internal",
  Args extends Row,
  Result,
>(definition: RegisteredMutation<Visibility, Args, Result>): (ctx: MutationCtx, args: Args) => Result {
  return (definition as unknown as { _handler: (ctx: MutationCtx, args: Args) => Result })._handler;
}

export function queryHandler<
  Visibility extends "public" | "internal",
  Args extends Row,
  Result,
>(definition: RegisteredQuery<Visibility, Args, Result>): (ctx: QueryCtx, args: Args) => Result {
  return (definition as unknown as { _handler: (ctx: QueryCtx, args: Args) => Result })._handler;
}

/**
 * Small adapter harness: invokes registered production handlers and records the
 * exact reads/writes/jobs. It does not model Convex's transaction scheduler or
 * claim to prove concurrent isolation on a deployed backend.
 */
export function mutationContext() {
  const rows = new Map<string, { table: TableName; doc: Row }>();
  const reads: string[] = [];
  const indexes: { table: TableName; name: string }[] = [];
  const writes: { kind: "insert" | "patch"; table: TableName; doc: Row }[] = [];
  const jobs: { when: number; args: Row }[] = [];
  let nextId = 0;

  const ctx = {
    db: {
      get: (id: string) => {
        reads.push(id);
        const doc = rows.get(id)?.doc;
        return Promise.resolve(doc === undefined ? null : { ...doc });
      },
      patch: (id: string, fields: Row) => {
        const row = rows.get(id);
        if (row === undefined) throw new Error("Missing test row");
        row.doc = { ...row.doc, ...fields };
        writes.push({ kind: "patch", table: row.table, doc: fields });
        return Promise.resolve();
      },
      insert: (table: TableName, fields: Row) => {
        const id = `${table}-${++nextId}`;
        rows.set(id, { table, doc: { _id: id, _creationTime: T0, ...fields } });
        writes.push({ kind: "insert", table, doc: fields });
        return Promise.resolve(id);
      },
      query: (table: TableName) => ({
        withIndex: (name: string, configure: (builder: { eq: (field: string, value: unknown) => unknown }) => unknown) => {
          indexes.push({ table, name });
          const filters: [string, unknown][] = [];
          const builder: IndexBuilder = {
            eq: (field: string, value: unknown): IndexBuilder => {
              filters.push([field, value]);
              return builder;
            },
          };
          configure(builder);
          const selected = () => [...rows.values()]
            .filter((row) => row.table === table && filters.every(([field, value]) => row.doc[field] === value))
            .map((row) => ({ ...row.doc }));
          let direction: "asc" | "desc" = "asc";
          const query = {
            take: (limit: number) => Promise.resolve(selected()
              .sort((left, right) => (Number(left.createdAt) - Number(right.createdAt)) * (direction === "asc" ? 1 : -1))
              .slice(0, limit)),
            unique: () => {
              const result = selected();
              if (result.length > 1) throw new Error("Non-unique indexed query");
              return Promise.resolve(result[0] ?? null);
            },
            collect: () => Promise.resolve(selected()),
          };
          return {
            ...query,
            order: (order: "asc" | "desc") => {
              direction = order;
              return query;
            },
          };
        },
      }),
    },
    scheduler: {
      runAt: (when: number, reference: unknown, args: Row) => {
        void reference;
        jobs.push({ when, args });
        return Promise.resolve("scheduled-job");
      },
    },
  } as unknown as MutationCtx;

  return {
    ctx, reads, indexes, writes, jobs,
    seed: <Table extends TableName>(table: Table, doc: Doc<Table>) => {
      rows.set(doc._id, { table, doc });
    },
    readPlayer: (id: Id<"players">) => rows.get(id)?.doc as Doc<"players"> | undefined,
  };
}

export const testIds = {
  match: "match-primary" as Id<"matches">,
  otherMatch: "match-other" as Id<"matches">,
  host: "host" as Id<"players">,
  guest: "guest" as Id<"players">,
  third: "third" as Id<"players">,
};

export function storedMatch(overrides: Partial<Doc<"matches">> = {}): Doc<"matches"> {
  return {
    ...match(),
    _id: testIds.match,
    _creationTime: T0,
    hostPlayerId: testIds.host,
    winnerPlayerId: null,
    code: "ABCDEF",
    centerLatitude: 0,
    centerLongitude: 0,
    arenaCenterAt: null,
    maxPlayers: 2,
    startedAt: T0,
    createdAt: T0,
    updatedAt: T0,
    ...overrides,
  };
}

export function storedPlayer(id: Id<"players">, overrides: Partial<Doc<"players">> = {}) {
  // Capabilities are generated in memory for the test run, never fixture data.
  const sessionSecret = sessionSecretFromBytes(randomBytes(32));
  const state = player(id);
  const { id: stateId, ...fields } = state;
  void stateId;
  const doc: Doc<"players"> = {
    ...fields,
    _id: id,
    _creationTime: T0,
    matchId: testIds.match,
    sessionHash: hashSecret(sessionSecret),
    ...overrides,
  };
  return { doc, sessionSecret };
}
