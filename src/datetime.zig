const std = @import("std");

pub const Date = struct {
    year: i16,
    month: i8,
    day: i8,
};

pub const Time = struct {
    hour: i8,
    minute: i8,
    second: i8,
    usec: i32 = 0,
};

pub const DateTime = struct {
    date: Date,
    time: Time,
};

pub const DateTimeTz = struct {
    date: Date,
    time: Time,
    tz_minutes: i16,
};

pub fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

pub fn isValidDate(date: Date) bool {
    if (date.month < 1 or date.month > 12) return false;
    const dim = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max_day = dim[@intCast(@as(i32, date.month) - 1)];
    if (date.month == 2 and isLeapYear(date.year)) max_day = 29;
    return date.day >= 1 and date.day <= max_day;
}

pub fn isValidTime(time: Time) bool {
    return time.hour >= 0 and time.hour <= 23 and
        time.minute >= 0 and time.minute <= 59 and
        time.second >= 0 and time.second <= 59 and
        time.usec >= 0 and time.usec <= 999_999;
}

pub fn isValidTz(minutes: i16) bool {
    return minutes >= -23 * 60 - 59 and minutes <= 23 * 60 + 59;
}

pub fn parseDate(text: []const u8) ?Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i16, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i8, text[8..10], 10) catch return null;
    const date = Date{ .year = year, .month = month, .day = day };
    if (!isValidDate(date)) return null;
    return date;
}

pub fn parseTime(text: []const u8) ?Time {
    if (text.len < 5 or text[2] != ':') return null;
    const hour = std.fmt.parseInt(i8, text[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(i8, text[3..5], 10) catch return null;
    var second: i8 = 0;
    var frac_start: usize = text.len;
    if (text.len > 5) {
        if (text.len < 8 or text[5] != ':' or !std.ascii.isDigit(text[6]) or !std.ascii.isDigit(text[7])) return null;
        second = std.fmt.parseInt(i8, text[6..8], 10) catch return null;
        frac_start = 8;
    }
    var usec: i32 = 0;
    if (frac_start < text.len) {
        if (text[frac_start] != '.') return null;
        const frac = text[frac_start + 1 ..];
        if (frac.len == 0) return null;
        for (frac) |ch| if (!std.ascii.isDigit(ch)) return null;
        const keep = @min(frac.len, 6);
        var padded: [6]u8 = [_]u8{'0'} ** 6;
        @memcpy(padded[0..keep], frac[0..keep]);
        usec = std.fmt.parseInt(i32, padded[0..], 10) catch return null;
    }
    const time = Time{ .hour = hour, .minute = minute, .second = second, .usec = usec };
    if (!isValidTime(time)) return null;
    return time;
}

pub fn parseDateTime(text: []const u8) ?union(enum) {
    local_date: Date,
    local_time: Time,
    local_datetime: DateTime,
    datetime_tz: DateTimeTz,
} {
    if (parseDate(text)) |date| return .{ .local_date = date };
    if (parseTime(text)) |time| return .{ .local_time = time };

    const sep = std.mem.indexOfAny(u8, text, "Tt ") orelse return null;
    const date = parseDate(text[0..sep]) orelse return null;
    var time_end = text.len;
    var tz_minutes: ?i16 = null;
    if (text.len > sep + 1) {
        const tail = text[sep + 1 ..];
        if (tail.len == 0) return null;
        if (tail[tail.len - 1] == 'Z' or tail[tail.len - 1] == 'z') {
            time_end = text.len - 1;
            tz_minutes = 0;
        } else {
            var i: usize = tail.len;
            while (i > 0) : (i -= 1) {
                const idx = sep + 1 + i - 1;
                if ((text[idx] == '+' or text[idx] == '-') and idx + 6 == text.len and text[idx + 3] == ':') {
                    const sign: i16 = if (text[idx] == '-') -1 else 1;
                    const hour = std.fmt.parseInt(i16, text[idx + 1 .. idx + 3], 10) catch return null;
                    const min = std.fmt.parseInt(i16, text[idx + 4 .. idx + 6], 10) catch return null;
                    if (hour > 23 or min > 59) return null;
                    tz_minutes = sign * (hour * 60 + min);
                    time_end = idx;
                    break;
                }
            }
        }
    }

    const time = parseTime(text[sep + 1 .. time_end]) orelse return null;
    if (tz_minutes) |mins| {
        if (!isValidTz(mins)) return null;
        return .{ .datetime_tz = .{ .date = date, .time = time, .tz_minutes = mins } };
    }
    return .{ .local_datetime = .{ .date = date, .time = time } };
}
