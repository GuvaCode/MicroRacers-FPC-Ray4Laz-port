# MicroRacers

A small top-down arcade racer built with Free Pascal + Ray4Laz (raylib bindings for
Lazarus/FPC). The physics model is a deliberate arcade simplification of the original
SkiaMicroRacers prototype by Lara Miriam Tamy Reschke, ported from FMX/Skia4Delphi to
raylib.

    ┌────────────────────────────────────────────────────┐
    │  MicroRacers — top-down racer, procedural tracks   │
    │  Level 1  ·  Wins 0  ·  Lap 2 / 3                  │
    └────────────────────────────────────────────────────┘


## Features

- Procedural track generation — closed, star-shaped loops built in polar coordinates:
  R(θ) = BaseR · (1 + Σ Ai·cos(Ki·θ + Pi)) with integer Ki.
  Because every angle θ has exactly one radius, the track cannot self-intersect and
  cannot spiral. Each generation is retried until the maximum turn between adjacent
  segments is below MAX_ALLOWED_TURN (24°), so no corner is too sharp for the arcade
  steering model.

- Player controls — arrow keys. Arcade physics:
    - speed depends only on throttle/brake,
    - steering scales with speed,
    - reverse inverts steering like a real car,
    - asphalt vs. grass affects acceleration and friction.

- AI opponents — waypoint followers with:
    - "passed waypoint" detection via projection along the track (Dot > 0) and a
      speed-dependent switch radius,
    - look-ahead braking (slows into sharp corners),
    - lane offsets disabled on curves,
    - rubber-band scaling when a 2+ lap gap opens,
    - a fallback timer that force-switches a waypoint after 2 seconds.

- Progressive difficulty — each win increments FLevel, which raises AI top speed and
  acceleration by 6% per level (capped at +60%). The player also gains a small bonus.

- Chequered start/finish strip, dashed centre line, shoulder and asphalt layers.

- Camera — TCamera2D with GetWorldToScreen2D, smooth follow, no rotation
  (controls stay screen-aligned).


## Requirements

- Free Pascal Compiler 3.2+ (or Lazarus 2.2+)
- Ray4Laz — the raylib bindings for FPC/Lazarus: https://github.com/GuvaCode/Ray4Laz
- raylib runtime (.dll / .so) that matches the Ray4Laz version you have installed

Tested on Linux (FPC + raylib.so). Should build on Windows with the matching .dll.


## Project layout

    MicroRacers/
    ├── MicroRacers.pas     ← main unit (game loop, AI, physics, rendering)
    ├── game.pas            ← program entry point
    └── README.md


### Minimal game.pas

    program game;

    {$mode objfpc}{$H+}

    uses
      cmem, {$IFDEF LINUX} cthreads, {$ENDIF}
      raylib, MicroRacers;

    const
      screenWidth  = 1024;
      screenHeight = 768;

    var
      Game: TMicroRacers;
    begin
      InitWindow(screenWidth, screenHeight, 'MicroRacers');
      SetTargetFPS(60);
      SetTraceLogLevel(LOG_WARNING);

      Game := TMicroRacers.Create;
      Game.Resize(screenWidth, screenHeight);

      while not WindowShouldClose() do
      begin
        Game.HandleInput;
        Game.Update(GetFrameTime);
        Game.Draw;
      end;

      Game.Free;
      CloseWindow;
    end.


### Building

With Lazarus: open the .lpi, add MicroRacers.pas to the project, and build.

From the command line:

    fpc -Fu/path/to/ray4laz -Fu. game.pas

Make sure the raylib runtime is on the library path (LD_LIBRARY_PATH on Linux).


## Controls

    Key              Action
    ──────────────   ─────────────────────────
    Up               Accelerate
    Down             Brake / reverse
    Left / Right     Steer
    Enter            Start race / continue
    R (on Ready)     Regenerate track
    Esc              Quit


## Gameplay loop

    1. Ready screen — press Enter to start, R to generate a new track.
    2. Countdown — 3… 2… 1… Go.
    3. Racing — 3 laps against 3 AI cars.
    4. Finished — results screen:
         Win  → next level, AI a bit faster.
         Lose → retry the same level.


## Physics model

