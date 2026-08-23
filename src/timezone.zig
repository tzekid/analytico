const std = @import("std");

pub const default_zoneinfo_root = "/usr/share/zoneinfo";

const header_size: usize = 44;
const maximum_file_bytes: usize = 1024 * 1024;
const maximum_transitions: usize = 4096;
const maximum_types: usize = 256;
const maximum_abbreviation_bytes: usize = 4096;
const maximum_footer_bytes: usize = 512;
const minimum_offset_seconds: i32 = -89_999;
const maximum_offset_seconds: i32 = 93_599;

pub const Local = struct {
    date: [10]u8,
    offset_minutes: i16,
};

pub const Range = struct {
    start_utc_seconds: i64,
    end_utc_seconds: i64,
};

pub const RebucketInterval = struct {
    start_utc_micros: i64,
    end_utc_micros: i64,
    offset_minutes: i16,
};

const LocalType = struct {
    offset_seconds: i32,
    is_dst: bool,
};

const RuleKind = enum {
    julian_no_leap,
    zero_based,
    month_week_day,
};

const TransitionRule = struct {
    kind: RuleKind,
    day: u16 = 0,
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    seconds: i32 = 2 * 60 * 60,
};

const PosixRule = struct {
    standard_offset_seconds: i32,
    daylight_offset_seconds: ?i32 = null,
    start: TransitionRule = .{ .kind = .zero_based },
    end: TransitionRule = .{ .kind = .zero_based },

    fn typeAt(self: PosixRule, utc_seconds: i64) !LocalType {
        const daylight_offset = self.daylight_offset_seconds orelse return .{
            .offset_seconds = self.standard_offset_seconds,
            .is_dst = false,
        };
        const standard_local = try addSeconds(utc_seconds, self.standard_offset_seconds);
        const civil = civilFromDays(@divFloor(standard_local, 86_400));
        if (civil.year < 1 or civil.year > 9999) return error.DateOutOfRange;
        var latest_transition: ?i64 = null;
        var daylight = false;
        var year = civil.year - 1;
        while (year <= civil.year + 1) : (year += 1) {
            for ([_]struct { at: i64, daylight: bool }{
                .{
                    .at = try transitionUtc(
                        year,
                        self.start,
                        self.standard_offset_seconds,
                    ),
                    .daylight = true,
                },
                .{
                    .at = try transitionUtc(year, self.end, daylight_offset),
                    .daylight = false,
                },
            }) |transition| {
                if (transition.at <= utc_seconds and
                    (latest_transition == null or transition.at > latest_transition.?))
                {
                    latest_transition = transition.at;
                    daylight = transition.daylight;
                }
            }
        }
        if (latest_transition == null) return error.InvalidPosixFooter;
        return .{
            .offset_seconds = if (daylight)
                daylight_offset
            else
                self.standard_offset_seconds,
            .is_dst = daylight,
        };
    }

    fn appendTransitions(
        self: PosixRule,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(i64),
        first_year: i64,
        last_year: i64,
    ) !void {
        const daylight_offset = self.daylight_offset_seconds orelse return;
        var year = first_year;
        while (year <= last_year) : (year += 1) {
            try output.append(allocator, try transitionUtc(
                year,
                self.start,
                self.standard_offset_seconds,
            ));
            try output.append(allocator, try transitionUtc(
                year,
                self.end,
                daylight_offset,
            ));
        }
    }
};

