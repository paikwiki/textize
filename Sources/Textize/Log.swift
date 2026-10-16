import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "wiki.paik.textize", category: "app")

    /// 통합 로그에만 남긴다. 자막 본문·번역문은 절대 넣지 않는다(사용자가 듣는 내용이 시스템 로그에 쌓인다).
    static func info(_ message: String) {
        app.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        app.error("\(message, privacy: .public)")
    }
}
