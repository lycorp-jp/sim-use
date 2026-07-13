# sim-use Tests

Clean, simple test structure following KISS principles.

## Structure

Each sim-use command has its own dedicated test file:

- `ListSimulatorsTests.swift` - Tests for `list-simulators` command
- `DescribeUITests.swift` - Tests for `describe-ui` command  
- `TapTests.swift` - Tests for `tap` command
- `SwipeTests.swift` - Tests for `swipe` command
- `TypeTests.swift` - Tests for `type` command
- `PasteTests.swift` - Tests for `paste` command (default Cmd+V and `--via-menu` paths)
- `KeyTests.swift` - Tests for `key` and `key-sequence` commands
- `TouchTests.swift` - Tests for `touch` command
- `ButtonTests.swift` - Tests for `button` command
- `GestureTests.swift` - Tests for `gesture` command
- `OrientationTests.swift` - AX→HID orientation self-calibration (tap-by-id after rotation)
- `PermissionAlertTests.swift` - system permission alert dismissal (describe-ui sees the SpringBoard layer, `tap` allows/denies)
- `BatchTests.swift` - E2E coverage for `batch` command variants

Android device E2E suites live alongside them (`AndroidTestSupport.swift` +
`AndroidTapTests`, `AndroidSwipeScrollTests`, `AndroidTypeTests`,
`AndroidKeyboardStateTests`, `AndroidMultiTouchTests`, `AndroidButtonTests`,
`AndroidDescribeUITests`) and drive the `Playgrounds/Android` fixture app on an
emulator/device.

## Running Tests

Use Swift's built-in testing system:

```bash
# Run default tests (unit/non-E2E)
swift test

# Run simulator E2E tests explicitly
SIM_USE_E2E=1 SIMULATOR_UDID=<UDID> swift test

# Run Android device E2E tests (playground APK must be installed;
# `make e2e-android` handles build+install+init+run in one go)
SIM_USE_E2E_ANDROID=1 ANDROID_SERIAL=emulator-5554 swift test --filter AndroidTapTests

# Run specific test files
swift test --filter TapTests
swift test --filter SwipeTests
swift test --filter TypeTests
swift test --filter PasteTests
swift test --filter KeyTests
swift test --filter TouchTests
swift test --filter ButtonTests
swift test --filter GestureTests
swift test --filter OrientationTests
swift test --filter PermissionAlertTests
swift test --filter BatchTests
swift test --filter ListSimulatorsTests
swift test --filter DescribeUITests

# Run with verbose output
swift test --verbose
```

## Test Requirements

- Simulator E2E tests require `SIM_USE_E2E=1` and a booted iOS simulator
- Set `SIMULATOR_UDID` with: `sim-use list-simulators` or `xcrun simctl list devices`
- `swift test` without `SIM_USE_E2E=1` runs non-E2E tests only
- Some tests use the iOS Playground app (`Playgrounds/iOS`) for validation
- Each test file is self-contained and executable
- `PasteTests`: the default Cmd+V cases only land when the simulator has a
  hardware keyboard connected (I/O > Keyboard > Connect Hardware Keyboard);
  without it they early-return with a logged reason and the `--via-menu`
  cases carry the coverage. First paste in an app session may raise the iOS
  "Allow Paste" prompt, which the suite dismisses automatically.
- `OrientationTests`: rotate the simulator and always restore portrait per
  test, so the shared device is left upright for sibling suites.
- `PermissionAlertTests`: reset the location grant with `xcrun simctl privacy
  reset location <bundle>` in setup so the system prompt reappears every run;
  the prompt's button labels are localised (the helper matches EN + JP).

## Test Philosophy

- **KISS**: Keep It Simple, Stupid
- **One responsibility**: Each file tests exactly one command
- **No code generation**: All tests are explicit and readable
- **Self-contained**: Each test file includes its own utilities
- **Executable**: Each test file can be run independently

## Individual Test Files

Each test file can be run directly:

```bash
swift test --filter TapTests
swift test --filter SwipeTests
```

## Test Coverage

All tests validate:
- ✅ Command execution (exit codes)
- ✅ Basic functionality
- ✅ Edge cases and error conditions
- ✅ Integration with the Playground app where applicable
- ✅ Input validation and error handling