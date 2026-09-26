{*******************************************************************************
  MicroRacers (Top-Down Racer Prototype) — FPC + Ray4Laz port
********************************************************************************
  Physics model — 1:1 with the original SkiaMicroRacers:
    - Single scalar Speed per car.
    - Car always moves exactly along its heading (no slip, no drift).
    - Steering is proportional to Speed (no turning in place).
    - Reverse works by making Speed negative via the brake key.
    - Surface (asphalt/grass) modifies Accel and Friction only.

  Angle handling:
    - Car.Angle is always kept in [0, 360).

  Camera:
    - raylib TCamera2D + GetWorldToScreen2D.
    - Target smoothly follows the player.

  Track generation:
    - Star-shaped closed curve in polar coordinates:
        R(θ) = BaseR * (1 + Σ Ai·cos(Ki·θ + Pi)), integer Ki.
    - Regenerated until the max turn between adjacent segments is
      below MAX_ALLOWED_TURN.

  AI navigation:
    - Waypoints followed in order.
    - A waypoint is "passed" when the car is close enough OR has
      projected ahead of it along the track.
    - Fallback: force-switch after AI_WP_TIMEOUT seconds.
    - Speed-dependent switch radius prevents overshoot.
    - Look-ahead braking slows the AI into sharp corners.

  Rendering:
    - Each car: coloured body quad + black rectangular cabin.
    - Track: shoulder + asphalt + solid centre line + chequered start.

  Colors:
    - Car color is stored as TColorB and created via TColorB.Create.

  Math:
    - All distance / length computations use raymath helpers:
      Vector2Distance, Vector2Length, Vector2Subtract.

  Progression:
    - Winning a race increments FLevel (AI get faster).

  Author of original: Lara Miriam Tamy Reschke
  License: MIT
*******************************************************************************}
unit MicroRacers;

{$mode objfpc}{$H+}
{$rangechecks off}

interface

uses
  Classes, SysUtils, Math, Types,
  fgl,
  raylib, raymath;

type
  TGameState = (gsReady, gsCountdown, gsRacing, gsFinished);

  TTrackPoint = record
    X, Y: Single;
    Angle: Single;
  end;

  TCar = class
  public
    FTargetIndex: Integer;
    X, Y: Single;
    Angle: Single;
    Speed: Single;
    LapsCompleted: Integer;
    Name: string;
    Color: TColorB;
    IsPlayer: Boolean;
    CanCountLap: Boolean;
    Finished: Boolean;
    FinalRank: Integer;
    Offset: Single;
    WaypointTimer: Single;
    constructor Create(AName: string; AColor: TColorB; AIsPlayer: Boolean);
    procedure Reset(AX, AY: Single; AAngle: Single);
  end;

  TCarList = specialize TFPGObjectList<TCar>;

  TMicroRacers = class
  private
    FKeys: set of Byte;
    FCamera: TCamera2D;
    FTrackPoints: array of TTrackPoint;
    FTrackWidth: Single;
    FStartIndex: Integer;
    FGameState: TGameState;
    FCountdownTimer: Single;
    FRaceTimer: Single;
    FTotalLaps: Integer;
    FCars: TCarList;
    FPlayerCar: TCar;
    FLevel: Integer;
    FWins: Integer;

    procedure InitRace;
    procedure GenerateTrack;
    function  IsOnTrack(X, Y: Single; out DistFromCenter: Single): Boolean;
    procedure UpdateCar(Car: TCar; DeltaSec: Double);
    procedure UpdateAI (Car: TCar; DeltaSec: Double);
    procedure ResolveCollisions;
    procedure CheckLap(Car: TCar);
    procedure StartCountdown;
    procedure CheckRaceFinish;
    function  LevelMul: Single;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure Update(DeltaSec: Double);
    procedure Draw;
    procedure HandleInput;
    procedure Resize(AWidth, AHeight: Integer);
    function  GetGameState: TGameState;
  end;

function NormalizeAngle360(A: Single): Single;

implementation

const
  CAR_SIZE       = 25.0;
  CAR_VISUAL_LEN = 30;
  CAR_VISUAL_W   = 20;

  // --- Difficulty scaling ---
  LEVEL_STEP     = 0.06;
  LEVEL_MAX_MUL  = 1.60;
  PLAYER_BONUS   = 5.0;

  // --- Base AI (level 1) — slower than the player ---
  AI_BASE_SPEED  = 270.0;
  AI_BASE_ACCEL  = 420.0;

  // --- AI waypoint following ---
  AI_WP_MIN_RADIUS     = 70.0;
  AI_WP_SPEED_FACTOR   = 0.30;
  AI_OFFSET_LIMIT      = 15.0;
  AI_WP_TIMEOUT        = 2.0;

  // --- AI look-ahead braking ---
  AI_CORNER_START    = 15.0;
  AI_CORNER_FULL     = 90.0;
  AI_CORNER_MIN_MUL  = 0.50;

  // --- Track visual widths ---
  SHOULDER_EXTRA = 40.0;
  CENTRE_LINE_W  = 6.0;

  // --- Chequered start/finish strip ---
  FINISH_CELLS   = 12;
  FINISH_ROWS    = 3;

  // --- Track generator ---
  NUM_POINTS        = 32;
  BASE_RADIUS       = 720.0;
  WORLD_CENTER_X    = 1500.0;
  WORLD_CENTER_Y    = 1500.0;
  MAX_ALLOWED_TURN  = 24.0;
  MAX_GEN_ATTEMPTS  = 80;

