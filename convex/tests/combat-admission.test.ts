import { randomBytes, bytesToHex } from "@noble/hashes/utils.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { validateTicketClaims } from "@vkz/combat-protocol";
import { prepare, ticket } from "../functions/combat.js";
import { create, join, start, activate, finish } from "../functions/matches.js";
import { fire, debugFire, recordVerdict } from "../functions/shots.js";
import { startReload, completeReload, respawn } from "../functions/players.js";
import { mutationContext, mutationHandler, storedMatch, storedPlayer, testIds } from "./mutation-context.js";
import { T0 } from "./factories.js";

let signingKey = "";
const decode = (value: string) => Uint8Array.from(atob(value.replace(/-/g,"+").replace(/_/g,"/")), c => c.charCodeAt(0));
beforeEach(() => {
  vi.spyOn(Date,"now").mockReturnValue(T0 + 1000);
  signingKey = bytesToHex(randomBytes(32));
  vi.stubEnv("COMBAT_TICKET_SECRET", signingKey);
  vi.stubEnv("COMBAT_WORKER_URL", "https://combat.example.test");
});
afterEach(() => {vi.restoreAllMocks(); vi.unstubAllEnvs();});

function room() {
  const b=mutationContext(), host=storedPlayer(testIds.host,{ready:true}), guest=storedPlayer(testIds.guest,{ready:true});
  b.seed("players",host.doc); b.seed("players",guest.doc);
  b.seed("matches",storedMatch({status:"waiting",phase:"lobby",combatMode:"durableObject",maxPlayers:4}));
  return {...b,host,guest,auth:{matchId:testIds.match,playerId:testIds.host,sessionSecret:host.sessionSecret}};
}

describe("realtime room admission", () => {
  it("creates a four-slot lobby, accepts slots three/four and rejects five", async () => {
    const b=mutationContext();
    const host=await mutationHandler(create)(b.ctx,{displayName:"Host",arenaRadiusMeters:30,combatMode:"durableObject",maxPlayers:4});
    for (const displayName of ["Second","Third","Fourth"]) await mutationHandler(join)(b.ctx,{code:host.code,displayName});
    await expect(mutationHandler(join)(b.ctx,{code:host.code,displayName:"Fifth"})).rejects.toMatchObject({data:{code:"MATCH_FULL"}});
    expect(b.writes.filter(w=>w.kind==="insert" && w.table==="players")).toHaveLength(4);
  });
  it("preserves the legacy two-slot match and rejects invalid caps", async () => {
    const b=mutationContext();
    await expect(mutationHandler(create)(b.ctx,{displayName:"Host",arenaRadiusMeters:30,maxPlayers:4})).rejects.toMatchObject({data:{code:"INVALID_ARENA"}});
    const host=await mutationHandler(create)(b.ctx,{displayName:"Host",arenaRadiusMeters:30});
    await mutationHandler(join)(b.ctx,{code:host.code,displayName:"Second"});
    await expect(mutationHandler(join)(b.ctx,{code:host.code,displayName:"Third"})).rejects.toMatchObject({data:{code:"MATCH_FULL"}});
  });
  it("freezes only a ready roster, rejects guests and makes retries idempotent", async () => {
    const b=room();
    await expect(mutationHandler(prepare)(b.ctx,{...b.auth,playerId:testIds.guest,sessionSecret:b.guest.sessionSecret})).rejects.toMatchObject({data:{code:"HOST_ONLY"}});
    b.seed("players",{...b.guest.doc,ready:false});
    await expect(mutationHandler(prepare)(b.ctx,b.auth)).rejects.toMatchObject({data:{code:"PLAYERS_NOT_READY"}});
    b.seed("players",b.guest.doc);
    await mutationHandler(prepare)(b.ctx,b.auth);
    const count=b.writes.length;
    await mutationHandler(prepare)(b.ctx,b.auth);
    expect(b.writes).toHaveLength(count);
    expect(b.jobs).toHaveLength(0);
    await expect(mutationHandler(join)(b.ctx,{code:"ABCDEF",displayName:"Late"})).rejects.toMatchObject({data:{code:"MATCH_ALREADY_STARTED"}});
  });
  it("issues a WebCrypto-verifiable JWT bound to the authenticated roster", async () => {
    const b=room(); await mutationHandler(prepare)(b.ctx,b.auth);
    const issued=await mutationHandler(ticket)(b.ctx,b.auth);
    const parts=issued.ticket.split(".");
    const claims: unknown=JSON.parse(new TextDecoder().decode(decode(parts[1] ?? "")));
    expect(validateTicketClaims(claims,Math.floor(Date.now()/1000))).toMatchObject({playerId:testIds.host,roster:[{playerId:testIds.host},{playerId:testIds.guest}]});
    const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(signingKey),{name:"HMAC",hash:"SHA-256"},false,["verify"]);
    expect(await crypto.subtle.verify("HMAC",key,decode(parts[2] ?? ""),new TextEncoder().encode(`${parts[0]}.${parts[1]}`))).toBe(true);
    expect(issued.endpoint).toBe(`https://combat.example.test/v1/matches/${testIds.match}/connect`);
    await expect(mutationHandler(ticket)(b.ctx,b.auth)).rejects.toMatchObject({data:{code:"CONNECTION_STALE"}});
    await expect(mutationHandler(ticket)(b.ctx,{...b.auth,sessionSecret:b.guest.sessionSecret})).rejects.toMatchObject({data:{code:"INVALID_SESSION"}});
  });
  it("fails before preparation when secure deployment configuration is missing", async () => {
    const b=room(); vi.stubEnv("COMBAT_WORKER_URL","http://combat.example.test");
    await expect(mutationHandler(prepare)(b.ctx,b.auth)).rejects.toMatchObject({data:{code:"COMBAT_UNAVAILABLE"}});
    expect(b.writes).toHaveLength(0);
  });
});

describe("one combat authority", () => {
  it("rejects every public legacy combat writer and ignores scheduled legacy jobs", async () => {
    const b=room(); await mutationHandler(prepare)(b.ctx,b.auth);
    const commands=[
      mutationHandler(start)(b.ctx,b.auth),mutationHandler(startReload)(b.ctx,b.auth),
      mutationHandler(debugFire)(b.ctx,{...b.auth,clientShotId:"s"}),
      mutationHandler(fire)(b.ctx,{matchId:testIds.match,shooterId:testIds.host,sessionSecret:b.host.sessionSecret,clientShotId:"s",firedAtClient:T0}),
      mutationHandler(recordVerdict)(b.ctx,{...b.auth,record:{clientShotId:"s",shooterPlayerId:testIds.host,targetPlayerId:null,zone:null,damage:0,rewindMs:0,verdict:"miss",rejectionReason:null,origin:[0,0,0],direction:[0,0,-1],impact:[0,0,-2],firedAtClient:T0,adjudicatedBy:testIds.host}}),
    ];
    for (const command of commands) await expect(command).rejects.toMatchObject({data:{code:"COMBAT_AUTHORITY_REQUIRED"}});
    const count=b.writes.length;
    await mutationHandler(activate)(b.ctx,{matchId:testIds.match,expectedStartsAt:T0});
    await mutationHandler(finish)(b.ctx,{matchId:testIds.match,expectedEndsAt:T0});
    await mutationHandler(completeReload)(b.ctx,{playerId:testIds.host,expectedReloadEndsAt:T0});
    await mutationHandler(respawn)(b.ctx,{playerId:testIds.host,expectedRespawnAt:T0});
    expect(b.writes).toHaveLength(count);
  });
});
