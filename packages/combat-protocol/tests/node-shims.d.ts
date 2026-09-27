declare module "node:crypto" {
  export function createHash(algorithm: string): {update(data: string): {digest(encoding: "hex"): string}};
}