{ Normalize angle to [0, 360) }
function NormalizeAngle360(A: Single): Single;
begin
  Result := A;
  while Result <    0 do Result := Result + 360;
  while Result >= 360 do Result := Result - 360;
end;

{ TCar }

constructor TCar.Create(AName: string; AColor: TColorB; AIsPlayer: Boolean);
begin
  inherited Create;
  Name := AName;
  Color := AColor;
  IsPlayer := AIsPlayer;
  LapsCompleted := 0;
  Finished := False;
  FinalRank := 0;
  FTargetIndex := 0;
  Speed := 0;
  WaypointTimer := 0;
end;

procedure TCar.Reset(AX, AY: Single; AAngle: Single);
begin
  X := AX;
  Y := AY;
  Angle := NormalizeAngle360(AAngle);
  Speed := 0;
  LapsCompleted := 0;
  CanCountLap := False;
  Finished := False;
  FinalRank := 0;
  WaypointTimer := 0;
end;

{ TMicroRacers }

constructor TMicroRacers.Create;
begin
  inherited Create;
  FKeys := [];
  FTotalLaps := 3;
  FCars := TCarList.Create(True);
  FLevel := 1;
  FWins := 0;

  FCamera.offset.X := GetScreenWidth  / 2;
  FCamera.offset.Y := GetScreenHeight / 2;
  FCamera.target.X := 0;
  FCamera.target.Y := 0;
  FCamera.rotation := 0;
  FCamera.zoom := 1.0;

  InitRace;

  FCamera.target.X := FPlayerCar.X;
  FCamera.target.Y := FPlayerCar.Y;
end;

destructor TMicroRacers.Destroy;
begin
  FCars.Free;
  inherited;
end;

function TMicroRacers.LevelMul: Single;
begin
  Result := 1.0 + (FLevel - 1) * LEVEL_STEP;
  if Result > LEVEL_MAX_MUL then
    Result := LEVEL_MAX_MUL;
end;

{ ---------- Procedural track generation ---------- }

procedure TMicroRacers.GenerateTrack;
var
  I: Integer;
  Theta, R: Single;
  NoiseA1, NoiseA2, NoiseA3: Single;
  NoiseP1, NoiseP2, NoiseP3: Single;
  K1, K2, K3: Integer;
  D: TVector2;
  BestIdx: Integer;
  BestTurn, TurnDiff, AngleA, AngleB: Single;
  Attempt: Integer;
  OK: Boolean;
begin
  SetLength(FTrackPoints, NUM_POINTS);

  K1 := 2;
  K2 := 3;
  K3 := 5;

  BestIdx := 0;
  Attempt := 0;
  OK := False;

  while (not OK) and (Attempt < MAX_GEN_ATTEMPTS) do
  begin
    Inc(Attempt);
    OK := True;

    NoiseA1 := 0.07 + Random * 0.05;
    NoiseA2 := 0.04 + Random * 0.03;
    NoiseA3 := 0.02 + Random * 0.02;

    NoiseP1 := Random * 2 * Pi;
    NoiseP2 := Random * 2 * Pi;
    NoiseP3 := Random * 2 * Pi;

    for I := 0 to NUM_POINTS - 1 do
    begin
      Theta := 2 * Pi * I / NUM_POINTS;
      R := BASE_RADIUS * (1
        + NoiseA1 * Cos(K1 * Theta + NoiseP1)
        + NoiseA2 * Cos(K2 * Theta + NoiseP2)
        + NoiseA3 * Cos(K3 * Theta + NoiseP3));

      FTrackPoints[I].X := WORLD_CENTER_X + Cos(Theta) * R;
      FTrackPoints[I].Y := WORLD_CENTER_Y + Sin(Theta) * R;
    end;

    for I := 0 to NUM_POINTS - 1 do
    begin
      D := Vector2Subtract(
             Vector2Create(FTrackPoints[(I+1) mod NUM_POINTS].X,
                           FTrackPoints[(I+1) mod NUM_POINTS].Y),
             Vector2Create(FTrackPoints[I].X, FTrackPoints[I].Y));
      FTrackPoints[I].Angle := RadToDeg(ArcTan2(D.Y, D.X));
    end;

    for I := 0 to NUM_POINTS - 1 do
    begin
      AngleA := FTrackPoints[I].Angle;
      AngleB := FTrackPoints[(I+1) mod NUM_POINTS].Angle;
      TurnDiff := Abs(AngleB - AngleA);
      if TurnDiff > 180 then TurnDiff := 360 - TurnDiff;

      if TurnDiff > MAX_ALLOWED_TURN then
      begin
        OK := False;
        Break;
      end;
    end;
  end;

  BestIdx := 0;
  BestTurn := 99999;
  for I := 0 to NUM_POINTS - 1 do
  begin
    AngleA := FTrackPoints[I].Angle;
    AngleB := FTrackPoints[(I+1) mod NUM_POINTS].Angle;
    TurnDiff := Abs(AngleB - AngleA);
    if TurnDiff > 180 then TurnDiff := 360 - TurnDiff;
    if TurnDiff < BestTurn then
    begin
      BestTurn := TurnDiff;
      BestIdx := I;
    end;
  end;
  FStartIndex := BestIdx;
