# 012.004 — IPv6 transport serials

## Context

Review-loop round 2 found R189-07. The shared session lock makes path validation
mandatory before every cold connection. The previous cache whitelist excludes
brackets and percent signs, so valid bracketed IPv6 adb serials fail before
discovery. Previously these serials could connect without a persistent cache.

## Decision

Allow `[` and `]` for bracketed addresses and `%` for IPv6 scope identifiers.
They are safe characters in a single path component. Keep rejecting empty
serials, `.` and `..`, slashes, and characters outside the whitelist. This is
path validation, not a parser for all adb transport names. No key migration or
new encoding layer is needed.

## Verification plan

First reproduce failure with cold ping/action and restored-session tests for
`[2001:db8::2]:5555` and `[fe80::2%wlan0]:5555`. Add both to store round trips
and check that malformed paths still fail before the lock body runs. Then run
the focused tests, `make build`, and `make test`. Use synthetic adb/HTTP fixtures;
a live IPv6 device is not available in this environment.

## Result

The new cold-connection test failed on `739fc53` with
`Invalid bridge session device serial`. Store round trips also rejected both
IPv6 examples. After adding the three characters, the focused connection/store
run passed all ten tests. Both cold ping/action and recent-session reuse pass
for bracketed and scoped IPv6 serials. Reuse preserves the disk record and
requires only a forward ownership query. Unsafe path tests still pass.

`make build` passed. `make test` passed all 1,628 tests, with only the three
pre-existing warnings in iOS orientation and MPEG-TS tests.

The fixture logs are in `.build/pr185-takeover/review-round2-*`. These checks
exercise production connection and persistence code with synthetic adb and
HTTP replies. A live IPv6 device was not tested.
