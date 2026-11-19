# Private text input implementation

## Changes

The explicit Android type command accepts stdin. It reads the text during argument resolution, before the local or daemon execution path runs. The client uses that text to report the grapheme count. The daemon still returns an empty success object.

The shared UTF-8 reader also serves iOS type and paste and their top-level forwarders. It preserves a leading U+FEFF, which Foundation's UTF-8 initializer discards on macOS, and rejects malformed bytes. HID conversion finishes before the first key event. Its error describes the keyboard limitation without quoting the character.

## Verification

- Before the change, the Android parser rejected stdin and iOS debug output printed the synthetic credential. The iOS JSON error also contained the unsupported character.
- On Android API 33, both execution paths preserved leading and trailing newlines, Unicode and option-like text. Invalid UTF-8 with `--clear` left the field intact. An empty stream cleared it.
- With the version check disabled for this probe, the new client sent an append to the baseline daemon from #176. After the seed text became observable, one invocation appended one family emoji and reported one grapheme.
- On iOS 27.2, the Playground field received the synthetic marker. Unsupported input and invalid UTF-8 left it unchanged. The marker was absent from the type command output and the daemon log for the operation with debug logging enabled.
- `make build` and `make test` passed on macOS. The Android type E2E suite passed all four cases. The iOS stdin E2E case checked successful and rejected input, client output, daemon diagnostics, and the final field value.
- Linux Swift 6.3 passed 325 XCTest cases and 174 Swift Testing cases. The Linux top-level type command advertised stdin.

## Scope

The iOS and Android checks used simulators. The existing iOS keyboard character set and the clipboard transport are unchanged. Swift callers of the previous iOS stdin helper can use `try StandardInputText.read()` from SimUseCore.
