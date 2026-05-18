import Foundation
import GRDB

/// "맥이 꺼져 있던" 구간을 보존하기 위한 행. 두 가지 소스가 row를 만든다:
///   1. `InactivityMonitor`가 NSWorkspace.willSleep / didWake를 받아 직접 기록한 슬립
///   2. 앱 시작 시 부팅 시각을 기준으로 "마지막 세션 종료 ~ 부팅 시각" 갭을
///      종료(shutdown) 구간으로 사후 기록 (지난 부팅 사이에 맥이 꺼져 있었음을
///      유일하게 알 수 있는 신호)
///
/// 잠금 / 자리비움(idle)은 의도적으로 저장하지 않는다 — 사용자 분류 정책은
/// "꺼짐 vs 그 외"이므로 추가 column이 필요 없다. 추후 확장이 필요해지면
/// `reason` 컬럼을 마이그레이션으로 더하면 된다.
struct OffIntervalRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "off_intervals"

    var id: Int64?
    var startAt: Date
    var endAt: Date?

    enum Columns {
        static let id = Column("id")
        static let startAt = Column("startAt")
        static let endAt = Column("endAt")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
