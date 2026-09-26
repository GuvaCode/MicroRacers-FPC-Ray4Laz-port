program race;

{$mode objfpc}{$H+}

uses
  cmem, {$IFDEF LINUX} cthreads, {$ENDIF}
  SysUtils,
  raylib, raymath, MicroRacers;

const
  screenWidth  = 800;
  screenHeight = 600;

var
  Game: TMicroRacers;
  LastTime, Now: Double;
  Delta: Single;

begin
  // Initialization
  InitWindow(screenWidth, screenHeight, 'Micro Racers (Ray4Laz)');
  SetWindowState(FLAG_MSAA_4X_HINT);
  SetTargetFPS(60);
  SetTraceLogLevel(LOG_WARNING);

  Game := TMicroRacers.Create;
  Game.Resize(screenWidth, screenHeight);

  LastTime := GetTime;

  // Main game loop
  while not WindowShouldClose() do
  begin
    // --- Timing ---
    Now := GetTime;
    Delta := Single(Now - LastTime);
    LastTime := Now;

    // Ограничиваем дельту (защита от скачков при перетаскивании окна/паузе)
    if Delta > 0.1 then
      Delta := 0.1;

    // --- Update ---
    Game.HandleInput;
    Game.Update(Delta);

    // --- Draw ---
    Game.Draw;
  end;

  // De-Initialization
  Game.Free;
  CloseWindow;
end.
