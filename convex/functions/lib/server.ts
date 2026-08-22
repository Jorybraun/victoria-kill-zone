import {
  type DataModelFromSchemaDefinition,
  type DocumentByName,
  type GenericMutationCtx,
  type GenericQueryCtx,
  type MutationBuilder,
  type QueryBuilder,
  type TableNamesInDataModel,
  mutationGeneric,
  queryGeneric,
} from "convex/server";
import type { GenericId } from "convex/values";
import type schema from "../schema.js";

/**
 * Schema-typed function builders.
 *
 * `convex/_generated` is produced by the Convex CLI against a deployment, so it
 * is not committed. Deriving the data model from the committed schema keeps the
 * backend fully typed, linted, and testable without a deployment or network.
 */
export type DataModel = DataModelFromSchemaDefinition<typeof schema>;
export type TableName = TableNamesInDataModel<DataModel>;
export type Doc<Table extends TableName> = DocumentByName<DataModel, Table>;
export type Id<Table extends TableName> = GenericId<Table>;
export type MutationCtx = GenericMutationCtx<DataModel>;
export type QueryCtx = GenericQueryCtx<DataModel>;

export const mutation: MutationBuilder<DataModel, "public"> = mutationGeneric;
export const query: QueryBuilder<DataModel, "public"> = queryGeneric;
