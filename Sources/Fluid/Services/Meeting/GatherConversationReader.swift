import AppKit
import ApplicationServices

/// Reads who is in the user's Gather conversation from Gather's sidebar, which lists each hallway
/// conversation as one line of everyone's names followed by a line per name.
nonisolated enum GatherConversationReader {
    static let bundleIdentifier = "com.gather.GatherV2"
    private static let sectionHeader = "Hallway conversations"
    private static let maximumNodes = 4000

    /// The other people in the user's conversation, or empty when Gather shows none.
    static func otherParticipants() -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron builds its accessibility tree only once a client asks for it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetMessagingTimeout(element, 0.5)
        var lines: [String] = []
        self.collectText(element, into: &lines, depth: 0)
        let selfName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return self.otherParticipants(in: lines, selfName: selfName)
    }

    static func otherParticipants(in lines: [String], selfName: String) -> [String] {
        guard let start = lines.firstIndex(of: self.sectionHeader) else { return [] }
        var groups: [[String]] = []
        var index = start + 1
        while index < lines.count, !lines[index].hasPrefix("Online (") {
            if let group = self.group(startingAt: index, in: lines) {
                groups.append(group)
                index += group.count + 1
            } else {
                index += 1
            }
        }
        guard let mine = groups.first(where: { $0.contains(selfName) }) ?? (groups.count == 1 ? groups.first : nil) else { return [] }
        return mine.filter { $0 != selfName }
    }

    /// A conversation is a line equal to the next few lines joined by spaces.
    private static func group(startingAt index: Int, in lines: [String]) -> [String]? {
        let combined = lines[index]
        var names: [String] = []
        var next = index + 1
        while next < lines.count, names.joined(separator: " ").count < combined.count {
            names.append(lines[next])
            next += 1
            if names.count >= 2, names.joined(separator: " ") == combined { return names }
        }
        return nil
    }

    private static func collectText(_ element: AXUIElement, into lines: inout [String], depth: Int) {
        guard depth < 40, lines.count < self.maximumNodes else { return }
        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty, lines.last != text {
                lines.append(text)
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return }
        for child in children {
            self.collectText(child, into: &lines, depth: depth + 1)
        }
    }
}
