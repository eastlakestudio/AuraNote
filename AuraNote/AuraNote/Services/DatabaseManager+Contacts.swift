import Foundation
import SQLite3

// MARK: - Contacts CRUD 扩展

extension DatabaseManager {

    func deleteContact(id: String) throws {
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DBError.executeFailed("BEGIN TRANSACTION: " + lastError)
        }
        do {
            // 清空关联的 speech_clips 的 contact_id
            let updateSQL = "UPDATE speech_clips SET contact_id = NULL WHERE contact_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed("UPDATE speech_clips: " + lastError)
            }
            sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw DBError.executeFailed("UPDATE step: " + lastError)
            }
            sqlite3_finalize(stmt)

            let deleteSQL = "DELETE FROM contacts WHERE id = ?"
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed("DELETE contacts: " + lastError)
            }
            sqlite3_bind_text(stmt, 1, id.cString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw DBError.executeFailed("DELETE step: " + lastError)
            }
            sqlite3_finalize(stmt)

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw DBError.executeFailed("COMMIT: " + lastError)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func saveContactEmbedding(contactId: String, embedding: [Float]) throws {
        let data = embedding.withUnsafeBytes { Data($0) }
        let sql = "UPDATE contacts SET voice_embedding = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        _ = data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 2, contactId.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    /// 有条件覆盖声纹向量：本次发言时长 ≥ 20 秒则覆盖，否则保留已有声纹
    /// - Parameters:
    ///   - contactId: 目标联系人 ID
    ///   - newEmbedding: 本次新提取的声纹向量
    ///   - newDuration: 新样本对应的发言时长（秒），作为覆盖条件判定
    func mergeContactEmbedding(contactId: String, newEmbedding: [Float], newDuration: Float) throws {
        guard let existing = fetchContactEmbedding(contactId: contactId),
              existing.count == newEmbedding.count else {
            // 联系人无声纹存档，或维度不一致 → 直接保存新向量，记录初始时长
            try saveContactEmbedding(contactId: contactId, embedding: newEmbedding)
            try updateContactEmbeddingDuration(contactId: contactId, duration: newDuration)
            AppLog.info("mergeContactEmbedding: first save, duration=\(String(format: "%.1f", newDuration))s")
            return
        }
        // 有条件覆盖：本次发言 ≥ 20 秒才覆盖旧声纹，否则保留已有（短样本不稳定）
        let minDuration: Float = 20.0
        if newDuration >= minDuration {
            try saveContactEmbedding(contactId: contactId, embedding: newEmbedding)
            try updateContactEmbeddingDuration(contactId: contactId, duration: newDuration)
            AppLog.info("mergeContactEmbedding: overwrite, newDuration=\(String(format: "%.1f", newDuration))s >= \(String(format: "%.0f", minDuration))s")
        } else {
            AppLog.info("mergeContactEmbedding: skipped, newDuration=\(String(format: "%.1f", newDuration))s < \(String(format: "%.0f", minDuration))s, keeping existing")
        }
    }

    /// 读取联系人的累计声纹采样时长
    func fetchContactEmbeddingDuration(contactId: String) -> Float {
        let sql = "SELECT voice_embedding_duration FROM contacts WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, contactId.cString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Float(sqlite3_column_double(stmt, 0))
        }
        return 0
    }

    /// 更新联系人的累计声纹采样时长
    private func updateContactEmbeddingDuration(contactId: String, duration: Float) throws {
        let sql = "UPDATE contacts SET voice_embedding_duration = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Double(duration))
        sqlite3_bind_text(stmt, 2, contactId.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    /// 将某场会议中指定发言人的声纹合并到目标联系人
    /// - Parameters:
    ///   - meetingId: 会议 ID（用于查找该会议的声纹存档）
    ///   - speakerLabel: 源发言人标签（如 Speaker_S0）
    ///   - contactId: 目标联系人 ID
    ///   - duration: 新样本的发言时长（秒），用于时长加权
    func mergeSpeakerEmbeddingToContact(meetingId: String, speakerLabel: String, contactId: String, duration: Float = 0) throws {
        let embeddings = fetchMeetingEmbeddings(meetingId: meetingId)
        guard let emb = embeddings[speakerLabel] else {
            AppLog.info("mergeSpeakerEmbeddingToContact: no embedding for \(speakerLabel) in meeting \(meetingId)")
            return
        }
        try mergeContactEmbedding(contactId: contactId, newEmbedding: emb, newDuration: duration)
        AppLog.info("mergeSpeakerEmbeddingToContact: \(speakerLabel) -> \(contactId) from meeting \(meetingId), duration=\(String(format: "%.1f", duration))s")
    }

    /// 读取单个联系人的声纹向量
    func fetchContactEmbedding(contactId: String) -> [Float]? {
        let sql = "SELECT voice_embedding FROM contacts WHERE id = ? AND voice_embedding IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, contactId.cString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: count)
                return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return nil
    }
    
    /// 清除单个联系人的声纹特征
    func clearContactEmbedding(contactId: String) throws {
        let sql = "UPDATE contacts SET voice_embedding = NULL WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, contactId.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }
    
    /// 清除所有联系人的声纹特征
    func clearAllContactEmbeddings() throws {
        let sql = "UPDATE contacts SET voice_embedding = NULL"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError.executeFailed(lastError)
        }
    }

    func fetchContactsWithEmbeddings() -> [(id: String, name: String, embedding: [Float])] {
        let sql = "SELECT id, name, voice_embedding FROM contacts WHERE voice_embedding IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(id: String, name: String, embedding: [Float])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0)
            let name = columnText(stmt, index: 1)
            if let blob = sqlite3_column_blob(stmt, 2) {
                let count = Int(sqlite3_column_bytes(stmt, 2))
                let data = Data(bytes: blob, count: count)
                let embedding = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                if !embedding.isEmpty {
                    results.append((id: id, name: name, embedding: embedding))
                }
            }
        }
        return results
    }

    func saveMeetingEmbeddings(meetingId: String, embeddings: [String: [Float]]) throws {
        let data = try JSONEncoder().encode(embeddings)
        let sql = "UPDATE meetings SET embedding_blob = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        _ = data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 2, meetingId.cString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func fetchMeetingEmbeddings(meetingId: String) -> [String: [Float]] {
        let sql = "SELECT embedding_blob FROM meetings WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, meetingId.cString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: count)
                return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
            }
        }
        return [:]
    }

    func fetchAllContacts() -> [Contact] {
        let sql = "SELECT id, name, role, company, avatar_url, created_at, updated_at FROM contacts ORDER BY name ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var contacts: [Contact] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0)
            let name = columnText(stmt, index: 1)
            let role = columnOptionalText(stmt, index: 2)
            let company = columnOptionalText(stmt, index: 3)
            let avatar = columnOptionalText(stmt, index: 4)
            let created = Self.dateFormatter.date(from: columnText(stmt, index: 5)) ?? Date()
            let updated = Self.dateFormatter.date(from: columnText(stmt, index: 6)) ?? Date()

            contacts.append(Contact(id: id, name: name, role: role, company: company, avatarUrl: avatar, createdAt: created, updatedAt: updated))
        }
        return contacts
    }

    func saveContact(_ contact: Contact) throws {
        let sql = """
        INSERT INTO contacts (id, name, role, company, avatar_url, created_at, updated_at) 
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET 
            name = excluded.name, 
            role = excluded.role,
            company = excluded.company,
            avatar_url = excluded.avatar_url, 
            updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, contact.id.cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, contact.name.cString, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, index: 3, value: contact.role)
        bindOptionalText(stmt, index: 4, value: contact.company)
        bindOptionalText(stmt, index: 5, value: contact.avatarUrl)
        sqlite3_bind_text(stmt, 6, Self.dateFormatter.string(from: contact.createdAt).cString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, Self.dateFormatter.string(from: contact.updatedAt).cString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.executeFailed(lastError)
        }
    }

    func fetchContact(byName name: String) -> Contact? {
        let sql = "SELECT id, name, role, company, avatar_url, created_at, updated_at FROM contacts WHERE name = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, name.cString, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0)
            let fetchedName = columnText(stmt, index: 1)
            let role = columnOptionalText(stmt, index: 2)
            let company = columnOptionalText(stmt, index: 3)
            let avatar = columnOptionalText(stmt, index: 4)
            let created = Self.dateFormatter.date(from: columnText(stmt, index: 5)) ?? Date()
            let updated = Self.dateFormatter.date(from: columnText(stmt, index: 6)) ?? Date()

            return Contact(id: id, name: fetchedName, role: role, company: company, avatarUrl: avatar, createdAt: created, updatedAt: updated)
        }
        return nil
    }

    func saveOrUpdateSpeakerContact(speakerId: String, name: String, embedding: [Float]) throws {
        guard !speakerId.hasPrefix("Speaker_"), speakerId != "?", speakerId != "Speaker_1", !embedding.isEmpty else { return }
        let contact = Contact(
            id: speakerId,
            name: name,
            role: nil,
            company: nil,
            avatarUrl: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try saveContact(contact)
        try saveContactEmbedding(contactId: speakerId, embedding: embedding)
    }

    /// 查出系统内所有的声纹档案（包含通讯录联系人及历史会议分析保存的声纹特征向量）
    func fetchAllKnownVoiceprintProfiles() -> [VoiceprintProfile] {
        var profiles: [VoiceprintProfile] = []
        var existingIds = Set<String>()

        // 1. 通讯录已有声纹的联系人
        let contacts = fetchContactsWithEmbeddings()
        for c in contacts {
            profiles.append(VoiceprintProfile(id: c.id, name: c.name, embedding: c.embedding, sourceType: .contact))
            existingIds.insert(c.id)
            existingIds.insert(c.name)
        }

        // 2. 历史会议中保存的声纹向量 (meetings.embedding_blob)
        let sql = "SELECT id, title, embedding_blob FROM meetings WHERE embedding_blob IS NOT NULL"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let meetingId = columnText(stmt, index: 0)
                if let blob = sqlite3_column_blob(stmt, 2) {
                    let count = Int(sqlite3_column_bytes(stmt, 2))
                    let data = Data(bytes: blob, count: count)
                    if let embs = try? JSONDecoder().decode([String: [Float]].self, from: data) {
                        for (spkKey, emb) in embs where !emb.isEmpty {
                            // 跳过 Speaker_ 前缀的历史临时标签（来自往期未命名说话人），
                            // 否则会导致本期相同 Speaker_ 被错误匹配，无法识别为新参会人
                            guard !spkKey.hasPrefix("Speaker_") else { continue }
                            let profileId = "\(meetingId)_\(spkKey)"
                            if !existingIds.contains(spkKey) && !existingIds.contains(profileId) {
                                profiles.append(VoiceprintProfile(
                                    id: profileId,
                                    name: spkKey,
                                    embedding: emb,
                                    sourceType: .priorSession
                                ))
                                existingIds.insert(profileId)
                            }
                        }
                    }
                }
            }
        }

        return profiles
    }
}