end;

procedure TMicroRacers.InitRace;
var
  I: Integer;
  Car: TCar;
  Colors: array[0..3] of TColorB;
  StartPtX, StartPtY, StartAng: Single;
  AlongOffset, LateralOffset: Single;
  DirX, DirY, PerpX, PerpY: Single;
begin
  Colors[0].Create(255,   0,   0, 255);   // player — red
  Colors[1].Create(  0,   0, 255, 255);   // AI 1   — blue
  Colors[2].Create(  0, 255,   0, 255);   // AI 2   — green
  Colors[3].Create(255, 255,   0, 255);   // AI 3   — yellow

  FTrackWidth := 180;
  GenerateTrack;
  FCars.Clear;

  StartPtX := FTrackPoints[FStartIndex].X;
  StartPtY := FTrackPoints[FStartIndex].Y;
  StartAng := FTrackPoints[FStartIndex].Angle;

  DirX  := Cos(DegToRad(StartAng));
  DirY  := Sin(DegToRad(StartAng));
  PerpX := -DirY;
  PerpY :=  DirX;

  for I := 0 to 3 do
  begin
    if I = 0 then
      Car := TCar.Create('Player', Colors[I], True)
    else
      Car := TCar.Create('AI ' + IntToStr(I), Colors[I], False);

    AlongOffset   := -I * 45;
    LateralOffset := ((I mod 2) * 40) - 20;

    Car.Reset(
      StartPtX + DirX * AlongOffset + PerpX * LateralOffset,
      StartPtY + DirY * AlongOffset + PerpY * LateralOffset,
      StartAng);

    Car.Offset := ((I * 40) mod 100) - 50;
    if Car.Offset >  AI_OFFSET_LIMIT then Car.Offset :=  AI_OFFSET_LIMIT;
    if Car.Offset < -AI_OFFSET_LIMIT then Car.Offset := -AI_OFFSET_LIMIT;

    Car.FTargetIndex := (FStartIndex + 1) mod NUM_POINTS;
    Car.WaypointTimer := 0;

    FCars.Add(Car);
  end;

  FPlayerCar := FCars[0];
  FCamera.target.X := FPlayerCar.X;
  FCamera.target.Y := FPlayerCar.Y;
  FCamera.rotation := 0;
  FCamera.zoom := 1.0;

  FGameState := gsReady;
  FCountdownTimer := 0;
  FRaceTimer := 0;
end;

function TMicroRacers.IsOnTrack(X, Y: Single; out DistFromCenter: Single): Boolean;
var
  I: Integer;
  P1X, P1Y, P2X, P2Y: Single;
  LineX, LineY, PointX, PointY: Single;
  LineLen, ProjT, ProjX, ProjY: Single;
  MinDist: Single;
begin
  MinDist := 99999;

  for I := 0 to High(FTrackPoints) do
  begin
    P1X := FTrackPoints[I].X;
    P1Y := FTrackPoints[I].Y;
    P2X := FTrackPoints[(I + 1) mod Length(FTrackPoints)].X;
    P2Y := FTrackPoints[(I + 1) mod Length(FTrackPoints)].Y;

    LineX := P2X - P1X;
    LineY := P2Y - P1Y;
    PointX := X - P1X;
    PointY := Y - P1Y;

    LineLen := Vector2Length(Vector2Create(LineX, LineY));
    if LineLen > 0 then
    begin
      ProjT := (PointX * LineX + PointY * LineY) / (LineLen * LineLen);
      ProjT := EnsureRange(ProjT, 0, 1);
      ProjX := P1X + ProjT * LineX;
      ProjY := P1Y + ProjT * LineY;

      DistFromCenter := Vector2Distance(
                          Vector2Create(X, Y),
                          Vector2Create(ProjX, ProjY));
      if DistFromCenter < MinDist then
        MinDist := DistFromCenter;
    end;
  end;

  DistFromCenter := MinDist;
  Result := (MinDist <= FTrackWidth / 2);
end;

procedure TMicroRacers.HandleInput;
begin
  FKeys := [];
  if IsKeyDown(KEY_LEFT)  then Include(FKeys, 0);
  if IsKeyDown(KEY_RIGHT) then Include(FKeys, 1);
  if IsKeyDown(KEY_UP)    then Include(FKeys, 2);
  if IsKeyDown(KEY_DOWN)  then Include(FKeys, 3);

  if (FGameState = gsReady) and IsKeyPressed(KEY_ENTER) then
    StartCountdown;

  if (FGameState = gsReady) and IsKeyPressed(KEY_R) then
    InitRace;

  if (FGameState = gsFinished) and IsKeyPressed(KEY_ENTER) then
  begin
    if FPlayerCar.FinalRank = 1 then
      Inc(FLevel);

    InitRace;
    StartCountdown;
  end;
