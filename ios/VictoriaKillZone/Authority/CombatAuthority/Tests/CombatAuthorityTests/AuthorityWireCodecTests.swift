import Foundation
import XCTest
import CombatAuthority
import CombatTransport
import PewPewSimulation

final class AuthorityWireCodecTests: XCTestCase {
  private let ids = [
    SimulationPlayerID("a"),
    SimulationPlayerID("b"),
    SimulationPlayerID("c"),
    SimulationPlayerID("d"),
  ]

  private func codec() throws -> AuthorityWireCodec {
    try AuthorityWireCodec(roster: AuthorityRoster(playerIDs: ids))
  }

  private func claim(
    shooter: SimulationPlayerID = SimulationPlayerID("a"),
    target: SimulationPlayerID? = SimulationPlayerID("b")
  ) -> ShotClaim {
    ShotClaim(
      shotID: "shot-1",
      shooterID: shooter,
      targetID: target,
      origin: Vector3(0, 0, 0),
      direction: Vector3(0, 0, 1),
      firedAtMs: 50
    )
  }

  func testRoundTripsInputsVerdictsAndSnapshots() throws {
    let codec = try codec()
    let record = ShotVerdictRecord(
      shot: claim(),
      verdict: .hit(zone: .torso, appliedDamage: 34),
      targetID: SimulationPlayerID("b"),
      evaluatedAtTick: 1,
      rewindMilliseconds: 0
    )
    let events: [SimulationEvent] = [
      .verdict(record),
      .playerKilled(target: ids[1], by: ids[0], atTick: 2),
      .fireRefused(
        shotID: "shot-2",
        shooter: ids[0],
        reason: .cooldownActive,
        atTick: 3
      ),
      .reloadStarted(player: ids[0], endsAtMs: 1_300, atTick: 4),
      .reloadCompleted(player: ids[0], atTick: 5),
      .playerRespawned(player: ids[1], protectedUntilMs: 2_100, atTick: 6),
    ]
    for (index, event) in events.enumerated() {
      let message = AuthorityMessage.verdict(
        VerdictFrame(sequence: UInt32(index + 1), tick: Int64(index + 1), event: event)
      )
      let payload = try codec.encodePayload(message)
      XCTAssertEqual(
        try codec.decodePayload(kind: .verdict, payload, senderSlot: 0),
        message
      )
    }
    let verdicts: [SpatialVerdict] = [
      .hit(zone: .head, appliedDamage: 80),
      .hit(zone: .torso, appliedDamage: 34),
      .hit(zone: .limbs, appliedDamage: 20),
      .miss,
      .rejected(.trackingLost),
      .rejected(.targetTooClose),
      .rejected(.targetOutOfRange),
      .rejected(.poseTooOld),
      .rejected(.shotTooLate),
      .rejected(.invalidTarget),
      .rejected(.targetNotAlive),
      .rejected(.shooterNotAlive),
    ]
    for (index, verdict) in verdicts.enumerated() {
      let event = SimulationEvent.verdict(
        ShotVerdictRecord(
          shot: claim(),
          verdict: verdict,
          targetID: ids[1],
          evaluatedAtTick: 20,
          rewindMilliseconds: 0
        )
      )
      let message = AuthorityMessage.verdict(
        VerdictFrame(sequence: UInt32(index + 20), tick: 20, event: event)
      )
      XCTAssertEqual(
        try codec.decodePayload(kind: .verdict, codec.encodePayload(message), senderSlot: 0),
        message
      )
    }

    let fire = AuthorityMessage.fire(
      FireInput(slot: 0, sequence: 7, claim: claim())
    )
    let reload = AuthorityMessage.reload(
      ReloadInput(slot: 0, sequence: 8, requestedAtMs: 200)
    )
    XCTAssertEqual(
      try codec.decodePayload(kind: .fire, codec.encodePayload(fire), senderSlot: 0),
      fire
    )
    XCTAssertEqual(
      try codec.decodePayload(kind: .control, codec.encodePayload(reload), senderSlot: 0),
      reload
    )

    let snapshot = StateSnapshot(
      sequence: 9,
      tick: 10,
      clockMs: 500,
      players: ids.enumerated().map {
        PlayerSnapshot(
          slot: UInt8($0.offset),
          health: 100,
          lifeState: .alive,
          kills: 0,
          deaths: 0,
          ammo: 8,
          reloadEndsAtMs: nil,
          respawnAtMs: nil,
          spawnProtectedUntilMs: nil,
          fireLocked: false
        )
      }
    )
    let snapshotPayload = try codec.encodePayload(.snapshot(snapshot))
    XCTAssertEqual(snapshotPayload.count, 111)
    XCTAssertLessThanOrEqual(snapshotPayload.count, 512)
    XCTAssertEqual(
      try codec.decodePayload(
        kind: .snapshot,
        snapshotPayload,
        senderSlot: 0
      ),
      .snapshot(snapshot)
    )
  }

  func testPoseRoundTripAndMalformedPayloads() throws {
    let codec = try codec()
    let input = PoseInput(
      slot: 2,
      sequence: 3,
      sample: PoseSample(
        timestampMs: 50,
        position: Vector3(1, 2, -3),
        tracking: .lost
      )
    )
    let frame = codec.poseFrame(
      from: input,
      epoch: 1,
      orientation: SIMD4<Float>(0, 0, 0, 1)
    )
    XCTAssertEqual(codec.poseInput(from: frame), input)

    var wrongVersion = try codec.encodePayload(
      .reload(ReloadInput(slot: 0, sequence: 1, requestedAtMs: 0))
    )
    wrongVersion[0] = 2
    XCTAssertThrowsError(
      try codec.decodePayload(kind: .control, wrongVersion, senderSlot: 0)
    )

    XCTAssertThrowsError(
      try codec.encodePayload(
        .fire(
          FireInput(
            slot: 0,
            sequence: 1,
            claim: ShotClaim(
              shotID: String(repeating: "x", count: 65),
              shooterID: ids[0],
              origin: Vector3.zero,
              direction: Vector3(0, 0, 1),
              firedAtMs: 1
            )
          )
        )
      )
    )
  }
}
