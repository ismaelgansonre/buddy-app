import Foundation

class SSEParser {
    var onEvent: (([String: Any]) -> Void)?
    private var buffer = ""

    func feed(_ text: String) {
        buffer += text
        while let range = buffer.range(of: "\n\n") {
            let event = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            parseEvent(event)
        }
    }

    func reset() {
        buffer = ""
    }

    private func parseEvent(_ event: String) {
        var data = ""
        for line in event.components(separatedBy: "\n") {
            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { return }
                data += payload
            } else if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5))
                if payload == "[DONE]" { return }
                data += payload
            }
        }
        guard !data.isEmpty,
              let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        onEvent?(json)
    }
}
