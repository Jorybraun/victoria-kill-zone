# Product context

## Shared spatial combat glossary

Canonical terms for `spatial-hit.v1`. Each term is defined once here and used verbatim everywhere else; the frozen semantics behind them live in [docs/features/shared-spatial-hit-registration/requirements.md](docs/features/shared-spatial-hit-registration/requirements.md).

- **Shared Arena Frame:** The common three-dimensional playing space used by every match member and the spectator.
- **Phone Pose Sample:** One time-labelled observation of a phone's position, orientation, and tracking condition inside the Shared Arena Frame.
- **Phone Target Proxy:** The deliberate game objective centred on a player's phone. It is not a claim about the player's body.
- **Frame-Aligned Shot Claim:** A shot whose origin, direction, and time come from one captured view of the arena. A target is not required for a shot to be valid.
- **Shot Tracer:** The brief visible line shown for a shot. It is presentation of an instantaneous shot, not a travelling projectile, and every member sees one per shot.
- **Candidate:** A member the shooter's aim currently favours. Naming a candidate is targeting feedback, never permission to fire.
- **Lane Distance:** The straight-line separation, in metres inside the Shared Arena Frame, between a shooter and the target being judged.
- **Rewind Window:** The limited recent period in which a shot may be judged against a target's earlier observed position.
- **Pose Age:** How old the target observation used for a verdict is, relative to the moment the shot was fired.
- **Spatial Verdict:** The single accepted result of a shot: hit, miss, or rejected, with a visible reason when rejected.
- **Provisional Spatial Verdict:** The Authority Host's immediate result, shown as pending and never counted as damage.
- **Authoritative Spatial Verdict:** The backend's recorded result. It is the only result that changes health, ammunition, or score.
- **Authority Host:** The one member of a match who defines the Shared Arena Frame and produces Provisional Spatial Verdicts.
- **Tracking Quality:** Whether a phone currently has enough confidence in the shared arena to allow spatial play.
- **Projectile Worldline:** The path a persistent projectile occupies through the arena over time.
