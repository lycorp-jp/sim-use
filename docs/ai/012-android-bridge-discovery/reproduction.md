# Android bridge endpoint discovery: Reproduction

Use an isolated Android emulator. The example serial is `emulator-5580`.
Run it headless if video tests also use it. Put Android platform-tools on PATH.

## Occupied device port

Build the bridge with `scripts/build-bridge.sh` and the CLI with `make build`.
The device must already have the bridge package installed so its shell provider
can stop the current listener.

In the first terminal:

```bash
export SERIAL=emulator-5580
.build/debug/sim-use daemon stop --device "$SERIAL"
adb -s "$SERIAL" shell content insert \
  --uri content://com.linecorp.simuse.devicebridge/toggle_socket_server \
  --bind enabled:b:false

cat > /tmp/sim-use-port-occupant.sh <<'SH'
#!/system/bin/sh
printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
SH
adb -s "$SERIAL" push /tmp/sim-use-port-occupant.sh /data/local/tmp/
adb -s "$SERIAL" shell toybox nc -s 127.0.0.1 -p 8080 -L \
  /system/bin/sh /data/local/tmp/sim-use-port-occupant.sh
```

Leave that listener running. In a second terminal:

```bash
export SERIAL=emulator-5580
.build/debug/sim-use android init --device "$SERIAL" \
  --apk-path bridge/app/build/outputs/apk/release/app-release.apk --json
.build/debug/sim-use describe-ui --device "$SERIAL" --json --no-raw
.build/debug/sim-use tap --point 40,40 --device "$SERIAL" --json
.build/debug/sim-use screenshot --device "$SERIAL" --output /tmp/bridge-fallback.png
```

With the base CLI and base APK, init reaches the unrelated listener and fails
with HTTP 404. With the continuation, init succeeds and `data.portForward` is
an assigned device port other than 8080. UI, tap, and screenshot must succeed.
Port 0 is a bind request only; discovery and init must report the actual port.

## Warm requests

Warm the daemon with one `describe-ui` call, then measure seven more calls.
Compare the original #185 CLI and the continuation with the same installed APK
and screen. Stop the serial's daemon between binaries.

An adb recording wrapper can log arguments before it runs the real adb binary.
Set `SIM_USE_ADB` to that wrapper before starting each daemon. Warm calls must
have no `content query` or `forward` commands. The CLI's separate process
liveness check can still run `shell ps -A -o PID,NAME`; it is not discovery.
Do not print the provider's returned token or record Authorization values.

## Recovery and concurrency

To force a port change, stop the bridge through its provider, occupy its old
device port, and start it again. Release the old listener before the next GET.
`describe-ui` must recover after transport failure without restarting the
daemon. For a connection-refusal action check, also remove that serial's old
local forward before the next tap. The tap must reconnect and succeed once.

An adb forward can accept a local connection even when its remote device port
is closed. That can appear as a lost connection rather than a refusal. A POST
with that uncertain outcome must fail without an automatic replay; a later
caller can decide whether a new action is appropriate.

Unit tests in `BridgeConnectionScopingTests` hold an old HTTP response while a
replacement session completes another request. They check that the old display
response cannot replace the new cache and that an old action failure cannot
remove the replacement forward. The same suite checks retry counts for HTTP
401, refusal, timeout, lost connection, cancellation, and business HTTP 500.

## Another listener on a warm port

Warm the daemon with one `describe-ui` call while the bridge uses device port
8080. Stop the bridge through its provider, start the occupied-port listener
from the first section on 8080, and start the bridge again. It binds another
port. Run `describe-ui` two times through the same daemon, then a tap.

The listener returns HTTP 404 without a bridge envelope. The first GET must
recover in the same call: the listener sees one request, and `adb forward
--list` then shows one forward, to the new device port. The daemon PID must
not change.

## New processes

`screenshot` and `android ping` do not use the daemon. After one of them
discovers the endpoint, the next calls in the following 600 s must run
`forward --list` but no `content query`. Check this with the adb recording
wrapper. `android init` must run `content query` again each time.

The accepted endpoint identity gap for reused sessions is tracked in #188.
