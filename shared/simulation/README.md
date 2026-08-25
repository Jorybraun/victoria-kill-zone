# PewPewSimulation

The package is a pure, Foundation-only simulation core. It owns the fixed match
clock, pose history, bounded-rewind hitscan evaluation, and deterministic event
ordering for match.v2 player sets.

## Scenario fixtures

Executable scenario specifications live in `scenarios/*.json`. Each file uses:

```json
{
  "name": "scenario_name",
  "description": "Hand-derived expectation from SimulationConstants.",
  "clock": { "tickMs": 50 },
  "players": [{ "id": "player-a" }, { "id": "player-b" }],
  "timeline": [
    {
      "atMs": 400,
      "poseSample": {
        "player": "player-b",
        "pos": [0.6, 0, 10],
        "stampedAtMs": 400,
        "tracking": "normal"
      }
    },
    {
      "atMs": 500,
      "fire": {
        "shooter": "player-a",
        "target": "player-b",
        "origin": [0, 0, 0],
        "dir": [0, 0, 1],
        "claimedAtMs": 450,
        "shotId": "s1"
      }
    }
  ],
  "expect": [
    { "verdict": { "shotId": "s1", "outcome": "hit", "appliedDamage": 34, "rewindMs": 50 } }
  ]
}
```

`atMs` is a positive multiple of `clock.tickMs`; the runner advances from tick
1 through the latest timeline entry. `stampedAtMs` defaults to `atMs`, and
`tracking` defaults to `normal`. Verdict outcomes are `hit`, `miss`, or
`rejected`; rejected verdicts require a `reason` matching
`ShotRejectionReason.rawValue`, and hit verdicts require `appliedDamage`.
`expect` is the complete emitted event sequence, including optional
`{ "killed": { "target": "...", "by": "...", "atMs": 500 } }` events.

The runner resolves every discovered JSON fixture, replays it twice, and checks
that a same-tick arrival permutation produces byte-identical event output.
