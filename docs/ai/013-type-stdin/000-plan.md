# 013 — Private text input

Status: Implemented. See [verification](001-action.md).
Anchor date: 2026-11-18
Related: #176 and [client-side input forwarding](../001-daemon-and-hid-lifecycle/001-dtuhidd-short-lived-clients.md).

## Background

Android's explicit type command requires a positional argument. The iOS simulator accepts stdin, but its type command logs the input and reports unsupported characters verbatim. The line reader also discards newlines.

## Decisions

- Decode stdin once as strict UTF-8. Preserve whitespace and distinguish empty input from a decoding or read error before sending input to the device.
- Reuse the existing daemon socket and option terminator. Keep the Android result empty and compute the diagnostic count from the client's resolved text.
- Remove payloads from iOS type diagnostics, including unsupported-character errors. Keep the HID and clipboard transports separate.
- Keep older skill installations usable through capability detection.

## Verification

Run parser, input fidelity and diagnostic regression tests plus the full unit suite. Read back Playground fields on both platforms. Compare Android JSON and old-daemon success responses and inspect iOS client and daemon output with synthetic markers.
