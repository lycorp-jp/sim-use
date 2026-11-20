# 001.002 - Refuse short-lived DTUHID input

2026-11-20, issue #175

A standalone tap can report success before the app receives it. The host-side send barrier can complete before dtuhidd activates its virtual HID services. The [short-lived client investigation](001-dtuhidd-short-lived-clients.md) found no acknowledgement of digitizer consumption.

Require the per-device daemon for events on DTUHID. Check routed touch before starting dtuhidd because a secondary display or Resize Mode scene already requires that transport. Check each send attempt again because dead-transport recovery can rebuild an Indigo session on DTUHID. A refusal ends the command without replaying input or starting a daemon.

Main-display Indigo input and non-HID commands can still run in-process. An unknown transport alone does not establish that delivery needs DTUHID.
