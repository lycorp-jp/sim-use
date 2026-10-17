// SPDX-License-Identifier: Apache-2.0
//
//  ChromeTestView.swift
//  SimUsePlayground
//
//  Container-owned chrome for outline layout checks: a navigation bar
//  with leading and trailing toolbar items, a bottom toolbar and a tab
//  bar. On the iPhone Duo cover display an iOS 27.1 SDK build moves the
//  container-owned bars into the vertical bar on the trailing edge; an
//  older SDK keeps them horizontal. Every control echoes its tap in
//  `chrome-last-action`, so a test can prove where a tap landed.
//
//  No screen-level accessibilityIdentifier: on a root it would replace
//  every child's id.

import SwiftUI

struct ChromeTestView: View {
    @State private var selectedTab = "home"
    @State private var lastAction = "none"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: "home") {
                tabContent(title: "Home", rows: ["Inbox", "Drafts", "Archive"])
            }
            .accessibilityIdentifier("chrome-tab-home")
            Tab("Search", systemImage: "magnifyingglass", value: "search") {
                tabContent(title: "Search", rows: ["Recent", "Saved"])
            }
            .accessibilityIdentifier("chrome-tab-search")
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                tabContent(title: "Settings", rows: ["Account", "Privacy", "About"])
            }
            .accessibilityIdentifier("chrome-tab-settings")
        }
        .navigationTitle("Chrome Test")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Edit") { lastAction = "edit" }
                    .accessibilityIdentifier("chrome-edit")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    lastAction = "add"
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("chrome-add")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Share") { lastAction = "share" }
                    .accessibilityIdentifier("chrome-share")
            }
        }
        .onChange(of: selectedTab) { _, tab in
            lastAction = "tab-\(tab)"
        }
    }

    private func tabContent(title: String, rows: [String]) -> some View {
        List {
            Section {
                Text("Last action: \(lastAction)")
                    .accessibilityIdentifier("chrome-last-action")
                    .accessibilityValue(lastAction)
            }
            Section(title) {
                ForEach(rows, id: \.self) { row in
                    Button(row) { lastAction = "row-\(row.lowercased())" }
                        .accessibilityIdentifier("chrome-row-\(row.lowercased())")
                }
            }
        }
    }
}
