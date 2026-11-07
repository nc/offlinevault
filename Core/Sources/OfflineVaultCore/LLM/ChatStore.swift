import Foundation

public struct Conversation: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), updatedAt: Date = Date(), model: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt; self.model = model
    }
    init(row: SQLiteDatabase.Row) {
        id = row.string("id") ?? ""; title = row.string("title") ?? "Conversation"
        createdAt = row.date("created_at") ?? Date(); updatedAt = row.date("updated_at") ?? Date(); model = row.string("model")
    }
}

/// Persists conversations and messages (with their retrieved sources) in the index database.
public final class ChatStore: @unchecked Sendable {
    let db: SQLiteDatabase
    public init(database: IndexDatabase) { db = database.db }

    public func conversations() throws -> [Conversation] {
        try db.query("SELECT * FROM conversations ORDER BY updated_at DESC").map(Conversation.init(row:))
    }

    public func create(title: String, model: String?) throws -> Conversation {
        let c = Conversation(title: title, model: model)
        try db.execute("INSERT INTO conversations(id, title, created_at, updated_at, model) VALUES (?, ?, ?, ?, ?)", [.text(c.id), .text(c.title), .from(c.createdAt), .from(c.updatedAt), .from(model)])
        return c
    }

    public func rename(_ id: String, title: String) throws {
        try db.execute("UPDATE conversations SET title = ? WHERE id = ?", [.text(title), .text(id)])
    }

    public func delete(_ id: String) throws {
        try db.execute("DELETE FROM messages WHERE conversation_id = ?", [.text(id)])
        try db.execute("DELETE FROM conversations WHERE id = ?", [.text(id)])
    }

    public func messages(in conversationId: String) throws -> [ChatMessage] {
        let dec = JSONDecoder()
        return try db.query("SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid", [.text(conversationId)]).map { r in
            var m = ChatMessage(id: r.string("id") ?? UUID().uuidString, role: ChatMessage.Role(rawValue: r.string("role") ?? "user") ?? .user, content: r.string("content") ?? "", createdAt: r.date("created_at") ?? Date())
            if let s = r.string("sources_json"), let d = s.data(using: .utf8), let src = try? dec.decode([RetrievedPassage].self, from: d) { m.sources = src }
            m.usedLibrary = r.int("used_library").map { $0 != 0 } ?? true
            m.leadingPassageLabel = r.int("leading_label").map(Int.init)
            return m
        }
    }

    public func save(_ m: ChatMessage, in conversationId: String) throws {
        let enc = JSONEncoder()
        let sources = m.sources.isEmpty ? nil : String(data: try enc.encode(m.sources), encoding: .utf8)
        try db.execute("""
        INSERT INTO messages(id, conversation_id, role, content, created_at, sources_json, used_library, leading_label) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET content = excluded.content, sources_json = excluded.sources_json, used_library = excluded.used_library, leading_label = excluded.leading_label
        """, [.text(m.id), .text(conversationId), .text(m.role.rawValue), .text(m.content), .from(m.createdAt), .from(sources), .from(m.usedLibrary), .from(m.leadingPassageLabel)])
        try db.execute("UPDATE conversations SET updated_at = ? WHERE id = ?", [.from(Date()), .text(conversationId)])
    }

    public func deleteMessage(_ id: String) throws {
        try db.execute("DELETE FROM messages WHERE id = ?", [.text(id)])
    }
}
