import Foundation
import XCTest

@testable import VictoriaKillZone

final class ConvexGameSessionWireTests: XCTestCase {
  func testArgumentsMatchExactBackendValidators() {
    let session = testSession()

    XCTAssertEqual(
      Set(
        ConvexGameSessionArguments.create(.init(displayName: "Host", arenaRadiusMeters: 30)).keys),
      ["displayName", "arenaRadiusMeters"]
    )
    XCTAssertEqual(
      Set(ConvexGameSessionArguments.join(.init(displayName: "Guest", code: "ABC123")).keys),
      ["displayName", "code"]
    )
    XCTAssertEqual(
      Set(ConvexGameSessionArguments.authenticated(session).keys),
      ["matchId", "playerId", "sessionSecret"]
    )
    XCTAssertEqual(
      Set(ConvexGameSessionArguments.setReady(session: session, isReady: true).keys),
      ["matchId", "playerId", "sessionSecret", "isReady"]
    )
    XCTAssertEqual(
      Set(ConvexGameSessionArguments.debugFire(session: session, clientShotId: "shot-1").keys),
      ["matchId", "playerId", "sessionSecret", "clientShotId"]
    )
  }

  func testPlayerSessionDecodesExactCreateAndJoinEnvelope() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "matchId": "match-1",
      "code": "ABC123",
      "playerId": "player-1",
      "sessionSecret": UUID().uuidString,
    ])

    let session = try JSONDecoder().decode(PlayerSession.self, from: data)

    XCTAssertEqual(session.matchId, "match-1")
    XCTAssertEqual(session.code, "ABC123")
    XCTAssertEqual(session.playerId, "player-1")
    XCTAssertFalse(session.sessionSecret.isEmpty)
  }

  func testMatchSnapshotDecodesBackendProjectionWithoutAliases() throws {
    let wire = try JSONDecoder().decode(MatchSnapshotWire.self, from: snapshotFixture)
    let snapshot = try wire.domainValue()

    XCTAssertEqual(snapshot.serverNow, 1_750_000_000_000)
    XCTAssertEqual(snapshot.match.id, "match-1")
    XCTAssertEqual(snapshot.match.code, "ABC123")
    XCTAssertEqual(snapshot.match.phase, .running)
    XCTAssertEqual(snapshot.match.durationMs, 180_000)
    XCTAssertEqual(snapshot.match.startsAt, 1_750_000_003_000)
    XCTAssertEqual(snapshot.match.endsAt, 1_750_000_183_000)
    XCTAssertEqual(snapshot.localPlayerId, "host-1")
    XCTAssertEqual(snapshot.players.map(\.role), [.host, .guest])
    XCTAssertEqual(snapshot.players.map(\.health), [100, 66])
    XCTAssertEqual(snapshot.players.map(\.ammo), [7, 8])
    XCTAssertEqual(snapshot.events.map(\.type), [.hit, .joined])
    XCTAssertEqual(snapshot.events.first?.zone, "torso")
    XCTAssertEqual(snapshot.events.first?.damage, 34)
    XCTAssertNil(snapshot.events.last?.targetPlayerId)
    XCTAssertNil(snapshot.events.last?.zone)
  }

  func testMatchSnapshotAcceptsEveryFrozenBackendPhase() throws {
    let cases: [(String, MatchPhase)] = [
      ("lobby", .lobby),
      ("countdown", .countdown),
      ("running", .running),
      ("finished", .finished),
      ("cancelled", .cancelled),
    ]

    for (wireValue, expected) in cases {
      let data = try replacingJSONValue(
        in: snapshotFixture,
        path: ["match", "phase"],
        with: wireValue
      )
      let snapshot = try JSONDecoder().decode(MatchSnapshotWire.self, from: data).domainValue()
      XCTAssertEqual(snapshot.match.phase, expected)
    }
  }

  func testSnapshotRejectsFractionalIntegerFields() throws {
    let malformed = try replacingJSONValue(
      in: snapshotFixture,
      path: ["match", "durationMs"],
      with: 180_000.5
    )
    let wire = try JSONDecoder().decode(MatchSnapshotWire.self, from: malformed)

    XCTAssertThrowsError(try wire.domainValue()) { error in
      XCTAssertEqual(error as? GameSessionClientError, .invalidSnapshot)
    }
  }

  func testSnapshotPreservesKnownAndIgnoresUnknownHitZones() throws {
    let cases: [(String, String?)] = [
      ("head", "head"),
      ("torso", "torso"),
      ("limbs", "limbs"),
      ("future-zone", nil),
    ]

    for (zone, expectedZone) in cases {
      let data = try replacingJSONValue(
        in: snapshotFixture,
        path: ["events", 0, "zone"],
        with: zone
      )
      let wire = try JSONDecoder().decode(MatchSnapshotWire.self, from: data)
      let snapshot = try wire.domainValue()

      XCTAssertEqual(snapshot.events.first?.zone, expectedZone)
    }
  }

  func testDebugFireDecodesAcceptedAndRejectedResults() throws {
    let accepted = try JSONDecoder().decode(DebugFireResultWire.self, from: acceptedFireFixture)
      .domainValue()
    XCTAssertEqual(
      accepted,
      DebugFireResult(
        accepted: true,
        outcome: .hit,
        clientShotId: "shot-1",
        replayed: false,
        damage: 34,
        shooterAmmo: 7,
        targetHealth: 66,
        eventId: "event-hit",
        rejectReason: nil
      )
    )

    let rejected = try JSONDecoder().decode(DebugFireResultWire.self, from: rejectedFireFixture)
      .domainValue()
    XCTAssertFalse(rejected.accepted)
    XCTAssertEqual(rejected.outcome, .rejected)
    XCTAssertEqual(rejected.rejectReason, .matchNotRunning)
    XCTAssertNil(rejected.eventId)
  }

  func testBackendErrorPayloadUsesStableCodeAtAnyConvexEnvelopeDepth() {
    let cases: [(String, BackendErrorCode)] = [
      ("INVALID_DISPLAY_NAME", .invalidDisplayName),
      ("INVALID_CODE", .invalidCode),
      ("MATCH_NOT_FOUND", .matchNotFound),
      ("MATCH_FULL", .matchFull),
      ("MATCH_ALREADY_STARTED", .matchAlreadyStarted),
      ("INVALID_SESSION", .invalidSession),
      ("PLAYERS_NOT_READY", .playersNotReady),
      ("PLAYERS_NOT_CONNECTED", .playersNotConnected),
      ("HOST_ONLY", .hostOnly),
      ("MATCH_NOT_RUNNING", .matchNotRunning),
      ("CONNECTION_STALE", .connectionStale),
    ]

    for (wireValue, expected) in cases {
      XCTAssertEqual(ConvexGameSessionClient.backendCode(in: wireValue), expected)
    }
    XCTAssertEqual(
      ConvexGameSessionClient.backendCode(
        in: #"{"data":{"error":{"code":"PLAYERS_NOT_READY"}}}"#
      ),
      .playersNotReady
    )
    XCTAssertNil(ConvexGameSessionClient.backendCode(in: #"{"code":"NEW_SERVER_CODE"}"#))
  }

  func testDeploymentURLSupportsEnvironmentOverrideAndSafeShellFallback() {
    XCTAssertEqual(
      AppEnvironment.configuredDeploymentURL(
        bundleValue: "$(CONVEX_DEPLOYMENT_URL)",
        environmentValue: "https://example.convex.cloud"
      ),
      "https://example.convex.cloud"
    )
    XCTAssertNil(
      AppEnvironment.configuredDeploymentURL(
        bundleValue: "$(CONVEX_DEPLOYMENT_URL)",
        environmentValue: nil
      )
    )
    XCTAssertNil(AppEnvironment.validatedDeploymentURL("http://example.convex.cloud"))
  }

  private func testSession() -> PlayerSession {
    PlayerSession(
      matchId: "match-1",
      code: "ABC123",
      playerId: "player-1",
      sessionSecret: UUID().uuidString
    )
  }

  private func replacingJSONValue(
    in data: Data,
    path: [Any],
    with replacement: Any
  ) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    if path.count == 2, let objectKey = path[0] as? String, let valueKey = path[1] as? String,
      var nested = object[objectKey] as? [String: Any]
    {
      nested[valueKey] = replacement
      object[objectKey] = nested
    } else if path.count == 3, let arrayKey = path[0] as? String,
      let index = path[1] as? Int, let valueKey = path[2] as? String,
      var nested = object[arrayKey] as? [[String: Any]]
    {
      nested[index][valueKey] = replacement
      object[arrayKey] = nested
    } else {
      XCTFail("Unsupported fixture path")
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  private var snapshotFixture: Data {
    Data(
      #"""
      {
        "serverNow": 1750000000000,
        "match": {
          "id": "match-1",
          "code": "ABC123",
          "phase": "running",
          "durationMs": 180000,
          "startsAt": 1750000003000,
          "endsAt": 1750000183000
        },
        "localPlayerId": "host-1",
        "players": [
          {
            "id": "host-1",
            "displayName": "Host",
            "role": "host",
            "ready": true,
            "connected": true,
            "health": 100,
            "ammo": 7
          },
          {
            "id": "guest-1",
            "displayName": "Guest",
            "role": "guest",
            "ready": true,
            "connected": true,
            "health": 66,
            "ammo": 8
          }
        ],
        "events": [
          {
            "id": "event-hit",
            "type": "hit",
            "message": "Host HIT Guest • TORSO −34",
            "createdAt": 1750000010000,
            "actorPlayerId": "host-1",
            "targetPlayerId": "guest-1",
            "zone": "torso",
            "damage": 34
          },
          {
            "id": "event-joined",
            "type": "joined",
            "message": "Guest joined",
            "createdAt": 1750000000000,
            "actorPlayerId": "guest-1"
          }
        ]
      }
      """#.utf8
    )
  }

  private var acceptedFireFixture: Data {
    Data(
      #"""
      {
        "accepted": true,
        "outcome": "hit",
        "clientShotId": "shot-1",
        "replayed": false,
        "damage": 34,
        "shooterAmmo": 7,
        "targetHealth": 66,
        "eventId": "event-hit"
      }
      """#.utf8
    )
  }

  private var rejectedFireFixture: Data {
    Data(
      #"""
      {
        "accepted": false,
        "outcome": "rejected",
        "clientShotId": "shot-2",
        "replayed": false,
        "damage": 0,
        "shooterAmmo": 8,
        "targetHealth": 100,
        "rejectReason": "MATCH_NOT_RUNNING"
      }
      """#.utf8
    )
  }
}
