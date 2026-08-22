import g2 from "../../contracts/fixtures/g2.v1.json";

/**
 * Reader for the integration-owned, immutable versioned fixtures.
 *
 * The files belong to integration and are read here, never written.
 *
 * The fixtures are the shared truth for what iOS and the spectator decode, so
 * they are parsed from `unknown` here rather than cast: a fixture whose shape
 * drifted from what the backend asserts against must fail loudly instead of
 * silently typing itself into agreement.
 */
export interface FixtureCase {
  readonly id: string;
  readonly wireName: string;
  readonly payload: Record<string, unknown>;
}

export interface ContractFixtures {
  readonly contractVersion: string;
  readonly enums: Readonly<Record<string, readonly string[]>>;
  readonly snapshots: readonly FixtureCase[];
  readonly mutationResults: readonly FixtureCase[];
  readonly connectionScenarios: readonly FixtureCase[];
  readonly errors: readonly FixtureCase[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireRecord(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new Error(`fixture ${path} is not an object`);
  }

  return value;
}

function requireString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`fixture ${path} is not a string`);
  }

  return value;
}

function requireArray(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`fixture ${path} is not an array`);
  }

  return value;
}

function parseCases(value: unknown, path: string): FixtureCase[] {
  return requireArray(value, path).map((entry, index) => {
    const record = requireRecord(entry, `${path}[${index}]`);
    return {
      id: requireString(record.id, `${path}[${index}].id`),
      wireName: requireString(record.wireName, `${path}[${index}].wireName`),
      payload: requireRecord(record.payload, `${path}[${index}].payload`),
    };
  });
}

function parseEnums(value: unknown): Record<string, string[]> {
  const record = requireRecord(value, "enums");
  return Object.fromEntries(
    Object.entries(record).map(([name, cases]) => [
      name,
      requireArray(cases, `enums.${name}`).map((entry, index) =>
        requireString(entry, `enums.${name}[${index}]`),
      ),
    ]),
  );
}

function parseFixtures(raw: unknown, expectedVersion: string): ContractFixtures {
  const record = requireRecord(raw, expectedVersion);
  const contractVersion = requireString(record.contractVersion, "contractVersion");
  if (contractVersion !== expectedVersion) {
    throw new Error(`expected fixture contract ${expectedVersion}, found ${contractVersion}`);
  }

  return {
    contractVersion,
    enums: parseEnums(record.enums),
    snapshots: parseCases(record.snapshots, "snapshots"),
    mutationResults: parseCases(record.mutationResults, "mutationResults"),
    connectionScenarios: parseCases(record.connectionScenarios, "connectionScenarios"),
    errors: parseCases(record.errors, "errors"),
  };
}

export function loadG2Fixtures(): ContractFixtures {
  // Parsed as unknown data: the fixture is the contract, so its shape is
  // validated rather than trusted from a JSON module's inferred type.
  return parseFixtures(g2, "g2.v1");
}

export function fixtureCase(cases: readonly FixtureCase[], id: string): FixtureCase {
  const found = cases.find((entry) => entry.id === id);
  if (found === undefined) {
    throw new Error(`fixture case ${id} is missing`);
  }

  return found;
}

/** Ordered scenario steps, parsed from unknown so a drifted fixture fails loudly. */
export function scenarioSteps(fixture: FixtureCase): Record<string, unknown>[] {
  return requireArray(fixture.payload.steps, `${fixture.id}.steps`).map((entry, index) =>
    requireRecord(entry, `${fixture.id}.steps[${index}]`),
  );
}

/** Fixture ids of every case for one wire name, so no case is silently skipped. */
export function caseIds(cases: readonly FixtureCase[], wireName: string): string[] {
  return cases.filter((entry) => entry.wireName === wireName).map((entry) => entry.id);
}
