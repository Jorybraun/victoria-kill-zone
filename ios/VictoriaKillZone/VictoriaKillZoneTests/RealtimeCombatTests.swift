import Foundation
import XCTest
@testable import VictoriaKillZone

final class RealtimeCombatTests: XCTestCase {
  func testClockRequiresSeveralFreshBoundedSamples() {
    var clock=CombatClock()
    for index in 0..<3 {
      let sent=Double(1000 + index * 100)
      XCTAssertTrue(clock.observe(localSentMs:sent,serverReceivedMs:sent - 990,serverSentMs:sent - 990,localReceivedMs:sent + 20))
      XCTAssertEqual(clock.isReady(at:sent + 20),index == 2)
    }
    XCTAssertEqual(clock.matchTime(at:1250),250)
    XCTAssertEqual(clock.uncertaintyMs,10)
    XCTAssertFalse(clock.isReady(at:5000))
    clock.reset(); XCTAssertNil(clock.matchTime(at:5000))
  }

  func testClockRejectsImpossibleTimingAndDetectsClockDiscontinuity() {
    var clock=CombatClock()
    XCTAssertFalse(clock.observe(localSentMs:100,serverReceivedMs:100,serverSentMs:99,localReceivedMs:110))
    XCTAssertFalse(clock.observe(localSentMs:100,serverReceivedMs:100,serverSentMs:100,localReceivedMs:99))
    for _ in 0..<3 {_ = clock.observe(localSentMs:1000,serverReceivedMs:10,serverSentMs:10,localReceivedMs:1020)}
    XCTAssertTrue(clock.isReady(at:1020))
    _ = clock.observe(localSentMs:1100,serverReceivedMs:500,serverSentMs:500,localReceivedMs:1120)
    XCTAssertFalse(clock.isReady(at:1120))
  }

  func testClientIntentEncodingMatchesTaggedProtocolAndOmitsIdentity() throws {
    let message=CombatWire.ClientMessage.command(.init(commandId:"c1",clientSequence:1,authorityEpoch:1,frameEpoch:1,sentAtMs:100,command:.fire(shotId:"s1",poseSequence:7,origin:[0,0,0],direction:[0,0,-1])))
    let data=try JSONEncoder().encode(message)
    let root=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    XCTAssertEqual(root["type"] as? String,"command")
    let envelope=try XCTUnwrap(root["envelope"] as? [String:Any])
    XCTAssertNil(envelope["playerId"])
    let command=try XCTUnwrap(envelope["command"] as? [String:Any])
    XCTAssertEqual(command["kind"] as? String,"fire")
    XCTAssertNil(command["damage"])
    XCTAssertNil(command["targetPlayerId"])
  }

  func testEventBatchIsAtomicAndReplayDoesNotRepeatPresentation() throws {
    var replica=CombatReplica(matchID:"match",localPlayerID:"p1")
    try replica.replace(Self.snapshot(),eventSequence:0,clientSequence:0)
    let spawn=Self.event(1,.projectileSpawn(Self.projectile()))
    XCTAssertEqual(try replica.apply([spawn]).count,1)
    XCTAssertTrue(try replica.apply([spawn]).isEmpty)
    let terminal=Self.event(2,.projectileTerminal(.init(projectileId:"bullet",shotId:"shot",shooterId:"p1",reason:"bodyHit",atMs:50,position:[0,1,-2],targetPlayerId:"p2",zone:.torso,damage:34)))
    XCTAssertThrowsError(try replica.apply([terminal,Self.event(4,.phaseChanged(.paused,reason:"gap"))]))
    XCTAssertEqual(replica.eventSequence,1)
    XCTAssertEqual(replica.snapshot?.projectiles.count,1)
    XCTAssertEqual(try replica.apply([terminal]).count,1)
    XCTAssertTrue(replica.snapshot?.projectiles.isEmpty == true)
  }

