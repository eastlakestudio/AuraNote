import Foundation
import SQLite3

/// 本地 SQLite 数据库管理器
/// 使用 iOS 内置的 SQLite3 C API，零外部依赖
/// 所有数据库操作限定在主 Actor 上执行，避免跨线程并发访问导致 SQLite 错误
@MainActor
@Observable
final class DatabaseManager {

    @ObservationIgnored internal var db: OpaquePointer?
    private let dbPath: String
    
    internal static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 兜底解析 SQLite datetime('now') 旧格式（yyyy-MM-dd HH:mm:ss）
    private static let fallbackDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// 统一解析日期字符串：先尝试 ISO8601，再兜底 SQLite 旧格式
    static func parseDate(_ str: String) -> Date? {
        if let d = dateFormatter.date(from: str) { return d }
        return fallbackDateFormatter.date(from: str)
    }

    init() {
        let dataDir = SettingsManager.shared.dataDirectory
        let oldPath = dataDir.appendingPathComponent("mttone.db").path
        dbPath = dataDir.appendingPathComponent("auranote.db").path
        
        // 从旧数据库迁移
        if !FileManager.default.fileExists(atPath: dbPath), FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.moveItem(atPath: oldPath, toPath: dbPath)
        }
        openDatabase()
        createTables()
        // 仅在启动时修复一次残留的 recording 状态
        fixZombieMeetings()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    // MARK: - 事务管理

