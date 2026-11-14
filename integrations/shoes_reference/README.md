# Shoes gait analysis

## Main commands

- `runMqttGaitLowLatency` starts gateway selection, calibration, recording,
  live plots, and CSV logging.
- `runAllTests` runs the maintained automated regression suite.
- `replayTrajectoryCalibration` replays the saved straight-walk calibration
  data and evaluates trajectory parameters.
- `analyzeGaitLowLatencyLog(fileName)` plots diagnostics for a recorded gait
  state CSV.

## Project layout

- `src/` contains the maintained runtime implementation.
- `tests/` contains automated MATLAB tests.
- `data/calibration_walks/` is local-only and is not committed to Git.
- `log/` contains timestamped recording sessions.
- `diagnostics/` is local-only and is not committed to Git.
- The device manual remains local and is not committed to Git.
- The xIMU third-party reference remains local and is not on the runtime path.

Run the project through the commands above rather than adding every project
folder to the MATLAB path. `setupGaitProject` adds only maintained source code.

## Sample time

Formal calibration, gait analysis, trajectory integration, and plots use the
timestamp carried in each MQTT payload. The left gateway is the reference
clock, and a constant correction maps right-foot timestamps into that clock.

Before connecting, the UI can optionally enable hard-board tap alignment. If
it is not enabled, the program automatically estimates the same constant from
several seconds of callback arrival statistics before enabling calibration.
MATLAB callback time is retained for transport diagnostics only.

Each session includes `time_alignment_<timestamp>.csv`. Decoded sensor logs
store aligned time, raw gateway time, callback arrival time, alignment method,
and the applied correction as separate columns.

The published main program reads MQTT host, username, password and optional
gateway defaults from `MEDVISION_SHOES_MQTT_HOST`,
`MEDVISION_SHOES_MQTT_USERNAME`, `MEDVISION_SHOES_MQTT_PASSWORD`,
`MEDVISION_SHOES_LEFT_GATEWAY_ID` and `MEDVISION_SHOES_RIGHT_GATEWAY_ID`.