end;

procedure TMicroRacers.Update(DeltaSec: Double);
var
  I: Integer;
  Car: TCar;
begin
  if FGameState = gsCountdown then
  begin
    FCountdownTimer := FCountdownTimer - DeltaSec;
    if FCountdownTimer <= 0 then
    begin
      FCountdownTimer := 0;
      FGameState := gsRacing;
    end;
  end;

  if FGameState = gsRacing then
    FRaceTimer := FRaceTimer + DeltaSec;

  if (FGameState = gsRacing) or (FGameState = gsCountdown) then
  begin
    for I := 0 to FCars.Count - 1 do
    begin
      Car := FCars[I];
      if not Car.Finished then
      begin
        if Car.IsPlayer then
          UpdateCar(Car, DeltaSec)
        else
          UpdateAI(Car, DeltaSec);
      end;
    end;
    ResolveCollisions;
  end;

  FCamera.offset.X := GetScreenWidth  / 2;
  FCamera.offset.Y := GetScreenHeight / 2;

  FCamera.target.X := FCamera.target.X +
    (FPlayerCar.X - FCamera.target.X) * 5 * DeltaSec;
  FCamera.target.Y := FCamera.target.Y +
    (FPlayerCar.Y - FCamera.target.Y) * 5 * DeltaSec;

  FCamera.rotation := 0;
  FCamera.zoom := 1.0;
end;

{ ---------- Player physics ---------- }
procedure TMicroRacers.UpdateCar(Car: TCar; DeltaSec: Double);
var
  Left, Right, Up, Down: Boolean;
  Accel, Friction, TurnSpeed: Single;
  Rad, VX, VY: Single;
  OnTrack: Boolean;
  DistFromCenter: Single;
  MaxSpeed: Single;
begin
  Left  := 0 in FKeys;
  Right := 1 in FKeys;
  Up    := 2 in FKeys;
  Down  := 3 in FKeys;

  if FGameState = gsCountdown then
  begin
    Up := False; Down := False; Left := False; Right := False;
  end;

  OnTrack := IsOnTrack(Car.X, Car.Y, DistFromCenter);

  Accel := 350;
  if not OnTrack then Accel := 100;
  Friction := 2.0;
  if not OnTrack then Friction := 5.0;

  MaxSpeed := 300 + (FLevel - 1) * PLAYER_BONUS;

  if Up then
    Car.Speed := Min(Car.Speed + Accel * DeltaSec, MaxSpeed)
  else if Down then
    Car.Speed := Max(Car.Speed - Accel * DeltaSec, -150)
  else
    Car.Speed := Car.Speed - (Car.Speed * Friction * DeltaSec);

  if Abs(Car.Speed) > 5 then
  begin
    TurnSpeed := 120 * (Car.Speed / MaxSpeed);
    if Left  then Car.Angle := Car.Angle - TurnSpeed * DeltaSec;
    if Right then Car.Angle := Car.Angle + TurnSpeed * DeltaSec;
    Car.Angle := NormalizeAngle360(Car.Angle);
  end;

  Rad := DegToRad(Car.Angle);
  VX := Cos(Rad) * Car.Speed * DeltaSec;
  VY := Sin(Rad) * Car.Speed * DeltaSec;
  Car.X := Car.X + VX;
  Car.Y := Car.Y + VY;

  CheckLap(Car);
end;

{ ---------- AI physics ---------- }
procedure TMicroRacers.UpdateAI(Car: TCar; DeltaSec: Double);
var
  TargetPt, NextPt, FarPt: TTrackPoint;
  DesiredAngle, AngleDiff: Single;
  TurnSpeed, Accel: Single;
  Rad, VX, VY: Single;
  DistToTarget: Single;
  PlainDist: Single;
  PerpX, PerpY: Single;
  OffsetX, OffsetY: Single;
  UseOffset: Single;
  AngleDelta: Single;
  OnTrack: Boolean;
  DistFromCenter: Single;
  LapDiff: Integer;
  RubberMul: Single;
  LevelFactor: Single;
  MaxAI: Single;
  Seg: TVector2;
  Dot: Single;
  SwitchRadius: Single;
  LookDelta, FarDelta: Single;
  CornerMul: Single;
  Switched: Boolean;