pub const Zone = struct {
    transitions: []i64,
    transition_types: []u8,
    types: []LocalType,
    footer: ?PosixRule,

    pub fn deinit(self: *Zone, allocator: std.mem.Allocator) void {
        allocator.free(self.transitions);
        allocator.free(self.transition_types);
        allocator.free(self.types);
        self.* = undefined;
    }

    pub fn localAt(self: Zone, utc_seconds: i64) !Local {
        const local_type = try self.typeAt(utc_seconds);
        const offset_minutes = try exactOffsetMinutes(local_type.offset_seconds);
        const local_seconds = try addSeconds(utc_seconds, local_type.offset_seconds);
        const civil = civilFromDays(@divFloor(local_seconds, 86_400));
        return .{
            .date = try formatDate(civil),
            .offset_minutes = offset_minutes,
        };
    }

    pub fn rangeForInclusiveDates(
        self: Zone,
        start_date: []const u8,
        end_date: []const u8,
    ) !Range {
        const start = try parseDate(start_date);
        const end = try parseDate(end_date);
        const start_days = daysFromCivil(start.year, start.month, start.day);
        const end_days = daysFromCivil(end.year, end.month, end.day);
        if (end_days < start_days) return error.InvalidDateRange;
        const next_end = civilFromDays(try std.math.add(i64, end_days, 1));
        return .{
            .start_utc_seconds = try self.resolveBoundary(start, .earliest),
            .end_utc_seconds = try self.resolveBoundary(next_end, .latest),
        };
    }

    pub fn rebucketIntervals(
        self: Zone,
        allocator: std.mem.Allocator,
        minimum_utc_micros: i64,
        maximum_utc_micros: i64,
    ) ![]RebucketInterval {
        if (maximum_utc_micros < minimum_utc_micros) return error.InvalidDateRange;
        const minimum_seconds = @divFloor(minimum_utc_micros, 1_000_000);
        const maximum_seconds = @divFloor(maximum_utc_micros, 1_000_000);
        const minimum_civil = civilFromDays(@divFloor(minimum_seconds, 86_400));
        const maximum_civil = civilFromDays(@divFloor(maximum_seconds, 86_400));
        if (minimum_civil.year < 1 or maximum_civil.year > 9999) {
            return error.DateOutOfRange;
        }

        var candidates: std.ArrayList(i64) = .empty;
        defer candidates.deinit(allocator);
        for (self.transitions) |transition| {
            try candidates.append(allocator, transition);
        }
        if (self.footer) |footer| {
            try footer.appendTransitions(
                allocator,
                &candidates,
                minimum_civil.year -| 1,
                @min(maximum_civil.year + 1, 9999),
            );
        }
        std.mem.sort(i64, candidates.items, {}, std.sort.asc(i64));

        var result: std.ArrayList(RebucketInterval) = .empty;
        errdefer result.deinit(allocator);
        var start = minimum_utc_micros;
        var index: usize = 0;
        while (index < candidates.items.len) : (index += 1) {
            const transition = candidates.items[index];
            if (index != 0 and transition == candidates.items[index - 1]) continue;
            const transition_micros = std.math.mul(i64, transition, 1_000_000) catch
                continue;
            if (transition_micros <= start or transition_micros > maximum_utc_micros) {
                continue;
            }
            const before_type = try self.typeAt(transition - 1);
            const after_type = try self.typeAt(transition);
            if (before_type.offset_seconds == after_type.offset_seconds) continue;
            try result.append(allocator, .{
                .start_utc_micros = start,
                .end_utc_micros = transition_micros - 1,
                .offset_minutes = try exactOffsetMinutes(before_type.offset_seconds),
            });
            start = transition_micros;
        }
        const final_type = try self.typeAt(@divFloor(start, 1_000_000));
        try result.append(allocator, .{
            .start_utc_micros = start,
            .end_utc_micros = maximum_utc_micros,
            .offset_minutes = try exactOffsetMinutes(final_type.offset_seconds),
        });
        return result.toOwnedSlice(allocator);
    }

    fn typeAt(self: Zone, utc_seconds: i64) !LocalType {
        if (self.transitions.len == 0) {
            if (self.footer) |footer| return footer.typeAt(utc_seconds);
            return self.types[0];
        }
        if (utc_seconds < self.transitions[0]) return self.types[0];
        const last_index = self.transitions.len - 1;
        if (utc_seconds >= self.transitions[last_index]) {
            if (self.footer) |footer| return footer.typeAt(utc_seconds);
            return error.UnspecifiedLocalTime;
        }
        var low: usize = 0;
        var high: usize = self.transitions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.transitions[middle] <= utc_seconds) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return self.types[self.transition_types[low - 1]];
    }

    fn footerTransitionApplies(self: Zone, transition: i64) bool {
        if (self.footer == null) return true;
        return self.transitions.len == 0 or
            transition >= self.transitions[self.transitions.len - 1];
    }

    const BoundaryChoice = enum { earliest, latest };

    fn resolveBoundary(
        self: Zone,
        date: Civil,
        choice: BoundaryChoice,
    ) !i64 {
        if (date.year < 1970 or date.year > 9999) return error.DateOutOfRange;
        const local_seconds = try std.math.mul(
            i64,
            daysFromCivil(date.year, date.month, date.day),
            86_400,
        );
        var offsets: [maximum_types + 2]i32 = undefined;
        var offset_count: usize = 0;
        for (self.types) |local_type| {
            appendUniqueOffset(&offsets, &offset_count, local_type.offset_seconds);
        }
        if (self.footer) |footer| {
            appendUniqueOffset(&offsets, &offset_count, footer.standard_offset_seconds);
            if (footer.daylight_offset_seconds) |offset| {
                appendUniqueOffset(&offsets, &offset_count, offset);
            }
        }

        var selected: ?i64 = null;
        for (offsets[0..offset_count]) |offset| {
            const candidate = try addSeconds(local_seconds, -@as(i64, offset));
            const actual = self.typeAt(candidate) catch continue;
            if (actual.offset_seconds != offset) continue;
            if (selected == null or
                choice == .earliest and candidate < selected.? or
                choice == .latest and candidate > selected.?)
            {
                selected = candidate;
            }
        }
        if (selected) |instant| return instant;

        for (self.transitions) |transition| {
            if (try gapContains(self, transition, local_seconds)) return transition;
        }
        if (self.footer) |footer| {
            if (footer.daylight_offset_seconds) |daylight_offset| {
                var year = date.year - 1;
                while (year <= @min(date.year + 1, 9999)) : (year += 1) {
                    for ([_]i64{
                        try transitionUtc(
                            year,
                            footer.start,
                            footer.standard_offset_seconds,
                        ),
                        try transitionUtc(year, footer.end, daylight_offset),
                    }) |transition| {
                        if (!self.footerTransitionApplies(transition)) continue;
                        if (try gapContains(self, transition, local_seconds)) {
                            return transition;
                        }
                    }
                }
            }
        }
        return error.NonexistentLocalBoundary;
    }
};

