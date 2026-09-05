import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, randomBytes, utf8ToBytes } from "@noble/hashes/utils.js";
import type { CombatPlayerState, CombatProjection } from "@vkz/combat-protocol";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { publishProjection } from "../functions/combat.js";
import { heartbeat } from "../functions/players.js";
import { spectatorSnapshot } from "../functions/queries.js";
import { mutationContext, mutationHandler, queryHandler, storedMatch, storedPlayer, testIds } from "./mutation-context.js";
import { T0 } from "./factories.js";

let key="";
beforeEach(()=>{key=bytesToHex(randomBytes(32));vi.stubEnv("COMBAT_PROJECTION_SECRET",key);vi.spyOn(Date,"now").mockReturnValue(T0+1000);});
afterEach(()=>{vi.restoreAllMocks();vi.unstubAllEnvs();});
function signed(p: CombatProjection) {
  const payload=JSON.stringify(p);
  return {payload,signature:bytesToHex(hmac(sha256,utf8ToBytes(key),utf8ToBytes(`vkz-projection-v1.${payload}`)))};
}
function setup() {
  const b=mutationContext(),host=storedPlayer(testIds.host,{displayName:"Host"}),guest=storedPlayer(testIds.guest,{displayName:"Guest"});
  b.seed("matches",storedMatch({combatMode:"durableObject",combatPreparedAt:T0,combatAuthorityEpoch:1,combatFrameEpoch:1,combatProjectionSequence:0}));
  b.seed("players",host.doc);b.seed("players",guest.doc);
  const players: CombatPlayerState[]=[host,guest].map(({doc})=>({playerId:doc._id,displayName:doc.displayName,role:doc._id === testIds.host ? "host" : "player",
    health:doc._id === testIds.guest ? 66 : 100,ammo:doc._id === testIds.host ? 7 : 8,kills:0,deaths:0,connected:true,frameReady:true,
    lastFireAtMs:null,reloadEndsAtMs:null,respawnAtMs:null,protectedUntilMs:null,shield:{activeUntilMs:null,cooldownUntilMs:0,energy:100},slowFieldReadyAtMs:0}));
  const projection: CombatProjection={v:1,matchId:testIds.match,authorityEpoch:1,frameEpoch:1,fromEventSequence:1,throughEventSequence:5,
    matchTimeMs:500,roundStartedAtMs:0,phase:"running",players,terminals:[{eventSequence:3,event:{kind:"projectileTerminal",projectileId:"p:1:0:1",shotId:"shot",shooterId:testIds.host,
      reason:"bodyHit",atMs:450,position:[0,1,-2],targetPlayerId:testIds.guest,zone:"torso",damage:34}}]};
  return {...b,host,guest,projection};
}

describe("ordered authority projection",()=>{
  it("persists one durable shot, projects scores and replays without extra writes",async()=>{
    const b=setup(),args=signed(b.projection),handler=mutationHandler(publishProjection);
    expect(await handler(b.ctx,args)).toEqual({eventSequence:5,replayed:false});
    expect(b.readPlayer(testIds.guest)?.health).toBe(66);
    expect(b.readPlayer(testIds.host)?.shotsFired).toBe(1);
    expect(b.readPlayer(testIds.host)?.damageDealt).toBe(34);
    const writes=b.writes.length;
    expect(await handler(b.ctx,args)).toEqual({eventSequence:5,replayed:true});
    expect(b.writes).toHaveLength(writes);
    const snapshot=await queryHandler(spectatorSnapshot)(b.ctx,{code:"ABCDEF"});
    expect(snapshot?.match).toMatchObject({combatMode:"durableObject",combatPhase:"running"});
    expect(snapshot?.players.find(p=>p.id === testIds.guest)?.health).toBe(66);
    expect(b.writes.filter(w=>w.table === "combatShots")).toHaveLength(1);
  });
  it("rejects tampering, foreign roster, gaps and conflicting retries before writes",async()=>{
    const b=setup(),handler=mutationHandler(publishProjection),args=signed(b.projection);
    await expect(handler(b.ctx,{...args,payload:args.payload.replace('"damage":34','"damage":99')})).rejects.toMatchObject({data:{code:"INVALID_SESSION"}});
    await expect(handler(b.ctx,signed({...b.projection,fromEventSequence:2}))).rejects.toMatchObject({data:{code:"IDEMPOTENCY_CONFLICT"}});
    await expect(handler(b.ctx,signed({...b.projection,players:b.projection.players.map(p=>({...p,displayName:"Imposter"}))}))).rejects.toMatchObject({data:{code:"INVALID_SESSION"}});
    expect(b.writes).toHaveLength(0);
    await handler(b.ctx,args);
    const count=b.writes.length;
    await expect(handler(b.ctx,signed({...b.projection,matchTimeMs:501}))).rejects.toMatchObject({data:{code:"IDEMPOTENCY_CONFLICT"}});
    expect(b.writes).toHaveLength(count);
  });
  it("preserves all shots beyond the reconnect ring and accepts ordered recovery epochs",async()=>{
    const b=setup(),handler=mutationHandler(publishProjection);
    await handler(b.ctx,signed(b.projection));
    const p={...b.projection,authorityEpoch:2,fromEventSequence:6,throughEventSequence:1500,phase:"paused" as const,terminals:[]};
    await handler(b.ctx,signed(p));
    const shots=await b.ctx.db.query("combatShots").withIndex("by_match_and_projectile",q=>q.eq("matchId",testIds.match)).collect();
    expect(shots).toHaveLength(1);
    const count=b.writes.length;
    await expect(handler(b.ctx,signed({...p,authorityEpoch:1,fromEventSequence:1501,throughEventSequence:1502}))).rejects.toMatchObject({data:{code:"IDEMPOTENCY_CONFLICT"}});
    expect(b.writes).toHaveLength(count);
  });
  it("does not let the lobby heartbeat overwrite a realtime life/connection projection",async()=>{
    const b=setup(); b.seed("players",{...b.host.doc,connected:false,lifeState:"disconnected"});
    await mutationHandler(heartbeat)(b.ctx,{matchId:testIds.match,playerId:testIds.host,sessionSecret:b.host.sessionSecret});
    expect(b.readPlayer(testIds.host)?.connected).toBe(false);
    expect(b.readPlayer(testIds.host)?.lifeState).toBe("disconnected");
  });
});