begin
  if FGameState <> gsRacing then
    Exit;

  TargetPt := FTrackPoints[Car.FTargetIndex];
  NextPt   := FTrackPoints[(Car.FTargetIndex + 1) mod Length(FTrackPoints)];
  FarPt    := FTrackPoints[(Car.FTargetIndex + 2) mod Length(FTrackPoints)];

  AngleDelta := Abs(TargetPt.Angle - NextPt.Angle);
  if AngleDelta > 180 then AngleDelta := 360 - AngleDelta;

  if AngleDelta > 12 then
    UseOffset := 0
  else
    UseOffset := Car.Offset;

  PerpX := -Sin(DegToRad(TargetPt.Angle));
  PerpY :=  Cos(DegToRad(TargetPt.Angle));
  OffsetX := PerpX * UseOffset;
  OffsetY := PerpY * UseOffset;

  DistToTarget := Vector2Distance(
                    Vector2Create(Car.X, Car.Y),
                    Vector2Create(TargetPt.X + OffsetX,
                                  TargetPt.Y + OffsetY));

  PlainDist := Vector2Distance(
                 Vector2Create(Car.X, Car.Y),
                 Vector2Create(TargetPt.X, TargetPt.Y));

  Seg := Vector2Subtract(
           Vector2Create(NextPt.X, NextPt.Y),
           Vector2Create(TargetPt.X, TargetPt.Y));

  Dot := Vector2DotProduct(
           Vector2Subtract(
             Vector2Create(Car.X, Car.Y),
             Vector2Create(TargetPt.X, TargetPt.Y)),
           Seg);

  SwitchRadius := AI_WP_MIN_RADIUS + Abs(Car.Speed) * AI_WP_SPEED_FACTOR;

  Car.WaypointTimer := Car.WaypointTimer + DeltaSec;

  Switched := False;

  if (PlainDist < 10) or
     (PlainDist < SwitchRadius) or
     (Dot > 0) then
    Switched := True;

  if Car.WaypointTimer > AI_WP_TIMEOUT then
    Switched := True;

  if Switched then
  begin
    Car.FTargetIndex := (Car.FTargetIndex + 1) mod Length(FTrackPoints);
    Car.WaypointTimer := 0;

    TargetPt := FTrackPoints[Car.FTargetIndex];
    NextPt   := FTrackPoints[(Car.FTargetIndex + 1) mod Length(FTrackPoints)];
    FarPt    := FTrackPoints[(Car.FTargetIndex + 2) mod Length(FTrackPoints)];

    AngleDelta := Abs(TargetPt.Angle - NextPt.Angle);
    if AngleDelta > 180 then AngleDelta := 360 - AngleDelta;

    if AngleDelta > 12 then
      UseOffset := 0
    else
      UseOffset := Car.Offset;

    OffsetX := -Sin(DegToRad(TargetPt.Angle)) * UseOffset;
    OffsetY :=  Cos(DegToRad(TargetPt.Angle)) * UseOffset;

    DistToTarget := Vector2Distance(
                      Vector2Create(Car.X, Car.Y),
                      Vector2Create(TargetPt.X + OffsetX,
                                    TargetPt.Y + OffsetY));
  end;

  DesiredAngle := RadToDeg(ArcTan2((TargetPt.Y + OffsetY) - Car.Y,
                                   (TargetPt.X + OffsetX) - Car.X));
  DesiredAngle := NormalizeAngle360(DesiredAngle);

  AngleDiff := DesiredAngle - Car.Angle;
  if AngleDiff >  180 then AngleDiff := AngleDiff - 360;
  if AngleDiff < -180 then AngleDiff := AngleDiff + 360;

  OnTrack := IsOnTrack(Car.X, Car.Y, DistFromCenter);

  LapDiff := FPlayerCar.LapsCompleted - Car.LapsCompleted;
  RubberMul := 1.0;
  if LapDiff >= 2 then
    RubberMul := 1.12
  else if LapDiff <= -2 then
    RubberMul := 0.92;

  LevelFactor := LevelMul;

  LookDelta := Abs(TargetPt.Angle - NextPt.Angle);
  if LookDelta > 180 then LookDelta := 360 - LookDelta;

  FarDelta := Abs(NextPt.Angle - FarPt.Angle);
  if FarDelta > 180 then FarDelta := 360 - FarDelta;

  if FarDelta > LookDelta then LookDelta := FarDelta;

  CornerMul := 1.0;
  if LookDelta > AI_CORNER_START then
  begin
    CornerMul := 1.0 - (LookDelta - AI_CORNER_START) /
                      (AI_CORNER_FULL - AI_CORNER_START);
    if CornerMul < AI_CORNER_MIN_MUL then
      CornerMul := AI_CORNER_MIN_MUL;
  end;

  Accel := AI_BASE_ACCEL * RubberMul * LevelFactor;
  if not OnTrack then Accel := Accel * 0.4;
  if Abs(AngleDiff) > 60 then Accel := Accel * 0.6;
  Accel := Accel * CornerMul;

  MaxAI := AI_BASE_SPEED * RubberMul * LevelFactor * CornerMul;
  Car.Speed := Min(Car.Speed + Accel * DeltaSec, MaxAI);

  if Abs(Car.Speed) > 5 then
  begin
    TurnSpeed := 150 * (Car.Speed / 320) * (0.7 + 0.3 * LevelFactor);
    if AngleDiff < 0 then
      Car.Angle := Car.Angle - Min(Abs(AngleDiff), TurnSpeed * DeltaSec)
    else
      Car.Angle := Car.Angle + Min(AngleDiff, TurnSpeed * DeltaSec);
    Car.Angle := NormalizeAngle360(Car.Angle);
  end;

  Rad := DegToRad(Car.Angle);
  VX := Cos(Rad) * Car.Speed * DeltaSec;
  VY := Sin(Rad) * Car.Speed * DeltaSec;
  Car.X := Car.X + VX;
  Car.Y := Car.Y + VY;

  CheckLap(Car);