pub fn validateZoneName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or name[0] == '/' or
        std.mem.findScalar(u8, name, 0) != null)
    {
        return error.InvalidZoneName;
    }
    var segments = std.mem.splitScalar(u8, name, '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        count += 1;
        if (segment.len == 0 or segment.len > 64 or
            std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
        {
            return error.InvalidZoneName;
        }
        for (segment) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or
                byte == '-' or byte == '+'))
            {
                return error.InvalidZoneName;
            }
        }
    }
    if (count == 0) return error.InvalidZoneName;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    zoneinfo_root: []const u8,
    name: []const u8,
) !Zone {
    try validateZoneName(name);
    if (!std.fs.path.isAbsolute(zoneinfo_root)) return error.InvalidZoneinfoRoot;
    const path = try std.fs.path.join(allocator, &.{ zoneinfo_root, name });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(maximum_file_bytes + 1),
    );
    defer allocator.free(bytes);
    if (bytes.len > maximum_file_bytes) return error.ZoneFileTooLarge;
    return parse(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Zone {
    if (bytes.len < header_size * 2) return error.InvalidTzif;
    const first = try parseHeader(bytes, 0);
    if (first.version != '2' and first.version != '3') return error.UnsupportedTzifVersion;
    const first_block_size = try blockSize(first, 4);
    const second_header_offset = try checkedAdd(header_size, first_block_size);
    const second = try parseHeader(bytes, second_header_offset);
    if (second.version != first.version) return error.InvalidTzif;
    try validateCounts(second);
    if (first.leap_count != 0 or second.leap_count != 0) {
        return error.UnsupportedLeapSeconds;
    }
    const second_block_offset = try checkedAdd(second_header_offset, header_size);
    const second_block_size = try blockSize(second, 8);
    const footer_offset = try checkedAdd(second_block_offset, second_block_size);
    if (footer_offset > bytes.len) return error.InvalidTzif;

    var cursor = second_block_offset;
    const transitions = try allocator.alloc(i64, second.time_count);
    errdefer allocator.free(transitions);
    for (transitions, 0..) |*transition, index| {
        transition.* = try readI64(bytes, &cursor);
        if (index != 0 and transition.* <= transitions[index - 1]) {
            return error.InvalidTzif;
        }
    }
    const transition_types = try allocator.alloc(u8, second.time_count);
    errdefer allocator.free(transition_types);
    if (cursor + transition_types.len > bytes.len) return error.InvalidTzif;
    @memcpy(transition_types, bytes[cursor .. cursor + transition_types.len]);
    cursor += transition_types.len;

    const types = try allocator.alloc(LocalType, second.type_count);
    errdefer allocator.free(types);
    const designation_indices = try allocator.alloc(u8, second.type_count);
    defer allocator.free(designation_indices);
    for (types, 0..) |*local_type, index| {
        const offset = try readI32(bytes, &cursor);
        if (offset == std.math.minInt(i32) or
            offset < minimum_offset_seconds or offset > maximum_offset_seconds)
        {
            return error.InvalidTzif;
        }
        const is_dst = try readByte(bytes, &cursor);
        if (is_dst > 1) return error.InvalidTzif;
        local_type.* = .{ .offset_seconds = offset, .is_dst = is_dst == 1 };
        designation_indices[index] = try readByte(bytes, &cursor);
    }
    if (cursor + second.character_count > bytes.len) return error.InvalidTzif;
    const designations = bytes[cursor .. cursor + second.character_count];
    cursor += second.character_count;
    if (designations.len == 0 or designations[designations.len - 1] != 0) {
        return error.InvalidTzif;
    }
    for (designation_indices) |designation_index| {
        if (designation_index >= designations.len) return error.InvalidTzif;
        const designation = std.mem.sliceTo(designations[designation_index..], 0);
        if (designation.len == designations.len - designation_index) {
            return error.InvalidTzif;
        }
        if (std.mem.eql(u8, designation, "-00")) return error.UnspecifiedLocalTime;
    }
    for (transition_types) |type_index| {
        if (type_index >= types.len) return error.InvalidTzif;
    }

    const indicators_offset = try checkedAdd(
        cursor,
        try checkedAdd(
            try checkedMul(second.leap_count, 12),
            second.standard_count,
        ),
    );
    if (indicators_offset + second.ut_count != footer_offset) return error.InvalidTzif;
    const standard_indicators = bytes[cursor .. cursor + second.standard_count];
    cursor += second.standard_count;
    const ut_indicators = bytes[cursor .. cursor + second.ut_count];
    for (standard_indicators) |value| if (value > 1) return error.InvalidTzif;
    for (ut_indicators, 0..) |value, index| {
        if (value > 1 or value == 1 and standard_indicators[index] != 1) {
            return error.InvalidTzif;
        }
    }

    const footer_bytes = bytes[footer_offset..];
    if (footer_bytes.len < 2 or footer_bytes.len > maximum_footer_bytes + 2 or
        footer_bytes[0] != '\n' or footer_bytes[footer_bytes.len - 1] != '\n')
    {
        return error.InvalidTzif;
    }
    const footer_text = footer_bytes[1 .. footer_bytes.len - 1];
    if (std.mem.findScalar(u8, footer_text, 0) != null) return error.InvalidTzif;
    const footer = if (footer_text.len == 0)
        null
    else
        try parsePosix(footer_text, second.version);

    var zone = Zone{
        .transitions = transitions,
        .transition_types = transition_types,
        .types = types,
        .footer = footer,
    };
    errdefer zone.deinit(allocator);
    if (transitions.len != 0 and footer != null) {
        const last_index = transitions.len - 1;
        const explicit = types[transition_types[last_index]];
        const continued = try footer.?.typeAt(transitions[last_index]);
        if (explicit.offset_seconds != continued.offset_seconds or
            explicit.is_dst != continued.is_dst)
        {
            return error.InconsistentTzifFooter;
        }
    }
    return zone;
}

const Header = struct {
    version: u8,
    ut_count: usize,
    standard_count: usize,
    leap_count: usize,
    time_count: usize,
    type_count: usize,
    character_count: usize,
};

fn parseHeader(bytes: []const u8, offset: usize) !Header {
    if (offset > bytes.len or bytes.len - offset < header_size) return error.InvalidTzif;
    if (!std.mem.eql(u8, bytes[offset .. offset + 4], "TZif")) return error.InvalidTzif;
    for (bytes[offset + 5 .. offset + 20]) |reserved| {
        if (reserved != 0) return error.InvalidTzif;
    }
    var cursor = offset + 20;
    return .{
        .version = bytes[offset + 4],
        .ut_count = try readU32(bytes, &cursor),
        .standard_count = try readU32(bytes, &cursor),
        .leap_count = try readU32(bytes, &cursor),
        .time_count = try readU32(bytes, &cursor),
        .type_count = try readU32(bytes, &cursor),
        .character_count = try readU32(bytes, &cursor),
    };
}

fn validateCounts(header: Header) !void {
    if (header.time_count > maximum_transitions or header.type_count == 0 or
        header.type_count > maximum_types or
        header.character_count == 0 or
        header.character_count > maximum_abbreviation_bytes or
        header.standard_count != 0 and header.standard_count != header.type_count or
        header.ut_count != 0 and header.ut_count != header.type_count or
        header.ut_count != 0 and header.standard_count == 0 or
        header.leap_count != 0)
    {
        return error.InvalidTzif;
    }
}

fn blockSize(header: Header, time_size: usize) !usize {
    if (header.time_count > maximum_transitions or header.type_count > maximum_types or
        header.character_count > maximum_abbreviation_bytes)
    {
        return error.InvalidTzif;
    }
    var size = try checkedMul(header.time_count, time_size);
    size = try checkedAdd(size, header.time_count);
    size = try checkedAdd(size, try checkedMul(header.type_count, 6));
    size = try checkedAdd(size, header.character_count);
    size = try checkedAdd(size, try checkedMul(header.leap_count, time_size + 4));
    size = try checkedAdd(size, header.standard_count);
    return checkedAdd(size, header.ut_count);
}

const PosixParser = struct {
    text: []const u8,
    index: usize = 0,
    version: u8,

    fn parse(self: *PosixParser) !PosixRule {
        try self.name();
        const standard_offset = try self.offset();
        if (self.index == self.text.len) return .{
            .standard_offset_seconds = standard_offset,
        };
        try self.name();
        var daylight_offset = try std.math.add(i32, standard_offset, 3600);
        if (self.index < self.text.len and self.text[self.index] != ',') {
            daylight_offset = try self.offset();
        }
        if (daylight_offset < minimum_offset_seconds or
            daylight_offset > maximum_offset_seconds)
        {
            return error.InvalidPosixFooter;
        }
        try self.expect(',');
        const start = try self.rule();
        try self.expect(',');
        const end = try self.rule();
        if (self.index != self.text.len) return error.InvalidPosixFooter;
        return .{
            .standard_offset_seconds = standard_offset,
            .daylight_offset_seconds = daylight_offset,
            .start = start,
            .end = end,
        };
    }

    fn name(self: *PosixParser) !void {
        const start = self.index;
        if (self.take('<')) {
            const inner = self.index;
            while (self.index < self.text.len and self.text[self.index] != '>') {
                const byte = self.text[self.index];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-')) {
                    return error.InvalidPosixFooter;
                }
                self.index += 1;
            }
            if (self.index - inner < 3 or self.index - inner > 16) {
                return error.InvalidPosixFooter;
            }
            try self.expect('>');
            return;
        }
        while (self.index < self.text.len and std.ascii.isAlphabetic(self.text[self.index])) {
            self.index += 1;
        }
        if (self.index - start < 3 or self.index - start > 16) {
            return error.InvalidPosixFooter;
        }
    }

    fn offset(self: *PosixParser) !i32 {
        const textual = try self.signedTime(25);
        const local_offset = try std.math.negate(textual);
        if (local_offset < minimum_offset_seconds or local_offset > maximum_offset_seconds) {
            return error.InvalidPosixFooter;
        }
        return local_offset;
    }

    fn rule(self: *PosixParser) !TransitionRule {
        var result: TransitionRule = undefined;
        if (self.take('J')) {
            const day = try self.unsigned(3);
            if (day < 1 or day > 365) return error.InvalidPosixFooter;
            result = .{ .kind = .julian_no_leap, .day = @intCast(day) };
        } else if (self.take('M')) {
            const month = try self.unsigned(2);
            try self.expect('.');
            const week = try self.unsigned(1);
            try self.expect('.');
            const weekday = try self.unsigned(1);
            if (month < 1 or month > 12 or week < 1 or week > 5 or weekday > 6) {
                return error.InvalidPosixFooter;
            }
            result = .{
                .kind = .month_week_day,
                .month = @intCast(month),
                .week = @intCast(week),
                .weekday = @intCast(weekday),
            };
        } else {
            const day = try self.unsigned(3);
            if (day > 365) return error.InvalidPosixFooter;
            result = .{ .kind = .zero_based, .day = @intCast(day) };
        }
        if (self.take('/')) {
            if (self.version == '2' and self.index < self.text.len and
                (self.text[self.index] == '-' or self.text[self.index] == '+'))
            {
                return error.InvalidPosixFooter;
            }
            result.seconds = try self.signedTime(if (self.version == '3') 167 else 24);
        }
        return result;
    }

    fn signedTime(self: *PosixParser, maximum_hours: u16) !i32 {
        var sign: i32 = 1;
        if (self.take('-')) sign = -1 else if (self.take('+')) sign = 1;
        const hours = try self.unsigned(3);
        if (hours > maximum_hours) return error.InvalidPosixFooter;
        var minutes: u16 = 0;
        var seconds: u16 = 0;
        if (self.take(':')) {
            minutes = try self.exactTwoDigits();
            if (minutes > 59) return error.InvalidPosixFooter;
            if (self.take(':')) {
                seconds = try self.exactTwoDigits();
                if (seconds > 59) return error.InvalidPosixFooter;
            }
        }
        const total = @as(i32, hours) * 3600 + @as(i32, minutes) * 60 +
            @as(i32, seconds);
        return sign * total;
    }

    fn unsigned(self: *PosixParser, maximum_digits: usize) !u16 {
        const start = self.index;
        var value: u16 = 0;
        while (self.index < self.text.len and self.index - start < maximum_digits and
            std.ascii.isDigit(self.text[self.index]))
        {
            value = try std.math.add(
                u16,
                try std.math.mul(u16, value, 10),
                self.text[self.index] - '0',
            );
            self.index += 1;
        }
        if (self.index == start) return error.InvalidPosixFooter;
        return value;
    }

    fn exactTwoDigits(self: *PosixParser) !u16 {
        if (self.index + 2 > self.text.len or
            !std.ascii.isDigit(self.text[self.index]) or
            !std.ascii.isDigit(self.text[self.index + 1]))
        {
            return error.InvalidPosixFooter;
        }
        const value = @as(u16, self.text[self.index] - '0') * 10 +
            (self.text[self.index + 1] - '0');
        self.index += 2;
        return value;
    }

    fn take(self: *PosixParser, byte: u8) bool {
        if (self.index >= self.text.len or self.text[self.index] != byte) return false;
        self.index += 1;
        return true;
    }

    fn expect(self: *PosixParser, byte: u8) !void {
        if (!self.take(byte)) return error.InvalidPosixFooter;
    }
};

