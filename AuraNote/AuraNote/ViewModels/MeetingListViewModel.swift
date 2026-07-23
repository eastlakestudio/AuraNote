import SwiftUI
import Foundation

/// 会议时间分组
enum MeetingTimeGroup: String, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case lastMonth
    case earlier

    var localeKey: String {
        switch self {
        case .today: return "time_group_today"
        case .yesterday: return "time_group_yesterday"
        case .thisWeek: return "time_group_this_week"
        case .thisMonth: return "time_group_this_month"
        case .lastMonth: return "time_group_last_month"
        case .earlier: return "time_group_earlier"
        }
    }
}

/// 一个时间分组下的会议列表
struct MeetingGroup: Identifiable {
    var id: MeetingTimeGroup { group }
    let group: MeetingTimeGroup
    let meetings: [Meeting]
}

/// 会议列表 ViewModel
@MainActor
@Observable
final class MeetingListViewModel {

    var meetings: [Meeting] = []
    var isLoading = false

    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func loadMeetings() {
        isLoading = true
        meetings = databaseManager.fetchAllMeetings()
        isLoading = false
    }

    /// 按时间分组（今日、昨日、本周、本月、上月、更早），每组内倒序排列
    var groupedMeetings: [MeetingGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)),
              let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfMonth)
        else { return [] }

        var dict: [MeetingTimeGroup: [Meeting]] = [:]

        for meeting in meetings {
            let date = meeting.createdAt
            if date >= startOfToday {
                dict[.today, default: []].append(meeting)
            } else if date >= startOfYesterday {
                dict[.yesterday, default: []].append(meeting)
            } else if date >= startOfWeek {
                dict[.thisWeek, default: []].append(meeting)
            } else if date >= startOfMonth {
                dict[.thisMonth, default: []].append(meeting)
            } else if date >= startOfLastMonth {
                dict[.lastMonth, default: []].append(meeting)
            } else {
                dict[.earlier, default: []].append(meeting)
            }
        }

        return MeetingTimeGroup.allCases.compactMap { group in
            guard let items = dict[group], !items.isEmpty else { return nil }
            return MeetingGroup(group: group, meetings: items)
        }
    }
}