  func testRecoveryCannotAcceptOldAuthorityEventsOrForeignMembers() throws {
    var replica=CombatReplica(matchID:"match",localPlayerID:"p1")
    try replica.replace(Self.snapshot(),eventSequence:0,clientSequence:0)
    var recovered=Self.snapshot(); recovered.authorityEpoch=2; recovered.phase = .paused
    XCTAssertTrue(try replica.replace(recovered,eventSequence:4,clientSequence:2))
    XCTAssertThrowsError(try replica.apply([Self.event(5,.projectileSpawn(Self.projectile()))]))
    var foreign=Self.projectile(); foreign.shooterId="outsider"
    var event=Self.event(5,.projectileSpawn(foreign)); event.authorityEpoch=2
    XCTAssertThrowsError(try replica.apply([event]))
    XCTAssertEqual(replica.eventSequence,4)
  }

  func testProjectileInterpolationChangesOnlyItsOwnWorldline() {
    var bullet=Self.projectile()
    bullet.timeScale=0.25
    XCTAssertEqual(bullet.position(at:1000),[0,1,-2])
    XCTAssertEqual(bullet.position(at:-100),[0,1,0])
    XCTAssertEqual(bullet.position(at:10_000),[0,1,-8])
  }

  func testSnapshotBoundsAndTicketRedaction() throws {
    XCTAssertTrue(CombatWireValidation.valid(Self.snapshot()))
    var invalid=Self.snapshot(); invalid.players += invalid.players
    XCTAssertFalse(CombatWireValidation.valid(invalid))
    let ephemeral=UUID().uuidString
    let ticket=CombatAccessTicket(endpoint:try XCTUnwrap(URL(string:"https://combat.example.test/v1/matches/match/connect")),token:ephemeral,expiresAt:Date(),authorityEpoch:1,frameEpoch:1)
    XCTAssertFalse(ticket.description.contains(ephemeral))
    XCTAssertFalse(ticket.debugDescription.contains(ephemeral))
  }

  static func projectile() -> CombatWire.Projectile {
    .init(projectileId:"bullet",shotId:"shot",shooterId:"p1",spawnedAtMs:0,position:[0,1,0],direction:[0,0,-1],speed:8,segmentStartedAtMs:0,segmentOrigin:[0,1,0],timeScale:1,radius:0.015,expiresAtMs:4000,distanceTravelled:0)
  }
  static func event(_ sequence: Int,_ event: CombatWire.Event) -> CombatWire.ServerEvent {
    .init(v:1,matchId:"match",authorityEpoch:1,frameEpoch:1,eventSequence:sequence,tick:1,matchTimeMs:50,event:event)
  }
  static func snapshot() -> CombatWire.Snapshot {
    let players=(1...2).map {index in
      CombatWire.Player(playerId:"p\(index)",displayName:"Player \(index)",role:index == 1 ? "host" : "player",health:100,ammo:8,kills:0,deaths:0,connected:true,frameReady:true,lastFireAtMs:nil,reloadEndsAtMs:nil,respawnAtMs:nil,protectedUntilMs:nil,shield:.init(activeUntilMs:nil,cooldownUntilMs:0,energy:100),slowFieldReadyAtMs:0)
    }
    let rules=CombatWire.Rules(durationMs:180_000,geometry:"trackedBody",respawnMs:5000,protectionMs:2000,
      weapon:.init(id:"pulse",kind:"projectile",damage:.init(head:75,torso:34,limbs:20),cooldownMs:150,magazine:8,reloadMs:1250,speed:8,projectileRadius:0.015,lifetimeMs:4000,rangeMeters:25),
      shield:.init(radius:0.4,offsetMeters:0.15,durationMs:2000,cooldownMs:8000,energy:100),
      slowField:.init(radius:2,durationMs:2000,cooldownMs:10000,scale:0.25))
    return .init(matchId:"match",authorityEpoch:1,frameEpoch:1,tick:0,matchTimeMs:0,phase:.running,rules:rules,players:players,projectiles:[],slowFields:[])
  }
}
