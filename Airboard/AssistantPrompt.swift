//
//  AssistantPrompt.swift
//
//  Pure prompt-building and output-parsing for the voice assistant.
//  Foundation-only on purpose: compiles standalone for scratch tests.
//  The offsets table is THE defense against DST hallucination — the model
//  does arithmetic on offsets macOS computed, it never recalls them.
//

import Foundation

enum AssistantReply: Equatable {
    case answer(String)
    case unsupported(String)
    case empty
}

enum AssistantPrompt {

    /// Abbreviations + major cities the prompt carries offsets for.
    static let zones: [(label: String, identifier: String)] = [
        ("IST (India)", "Asia/Kolkata"),
        ("PT/PST/PDT (US Pacific, SF/LA/Seattle)", "America/Los_Angeles"),
        ("MT (US Mountain, Denver)", "America/Denver"),
        ("CT (US Central, Chicago/Austin)", "America/Chicago"),
        ("ET/EST/EDT (US Eastern, New York/Toronto)", "America/New_York"),
        ("UTC", "UTC"),
        ("UK (London)", "Europe/London"),
        ("CET (Paris/Berlin/Madrid/Rome)", "Europe/Paris"),
        ("EET (Athens/Helsinki)", "Europe/Helsinki"),
        ("MSK (Moscow)", "Europe/Moscow"),
        ("GST (Dubai)", "Asia/Dubai"),
        ("PKT (Karachi)", "Asia/Karachi"),
        ("BDT (Dhaka)", "Asia/Dhaka"),
        ("ICT (Bangkok)", "Asia/Bangkok"),
        ("SGT (Singapore)", "Asia/Singapore"),
        ("HKT (Hong Kong)", "Asia/Hong_Kong"),
        ("CST-China (Beijing/Shanghai)", "Asia/Shanghai"),
        ("JST (Tokyo)", "Asia/Tokyo"),
        ("KST (Seoul)", "Asia/Seoul"),
        ("AEST (Sydney/Melbourne)", "Australia/Sydney"),
        ("NZT (Auckland)", "Pacific/Auckland"),
        ("BRT (São Paulo)", "America/Sao_Paulo"),
        ("ART (Buenos Aires)", "America/Argentina/Buenos_Aires"),
        ("PET (Lima)", "America/Lima"),
        ("COT (Bogotá)", "America/Bogota"),
        ("CLT (Santiago)", "America/Santiago"),
        ("EAT (Nairobi)", "Africa/Nairobi"),
        ("SAST (Johannesburg)", "Africa/Johannesburg"),
        ("WAT (Lagos)", "Africa/Lagos"),
        ("HST (Honolulu)", "Pacific/Honolulu"),
    ]

    static func offsetString(secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let s = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, s / 3600, (s % 3600) / 60)
    }

    static func systemPrompt(now: Date = Date(), localZone: TimeZone = .current) -> String {
        let table = zones.compactMap { zone -> String? in
            guard let tz = TimeZone(identifier: zone.identifier) else { return nil }
            return "\(zone.label)=\(offsetString(secondsFromGMT: tz.secondsFromGMT(for: now)))"
        }.joined(separator: ", ")

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE MMMM d yyyy, h:mm a"
        fmt.timeZone = localZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let localNow = fmt.string(from: now)
        let localOffset = offsetString(secondsFromGMT: localZone.secondsFromGMT(for: now))

        return """
        You are a voice assistant inside a macOS dictation app, answering via a small toast notification.
        Answer in ONE short line. No preamble, no markdown, numbers first.
        The user's local time is \(localNow) (UTC\(localOffset)).
        Current UTC offsets (already DST-adjusted — use these, never recall offsets yourself): \(table).
        ALWAYS use the calc tool for any arithmetic — never compute numbers yourself.
        Mark day rollover in time conversions with (-1d) or (+1d).
        Exchange rates: fetch https://api.frankfurter.app/latest?from=XXX&to=YYY (ISO codes), then calc the amount.
        For other fresh facts you may fetch_url a relevant https page; if you cannot find a reliable source, say so plainly.
        If the request needs abilities you lack (sending messages, reading email or calendars, editing files, controlling apps), reply exactly: UNSUPPORTED: <short reason>
        """
    }

    /// Normalize pi's stdout into a toast-ready reply.
    static func parse(_ raw: String) -> AssistantReply {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        if text.uppercased().hasPrefix("UNSUPPORTED:") {
            let reason = String(text.dropFirst("UNSUPPORTED:".count))
                .trimmingCharacters(in: .whitespaces)
            return .unsupported(reason)
        }
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        return .answer(text)
    }
}
