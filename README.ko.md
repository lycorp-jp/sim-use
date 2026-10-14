# sim-use

[English](README.md) | [한국어](README.ko.md)

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tests](https://github.com/lycorp-jp/sim-use/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/lycorp-jp/sim-use/actions/workflows/tests.yml)

AI 에이전트가 iOS Simulator와 Android 에뮬레이터 / 기기 화면을 관찰하고 조작할 수 있게 해주는 도구입니다.

**Observe** - 어떤 화면이든 LLM이 이해하기 쉬운, 토큰 효율적인 outline으로 변환합니다.

```text
$ sim-use ui
App: Settings  402x874

[Top  y<120]
  @1  StaticText  "Settings"
[Content  y=120..754]
  @5  SearchField  "Search"
  @7  Button  "Sign in to your iPhone"
  @9  Button  "General"
  @10 Button  "Display & Brightness"
  @11 Button  "Wallpaper"
  ...
[Bottom  y>754]
  @43 TabBar
```

**Act** - 좌표를 직접 계산하지 않고도 alias로 요소를 탭할 수 있습니다.

```text
$ sim-use tap @9
✓ Tap at (201.0, 452.0) completed successfully
```

계획하고, 코드를 작성하고, **검증**하고, 배포하세요. `sim-use`는 AI 에이전트가 자신이 만든 모바일 UI를 직접 확인할 수 있게 해 agentic mobile development loop의 마지막 빈틈을 메웁니다.

`sim-use`는 Apple Accessibility API, iOS Simulator HID pipeline, Android AccessibilityService를 하나의 명령어 표면으로 다루는 크로스 플랫폼 CLI입니다. compact screen description인 `ui`와 alias 기반 탭 shortcut인 `tap @N`을 제공해, LLM 루프가 observe -> act를 몇백 ms 안에 반복할 수 있습니다.

- [Observe -> act 루프](#observe---act-루프)
- [설치](#설치)
- [플랫폼](#플랫폼)
- [명령어](#명령어)
- [아키텍처](#아키텍처)
- [Viewer](#viewer)
- [기여하기](#기여하기)
- [라이선스](#라이선스)


## Observe -> act 루프

모든 상호작용은 같은 흐름을 따릅니다. 관찰하고, 행동하고, 검증합니다.

```bash
sim-use ui                  # 1. 화면을 읽습니다
sim-use tap @9              # 2. 보이는 요소에 행동합니다
sim-use ui                  # 3. 결과를 확인합니다
```

상황에 따라 여러 selector 방식을 사용할 수 있습니다.

| Selector | 예시 | 적합한 경우 |
|---|---|---|
| `@N` alias | `tap @9` | 빠른 조작 - 마지막 `ui` 결과에서 캐시됨 |
| `#<id>` | `tap #settingsButton` | 안정성 - 레이아웃이 바뀌어도 유지됨 |
| `--label` | `tap --label "General"` | `--wait-timeout`과 함께 쓰는 scripted flow |
| `-x -y` / `--point` | `tap --point 100,200` | AX 데이터가 없을 때의 마지막 선택지 |

AX 기반 selector는 어떤 방향에서도 동작합니다. iOS에서는 매 명령마다 현재 회전을 자체 보정하고, outline 좌표를 framebuffer 좌표로 변환한 뒤 입력을 보냅니다. 명시적인 `-x/-y` / `--point`는 항상 기기의 native portrait 좌표계로 해석됩니다.


## 왜 sim-use인가

- **토큰 효율적입니다.** outline 표현은 raw JSON accessibility tree보다 약 16배 작습니다. LLM이 전체 화면을 몇백 토큰 수준으로 읽고 추론할 수 있습니다.
- **숨기는 것이 없습니다.** WebView, 시스템 overlay, embedded content를 포함해 전체 accessibility tree를 탐색합니다. frontmost app이 빈 tree를 노출하는 경우에도 cross-process discovery로 재시도하고, 복구된 flat hierarchy를 `advisory` envelope key로 표시합니다.
- **AI-native입니다.** 사람용 테스트 도구가 아니라 agent loop를 위해 설계되었습니다. alias 기반 탭, actionable `hint`가 담긴 structured `--json` envelope, AI 클라이언트에 명령어 표면을 알려주는 bundled agent skill을 제공합니다.
- **빠릅니다.** 기기별 background daemon이 초기화 비용을 분산합니다. 첫 명령 이후 observe-act 왕복은 약 300 ms 안에 끝납니다.
- **크로스 플랫폼입니다.** 하나의 명령어 표면으로 iOS Simulator와 Android emulator / device를 모두 다룹니다. 같은 verb, 같은 flag, 같은 `--json` 형태로 하나의 agent loop를 작성할 수 있습니다.


## 설치

### Homebrew 권장 설치

```bash
brew tap lycorp-jp/tap
brew install lycorp-jp/tap/sim-use
```

Homebrew 6.0.5 이상에서 "untrusted tap" 오류가 보이면 먼저 다음을 실행하세요.

```bash
brew trust lycorp-jp/tap
```

### 소스에서 빌드

`sim-use`는 **macOS 14+**를 대상으로 하는 Swift package이며 최신 Xcode toolchain으로 빌드됩니다. Meta의 [idb](https://github.com/facebook/idb)에서 로컬로 생성하는 static XCFramework에 링크합니다. 이 파일들은 크기 때문에 repository에 포함되지 않습니다. idb checkout은 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 Xcode project를 생성합니다.

```bash
git clone https://github.com/lycorp-jp/sim-use.git
cd sim-use

# 필요한 XCFramework를 처음 한 번 빌드합니다
./scripts/build.sh dev

# sim-use 자체를 빌드합니다
make build
.build/debug/sim-use --help

# 그 외 Makefile target
make test    # 테스트 실행
make clean
```

XCFramework는 library evolution 없이 빌드되므로, 생성한 toolchain에 Swift module이 묶입니다. Xcode 버전을 바꾼 뒤에는 `./scripts/build.sh dev`를 다시 실행하세요.

### Xcode 27 beta 호환성

`sim-use`는 `Contents/SharedFrameworks`에 `SimulatorKit.framework`를 포함하는 Xcode 27 beta를 지원합니다. Beta 4 이후가 해당하며 Beta 1에는 포함되지 않았습니다. Device Hub workflow도 지원합니다.

- Simulator가 boot된 상태에 따라 HID transport를 자동 선택합니다. legacy HID가 억제된 simulator는 dtuhidd의 CoreDevice HID service를 사용하고, 나머지는 legacy SimulatorKit 경로를 사용합니다.
- boot 후 15초 안에 선택한 transport는 한 번만 사용하고 cache하지 않습니다. `simctl boot && sim-use type` 같은 script가 너무 빨리 probe해도 다음 명령에서 다시 판별합니다.
- `SIM_USE_HID_TRANSPORT=indigo|dtuhid`로 debugging용 transport를 강제할 수 있습니다. `SIM_USE_DEBUG=1`은 transport selection signal과 내부 info line을 stderr 또는 daemon logfile에 표시합니다.
- Xcode 27은 더 이상 Simulator.app을 bundle하지 않습니다. Xcode 26.x의 Simulator.app이나 Device Hub로 simulator를 볼 수 있습니다.
- 작업 기록은 [`docs/ai/xxxx-xcode27-support/README.md`](docs/ai/xxxx-xcode27-support/README.md)를 참고하세요.

### Agent skill

bundled agent skill을 AI 클라이언트의 skill directory에 설치하려면 다음을 사용하세요.

```bash
sim-use init                        # 설치된 client 자동 감지
sim-use init --client claude        # non-interactive
sim-use init --dest ~/.claude/skills
sim-use init --print                # 설치하지 않고 skill 내용 출력
sim-use init --uninstall --client claude
```


## 플랫폼

`sim-use`는 같은 명령어 표면으로 **iOS Simulator**와 **Android device / emulator**를 다룹니다. device ID 형태로 backend가 결정됩니다.

- `1A2B3C4D-...` 형식의 UUID -> iOS Simulator
- `emulator-5554` / `R5CT1ABCD12` / `192.168.1.5:5555` -> Android device

Android는 bridge APK 설치를 위해 한 번 `sim-use android init --device <serial>`을 실행하세요. Android toolchain 설정은 [`AGENTS.md`](AGENTS.md)를 참고하세요.


## 명령어

device-scoped 명령은 모두 `--device <ID>`를 받습니다. boot된 simulator가 하나뿐이면 생략할 수 있습니다. 명령어는 세 계층으로 나뉩니다.

- **Top-level** - 크로스 플랫폼 verb: `ui`, `tap`, `swipe`, `type`, `paste`, `button`, `gesture`, `keyboard-state`, `screenshot`, `record-video`, `stream-video`, `app-state`
- **`sim-use ios <verb>`** - iOS 전용: `key`, `key-combo`, `key-sequence`, `batch`
- **`sim-use android <verb>`** - Android 전용: `init`, `devices`, `ping`

전체 flag는 `sim-use --help` 또는 `sim-use <command> --help`로 확인하세요.

```bash
sim-use devices
UDID="B34FF305-5EA8-412B-943F-1D0371CA17FF"
```

### 터치와 gesture

```bash
sim-use tap -x 100 -y 200 --device $UDID
sim-use tap --point 100,200 --device $UDID
sim-use tap @5 --device $UDID
sim-use tap "#3" --device $UDID
sim-use tap "#2@2" --device $UDID
sim-use tap "#settingsButton" --device $UDID
sim-use tap --id Safari --device $UDID
sim-use tap --label "Safari" --device $UDID
sim-use tap --value "On" --device $UDID

sim-use swipe --from 100,300 --to 300,100 --device $UDID
sim-use swipe 100,300 300,100 --device $UDID
sim-use swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --device $UDID
sim-use swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --device $UDID

sim-use touch -x 150 -y 250 --down --device $UDID
sim-use touch -x 150 -y 250 --up --device $UDID
sim-use touch -x 150 -y 250 --down --up --delay 1.0 --device $UDID

sim-use gesture scroll-up --device $UDID
sim-use gesture swipe-from-left-edge --device $UDID
sim-use gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --device $UDID
```

`--pre-delay` / `--post-delay` / `--duration`은 `tap`, `swipe`, `gesture`에서 모두 사용할 수 있습니다.

single-finger preset인 `scroll-*`, `swipe-from-*-edge`는 화면에 보이는 방향을 기준으로 동작하며 iOS에서는 orientation-aware입니다. 명시적 `swipe` / `touch` 좌표는 기본적으로 device-native portrait 좌표계입니다. `--coordinate-space ui`를 넘기면 `ui`가 출력한 visual space 좌표를 사용할 수 있습니다. Android에서는 이 flag를 받아들이지만 별도 변환은 하지 않습니다.

### 텍스트 입력

```bash
sim-use type 'Hello World!' --device $UDID
echo "complex text" | sim-use type --stdin --device $UDID
sim-use type --file input.txt --device $UDID
```

### Paste: IME-safe Unicode

`sim-use paste`는 텍스트를 simulator pasteboard에 쓰고 Cmd+V를 보냅니다. 따라서 host IME 조합을 거치지 않고 focused field에 문자가 들어갑니다. CJK, emoji, diacritic처럼 HID keycode table로 표현하기 어려운 Unicode도 처리할 수 있습니다.

```bash
sim-use paste 'ABC 日本語 🎉' --device $UDID
sim-use paste 'new content' --replace --device $UDID

printf '%s' "$CONTENT" | sim-use paste --stdin --device $UDID
sim-use paste --file body.txt --device $UDID
```

기본 Cmd+V 경로는 simulator의 hardware keyboard 연결이 필요합니다. soft keyboard만 쓰는 상태에서는 HID Cmd+V가 무시될 수 있으므로 `--via-menu`를 사용하세요.

```bash
sim-use paste 'ABC 日本語' --via-menu --target-id chatTextField --device $UDID
sim-use paste 'NEW' --replace --via-menu --target-id chatTextField --device $UDID
sim-use paste 'at xy' --via-menu --target-x 171 --target-y 513 --device $UDID
```

iOS 16 이상에서는 app session당 첫 paste가 "Allow Paste" prompt로 제한될 수 있습니다. `sim-use`가 이 prompt를 자동으로 닫지는 않으므로 한 번 승인하거나 앱별 Settings -> Paste from Other Apps를 미리 설정하세요.

### Keyboard state

software keyboard가 보이는지 확인합니다. 주 용도는 `paste`의 기본 Cmd+V 경로와 `--via-menu` 경로 중 하나를 고르는 것입니다.

```bash
if [[ "$(sim-use keyboard-state --device $UDID)" == soft ]]; then
  sim-use paste "$TEXT" --via-menu --target-id chatTextField --device $UDID
else
  sim-use paste "$TEXT" --device $UDID
fi

sim-use keyboard-state --json --device $UDID
# -> {"ok":true,"data":{"visible":true, ...}}
```

### Hardware buttons

```bash
sim-use button home --device $UDID
sim-use button lock --duration 2.0 --device $UDID
sim-use button siri --device $UDID
# Also: side-button, apple-pay
```

### Low-level keyboard: iOS 전용

이 verb들은 USB HID keycode를 사용하므로 `sim-use ios <verb>` 아래에 있습니다. Android keyboard input은 다른 추상화를 사용합니다. Android text entry에는 `sim-use type` 또는 `sim-use paste`를 사용하세요.

```bash
sim-use ios key 40 --device $UDID
sim-use ios key 42 --duration 1.0 --device $UDID

sim-use ios key-sequence --keycodes 11,8,15,15,18 --device $UDID
sim-use ios key-combo --modifiers 227 --key 4 --device $UDID
sim-use ios key-combo --modifiers 227,225 --key 4 --device $UDID
```

### Batch chaining: iOS 전용

여러 단계를 한 번의 invocation으로 실행합니다. batch는 하나의 HID session과 하나의 AX snapshot을 재사용해 multi-step flow의 round trip 비용을 줄입니다.

```bash
sim-use ios batch --device $UDID \
  --step "tap --id SearchField" \
  --step "type 'hello world'" \
  --step "key 40"

sim-use ios batch --device $UDID \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"

sim-use ios batch --device $UDID --file steps.txt
```

핵심 규칙:

- 한 번 실행할 때 step source는 `--step`, `--file`, `--stdin` 중 정확히 하나만 사용할 수 있습니다.
- 기본은 fail-fast입니다. `--continue-on-error`를 쓰면 best-effort로 계속 진행합니다.
- `--wait-timeout <seconds>`는 selector tap이 요소가 나타날 때까지 polling하게 합니다.
- `--ax-cache perBatch`가 기본값입니다. UI가 단계 사이에서 바뀌면 `--ax-cache perStep`을 사용할 수 있고, snapshot reuse를 끄려면 `--ax-cache none`을 사용하세요.

### Screenshot

```bash
sim-use screenshot --device $UDID
sim-use screenshot --output ~/Desktop/shot.png --device $UDID
sim-use screenshot --output ~/Desktop/ --device $UDID
```

output path는 stdout으로, progress message는 stderr로 출력됩니다.

### Video streaming과 recording

```bash
sim-use stream-video --device $UDID --fps 10 --format mjpeg > stream.mjpeg

sim-use stream-video --device $UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast out.mp4

sim-use stream-video --device emulator-5554 --format h264 | \
  ffplay -f h264 -probesize 32 -fflags nobuffer -

sim-use record-video --device $UDID --output recording.mp4
sim-use record-video --device $UDID --fps 60 --output smooth.mp4
sim-use record-video --device $UDID --quality 60 --scale 0.5 --output low-bw.mp4
```

`record-video`는 실제 H.264 stream을 캡처하고 MP4로 바로 mux합니다. iOS는 eager H.264 mode의 `FBSimulatorVideoStream`을 사용하고, Android는 device native variable frame rate의 `adb screenrecord --output-format=h264`를 pipe합니다.

녹화 중 화면 회전은 Android capture를 중단시킵니다. Ctrl+C로 중지하면 `sim-use`가 종료 전에 MP4를 finalize합니다.

### Accessibility inspection

```bash
sim-use ui --device $UDID
sim-use ui --json --device $UDID
sim-use ui --json --no-raw --device $UDID
sim-use ui --point 100,200 --device $UDID
```

`--json` envelope는 기본적으로 raw accessibility tree를 `data.raw` 아래에 담습니다. agent loop에서는 raw tree가 debugging 용도로만 필요하다면 `--no-raw`를 선호하세요.

outline은 `[Top]` / `[Content]` / `[Bottom]` / declared `Group` region과 `@N` / `#N` / `#N@M` / `#<id>` alias addressing을 사용합니다. 기기가 회전되어 있으면 `App:` header에 orientation tag가 붙고 `--json` envelope에는 `orientation` field가 포함됩니다.

list cluster detector는 snapshot마다 실행되어 감지된 list cell에 `#N` alias를 붙입니다. `--json` envelope의 `lists` array와 `entries[*].aliases.list`를 통해 list 정보를 기계적으로 사용할 수 있습니다.

### App state와 crash detection

```bash
sim-use app-state --device $UDID
sim-use app-state --bundle-id com.example.app --device $UDID
sim-use app-state --reset --device $UDID
```

daemon이 기기를 조작하는 동안 target process가 명령 사이에 사라지면 다음 `ui` 호출에서 banner로 알려줍니다. Android에서는 accessibility tree에서 AOSP system crash dialog도 직접 감지합니다. 의도적으로 재실행한 뒤에는 `app-state --reset`을 호출하세요. `SIM_USE_NO_CRASH_DETECT=1`로 감지를 끌 수 있습니다.

### Daemon

UDID-scoped 명령은 첫 사용 시 기기별 background daemon을 자동으로 띄우고 이후 명령에서 재사용합니다. script가 daemon을 직접 관리할 필요는 없습니다.

```bash
sim-use daemon status
sim-use daemon stop --device $UDID
sim-use daemon stop --all

SIM_USE_NO_DAEMON=1 sim-use ui --device $UDID
```

daemon은 600초 동안 idle이면 자동 종료되며 `/tmp/sim-use-<uid>/<UDID>.log`에 log를 남깁니다. streaming command인 `screenshot`, `record-video`, `stream-video`는 항상 in-process로 실행됩니다.


## 아키텍처

`sim-use`는 Facebook [idb](https://github.com/facebook/idb)의 lower-level XCFramework, Apple Accessibility API, simulator HID pipeline을 통해 iOS Simulator를 조작합니다. Android device는 AccessibilityService tree와 input injection을 HTTP로 노출하는 on-device bridge APK를 통해 조작하며, 연결은 `adb forward`로 tunnel됩니다.

- **하나의 binary, 하나의 invocation.** 수동으로 관리해야 하는 RPC daemon은 없습니다. 기기별 background daemon은 자동으로 시작되며 `SIM_USE_NO_DAEMON=1`로 끌 수 있습니다.
- **Agent-first output.** `ui`는 LLM과 simulator 사이를 적은 token 비용으로 왕복하도록 설계된 compact outline과 안정적인 `@N` / `#<id>` alias를 출력합니다.
- **넓은 HID 표면.** tap, swipe, touch, gesture preset, hardware button, key combo, IME-safe Unicode paste를 first-class command로 제공합니다.
- **처음부터 scriptable.** 모든 명령은 machine consumption을 위한 `--json`을 지원하고, `batch`는 multi-step flow를 하나의 invocation으로 줄입니다.


## Viewer

`sim-use ui --json` 결과를 scaled SVG canvas로 렌더링하는 local web app입니다. accessibility tree가 어떤 요소를 노출하는지 확인하고, blind spot을 찾고, browser에서 직접 탭할 수 있습니다.

```bash
sim-use viewer
```

Node나 npm은 필요 없습니다. SPA가 binary에 bundle되어 있고 browser가 자동으로 열립니다. Viewer front-end 개발은 [`Tools/Viewer/README.md`](Tools/Viewer/README.md)를 참고하세요.


## 기여하기

개발 환경 설정, coding convention, 모든 contribution에 필요한 DCO sign-off는 [`CONTRIBUTING.md`](CONTRIBUTING.md)를 참고하세요.

요약하면:

```bash
git clone https://github.com/lycorp-jp/sim-use.git
cd sim-use
./scripts/build.sh dev
make build
make test
```

commit에는 DCO sign-off가 필요합니다.

```bash
git commit -s -m "docs: add Korean README"
```

device 동작을 바꾸는 PR이라면 `make e2e-ios`, `make e2e-android`, 또는 `make e2e`도 실행하세요.


## 라이선스

`sim-use`는 **Apache License, Version 2.0**으로 배포됩니다. 자세한 내용은 [`LICENSE`](LICENSE)와 [`NOTICE`](NOTICE)를 참고하세요.

`sim-use`는 [`cameroncooke/AXe`](https://github.com/cameroncooke/AXe)에서 fork되어 시작했습니다. AXe는 MIT license이며 2025 Cameron Cooke의 저작권 고지를 포함합니다. 또한 [Meta's idb](https://github.com/facebook/idb)에서 빌드한 XCFramework에 링크합니다. 두 MIT license 고지는 [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES)에 포함되어 있습니다.