end;

procedure TMicroRacers.ResolveCollisions;
var
  I, J: Integer;
  CarA, CarB: TCar;
  DX, DY, Dist: Single;
  Overlap: Single;
  PushX, PushY: Single;
  SpeedDiff: Single;
begin
  for I := 0 to FCars.Count - 1 do
  begin
    for J := I + 1 to FCars.Count - 1 do
    begin
      CarA := FCars[I];
      CarB := FCars[J];
      DX := CarB.X - CarA.X;
      DY := CarB.Y - CarA.Y;
      Dist := Vector2Length(Vector2Create(DX, DY));

      if Dist < CAR_SIZE then
      begin
        if Dist = 0 then
        begin
          Dist := 0.1;
          DX := 1;
          DY := 0;
        end;

        Overlap := CAR_SIZE - Dist;
        PushX := (DX / Dist) * (Overlap / 2);
        PushY := (DY / Dist) * (Overlap / 2);

        CarA.X := CarA.X - PushX;
        CarA.Y := CarA.Y - PushY;
        CarB.X := CarB.X + PushX;
        CarB.Y := CarB.Y + PushY;

        SpeedDiff := (CarA.Speed - CarB.Speed) * 0.5;
        CarA.Speed := CarA.Speed - SpeedDiff * 0.5;
        CarB.Speed := CarB.Speed + SpeedDiff * 0.5;

        CarA.Angle := NormalizeAngle360(CarA.Angle - (DX / Dist) * 5);
        CarB.Angle := NormalizeAngle360(CarB.Angle + (DX / Dist) * 5);
      end;
    end;
  end;
end;

procedure TMicroRacers.CheckLap(Car: TCar);
var
  DistToStart: Single;
  AngleDiff: Single;
  I: Integer;
  StartPt: TTrackPoint;
begin
  StartPt := FTrackPoints[FStartIndex];

  DistToStart := Vector2Distance(
                   Vector2Create(Car.X, Car.Y),
                   Vector2Create(StartPt.X, StartPt.Y));

  if DistToStart < 100 then
  begin
    if not Car.CanCountLap then
    begin
      AngleDiff := Abs(Car.Angle - StartPt.Angle);
      if AngleDiff > 180 then
        AngleDiff := 360 - AngleDiff;

      if AngleDiff < 70 then
      begin
        if Car.LapsCompleted = 0 then
          Car.LapsCompleted := 1
        else
          Car.LapsCompleted := Car.LapsCompleted + 1;

        Car.CanCountLap := True;

        if (Car.LapsCompleted > FTotalLaps) and not Car.Finished then
        begin
          Car.Finished := True;

          Car.FinalRank := 1;
          for I := 0 to FCars.Count - 1 do
            if (FCars[I] <> Car) and FCars[I].Finished then
              Inc(Car.FinalRank);

          CheckRaceFinish;
        end;
      end;
    end;
  end
  else
  begin
    if DistToStart > 170 then
      Car.CanCountLap := False;
  end;
end;

procedure TMicroRacers.StartCountdown;
begin
  FGameState := gsCountdown;
  FCountdownTimer := 3.0;
  FRaceTimer := 0;
end;

procedure TMicroRacers.CheckRaceFinish;
var
  I, FinishedCount: Integer;
begin
  FinishedCount := 0;
  for I := 0 to FCars.Count - 1 do
    if FCars[I].Finished then
      Inc(FinishedCount);

  if FinishedCount >= FCars.Count then
  begin
    if FPlayerCar.FinalRank = 1 then
      Inc(FWins);

    FGameState := gsFinished;
  end;
end;

{ ---------- Rendering ---------- }

procedure TMicroRacers.Resize(AWidth, AHeight: Integer);
begin
  FCamera.offset.X := AWidth  / 2;
  FCamera.offset.Y := AHeight / 2;
end;

