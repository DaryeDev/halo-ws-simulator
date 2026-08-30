## 5.1.0

* Initial WebSocket-transport build, tracking `brilliant_ble` 5.1.0's public API.
* `BrilliantBluetooth` / `BrilliantDevice` / `BrilliantScannedDevice` backed by
  `HaloSimLink` (a single WebSocket to `halo-ws-simulator`).
* `sendString`, `sendData`, `sendMessage`, `uploadScript`, `clearDisplay`,
  break/reset/remove signals and the `stringResponse` / `dataResponse` /
  `connectionState` streams behave as on hardware.
* Not implemented: `BrilliantDfuDevice` (DFU/OTA).
