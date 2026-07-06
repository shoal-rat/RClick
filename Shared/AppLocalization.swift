//
//  AppLocalization.swift
//  RClick
//
//  Created by Codex on 2026/7/3.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .automatic:
            AppLocalization.systemLanguage.localeIdentifier
        case .simplifiedChinese:
            "zh-Hans"
        case .english:
            "en"
        case .japanese:
            "ja"
        }
    }
}

enum AppLocalization {
    static let tableName = "Localizable"
    private static let selectedLanguageKey = "SELECTED_LANGUAGE"
    // Deliberately NOT an app-group ("group.*") suite. On macOS 15+ an app
    // group id that is not prefixed with the team ID routes every access
    // through a TCC "App Data" consent — and because the answer is never
    // persisted for this class, a fresh FinderSyncExt process re-prompted
    // ("RClick" would like to access data from other apps) after every Finder
    // restart. A plain preferences domain has no group container and never
    // prompts. Trade-off: the app and the extension each read their own copy
    // of this domain, so a language override set in the app no longer reaches
    // the extension (the extension falls back to the system language).
    private static var groupDefaults: UserDefaults {
        UserDefaults(suiteName: "prefs.cn.wflixu.RClick") ?? .standard
    }

    static var systemLanguage: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") {
            return .simplifiedChinese
        }
        if preferred.hasPrefix("ja") {
            return .japanese
        }
        return .english
    }

    static var currentLanguage: AppLanguage {
        guard let rawValue = groupDefaults.string(forKey: selectedLanguageKey),
              let language = AppLanguage(rawValue: rawValue)
        else {
            return .automatic
        }
        return language
    }

    static var currentLocale: Locale {
        Locale(identifier: currentLanguage.localeIdentifier)
    }

    static func localized(_ key: String, bundle: Bundle = .main) -> String {
        localized(key, tableName: tableName, bundle: bundle)
    }

    static func localized(_ key: String, tableName: String, bundle: Bundle = .main) -> String {
        let bundle = localizedBundle(for: bundle)
        return bundle.localizedString(forKey: key, value: key, table: tableName)
    }

    private static func localizedBundle(for bundle: Bundle) -> Bundle {
        let localeIdentifier = currentLanguage.localeIdentifier

        if let path = bundle.path(forResource: localeIdentifier, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }

        let candidates = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [localeIdentifier])
        if let preferred = candidates.first,
           let path = bundle.path(forResource: preferred, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }

        return bundle
    }
}

extension Text {
    init(appLocalized key: String) {
        self.init(AppLocalization.localized(key))
    }
}
