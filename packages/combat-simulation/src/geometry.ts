import type {BodyCollider, Quaternion, Vec3} from "@vkz/combat-protocol";

export const EPSILON = 1e-8;
export const add = (a: Vec3, b: Vec3): Vec3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
export const sub = (a: Vec3, b: Vec3): Vec3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
export const mul = (a: Vec3, s: number): Vec3 => [a[0] * s, a[1] * s, a[2] * s];
export const dot = (a: Vec3, b: Vec3): number => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
export const length = (a: Vec3): number => Math.sqrt(dot(a, a));
export const distance = (a: Vec3, b: Vec3): number => length(sub(a, b));
export const lerp = (a: Vec3, b: Vec3, t: number): Vec3 => add(a, mul(sub(b, a), t));
export const finiteVector = (v: Vec3): boolean => v.length === 3 && v.every(Number.isFinite);
export function normalized(v: Vec3): Vec3 | null {
  const size = length(v);
  return finiteVector(v) && size > EPSILON ? mul(v, 1 / size) : null;
}

/** ARKit's rear camera looks down local -Z. Returned normal faces that side. */
export function phoneForward(q: Quaternion): Vec3 {
  const [x, y, z, w] = q;
  return [-2 * (x * z + w * y), -2 * (y * z - w * x), -(1 - 2 * (x * x + y * y))];
}

export function interpolateCollider(a: BodyCollider, b: BodyCollider, u: number): BodyCollider | null {
  if (a.id !== b.id || a.kind !== b.kind || a.zone !== b.zone) return null;
  const radius = a.radius + (b.radius - a.radius) * u;
  if (a.kind === "sphere" && b.kind === "sphere") return {...a, radius, center: lerp(a.center, b.center, u)};
  if (a.kind === "capsule" && b.kind === "capsule") return {...a, radius, a: lerp(a.a, b.a, u), b: lerp(a.b, b.b, u)};
  return null;
}

type Polynomial = readonly number[];
const evaluate = (p: Polynomial, x: number): number => {
  let value = 0;
  for (let i = p.length - 1; i >= 0; i--) value = value * x + p[i]!;
  return value;
};
function product(a: Polynomial, b: Polynomial): number[] {
  const result = Array<number>(a.length + b.length - 1).fill(0);
  for (let i = 0; i < a.length; i++) for (let j = 0; j < b.length; j++) result[i + j]! += a[i]! * b[j]!;
  return result;
}
function minus(a: Polynomial, b: Polynomial): number[] {
  return Array.from({length: Math.max(a.length, b.length)}, (_, i) => (a[i] ?? 0) - (b[i] ?? 0));
}
const linearDot = (a: Vec3, av: Vec3, b: Vec3, bv: Vec3): number[] => [dot(a, b), dot(a, bv) + dot(av, b), dot(av, bv)];

/** Isolate degree<=4 roots using derivative extrema, including tangent roots.
 * All collision intervals are normalized to [0,1] to bound numerical error.
 */
export function unitIntervalRoots(coefficients: Polynomial): number[] {
  const scale = Math.max(1, ...coefficients.map(Math.abs));
  const p = coefficients.map(x => x / scale);
  while (p.length > 1 && Math.abs(p[p.length - 1]!) < 1e-12) p.pop();
  if (p.length === 1) return Math.abs(p[0]!) < 1e-10 ? [0] : [];
  if (p.length === 2) {
    const root = -p[0]! / p[1]!;
    return root >= -EPSILON && root <= 1 + EPSILON ? [Math.max(0, Math.min(1, root))] : [];
  }
  const critical = unitIntervalRoots(p.slice(1).map((c, i) => c * (i + 1)));
  const points = [0, ...critical.filter(x => x > EPSILON && x < 1 - EPSILON), 1];
  const roots: number[] = [];
  for (const point of points) if (Math.abs(evaluate(p, point)) <= 1e-10) roots.push(point);
  for (let i = 1; i < points.length; i++) {
    let low = points[i - 1]!;
    let high = points[i]!;
    let a = evaluate(p, low);
    const b = evaluate(p, high);
    if (a * b >= 0) continue;
    for (let iteration = 0; iteration < 55; iteration++) {
      const middle = (low + high) / 2;
      const value = evaluate(p, middle);
      if (a * value <= 0) high = middle;
      else {low = middle; a = value;}
    }
    roots.push((low + high) / 2);
  }
  return roots.sort((a, b) => a - b).filter((x, i, all) => i === 0 || x - all[i - 1]! > EPSILON);
}

function movingSphere(start: Vec3, end: Vec3, a: Vec3, b: Vec3, r0: number, r1: number): number | null {
  const offset = sub(start, a);
  const velocity = sub(sub(end, start), sub(b, a));
  const dr = r1 - r0;
  const polynomial = [dot(offset, offset) - r0 * r0, 2 * dot(offset, velocity) - 2 * r0 * dr, dot(velocity, velocity) - dr * dr];
  if (polynomial[0]! <= EPSILON) return 0;
  return unitIntervalRoots(polynomial)[0] ?? null;
}

