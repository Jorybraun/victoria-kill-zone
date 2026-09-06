import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, LIMITS, parseClientMessage, validateTicketClaims} from "../src/index.js";

const envelope = (command: unknown) => ({type:"command",envelope:{v:1,commandId:"shot-1",clientSequence:1,authorityEpoch:1,frameEpoch:1,sentAtMs:50,command}});
const parse = (x: unknown) => parseClientMessage(JSON.stringify(x));
const ticket = () => ({v:1,iss:"vkz-lobby",aud:"vkz-combat",matchId:"match",playerId:"p1",
  roster:[{playerId:"p1",displayName:"One",role:"host"},{playerId:"p2",displayName:"Two",role:"player"}],
  authorityEpoch:1,frameEpoch:1,rules:structuredClone(DEFAULT_RULES),iat:100,exp:220,nonce:"random-nonce"});

describe("untrusted combat messages", () => {
  it("accepts normalized fire intent without a desired verdict", () => {
    const msg = envelope({kind:"fire",shotId:"s1",poseSequence:2,origin:[0,1,0],direction:[0,0,-1]});
    expect(parse(msg)).toEqual(msg);
    expect(parse({...msg,envelope:{...msg.envelope,playerId:"victim"}})).toBeNull();
    expect(parse(envelope({...msg.envelope.command as object,damage:100}))).toBeNull();
  });
  it.each([[0,0,0],[0,0,2],[0,null,-1],[1e20,0,0]])("rejects invalid ray %j", (...direction) => {
    expect(parse(envelope({kind:"fire",shotId:"s",poseSequence:0,origin:[0,0,0],direction}))).toBeNull();
  });
  it("rejects invalid versions, unbounded sequences and extra keys", () => {
    const msg = envelope({kind:"reload"});
    for (const patch of [{v:2},{clientSequence:0},{clientSequence:1.2},{authorityEpoch:0},{sentAtMs:-1},{commandId:"x/y"}])
      expect(parse({...msg,envelope:{...msg.envelope,...patch}})).toBeNull();
    expect(parse(envelope({kind:"reload",extra:true}))).toBeNull();
  });
  it("bounds bytes before parsing including multibyte Unicode", () => {
    expect(parseClientMessage("x".repeat(LIMITS.messageBytes+1))).toBeNull();
    expect(parseClientMessage(JSON.stringify({type:"ping",nonce:"🙂".repeat(5000),clientSentAtMs:0}))).toBeNull();
    expect(parseClientMessage("{" )).toBeNull();
  });
  it("requires unique stable collider identities and one observation per target", () => {
    const c = {id:"head",kind:"sphere",zone:"head",center:[0,1,0],radius:.15};
    const o = {targetPlayerId:"p2",capturedAtMs:0,associationConfidence:1,uncertaintyMeters:.02,colliders:[c]};
    const p = {kind:"pose",pose:{sequence:0,capturedAtMs:0,position:[0,0,0],orientation:[0,0,0,1],tracking:"normal"},observations:[o]};
    expect(parse(envelope(p))).not.toBeNull();
    expect(parse(envelope({...p,observations:[{...o,colliders:[c,c]}]}))).toBeNull();
    expect(parse(envelope({...p,observations:[o,o]}))).toBeNull();
    expect(parse(envelope({...p,pose:{...p.pose,orientation:[0,0,0,0]}}))).toBeNull();
  });
  it("accepts bounded reconnect and acknowledgement messages", () => {
    expect(parse({type:"received",eventSequence:5})).toEqual({type:"received",eventSequence:5});
    expect(parse({type:"resume",afterEventSequence:0})).not.toBeNull();
    expect(parse({type:"received",eventSequence:-1})).toBeNull();
  });
});

describe("ticket claims", () => {
  it("accepts two to four unique members with exactly one host", () => {
    const t=ticket();
    expect(validateTicketClaims(t,150)).toEqual(t);
    t.roster.push({playerId:"p3",displayName:"Three",role:"player"},{playerId:"p4",displayName:"Four",role:"player"});
    expect(validateTicketClaims(t,150)).not.toBeNull();
    t.roster.push({playerId:"p5",displayName:"Five",role:"player"});
    expect(validateTicketClaims(t,150)).toBeNull();
  });
  it("rejects expired, future, excessively long and wrong-audience claims", () => {
    for (const patch of [{exp:150},{iat:160},{exp:221},{aud:"other"},{playerId:"intruder"},{authorityEpoch:0},{extra:true}])
      expect(validateTicketClaims({...ticket(),...patch},150)).toBeNull();
  });
  it("rejects duplicate players, missing host and malformed rules", () => {
    const t=ticket();
    expect(validateTicketClaims({...t,roster:[t.roster[0],t.roster[0]]},150)).toBeNull();
    expect(validateTicketClaims({...t,roster:t.roster.map(m=>({...m,role:"player"}))},150)).toBeNull();
    t.rules.slowField.scale=0;
    expect(validateTicketClaims(t,150)).toBeNull();
    t.rules=structuredClone(DEFAULT_RULES); t.rules.weapon.cooldownMs=1;
    expect(validateTicketClaims(t,150)).toBeNull();
  });
});
