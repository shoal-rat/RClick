//
//  RCBaseSubset.swift
//  RClick Agent
//
//  Menu-item payload structs copied verbatim from RClick v2.0.4
//  Shared/RCBase.swift (lines 254-318) so the JSON wire format matches
//  the installed FinderSyncExt exactly.
//

import Foundation

/// Menu item for opening files with external applications
struct AppMenuItem: Codable {
    let id: String
    let name: String
    let icon: String
    let tag: Int
    let appURL: String?  // 应用路径，用于获取应用图标

    init(id: String, name: String, icon: String, tag: Int, appURL: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tag = tag
        self.appURL = appURL
    }
}

/// Menu item for custom actions (copy path, delete, etc.)
struct ActionMenuItem: Codable {
    let id: String
    let name: String
    let icon: String
    let tag: Int

    init(id: String, name: String, icon: String, tag: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tag = tag
    }
}

/// Menu item for creating new files
struct NewFileMenuItem: Codable {
    static let customFileId = "__rclick_custom_new_file"

    let id: String
    let name: String
    let ext: String
    let icon: String

    init(id: String, name: String, ext: String, icon: String) {
        self.id = id
        self.name = name
        self.ext = ext
        self.icon = icon
    }
}

/// Menu item for common directories
struct CommonDirMenuItem: Codable {
    let id: String
    let name: String
    let icon: String
    let url: String?  // 文件夹路径，用于获取文件夹图标

    init(id: String, name: String, icon: String, url: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.url = url
    }
}