function pointSegmentDistanceSquared(point: Vec3, a: Vec3, b: Vec3): number {
  const segment = sub(b, a);
  const fraction = Math.max(0, Math.min(1, dot(sub(point, a), segment) / Math.max(EPSILON, dot(segment, segment))));
  const offset = sub(point, add(a, mul(segment, fraction)));
  return dot(offset, offset);
}

function broadPhase(start: Vec3, end: Vec3, a: BodyCollider, b: BodyCollider, radius: number): boolean {
  const points = a.kind === "sphere" && b.kind === "sphere" ? [a.center, b.center]
    : a.kind === "capsule" && b.kind === "capsule" ? [a.a, a.b, b.a, b.b] : [];
  for (let axis = 0; axis < 3; axis++) {
    const low = Math.min(...points.map(p => p[axis]!)) - radius;
    const high = Math.max(...points.map(p => p[axis]!)) + radius;
    if (Math.max(start[axis]!, end[axis]!) < low || Math.min(start[axis]!, end[axis]!) > high) return false;
  }
  return true;
}

/** Sweeps a finite-radius bullet against independently moving capsule endpoints.
 * Body positions and radii interpolate between two validated observations.
 */
export function sweepCollider(start: Vec3, end: Vec3, a: BodyCollider, b: BodyCollider, bulletRadius: number): number | null {
  if (a.id !== b.id || a.kind !== b.kind || a.zone !== b.zone) return null;
  const r0 = a.radius + bulletRadius;
  const r1 = b.radius + bulletRadius;
  if (!broadPhase(start, end, a, b, Math.max(r0, r1))) return null;
  if (a.kind === "sphere" && b.kind === "sphere") return movingSphere(start, end, a.center, b.center, r0, r1);
  if (a.kind !== "capsule" || b.kind !== "capsule") return null;
  if (pointSegmentDistanceSquared(start, a.a, a.b) <= r0 * r0 + EPSILON) return 0;
  const candidates: number[] = [];
  for (const [first, second] of [[a.a, b.a], [a.b, b.b]] as const) {
    const hit = movingSphere(start, end, first, second, r0, r1);
    if (hit !== null) candidates.push(hit);
  }
  const x = sub(start, a.a);
  const xv = sub(sub(end, start), sub(b.a, a.a));
  const d = sub(a.b, a.a);
  const dv = sub(sub(b.b, b.a), d);
  const xx = linearDot(x, xv, x, xv);
  const dd = linearDot(d, dv, d, dv);
  const xd = linearDot(x, xv, d, dv);
  const dr = r1 - r0;
  const radial = [r0 * r0, 2 * r0 * dr, dr * dr];
  const polynomial = minus(product(minus(xx, radial), dd), product(xd, xd));
  for (const u of unitIntervalRoots(polynomial)) {
    const direction = add(d, mul(dv, u));
    const size = dot(direction, direction);
    if (size <= EPSILON) continue;
    const fraction = dot(add(x, mul(xv, u)), direction) / size;
    if (fraction >= -EPSILON && fraction <= 1 + EPSILON) candidates.push(u);
  }
  return candidates.length ? Math.min(...candidates) : null;
}

/** Earliest front-to-back crossing of an oriented thin shield. The centre and
 * normal interpolate during the sample interval. Rim includes bullet radius.
 */
export function sweepShield(
  start: Vec3, end: Vec3, center0: Vec3, center1: Vec3, normal0: Vec3, normal1: Vec3,
  shieldRadius: number, bulletRadius: number,
): number | null {
  const offset = sub(start, center0);
  const velocity = sub(sub(end, start), sub(center1, center0));
  const normalDelta = sub(normal1, normal0);
  const polynomial = linearDot(offset, velocity, normal0, normalDelta);
  for (const u of unitIntervalRoots(polynomial)) {
    const derivative = polynomial[1]! + 2 * polynomial[2]! * u;
    if (derivative >= -EPSILON) continue;
    const normal = normalized(lerp(normal0, normal1, u));
    if (!normal) continue;
    const point = sub(lerp(start, end, u), lerp(center0, center1, u));
    const radial = sub(point, mul(normal, dot(point, normal)));
    if (length(radial) <= shieldRadius + bulletRadius + EPSILON) return u;
  }
  return null;
}

/** Positive forward distances to a sphere boundary; used to split field travel. */
export function sphereBoundaries(origin: Vec3, direction: Vec3, center: Vec3, radius: number): number[] {
  const offset = sub(origin, center);
  const halfB = dot(offset, direction);
  const discriminant = halfB * halfB - (dot(offset, offset) - radius * radius);
  if (discriminant < 0) return [];
  const root = Math.sqrt(discriminant);
  return [-halfB - root, -halfB + root].filter(t => t > EPSILON);
}