fn parsePosix(text: []const u8, version: u8) !PosixRule {
    var parser = PosixParser{ .text = text, .version = version };
    return parser.parse();
}

fn transitionUtc(year: i64, rule: TransitionRule, offset_before: i32) !i64 {
    const day = switch (rule.kind) {
        .julian_no_leap => blk: {
            var ordinal: i64 = rule.day - 1;
            if (isLeapYear(year) and rule.day >= 60) ordinal += 1;
            break :blk ordinal;
        },
        .zero_based => rule.day,
        .month_week_day => blk: {
            const first = daysFromCivil(year, rule.month, 1);
            const first_weekday: i64 = @mod(first + 4, 7);
            var day_of_month: i64 = 1 + @mod(
                @as(i64, rule.weekday) - first_weekday,
                7,
            ) + @as(i64, rule.week - 1) * 7;
            const maximum = monthLength(year, rule.month);
            if (day_of_month > maximum) day_of_month -= 7;
            break :blk daysFromCivil(year, rule.month, @intCast(day_of_month)) -
                daysFromCivil(year, 1, 1);
        },
    };
    const local = try std.math.add(
        i64,
        try std.math.mul(
            i64,
            try std.math.add(i64, daysFromCivil(year, 1, 1), day),
            86_400,
        ),
        rule.seconds,
    );
    return addSeconds(local, -@as(i64, offset_before));
}

