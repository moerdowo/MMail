import Foundation

// Pragmatic MIME helpers: RFC 2047 header decoding, outgoing message building,
// and a minimal text-part extractor for incoming messages.
enum MIME {

    // MARK: RFC 2047 encoded-word header decoding ("=?utf-8?B?...?=")

    static func decodeHeader(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var rest = Substring(input)
        while let start = rest.range(of: "=?") {
            result += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            // charset?enc?text?=
            guard let q1 = after.range(of: "?"),
                  let q2 = after[q1.upperBound...].range(of: "?"),
                  let end = after[q2.upperBound...].range(of: "?=") else {
                result += "=?"; rest = after; continue
            }
            let charset = String(after[after.startIndex..<q1.lowerBound])
            let enc = String(after[q1.upperBound..<q2.lowerBound]).uppercased()
            let text = String(after[q2.upperBound..<end.lowerBound])
            if let decoded = decodeWord(text, encoding: enc, charset: charset) {
                result += decoded
            } else {
                result += text
            }
            rest = after[end.upperBound...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeWord(_ text: String, encoding: String, charset: String) -> String? {
        let data: Data?
        if encoding == "B" {
            data = Data(base64Encoded: text)
        } else { // "Q" — quoted-printable variant (underscore = space)
            data = quotedPrintableData(text.replacingOccurrences(of: "_", with: " "), underscoreSpace: true)
        }
        guard let d = data else { return nil }
        return string(from: d, charset: charset)
    }

    // MARK: Outgoing message

    static func buildMessage(from: String, fromName: String?, to: String, cc: String = "",
                             subject: String, body: String, date: Date = Date(),
                             attachments: [ComposeAttachment] = [], bodyHTML: String? = nil) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let dateStr = df.string(from: date)
        // Message-ID must use the sender's real domain; a bogus host (e.g. .local)
        // is a common spam signal.
        let senderDomain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = "<\(UUID().uuidString)@\(senderDomain)>"
        let fromHeader: String
        if let name = fromName, !name.isEmpty {
            fromHeader = "\(encodeWordIfNeeded(name)) <\(from)>"
        } else {
            fromHeader = from
        }
        let bodyData = Data(body.utf8)
        let encodedBody = bodyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])

        var headers: [String] = []
        headers.append("From: \(fromHeader)")
        headers.append("To: \(to)")
        if !cc.trimmingCharacters(in: .whitespaces).isEmpty { headers.append("Cc: \(cc)") }
        headers.append("Subject: \(encodeWordIfNeeded(subject))")
        headers.append("Date: \(dateStr)")
        headers.append("Message-ID: \(messageID)")
        headers.append("MIME-Version: 1.0")

        let htmlEncoded = bodyHTML.map {
            Data($0.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        }
        let plainPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        let htmlPart = "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"

        // Plain text only, no attachments.
        if htmlEncoded == nil && attachments.isEmpty {
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: base64")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody + "\r\n"
        }

        // The body entity: a multipart/alternative when we have HTML, else plain.
        func alternativeBlock(_ boundary: String) -> String {
            var s = "--\(boundary)\r\n" + plainPart + encodedBody + "\r\n"
            if let htmlEncoded { s += "--\(boundary)\r\n" + htmlPart + htmlEncoded + "\r\n" }
            s += "--\(boundary)--\r\n"
            return s
        }

        // HTML body, no attachments → top-level multipart/alternative.
        if let _ = htmlEncoded, attachments.isEmpty {
            let altB = "MMail-alt-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/alternative; boundary=\"\(altB)\"")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + alternativeBlock(altB)
        }

        // Attachments present → multipart/mixed wrapping the body + attachment parts.
        let mixB = "MMail-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(mixB)\"")
        var out = headers.joined(separator: "\r\n") + "\r\n\r\n"
        out += "This is a multi-part message in MIME format.\r\n"
        out += "--\(mixB)\r\n"
        if htmlEncoded != nil {
            let altB = "MMail-alt-\(UUID().uuidString)"
            out += "Content-Type: multipart/alternative; boundary=\"\(altB)\"\r\n\r\n"
            out += alternativeBlock(altB)
        } else {
            out += plainPart + encodedBody + "\r\n"
        }
        for att in attachments {
            let encoded = att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
            out += "--\(mixB)\r\n"
            out += "Content-Type: \(att.mimeType); name=\"\(att.filename)\"\r\n"
            out += "Content-Transfer-Encoding: base64\r\n"
            out += "Content-Disposition: attachment; filename=\"\(att.filename)\"\r\n\r\n"
            out += encoded + "\r\n"
        }
        out += "--\(mixB)--\r\n"
        return out
    }

    private static func encodeWordIfNeeded(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        let b64 = Data(s.utf8).base64EncodedString()
        return "=?utf-8?B?\(b64)?="
    }

    // MARK: Incoming text + attachment extraction

    struct Attachment { let filename: String; let mimeType: String; let data: Data }
    struct Parsed { var text: String; var html: String?; var attachments: [Attachment]; var listUnsubscribe: String?; var calendar: String? }

    static func extractText(from data: Data) -> String { parse(data).text }

    static func parse(_ data: Data) -> Parsed {
        var result = Parsed(text: "", html: nil, attachments: [], listUnsubscribe: nil, calendar: nil)
        walk(data, into: &result)
        if result.text.isEmpty, let html = result.html { result.text = stripHTML(html) }
        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private static func walk(_ data: Data, into result: inout Parsed) {
        let (headers, body) = splitHeadersBody(data)
        if result.listUnsubscribe == nil, let lu = headers["list-unsubscribe"] { result.listUnsubscribe = lu }
        let ct = headers["content-type"] ?? "text/plain"
        let ctl = ct.lowercased()
        let enc = (headers["content-transfer-encoding"] ?? "").lowercased()
        let disp = (headers["content-disposition"] ?? "").lowercased()
        let filename = parameter("filename", in: headers["content-disposition"] ?? "") ?? parameter("name", in: ct)

        if ctl.contains("multipart/"), let boundary = parameter("boundary", in: ct) {
            for part in splitParts(body, boundary: boundary) { walk(part, into: &result) }
            return
        }

        // Calendar invite (text/calendar part, or a .ics attachment).
        let isICS = ctl.contains("text/calendar") || ctl.contains("application/ics")
            || (filename?.lowercased().hasSuffix(".ics") ?? false)
        if isICS {
            let decoded = decodeBody(body, encoding: enc)
            if result.calendar == nil {
                result.calendar = string(from: decoded, charset: parameter("charset", in: ct) ?? "utf-8")
                    ?? String(decoding: decoded, as: UTF8.self)
            }
            return
        }

        // Attachment: explicit disposition, or a named non-text part.
        if let filename, disp.contains("attachment") || !ctl.hasPrefix("text/") {
            let decoded = decodeBody(body, encoding: enc)
            result.attachments.append(Attachment(filename: decodeHeader(filename),
                                                  mimeType: ctl.split(separator: ";").first.map(String.init) ?? ctl,
                                                  data: decoded))
            return
        }

        // Text content (prefer the first text/plain; keep html as a fallback).
        let decoded = decodeBody(body, encoding: enc)
        let charset = parameter("charset", in: ct) ?? "utf-8"
        let text = string(from: decoded, charset: charset) ?? String(decoding: decoded, as: UTF8.self)
        if ctl.contains("text/html") {
            if result.html == nil { result.html = text }
        } else if result.text.isEmpty {
            result.text = text
        }
    }

    // MARK: iCalendar (.ics) parsing

    static func parseICS(_ ics: String) -> CalendarEvent? {
        // Unfold RFC 5545 continuation lines, then read the VEVENT properties.
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var summary = "", location = "", organizer = ""
        var start: Date?, end: Date?
        for rawLine in unfolded.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let key = keyPart.split(separator: ";").first.map { String($0).uppercased() } ?? keyPart.uppercased()
            switch key {
            case "SUMMARY": summary = unescapeICS(value)
            case "LOCATION": location = unescapeICS(value)
            case "ORGANIZER":
                if let cn = keyPart.range(of: "CN=", options: .caseInsensitive) {
                    organizer = String(keyPart[cn.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else {
                    organizer = value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                }
            case "DTSTART": start = icsDate(value)
            case "DTEND": end = icsDate(value)
            default: break
            }
        }
        guard !summary.isEmpty || start != nil else { return nil }
        return CalendarEvent(summary: summary.isEmpty ? "(untitled event)" : summary,
                             start: start, end: end,
                             location: location.isEmpty ? nil : location,
                             organizer: organizer.isEmpty ? nil : organizer, raw: ics)
    }

    private static func unescapeICS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func icsDate(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for (fmt, utc) in [("yyyyMMdd'T'HHmmss'Z'", true), ("yyyyMMdd'T'HHmmss", false), ("yyyyMMdd", false)] {
            f.dateFormat = fmt
            f.timeZone = utc ? TimeZone(identifier: "UTC") : TimeZone.current
            if let d = f.date(from: value) { return d }
        }
        return nil
    }

    // MARK: Low-level parsing

    private static func splitHeadersBody(_ data: Data) -> (headers: [String: String], body: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let sep = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        guard let sep else { return ([:], data) }
        let headerText = String(text[text.startIndex..<sep.lowerBound])
        let bodyText = String(text[sep.upperBound...])
        return (parseHeaders(headerText), Data(bodyText.utf8))
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                map[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                map[key] = value
                currentKey = key
            }
        }
        return map
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            let lower = kv.lowercased()
            if lower.hasPrefix(name.lowercased() + "=") {
                var v = String(kv.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                return v
            }
        }
        return nil
    }

    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var search = body.startIndex
        var ranges: [Range<Data.Index>] = []
        while let r = body.range(of: delimiter, in: search..<body.endIndex) {
            ranges.append(r)
            search = r.upperBound
        }
        for i in 0..<ranges.count {
            let start = ranges[i].upperBound
            let end = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : body.endIndex
            guard start < end else { continue }
            var chunk = body.subdata(in: start..<end)
            // Strip leading CRLF and trailing CRLF before next boundary.
            while chunk.first == 0x0D || chunk.first == 0x0A { chunk.removeFirst() }
            while chunk.last == 0x0D || chunk.last == 0x0A { chunk.removeLast() }
            if !chunk.isEmpty { parts.append(chunk) }
        }
        return parts
    }

    private static func decodeBody(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let s = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Data(base64Encoded: s) ?? data
        case "quoted-printable":
            return quotedPrintableData(String(decoding: data, as: UTF8.self), underscoreSpace: false) ?? data
        default:
            return data
        }
    }

    private static func quotedPrintableData(_ s: String, underscoreSpace: Bool) -> Data? {
        // Operate on raw UTF-8 octets, NOT Characters. Swift treats "\r\n" as a
        // single Character (extended grapheme cluster), so a char-based scan can
        // never match `=` then `\r` then `\n` as separate units and silently
        // leaves CRLF soft line breaks (`=\r\n`) undecoded — which is exactly how
        // RFC-compliant email wraps quoted-printable. Quoted-printable is defined
        // on octets anyway, so decode over bytes.
        let bytes = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30          // 0–9
            case 0x41...0x46: return b - 0x41 + 10     // A–F
            case 0x61...0x66: return b - 0x61 + 10     // a–f
            default: return nil
            }
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {  // '='
                // Soft line break: "=\r\n", "=\n", or a bare "=\r".
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0D { i += 2; continue }
                // "=XX" hex escape.
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo); i += 3; continue
                }
                out.append(0x3D); i += 1   // stray '=' — keep literal
            } else if b == 0x5F, underscoreSpace {  // '_'
                out.append(0x20); i += 1
            } else {
                out.append(b); i += 1
            }
        }
        return Data(out)
    }

    private static func string(from data: Data, charset: String) -> String? {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        case "iso-8859-1", "latin1", "iso8859-1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        for (tag, repl) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</div>", "\n")] {
            text = text.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (e, r) in entities { text = text.replacingOccurrences(of: e, with: r) }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
}