procedure TMicroRacers.Draw;
var
  I: Integer;
  Pt1, Pt2: TTrackPoint;
  ScreenW, ScreenH: Integer;

  StartP: TTrackPoint;
  SFAng, SFNX, SFNY, SFTX, SFTY: Single;
  CellW, CellH, HalfW, HalfH: Single;
  Col, Row, ColFrom, ColTo, RowFrom, RowTo: Integer;
  CXw, CYw: Single;
  CellCol: TColorB;
  V0, V1, V2, V3: TVector2;

  CountdownInt: Integer;

  function WorldToScreen(WX, WY: Single): TVector2;
  begin
    Result := GetWorldToScreen2D(Vector2Create(WX, WY), FCamera);
  end;

  procedure DrawCarBody(C: TCar);
  var
    P: TVector2;
    H, W: Single;
    Rad, CosA, SinA: Single;
    A, B, D, E: TVector2;
    CabFwd, CabBack, CabHalfW, CabHalfH: Single;
    CA, CB, CC, CD: TVector2;
    CarCol: TColorB;
    CabCol: TColorB;
  begin
    P := WorldToScreen(C.X, C.Y);
    H := CAR_VISUAL_LEN / 2;
    W := CAR_VISUAL_W   / 2;
    Rad  := DegToRad(C.Angle);
    CosA := Cos(Rad);
    SinA := Sin(Rad);

    CarCol := C.Color;
    CabCol.Create(0, 0, 0, 255);

    { --- Body quad --- }
    A.X := P.X + H * CosA - W * SinA;
    A.Y := P.Y + H * SinA + W * CosA;

    B.X := P.X + H * CosA + W * SinA;
    B.Y := P.Y + H * SinA - W * CosA;

    D.X := P.X - H * CosA + W * SinA;
    D.Y := P.Y - H * SinA - W * CosA;

    E.X := P.X - H * CosA - W * SinA;
    E.Y := P.Y - H * SinA + W * CosA;

    DrawTriangle(A, B, D, CarCol);
    DrawTriangle(A, D, E, CarCol);

    { --- Cabin --- }
    CabFwd  := H * 0.30;
    CabBack := H * 0.05;

    CabHalfW := W * 0.65;
    CabHalfH := H * 0.20;

    CA.X := P.X + (CabFwd + CabHalfH) * CosA - CabHalfW * SinA;
    CA.Y := P.Y + (CabFwd + CabHalfH) * SinA + CabHalfW * CosA;

    CB.X := P.X + (CabFwd + CabHalfH) * CosA + CabHalfW * SinA;
    CB.Y := P.Y + (CabFwd + CabHalfH) * SinA - CabHalfW * CosA;

    CC.X := P.X + (CabFwd - CabBack) * CosA + CabHalfW * SinA;
    CC.Y := P.Y + (CabFwd - CabBack) * SinA - CabHalfW * CosA;

    CD.X := P.X + (CabFwd - CabBack) * CosA - CabHalfW * SinA;
    CD.Y := P.Y + (CabFwd - CabBack) * SinA + CabHalfW * CosA;

    DrawTriangle(CA, CB, CC, CabCol);
    DrawTriangle(CA, CC, CD, CabCol);
  end;