fn gapContains(zone: Zone, transition: i64, local_seconds: i64) !bool {
    if (transition == std.math.minInt(i64)) return false;
    const before = try zone.typeAt(transition - 1);
    const after = try zone.typeAt(transition);
    if (after.offset_seconds <= before.offset_seconds) return false;
    const gap_start = try addSeconds(transition, before.offset_seconds);
    const gap_end = try addSeconds(transition, after.offset_seconds);
    return local_seconds >= gap_start and local_seconds < gap_end;
}

fn exactOffsetMinutes(offset_seconds: i32) !i16 {
    if (@mod(offset_seconds, 60) != 0) return error.UnrepresentableUtcOffset;
    return @intCast(@divTrunc(offset_seconds, 60));
}

fn appendUniqueOffset(output: *[maximum_types + 2]i32, count: *usize, value: i32) void {
    for (output[0..count.*]) |existing| if (existing == value) return;
    output[count.*] = value;
    count.* += 1;
}

pub const Date = struct {
    year: i64,
    month: u8,
    day: u8,

    pub fn parse(text: []const u8) !Date {
        return parseDate(text);
    }

    pub fn format(self: Date) ![10]u8 {
        return formatDate(self);
    }

    pub fn dayNumber(self: Date) i64 {
        return daysFromCivil(self.year, self.month, self.day);
    }

    pub fn addDays(self: Date, delta: i64) !Date {
        const result = civilFromDays(try std.math.add(i64, self.dayNumber(), delta));
        if (result.year < 1970 or result.year > 9999) {
            return error.DateOutOfRange;
        }
        return result;
    }

    pub fn firstOfMonth(self: Date) Date {
        return .{ .year = self.year, .month = self.month, .day = 1 };
    }

    pub fn previousYear(self: Date) !Date {
        if (self.year <= 1970) return error.DateOutOfRange;
        const year = self.year - 1;
        return .{
            .year = year,
            .month = self.month,
            .day = @min(self.day, monthLength(year, self.month)),
        };
    }
};

