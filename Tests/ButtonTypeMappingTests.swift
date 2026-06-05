// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import SimUse
@testable import iOSSimBackend

@Suite("ButtonType platform mapping")
struct ButtonTypeMappingTests {

    @Test("iOS-only buttons have an iosHidButton but no androidKeyCode")
    func iosOnly() {
        for type in [ButtonType.applePay, .sideButton, .siri] {
            #expect(type.iosHidButton != nil, "\(type.rawValue) must map to an iOS HID button")
            #expect(type.androidKeyCode == nil, "\(type.rawValue) must NOT map to an Android keycode")
        }
    }

    @Test("Android-only buttons have an androidKeyCode but no iosHidButton")
    func androidOnly() {
        let backCode = ButtonType.back.androidKeyCode
        let recentsCode = ButtonType.recents.androidKeyCode
        #expect(backCode == 4, "back → KEYCODE_BACK (4)")
        #expect(recentsCode == 187, "recents → KEYCODE_APP_SWITCH (187)")
        #expect(ButtonType.back.iosHidButton == nil)
        #expect(ButtonType.recents.iosHidButton == nil)
    }

    @Test("Cross-platform buttons (home, lock) map on both sides")
    func bothSides() {
        #expect(ButtonType.home.androidKeyCode == 3, "home → KEYCODE_HOME (3)")
        #expect(ButtonType.lock.androidKeyCode == 26, "lock → KEYCODE_POWER (26) → GLOBAL_ACTION_LOCK_SCREEN on bridge")
        #expect(ButtonType.home.iosHidButton != nil)
        #expect(ButtonType.lock.iosHidButton != nil)
    }

    @Test("Every case maps to at least one platform")
    func everyCaseSupportedSomewhere() {
        for type in ButtonType.allCases {
            #expect(type.iosHidButton != nil || type.androidKeyCode != nil,
                    "\(type.rawValue) is mapped on neither platform")
        }
    }

    @Test("Supported-on lists contain the expected values")
    func supportedLists() {
        let iosList = ButtonType.supportedOnIOSList
        let androidList = ButtonType.supportedOnAndroidList
        for token in ["home", "lock", "apple-pay", "side-button", "siri"] {
            #expect(iosList.contains(token), "iOS list missing \(token)")
        }
        for token in ["home", "back", "lock", "recents"] {
            #expect(androidList.contains(token), "Android list missing \(token)")
        }
        #expect(!iosList.contains("back"))
        #expect(!iosList.contains("recents"))
        #expect(!androidList.contains("siri"))
        #expect(!androidList.contains("apple-pay"))
    }
}