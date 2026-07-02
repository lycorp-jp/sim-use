// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.model

import android.graphics.Rect
import org.json.JSONArray
import org.json.JSONObject

/**
 * Wire schema for an accessibility tree node. Mirrors the Swift
 * decoder `Sources/AndroidBackend/Bridge/ElementNode.swift` — keep the
 * two field sets in sync. Full **P0+P1** field set (csat ships only 10
 * fields; we ship 22 so V2/V3 verbs don't have to bump
 * `protocol_version` to read additional fields).
 *
 * Fields that may be absent on older Android versions (`uniqueId` on
 * pre-API-33, `hintText` on pre-API-26, `stateDescription` on pre-API-30)
 * are typed `String?` and emitted as `null` when unavailable.
 */
data class ElementNode(
    // Identifiers
    val resourceId: String,
    val uniqueId: String?,
    val packageName: String,

    // Class & labels
    val className: String,
    val text: String,
    val contentDescription: String,
    val hintText: String?,
    val stateDescription: String?,

    // Geometry
    val boundsInScreen: Rect,

    // Interaction flags
    val clickable: Boolean,
    val longClickable: Boolean,
    val scrollable: Boolean,
    val focusable: Boolean,
    val focused: Boolean,
    val enabled: Boolean,
    val checkable: Boolean,
    val checked: Boolean,
    val selected: Boolean,
    val password: Boolean,

    // True when the framework considers the node visible on screen.
    // Catches stale-fragment leakage where an old screen's view tree
    // hasn't been detached but is no longer drawn.
    val visibleToUser: Boolean,

    // Collection metadata
    val collectionInfo: CollectionInfo?,
    val collectionItemInfo: CollectionItemInfo?,

    // Tree
    val children: MutableList<ElementNode> = mutableListOf(),
) {

    data class CollectionInfo(
        val rowCount: Int,
        val columnCount: Int,
        val itemCount: Int,
        val isHierarchical: Boolean,
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("rowCount", rowCount)
            put("columnCount", columnCount)
            put("itemCount", itemCount)
            put("isHierarchical", isHierarchical)
        }
    }

    data class CollectionItemInfo(
        val rowIndex: Int,
        val columnIndex: Int,
        val rowSpan: Int,
        val columnSpan: Int,
        val isHeading: Boolean,
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("rowIndex", rowIndex)
            put("columnIndex", columnIndex)
            put("rowSpan", rowSpan)
            put("columnSpan", columnSpan)
            put("isHeading", isHeading)
        }
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("resourceId", resourceId)
        putOptString("uniqueId", uniqueId)
        put("package", packageName)
        put("className", className)
        put("text", text)
        put("contentDescription", contentDescription)
        putOptString("hintText", hintText)
        putOptString("stateDescription", stateDescription)
        put("boundsInScreen", JSONObject().apply {
            put("left", boundsInScreen.left)
            put("top", boundsInScreen.top)
            put("right", boundsInScreen.right)
            put("bottom", boundsInScreen.bottom)
        })
        put("clickable", clickable)
        put("longClickable", longClickable)
        put("scrollable", scrollable)
        put("focusable", focusable)
        put("focused", focused)
        put("enabled", enabled)
        put("checkable", checkable)
        put("checked", checked)
        put("selected", selected)
        put("password", password)
        put("visibleToUser", visibleToUser)
        if (collectionInfo != null) put("collectionInfo", collectionInfo.toJson()) else put("collectionInfo", JSONObject.NULL)
        if (collectionItemInfo != null) put("collectionItemInfo", collectionItemInfo.toJson()) else put("collectionItemInfo", JSONObject.NULL)
        put("children", JSONArray().apply { children.forEach { put(it.toJson()) } })
    }

    private fun JSONObject.putOptString(key: String, value: String?) {
        if (value != null) put(key, value) else put(key, JSONObject.NULL)
    }
}