//
//  test-cli.swift
//  Dev tool: impersonates the FinderSync extension to exercise RClick Agent.
//
//  Usage:
//    rclick-test request <seconds>            request config, then print every
//                                             MainToExtension message received
//    rclick-test click <itemId> <itemType> <path...>
//                                             send a signed click event
//                                             itemType: action|app|new-file|common-dir
//

import AppKit
import Foundation

@main
struct TestCLI {
    static func main() {
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "" {
        case "request":
            let seconds = args.count > 2 ? TimeInterval(args[2]) ?? 5 : 5
            Messager.shared.requestMenuConfig()
            print("sent request-config; listening \(Int(seconds))s ...")
            listen(seconds: seconds)

        case "click":
            guard args.count >= 4, let type = MenuItemType(rawValue: args[3]) else {
                print("usage: rclick-test click <itemId> <action|app|new-file|common-dir> [path...]")
                exit(2)
            }
            let paths = Array(args.dropFirst(4))
            let event = ClickEventPayload(itemId: args[2], itemType: type, target: paths, trigger: .contextualItems)
            Messager.shared.sendClickEvent(event)
            print("sent click \(args[2]) targets=\(paths)")
            // give the runloop a beat so the distributed notification flushes
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        default:
            print("usage: rclick-test request <seconds> | click <itemId> <itemType> [path...]")
            exit(2)
        }
    }
}

func listen(seconds: TimeInterval) {
    DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(Messager.mainToExtensionNotification),
        object: nil, queue: nil
    ) { note in
        guard let json = note.object as? String,
              let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(MainToExtensionMessage.self, from: data) else {
            print("RECV <undecodable>")
            return
        }
        if message.action == .menuConfig,
           let config = Messager.shared.decodeSignedData(message.signedData, as: MenuConfigPayload.self) {
            print("RECV menu-config version=\(config.version) actions=\(config.actions.count) apps=\(config.apps.count) newFiles=\(config.newFiles.count) commonDirs=\(config.commonDirs.count) collapsed=[\(config.actionsCollapsed),\(config.appsCollapsed),\(config.newFilesCollapsed),\(config.commonDirsCollapsed)]")
            for a in config.actions { print("  action \(a.id) '\(a.name)' icon=\(a.icon)") }
            for a in config.apps { print("  app    \(a.id) '\(a.name)' appURL=\(a.appURL ?? "nil") icon=\(a.icon)") }
            for f in config.newFiles { print("  new    \(f.id) '\(f.name)' ext=\(f.ext)") }
            for d in config.commonDirs { print("  dir    \(d.id) '\(d.name)' url=\(d.url ?? "nil")") }
        } else {
            print("RECV \(message.action.rawValue) signed=\(message.signedData != nil)")
        }
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}
