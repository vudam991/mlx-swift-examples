//
//  LocalAPIServer.swift
//  mlx-swift-examples
//
//  Created by vu on 11/25/26.
//

import Foundation
import Hummingbird
import NIOCore

struct ChatRequest: Decodable {
    struct Message: Decodable { let role: String; let content: String }
    let model: String?
    let messages: [Message]
    let stream: Bool?
}

@MainActor
final class LocalAPIServer {
    private var task: Task<Void, Error>?
    let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func start(port: Int = 8080, generate: @escaping @Sendable ([ChatRequest.Message]) -> AsyncStream<String>) {
        let key = apiKey
        task = Task.detached {
            let router = Router()
            router.get("v1/models") { _, _ in
                #"{"object":"list","data":[{"id":"qwen3-vl-2b","object":"model"}]}"#
            }
            router.post("v1/chat/completions") { request, context in
                guard request.headers[.authorization] == "Bearer \(key)" else {
                    throw HTTPError(.unauthorized)
                }
                let body = try await request.decode(as: ChatRequest.self, context: context)
                let stream = generate(body.messages)
                return Response(status: .ok, headers: [.contentType: "text/event-stream"],
                    body: .init { writer in
                        for await chunk in stream {
                            let json = #"{"choices":[{"delta":{"content":\#(Self.escape(chunk))}}]}"#
                            try await writer.write(ByteBuffer(string: "data: \(json)\n\n"))
                        }
                        try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                        try await writer.finish(nil)
                    })
            }
            let app = Application(router: router,
                configuration: .init(address: .hostname("0.0.0.0", port: port)))
            try await app.runService()
        }
    }

    func stop() { task?.cancel(); task = nil }

    nonisolated static func escape(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(decoding: data, as: UTF8.self)
    }
}