Arcade, not a simulator. Per car:

    - Car.Speed (scalar, signed) — the single source of truth for acceleration,
      braking and reverse.
    - Car.Angle — heading in degrees, always kept in [0, 360).
    - Position is integrated along the current heading:
          X += cos(Angle) · Speed · dt
          Y += sin(Angle) · Speed · dt

Steering rate is proportional to speed:

    TurnSpeed := 120 · (Speed / MaxSpeed)

so a stationary car cannot turn, and full-speed turns are sharper.

Surface check via IsOnTrack (point-to-segment distance across all track segments):

    On asphalt:  Accel = 350, Friction = 2.0
    On grass:    Accel = 100, Friction = 5.0

Collisions between cars push them apart and exchange a bit of forward momentum;
a small spin kick is added for feel.


## Track generation

    R(θ) = BaseR · (1 + A1·cos(2θ + φ1) + A2·cos(3θ + φ2) + A3·cos(5θ + φ3))

    BaseR = 720
    A1 ∈ [0.07, 0.12]
    A2 ∈ [0.04, 0.07]
    A3 ∈ [0.02, 0.04]
    φ1..φ3 random in [0, 2π)

Integer harmonic numbers (2, 3, 5) guarantee the loop closes exactly at θ = 2π.
The generator rejects any candidate whose maximum adjacent turn exceeds 24°, so the
AI never meets a corner it can't handle.

After generation, the straightest segment is found and used as the start/finish line.


## AI

Each AI car keeps a FTargetIndex into FTrackPoints. Per frame:

    1. Compute a steering target from the current waypoint (with a small lateral
       offset that is disabled on corners).

    2. Decide whether the waypoint is "passed":
         - the bare distance to the waypoint is within SwitchRadius, OR
         - the car is already ahead of the waypoint along the track direction
           (Dot > 0).

    3. Fallback: if the AI has been chasing the same waypoint for more than
       AI_WP_TIMEOUT = 2.0 s, force a switch.

    4. Look ahead one more waypoint; if the corner is sharp, reduce target speed
       (look-ahead braking).

    5. Apply rubber-band scaling on a 2+ lap gap.

This keeps the AI on the track even with procedural, curved circuits.


## Tuning

All knobs are const at the top of MicroRacers.pas.

    Constant              What it does                              Default
    ──────────────────    ──────────────────────────────────────    ───────
    BASE_RADIUS           Overall track size                        720
    NUM_POINTS            Waypoints per loop                        32
    MAX_ALLOWED_TURN      Reject tracks with sharper corners        24°
    FTrackWidth           Road width in world units                 180
    AI_BASE_SPEED         Level 1 AI top speed                      270
    AI_BASE_ACCEL         Level 1 AI acceleration                   420
    AI_WP_MIN_RADIUS      Min waypoint switch radius                70
    AI_WP_SPEED_FACTOR    How much switch radius grows with speed   0.30
    AI_WP_TIMEOUT         Fallback switch after this many seconds   2.0
    AI_CORNER_START       Corner angle at which braking begins      15°
    AI_CORNER_MIN_MUL     Slowest the AI goes into a corner         0.50
    LEVEL_STEP            AI speed bonus per won race               0.06
    PLAYER_BONUS          Player top-speed bonus per level (px/s)   5.0


## Credits

    - Original SkiaMicroRacers prototype:
        Lara Miriam Tamy Reschke — MIT license.

    - FPC + Ray4Laz port, procedural track, AI, progression:
        Gunko Vadim (@guvacode).

    - raylib:
        Ramon Santamaria and contributors.

    - Ray4Laz:
        Gunko Vadim (@guvacode) and contributors.


## License

MIT — see LICENSE for details.

You are free to use this code in personal and commercial projects, modify it, and
redistribute it, as long as the original copyright notice and license text are
preserved.


## Ideas for future work

    - Skid marks / dust particles on grass.
    - Minimap.
    - Save/load best lap times.
    - Split-screen or two-player mode.
    - Sound effects (InitAudioDevice + LoadSound).
    - Rain / night variants that change grip and visibility.
    - AI personalities (aggressive blocker vs. clean racer).
    - Replays: record (t, x, y, angle) per car and play back.