const Civil = Date;

fn parseDate(text: []const u8) !Civil {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidDate;
    if (year < 1970 or year > 9999 or month < 1 or month > 12 or day < 1 or
        day > monthLength(year, month))
    {
        return error.InvalidDate;
    }
    return .{ .year = year, .month = month, .day = day };
}

fn formatDate(civil: Civil) ![10]u8 {
    if (civil.year < 1 or civil.year > 9999 or civil.month < 1 or
        civil.month > 12 or civil.day < 1 or
        civil.day > monthLength(civil.year, civil.month))
    {
        return error.DateOutOfRange;
    }
    var result: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u16, @intCast(civil.year)),
        civil.month,
        civil.day,
    });
    return result;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthLength(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(input_year: i64, month: u8, day: u8) i64 {
    var year = input_year;
    if (month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

fn civilFromDays(input_days: i64) Civil {
    const days = input_days + 719_468;
    const era = @divFloor(days, 146_097);
    const day_of_era = days - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) +
            @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100));
    const month_piece = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_piece + 2, 5) + 1;
    const month = month_piece + (if (month_piece < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

fn addSeconds(value: i64, delta: anytype) !i64 {
    return std.math.add(i64, value, @as(i64, delta));
}

fn checkedAdd(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch return error.InvalidTzif;
}

fn checkedMul(left: usize, right: usize) !usize {
    return std.math.mul(usize, left, right) catch return error.InvalidTzif;
}

fn readByte(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len) return error.InvalidTzif;
    defer cursor.* += 1;
    return bytes[cursor.*];
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 4) return error.InvalidTzif;
    const start = cursor.*;
    cursor.* += 4;
    return (@as(u32, bytes[start]) << 24) |
        (@as(u32, bytes[start + 1]) << 16) |
        (@as(u32, bytes[start + 2]) << 8) |
        bytes[start + 3];
}

