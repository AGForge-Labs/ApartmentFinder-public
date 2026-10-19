import Foundation
public struct UsageLedger: Codable, Sendable {
    public var day: String
    public var month: String
    public var dailyUsed: Int
    public var monthlyUsed: Int
    public init(day: String = "", month: String = "", dailyUsed: Int = 0, monthlyUsed: Int = 0) { self.day = day; self.month = month; self.dailyUsed = dailyUsed; self.monthlyUsed = monthlyUsed }
    public mutating func consume(day: String, month: String, dailyLimit: Int, monthlyLimit: Int) throws {
        let emptyStoredPeriod = self.day.isEmpty && self.month.isEmpty && dailyUsed == 0 && monthlyUsed == 0
        let validStoredPeriod = Self.isValid(day: self.day, month: self.month) && dailyUsed >= 0 && monthlyUsed >= 0
        guard Self.isValid(day: day, month: month),
              emptyStoredPeriod || validStoredPeriod,
              day >= self.day, month >= self.month,
              dailyLimit > 0, monthlyLimit > 0 else { throw CoreError("Online usage is disabled or the clock moved backwards.") }
        let dayCount = day == self.day ? dailyUsed : 0
        let monthCount = month == self.month ? monthlyUsed : 0
        guard dayCount < dailyLimit, monthCount < monthlyLimit else { throw CoreError("Free online allowance reached. Local maps remain available.") }
        self.day = day; self.month = month; dailyUsed = dayCount + 1; monthlyUsed = monthCount + 1
    }

    private static func isValid(day: String, month: String) -> Bool {
        let monthBytes = Array(month.utf8), dayBytes = Array(day.utf8)
        guard monthBytes.count == 7, monthBytes[4] == 45,
              dayBytes.count == 10, dayBytes[4] == 45, dayBytes[7] == 45,
              monthBytes.enumerated().allSatisfy({ $0.offset == 4 || (48...57).contains($0.element) }),
              dayBytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              String(day.prefix(7)) == month,
              let year = Int(String(day.prefix(4))),
              let monthNumber = Int(String(day.dropFirst(5).prefix(2))),
              let dayNumber = Int(String(day.suffix(2))),
              (1...9999).contains(year), (1...12).contains(monthNumber) else { return false }
        let leapYear = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...daysInMonth[monthNumber - 1]).contains(dayNumber)
    }
}
