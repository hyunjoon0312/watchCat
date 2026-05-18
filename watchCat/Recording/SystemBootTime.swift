import Darwin
import Foundation

/// `kern.boottime` sysctl 래퍼. 시스템이 마지막으로 부팅된 시각을 반환한다.
/// 앱 시작 시점에 "마지막 활동 ~ 부팅" 사이 공백을 "꺼짐(shutdown)" 구간으로
/// 사후 기록할 때 쓰임. 실패하면 nil — 호출자는 reconcile을 건너뛴다.
enum SystemBootTime {
    static func current() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        guard result == 0, tv.tv_sec > 0 else { return nil }
        let secs = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: secs)
    }
}