fn readI32(bytes: []const u8, cursor: *usize) !i32 {
    return @bitCast(try readU32(bytes, cursor));
}

fn readI64(bytes: []const u8, cursor: *usize) !i64 {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 8) return error.InvalidTzif;
    const start = cursor.*;
    cursor.* += 8;
    var value: u64 = 0;
    for (bytes[start .. start + 8]) |byte| value = (value << 8) | byte;
    return @bitCast(value);
}

fn minimalUtcTzif() [114]u8 {
    var result: [114]u8 = @splat(0);
    for ([_]usize{ 0, 54 }) |header| {
        @memcpy(result[header .. header + 5], "TZif2");
        result[header + 39] = 1;
        result[header + 43] = 4;
    }
    @memcpy(result[50..54], "UTC\x00");
    @memcpy(result[104..108], "UTC\x00");
    @memcpy(result[108..114], "\nUTC0\n");
    return result;
}

test "pure TZif v2 fixture parses bounded UTC and local ranges" {
    const allocator = std.testing.allocator;
    const fixture = minimalUtcTzif();
    var zone = try parse(allocator, &fixture);
    defer zone.deinit(allocator);
    const local = try zone.localAt(1_709_164_800); // 2024-02-29T00:00:00Z
    try std.testing.expectEqualStrings("2024-02-29", &local.date);
    try std.testing.expectEqual(@as(i16, 0), local.offset_minutes);
    const range = try zone.rangeForInclusiveDates("2024-02-29", "2024-02-29");
    try std.testing.expectEqual(@as(i64, 86_400), range.end_utc_seconds - range.start_utc_seconds);
}

