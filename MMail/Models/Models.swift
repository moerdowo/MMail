import SwiftUI

enum Org: String {
    case team, ext, bot
}

struct Sender: Identifiable {
    let id: String
    let name: String
    let email: String
    let colorHex: String
    let org: Org
    var color: Color { Color(hex: colorHex) }
    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
    var firstName: String { String(name.split(separator: " ").first ?? "") }
}

struct Account: Identifiable {
    let id: String
    let name: String
    let email: String
    let initials: String
    let gradient: [String]
    let colorHex: String
    let provider: String
    var color: Color { Color(hex: colorHex) }
    var gradientColors: [Color] { gradient.map { Color(hex: $0) } }
}

struct MailLabel: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let colorHex: String
    var color: Color { Color(hex: colorHex) }
}

struct ThreadItem: Identifiable, Codable {
    var id = UUID()
    let from: String
    let time: String
    let preview: String
    var emailId: String? = nil   // the underlying Email.id, when this is real mail
}

struct Email: Identifiable, Codable {
    let id: String
    var account: String
    var from: String          // sender id, or "you"
    var to: [String]?
    var subject: String
    var preview: String
    var body: String
    var time: String
    var day: String           // today | yesterday | earlier | snoozed
    var unread: Bool
    var starred: Bool
    var hasAttachment: Bool
    var labels: [String]
    var folder: String
    var thread: [ThreadItem]?
    var snoozeUntil: String?

    // Real-mail fields (nil/defaults for demo data)
    var fromName: String?
    var fromEmail: String?
    var uid: UInt32?
    var bodyLoaded: Bool
    /// Whether the loaded body is the WHOLE message (vs. a capped-prefetch
    /// preview that may be truncated). Optional so it is additively decodable:
    /// a cache written before this feature has no key → decodes as `nil` →
    /// treated as not-complete (the body, if any, may be a 64 KB preview), NOT a
    /// decode failure that would discard the whole cached folder.
    var bodyComplete: Bool?
    var attachments: [AttachmentMeta] = []
    var messageID: String?
    var inReplyTo: String?
    var unsubscribe: String?   // raw List-Unsubscribe header, when present
    var bodyHTML: String?      // text/html part, when present
    var calendarEvent: CalendarEvent?  // parsed .ics invite, when present

    init(id: String, account: String, from: String, to: [String]? = nil,
         subject: String, preview: String, body: String, time: String, day: String,
         unread: Bool = false, starred: Bool = false, hasAttachment: Bool = false,
         labels: [String] = [], folder: String, thread: [ThreadItem]? = nil,
         snoozeUntil: String? = nil,
         fromName: String? = nil, fromEmail: String? = nil, uid: UInt32? = nil,
         bodyLoaded: Bool = true) {
        self.id = id; self.account = account; self.from = from; self.to = to
        self.subject = subject; self.preview = preview; self.body = body
        self.time = time; self.day = day; self.unread = unread; self.starred = starred
        self.hasAttachment = hasAttachment; self.labels = labels; self.folder = folder
        self.thread = thread; self.snoozeUntil = snoozeUntil
        self.fromName = fromName; self.fromEmail = fromEmail; self.uid = uid
        self.bodyLoaded = bodyLoaded
    }

    /// Resolves a displayable sender: demo emails key into SampleData; real
    /// emails synthesize one from the stored name/address.
    var resolvedSender: Sender {
        if from == "you" {
            return Sender(id: "you", name: "You", email: "", colorHex: "6B7088", org: .team)
        }
        if let s = SampleData.senders[from] { return s }
        let name = (fromName?.isEmpty == false ? fromName : nil) ?? fromEmail ?? from
        return Sender(id: from, name: name ?? from, email: fromEmail ?? "",
                      colorHex: Sender.stableColorHex(for: fromEmail ?? from),
                      org: (fromEmail.map(Sender.looksAutomated) ?? false) ? .bot : .ext)
    }
}

extension Sender {
    /// Deterministic avatar color from an address, so a contact keeps one color.
    static func stableColorHex(for key: String) -> String {
        let palette = ["E5484D", "1FB36B", "7A5AE0", "F4A52A", "2D3DEC",
                       "0EA5E9", "D946EF", "06B6D4", "B25A2A", "635BFF"]
        var hash: UInt64 = 5381
        for b in key.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func looksAutomated(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        return ["noreply", "no-reply", "donotreply", "notifications", "notification",
                "automated", "mailer", "support", "info", "hello", "team"].contains { local.contains($0) }
    }
}

struct CalendarEvent: Codable, Hashable {
    var summary: String
    var start: Date?
    var end: Date?
    var location: String?
    var organizer: String?
    var raw: String   // original iCalendar text, written out for "Add to Calendar"
}

struct MailRule: Identifiable, Codable, Hashable {
    enum Field: String, Codable, CaseIterable {
        case from, subject
        var label: String { self == .from ? "From" : "Subject" }
    }
    enum Action: String, Codable, CaseIterable {
        case trash, archive, label
        var label: String {
            switch self {
            case .trash: return "Move to Trash"
            case .archive: return "Archive"
            case .label: return "Apply label"
            }
        }
    }
    var id: String = UUID().uuidString
    var field: Field
    var value: String
    var action: Action
    var labelId: String? = nil

    func matches(_ e: Email) -> Bool {
        let v = value.lowercased()
        guard !v.isEmpty else { return false }
        switch field {
        case .from:
            return (e.fromEmail?.lowercased().contains(v) ?? false) || (e.fromName?.lowercased().contains(v) ?? false)
        case .subject:
            return e.subject.lowercased().contains(v)
        }
    }
}

struct Todo: Identifiable, Codable {
    var id: String
    var text: String
    var done: Bool
    var source: String?
}

struct JournalEntry: Identifiable, Codable {
    var id: String
    var date: String
    var text: String
}

struct ReplyTemplate: Identifiable, Codable {
    var id: String
    var name: String
    var shortcut: String
    var body: String
    var custom: Bool = false
}

struct AttachmentMeta: Codable, Hashable {
    var filename: String
    var mimeType: String
    var size: Int = 0
}

struct ComposeAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct Folder: Identifiable {
    let id: String
    let name: String
    let shortcut: String?
}

struct WeatherInfo {
    let temp: Int
    let feels: Int
    let hi: Int
    let lo: Int
    let condition: String
    let location: String
}