begin
  BeginDrawing;
  try
    ClearBackground(ColorCreate(46, 125, 50, 255));

    ScreenW := GetScreenWidth;
    ScreenH := GetScreenHeight;

    { --- Track: shoulder --- }
    for I := 0 to High(FTrackPoints) do
    begin
      Pt1 := FTrackPoints[I];
      Pt2 := FTrackPoints[(I + 1) mod Length(FTrackPoints)];
      DrawLineEx(WorldToScreen(Pt1.X, Pt1.Y),
                 WorldToScreen(Pt2.X, Pt2.Y),
                 FTrackWidth + SHOULDER_EXTRA,
                 ColorCreate(120, 100, 60, 255));
    end;
    for I := 0 to High(FTrackPoints) do
      DrawCircleV(WorldToScreen(FTrackPoints[I].X, FTrackPoints[I].Y),
                  (FTrackWidth + SHOULDER_EXTRA) / 2,
                  ColorCreate(120, 100, 60, 255));

    { --- Track: asphalt --- }
    for I := 0 to High(FTrackPoints) do
    begin
      Pt1 := FTrackPoints[I];
      Pt2 := FTrackPoints[(I + 1) mod Length(FTrackPoints)];
      DrawLineEx(WorldToScreen(Pt1.X, Pt1.Y),
                 WorldToScreen(Pt2.X, Pt2.Y),
                 FTrackWidth, ColorCreate(58, 58, 58, 255));
    end;
    for I := 0 to High(FTrackPoints) do
      DrawCircleV(WorldToScreen(FTrackPoints[I].X, FTrackPoints[I].Y),
                  FTrackWidth / 2, ColorCreate(58, 58, 58, 255));

    { --- Track: solid centre line --- }
    for I := 0 to High(FTrackPoints) do
    begin
      Pt1 := FTrackPoints[I];
      Pt2 := FTrackPoints[(I + 1) mod Length(FTrackPoints)];
      DrawLineEx(WorldToScreen(Pt1.X, Pt1.Y),
                 WorldToScreen(Pt2.X, Pt2.Y),
                 CENTRE_LINE_W, ColorCreate(255, 255, 255, 255));
    end;

    { --- Start / finish chequered strip --- }
    StartP := FTrackPoints[FStartIndex];
    SFAng := DegToRad(StartP.Angle);

    SFNX := -Sin(SFAng);  SFNY := Cos(SFAng);
    SFTX :=  Cos(SFAng);  SFTY := Sin(SFAng);

    CellW := FTrackWidth / FINISH_CELLS;
    CellH := CellW;
    HalfW := CellW / 2;
    HalfH := CellH / 2;

    ColFrom := -(FINISH_CELLS div 2);
    ColTo   := ColFrom + FINISH_CELLS - 1;

    RowFrom := -(FINISH_ROWS div 2);
    RowTo   := RowFrom + FINISH_ROWS - 1;

    for Col := ColFrom to ColTo do
    begin
      for Row := RowFrom to RowTo do
      begin
        CXw := StartP.X
             + SFNX * (Col + 0.5) * CellW
             + SFTX * (Row + 0.5) * CellH;
        CYw := StartP.Y
             + SFNY * (Col + 0.5) * CellW
             + SFTY * (Row + 0.5) * CellH;

        V0.X := CXw + SFNX * (-HalfW) + SFTX * (-HalfH);
        V0.Y := CYw + SFNY * (-HalfW) + SFTY * (-HalfH);

        V1.X := CXw + SFNX * ( HalfW) + SFTX * (-HalfH);
        V1.Y := CYw + SFNY * ( HalfW) + SFTY * (-HalfH);

        V2.X := CXw + SFNX * ( HalfW) + SFTX * ( HalfH);
        V2.Y := CYw + SFNY * ( HalfW) + SFTY * ( HalfH);

        V3.X := CXw + SFNX * (-HalfW) + SFTX * ( HalfH);
        V3.Y := CYw + SFNY * (-HalfW) + SFTY * ( HalfH);

        V0 := WorldToScreen(V0.X, V0.Y);
        V1 := WorldToScreen(V1.X, V1.Y);
        V2 := WorldToScreen(V2.X, V2.Y);
        V3 := WorldToScreen(V3.X, V3.Y);

        if Odd(Col + Row) then
          CellCol := ColorCreate(20, 20, 20, 255)
        else
          CellCol := ColorCreate(245, 245, 245, 255);

        DrawTriangle(V0, V1, V2, CellCol);
        DrawTriangle(V0, V2, V3, CellCol);
      end;
    end;

    { --- Cars --- }
    for I := 0 to FCars.Count - 1 do
      DrawCarBody(FCars[I]);

    { --- HUD --- }
    case FGameState of
      gsReady:
        begin
          DrawText('MICRO RACERS', 40, 40, 40,
                   ColorCreate(255, 255, 255, 255));
          DrawText(PChar(Format('Level %d   Wins %d', [FLevel, FWins])),
                   40, 100, 24, ColorCreate(255, 230, 60, 255));
          DrawText('Press ENTER to start', 40, 140, 20,
                   ColorCreate(255, 255, 255, 255));
          DrawText('Press R to generate a new track', 40, 170, 20,
                   ColorCreate(200, 220, 255, 255));
        end;
      gsCountdown:
        begin
          CountdownInt := Ceil(FCountdownTimer);
          if CountdownInt < 0 then CountdownInt := 0;

          DrawText(PChar(IntToStr(CountdownInt)),
                   ScreenW div 2 - 25, ScreenH div 2 - 60,
                   120, ColorCreate(255, 255, 255, 255));
          DrawText(PChar(Format('LEVEL %d', [FLevel])), 40, 40, 30,
                   ColorCreate(255, 220, 0, 255));
        end;
      gsRacing:
        begin
          DrawText(PChar(Format('Lap: %d / %d',
                     [FPlayerCar.LapsCompleted, FTotalLaps])),
                   10, 10, 20, ColorCreate(255, 255, 255, 255));
          DrawText(PChar(Format('Time: %.2f', [FRaceTimer])),
                   10, 40, 20, ColorCreate(255, 255, 255, 255));
          DrawText(PChar(Format('Level: %d   Wins: %d', [FLevel, FWins])),
                   10, 70, 20, ColorCreate(200, 220, 255, 255));
        end;
      gsFinished:
        begin
          if FPlayerCar.FinalRank = 1 then
          begin
            DrawText('YOU WIN!', 40, 40, 48,
                     ColorCreate(255, 230, 60, 255));
            DrawText(PChar(Format('Level %d cleared. Next: %d',
                       [FLevel, FLevel + 1])),
                     40, 110, 24, ColorCreate(255, 255, 255, 255));
          end
          else
          begin
            DrawText('YOU LOST', 40, 40, 48,
                     ColorCreate(255, 80, 80, 255));
            DrawText(PChar(Format('Finished %d of %d',
                       [FPlayerCar.FinalRank, FCars.Count])),
                     40, 110, 24, ColorCreate(255, 255, 255, 255));
          end;
          DrawText(PChar(Format('Wins total: %d', [FWins])),
                   40, 150, 20, ColorCreate(200, 220, 255, 255));
          DrawText('Press ENTER to continue', 40, 190, 20,
                   ColorCreate(255, 255, 255, 255));
        end;
    end;

    DrawFPS(ScreenW - 90, 10);
  finally
    EndDrawing;
  end;
end;

function TMicroRacers.GetGameState: TGameState;
begin
  Result := FGameState;
end;

end.