test "pure TZif fixtures reject malformed bounds and zone traversal" {
    const allocator = std.testing.allocator;
    var fixture = minimalUtcTzif();
    fixture[43] = 0;
    try std.testing.expectError(error.InvalidTzif, parse(allocator, &fixture));
    try std.testing.expectError(error.InvalidZoneName, validateZoneName("../UTC"));
    try std.testing.expectError(error.InvalidZoneName, validateZoneName("Europe//Berlin"));
    try std.testing.expectError(error.InvalidZoneName, validateZoneName("/etc/passwd"));
}

test "POSIX footer provides Berlin DST after explicit TZif transitions" {
    const rule = try parsePosix("CET-1CEST,M3.5.0,M10.5.0/3", '2');
    const before = try rule.typeAt(4_109_878_799); // 2100-03-28T00:59:59Z
    const after = try rule.typeAt(4_109_878_800); // 2100-03-28T01:00:00Z
    try std.testing.expectEqual(@as(i32, 3600), before.offset_seconds);
    try std.testing.expectEqual(@as(i32, 7200), after.offset_seconds);
}

test "real UTC and Europe Berlin zoneinfo cover DST leap day and footer future" {
    const allocator = std.testing.allocator;
    var utc = try load(allocator, std.testing.io, default_zoneinfo_root, "UTC");
    defer utc.deinit(allocator);
    var berlin = try load(
        allocator,
        std.testing.io,
        default_zoneinfo_root,
        "Europe/Berlin",
    );
    defer berlin.deinit(allocator);

    const leap = try berlin.localAt(1_709_164_800); // 2024-02-29T00:00:00Z
    try std.testing.expectEqualStrings("2024-02-29", &leap.date);
    try std.testing.expectEqual(@as(i16, 60), leap.offset_minutes);
    const before = try berlin.localAt(1_711_846_799); // 2024-03-31T00:59:59Z
    const after = try berlin.localAt(1_711_846_800); // 2024-03-31T01:00:00Z
    try std.testing.expectEqual(@as(i16, 60), before.offset_minutes);
    try std.testing.expectEqual(@as(i16, 120), after.offset_minutes);
    const spring = try berlin.rangeForInclusiveDates("2024-03-31", "2024-03-31");
    try std.testing.expectEqual(@as(i64, 23 * 3600), spring.end_utc_seconds - spring.start_utc_seconds);
    const autumn = try berlin.rangeForInclusiveDates("2024-10-27", "2024-10-27");
    try std.testing.expectEqual(@as(i64, 25 * 3600), autumn.end_utc_seconds - autumn.start_utc_seconds);
    const future = try berlin.localAt(4_109_878_800); // footer-derived 2100 DST
    try std.testing.expectEqual(@as(i16, 120), future.offset_minutes);
    const utc_leap = try utc.rangeForInclusiveDates("2024-02-29", "2024-02-29");
    try std.testing.expectEqual(@as(i64, 86_400), utc_leap.end_utc_seconds - utc_leap.start_utc_seconds);
}

test "local midnight gaps advance and overlaps select the latest next boundary" {
    var types = [_]LocalType{.{ .offset_seconds = 0, .is_dst = false }};
    const zone = Zone{
        .transitions = &.{},
        .transition_types = &.{},
        .types = &types,
        .footer = .{
            .standard_offset_seconds = 0,
            .daylight_offset_seconds = 3600,
            .start = .{
                .kind = .month_week_day,
                .month = 3,
                .week = 5,
                .weekday = 0,
                .seconds = 0,
            },
            .end = .{
                .kind = .month_week_day,
                .month = 10,
                .week = 5,
                .weekday = 0,
                .seconds = 3600,
            },
        },
    };
    const gap = try zone.rangeForInclusiveDates("2024-03-31", "2024-03-31");
    try std.testing.expectEqual(@as(i64, 23 * 3600), gap.end_utc_seconds - gap.start_utc_seconds);
    const overlap = try zone.rangeForInclusiveDates("2024-10-26", "2024-10-26");
    try std.testing.expectEqual(@as(i64, 25 * 3600), overlap.end_utc_seconds - overlap.start_utc_seconds);
}