    func beginTransaction() throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DBError.executeFailed(msg)
        }
    }

    func commitTransaction() throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "COMMIT", nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DBError.executeFailed(msg)
        }
    }

    func rollbackTransaction() throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "ROLLBACK", nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DBError.executeFailed(msg)
        }
    }

    // MARK: - 数据库初始化

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let errmsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "未知错误"
            AppLog.error("Failed to open database path=\(dbPath): \(errmsg)")
        } else {
            // 开启外键约束
            sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        }
    }

    private func createTables() {
        let schema = """
        CREATE TABLE IF NOT EXISTS contacts (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            role TEXT,
            company TEXT,
            avatar_url TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS meetings (
            id TEXT PRIMARY KEY,
            parent_meeting_id TEXT,
            title TEXT NOT NULL,
            location TEXT,
            audio_path TEXT NOT NULL,
            duration INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL CHECK(status IN ('recording', 'pending_diarization', 'processing_llm', 'completed')),
            summary TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            attendees TEXT,
            hotword_categories TEXT,
            FOREIGN KEY (parent_meeting_id) REFERENCES meetings(id) ON DELETE SET NULL
        );

        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            file_path TEXT NOT NULL,
            text_content TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS meeting_document_bindings (
            meeting_id TEXT NOT NULL,
            document_id TEXT NOT NULL,
            PRIMARY KEY (meeting_id, document_id),
            FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS speech_clips (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            speaker_label TEXT NOT NULL,
            contact_id TEXT,
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            original_text TEXT NOT NULL,
            cleaned_text TEXT,
            audio_clip_path TEXT,
            is_key_clip INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
            FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE SET NULL
        );
        """

        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            let _ = String(cString: sqlite3_errmsg(db)!)
            // Failed to create tables: errmsg
        } else {
            
            // 增量在数据库中检查并补全 attendees 字段
            let checkColumnSql = "PRAGMA table_info(meetings);"
            var checkStmt: OpaquePointer?
            var hasAttendees = false
            if sqlite3_prepare_v2(db, checkColumnSql, -1, &checkStmt, nil) == SQLITE_OK {
                while sqlite3_step(checkStmt) == SQLITE_ROW {
                    if let name = columnOptionalText(checkStmt, index: 1), name == "attendees" {
                        hasAttendees = true
                        break
                    }
                }
                sqlite3_finalize(checkStmt)
            }
            if !hasAttendees {
                sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN attendees TEXT;", nil, nil, nil)
            }
            
            // 增量检查 meetings 表的热词字段
            var hasHotwordCategories = false
            if sqlite3_prepare_v2(db, checkColumnSql, -1, &checkStmt, nil) == SQLITE_OK {
                while sqlite3_step(checkStmt) == SQLITE_ROW {
                    if let name = columnOptionalText(checkStmt, index: 1) {
                        if name == "hotword_categories" { hasHotwordCategories = true }
                    }
                }
                sqlite3_finalize(checkStmt)
            }
            if !hasHotwordCategories {
                sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN hotword_categories TEXT;", nil, nil, nil)
            }

            // 增量检查 contacts 表的 role / company 字段
            let checkContactSql = "PRAGMA table_info(contacts);"
            var contactStmt: OpaquePointer?
            var hasRole = false, hasCompany = false
            if sqlite3_prepare_v2(db, checkContactSql, -1, &contactStmt, nil) == SQLITE_OK {
                while sqlite3_step(contactStmt) == SQLITE_ROW {
                    if let n = columnOptionalText(contactStmt, index: 1) {
                        if n == "role" { hasRole = true }
                        if n == "company" { hasCompany = true }
                    }
                }
                sqlite3_finalize(contactStmt)
            }
            if !hasRole {
                sqlite3_exec(db, "ALTER TABLE contacts ADD COLUMN role TEXT;", nil, nil, nil)
            }
            if !hasCompany {
                sqlite3_exec(db, "ALTER TABLE contacts ADD COLUMN company TEXT;", nil, nil, nil)
            }

            // 增量检查 contacts 表的 voice_embedding 字段（BLOB）
            var hasEmbed = false
            if sqlite3_prepare_v2(db, checkContactSql, -1, &contactStmt, nil) == SQLITE_OK {
                while sqlite3_step(contactStmt) == SQLITE_ROW {
                    if let n = columnOptionalText(contactStmt, index: 1), n == "voice_embedding" { hasEmbed = true }
                }
                sqlite3_finalize(contactStmt)
            }
            if !hasEmbed {
                sqlite3_exec(db, "ALTER TABLE contacts ADD COLUMN voice_embedding BLOB;", nil, nil, nil)
            }

            // 增量检查 meetings 表的 embedding_blob 字段
            var hasMeetingEmbed = false
            let checkMeetingSql = "PRAGMA table_info(meetings);"
            var meetingStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkMeetingSql, -1, &meetingStmt, nil) == SQLITE_OK {
                while sqlite3_step(meetingStmt) == SQLITE_ROW {
                    if let n = columnOptionalText(meetingStmt, index: 1), n == "embedding_blob" { hasMeetingEmbed = true }
                }
                sqlite3_finalize(meetingStmt)
            }
            if !hasMeetingEmbed {
                sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN embedding_blob BLOB;", nil, nil, nil)
            }

            // 增量检查 contacts 表的 voice_embedding_duration 字段（REAL，累计声纹采样时长）
            var hasEmbedDuration = false
            if sqlite3_prepare_v2(db, checkContactSql, -1, &contactStmt, nil) == SQLITE_OK {
                while sqlite3_step(contactStmt) == SQLITE_ROW {
                    if let n = columnOptionalText(contactStmt, index: 1), n == "voice_embedding_duration" { hasEmbedDuration = true }
                }
                sqlite3_finalize(contactStmt)
            }
            if !hasEmbedDuration {
                sqlite3_exec(db, "ALTER TABLE contacts ADD COLUMN voice_embedding_duration REAL DEFAULT 0;", nil, nil, nil)
            }
        }
    }

    // MARK: - Meeting CRUD

    func createMeeting(_ meeting: Meeting) throws {
        let sql = """
        INSERT INTO meetings (id, parent_meeting_id, title, location, audio_path, duration, status, attendees, hotword_categories, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, meeting.id.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 2, value: meeting.parentMeetingId)
        sqlite3_bind_text(stmt, 3, meeting.title.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 4, value: meeting.location)
        sqlite3_bind_text(stmt, 5, meeting.audioPath.cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 6, Int32(meeting.duration))
        sqlite3_bind_text(stmt, 7, meeting.status.rawValue.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 8, value: meeting.attendees)
        bindOptionalText(stmt, index: 9, value: meeting.hotwordCategories)
        let nowStr = Self.dateFormatter.string(from: meeting.createdAt)
        sqlite3_bind_text(stmt, 10, nowStr.cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, nowStr.cString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func fixZombieMeetings() {
        let sql = "UPDATE meetings SET status = 'pending_diarization' WHERE status = 'recording'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_DONE {
            // Fixed zombie meetings
        }
    }

    /// 获取上一次会议的 ID
    func fetchLastMeetingId() -> String? {
        let sql = "SELECT id FROM meetings ORDER BY created_at DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return columnText(stmt, index: 0)
        }
        return nil
    }

    func fetchDistinctLocations(excludeExternal: String? = nil) -> [String] {
        var sql = "SELECT DISTINCT location FROM meetings WHERE location IS NOT NULL AND location != ''"
        let needsExclude = (excludeExternal?.isEmpty == false)
        if needsExclude {
            sql += " AND location != ?"
        }
        sql += " ORDER BY created_at DESC LIMIT 20"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if needsExclude {
            sqlite3_bind_text(stmt, 1, excludeExternal!.cString, -1, SQLITE_TRANSIENT)
        }

        var locations: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let loc = columnOptionalText(stmt, index: 0) {
                locations.append(loc)
            }
        }
        return locations
    }

    func fetchDistinctSpeakers() -> [String] {
        let sql = "SELECT DISTINCT speaker_label FROM speech_clips WHERE speaker_label NOT LIKE 'Speaker_%' AND speaker_label != '' ORDER BY speaker_label ASC LIMIT 50"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var speakers: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            speakers.append(columnText(stmt, index: 0))
        }
        return speakers
    }

    func fetchAllMeetings() -> [Meeting] {
        let sql = "SELECT id, parent_meeting_id, title, location, audio_path, duration, status, summary, created_at, updated_at, attendees, hotword_categories FROM meetings ORDER BY created_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var meetings: [Meeting] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0)
            let parentId = columnOptionalText(stmt, index: 1)
            let title = columnText(stmt, index: 2)
            let location = columnOptionalText(stmt, index: 3)
            let audioPath = columnText(stmt, index: 4)
            let duration = Int(sqlite3_column_int(stmt, 5))
            let statusStr = columnText(stmt, index: 6)
            let summary = columnOptionalText(stmt, index: 7)
            let createdAtStr = columnText(stmt, index: 8)
            let updatedAtStr = columnText(stmt, index: 9)
            let attendees = columnOptionalText(stmt, index: 10)
            let hotwordCategories = columnOptionalText(stmt, index: 11)

            let status = Meeting.Status(rawValue: statusStr) ?? .recording
            let createdAt = Self.parseDate(createdAtStr) ?? Date()
            let updatedAt = Self.parseDate(updatedAtStr) ?? Date()

            meetings.append(Meeting(
                id: id,
                parentMeetingId: parentId,
                title: title,
                location: location,
                audioPath: audioPath,
                duration: duration,
                status: status,
                summary: summary,
                createdAt: createdAt,
                updatedAt: updatedAt,
                attendees: attendees,
                hotwordCategories: hotwordCategories
            ))
        }
        return meetings
    }

    func updateMeetingInfo(id: String, title: String, location: String?, createdAt: Date, attendees: String?, hotwordCategories: String? = nil, duration: Int? = nil) throws {
        let sql = """
        UPDATE meetings 
        SET title = ?, location = ?, created_at = ?, attendees = ?, hotword_categories = ?, updated_at = ?
        """ + (duration != nil ? ", duration = ?" : "") + """
        WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        
        let dateStr = Self.dateFormatter.string(from: createdAt)
        let updatedAtStr = Self.dateFormatter.string(from: Date())
        
        sqlite3_bind_text(stmt, 1, title.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 2, value: location)
        sqlite3_bind_text(stmt, 3, dateStr.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 4, value: attendees)
        bindOptionalText(stmt, index: 5, value: hotwordCategories)
        sqlite3_bind_text(stmt, 6, updatedAtStr.cString, -1, SQLITE_TRANSIENT)
        
        var nextIndex: Int32 = 7
        if let d = duration {
            sqlite3_bind_int(stmt, nextIndex, Int32(d))
            nextIndex += 1
        }
        sqlite3_bind_text(stmt, nextIndex, id.cString, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func updateMeetingStatus(id: String, status: Meeting.Status, duration: Int? = nil) throws {
        var sql = "UPDATE meetings SET status = ?, updated_at = ?"
        if duration != nil {
            sql += ", duration = ?"
        }
        sql += " WHERE id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let updatedAtStr = Self.dateFormatter.string(from: Date())

        sqlite3_bind_text(stmt, 1, status.rawValue.cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, updatedAtStr.cString, -1, SQLITE_TRANSIENT)
        if let dur = duration {
            sqlite3_bind_int(stmt, 3, Int32(dur))
            sqlite3_bind_text(stmt, 4, id.cString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_text(stmt, 3, id.cString, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func updateMeetingAudioPath(id: String, audioPath: String) throws {
        let sql = "UPDATE meetings SET audio_path = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, audioPath.cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func fetchMeetingGroup(id: String) -> [Meeting] {
        var group: [Meeting] = []
        // 获取当前会议
        let all = fetchAllMeetings()
        guard let target = all.first(where: { $0.id == id }) else { return group }

        // 回溯找到根会议
        var root = target
        while let parentId = root.parentMeetingId, let parent = all.first(where: { $0.id == parentId }) {
            root = parent
        }

        // 收集根及其所有子孙
        let rootId = root.id
        for m in all {
            if m.id == rootId || m.parentMeetingId == rootId || isChildOf(rootId: rootId, meeting: m, all: all) {
                group.append(m)
            }
        }
        if group.isEmpty { group.append(target) }
        group.sort { ($0.createdAt) < ($1.createdAt) }
        return group
    }

    private func isChildOf(rootId: String, meeting: Meeting, all: [Meeting]) -> Bool {
        var current = meeting
        while let parentId = current.parentMeetingId {
            if parentId == rootId { return true }
            guard let parent = all.first(where: { $0.id == parentId }) else { return false }
            current = parent
        }
        return false
    }

    /// 检查会议是否存在（轻量级，只查 id）
    func meetingExists(id: String) -> Bool {
        let sql = "SELECT 1 FROM meetings WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func deleteMeeting(id: String) throws {
        let sql = "SELECT audio_path FROM meetings WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)

        var audioPath: String?
        if sqlite3_step(stmt) == SQLITE_ROW {
            audioPath = columnOptionalText(stmt, index: 0)
        }
        sqlite3_finalize(stmt)
        stmt = nil

        let deleteSQL = "DELETE FROM meetings WHERE id = ?"
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw DBError.executeFailed(lastError)
        }
        sqlite3_finalize(stmt)

        if let path = audioPath, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - SQLite Helpers

    internal var lastError: String {
        if let errmsg = sqlite3_errmsg(db) {
            return String(cString: errmsg)
        }
        return "Unknown error"
    }

    internal func columnText(_ stmt: OpaquePointer?, index: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return ""
    }

    internal func columnOptionalText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return nil
    }

    internal func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, index, v.cString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    // MARK: - 发言记录删除
    
    /// 删除单条发言记录
    func deleteSpeechClip(id: String) throws {
        let sql = "DELETE FROM speech_clips WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }
    
    /// 删除指定会议的所有发言记录
    func deleteClips(forMeeting meetingId: String) throws {
        let sql = "DELETE FROM speech_clips WHERE meeting_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, meetingId.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }
    
    /// 清空所有发言记录
    func clearAllSpeechClips() throws {
        let sql = "DELETE FROM speech_clips"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }
    
    /// 从查询结果的列中构造 SpeechClip，列顺序: id(0), meeting_id(1), speaker_label(2), contact_id(3),
    /// start_time(4), end_time(5), original_text(6), cleaned_text(7), audio_clip_path(8), is_key_clip(9)
    internal func makeSpeechClip(from stmt: OpaquePointer?) -> SpeechClip {
        SpeechClip(
            id: columnText(stmt, index: 0),
            meetingId: columnText(stmt, index: 1),
            speakerLabel: columnText(stmt, index: 2),
            contactId: columnOptionalText(stmt, index: 3),
            startTime: sqlite3_column_double(stmt, 4),
            endTime: sqlite3_column_double(stmt, 5),
            originalText: columnText(stmt, index: 6),
            cleanedText: columnOptionalText(stmt, index: 7),
            audioClipPath: columnOptionalText(stmt, index: 8),
            isKeyClip: sqlite3_column_int(stmt, 9) != 0
        )
    }
}
