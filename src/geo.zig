//! IP to country, region and city at ingest. The address is looked up and
//! discarded; only the place names are stored. The data comes from the DB-IP
//! IP to City Lite database (CC BY 4.0), converted by `analytico geo import`
//! into one compact file that the server maps read-only.
const std = @import("std");

pub const file_name = "geo.bin";
const magic = "ANGEO001";
const header_len = 32;

pub const Place = struct {
    /// ISO 3166-1 alpha-2, uppercase.
    country: []const u8,
    region: []const u8,
    city: []const u8,
};

/// Visitors here are asked before anything beyond Lite is collected under the
/// default "ask in the EU, UK and Switzerland" policy.
pub fn consentRegion(country: ?[]const u8) bool {
    const code = country orelse return true;
    const listed = [_][]const u8{
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT",
        "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO",
        "GB", "CH", "GG", "JE", "IM", "GI",
    };
    for (listed) |item| if (std.mem.eql(u8, item, code)) return true;
    return false;
}

/// Layout, all integers little-endian:
///   magic[8] v4_count:u32 v6_count:u32 place_count:u32 strings_len:u32 pad[8]
///   v4_start[v4_count]:u32  v4_place[v4_count]:u32
///   v6_start[v6_count]:u64 (upper 64 bits)  v6_place[v6_count]:u32
///   place_offset[place_count]:u32  place_len[place_count]:u32
///   strings: "CC\x00region\x00city" per place
/// Ranges are contiguous: each one ends where the next starts.
pub const Geo = struct {
    map: std.Io.File.MemoryMap,
    file: std.Io.File,
    v4_start: []align(1) const u32,
    v4_place: []align(1) const u32,
    v6_start: []align(1) const u64,
    v6_place: []align(1) const u32,
    place_offset: []align(1) const u32,
    place_len: []align(1) const u32,
    strings: []const u8,

    pub fn open(io: std.Io, path: []const u8) !Geo {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.size < header_len) return error.InvalidGeoFile;
        var map = try std.Io.File.MemoryMap.create(io, file, .{
            .len = @intCast(stat.size),
            .protection = .{ .read = true, .write = false },
            .populate = false,
        });
        errdefer map.destroy(io);
        const bytes = map.memory;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidGeoFile;
        const v4_count: usize = std.mem.readInt(u32, bytes[8..12], .little);
        const v6_count: usize = std.mem.readInt(u32, bytes[12..16], .little);
        const place_count: usize = std.mem.readInt(u32, bytes[16..20], .little);
        const strings_len: usize = std.mem.readInt(u32, bytes[20..24], .little);
        const expected = header_len + v4_count * 8 + v6_count * 12 + place_count * 8 + strings_len;
        if (expected != bytes.len or v4_count == 0) return error.InvalidGeoFile;
        var at: usize = header_len;
        const out: Geo = .{
            .map = map,
            .file = file,
            .v4_start = slice(u32, bytes, &at, v4_count),
            .v4_place = slice(u32, bytes, &at, v4_count),
            .v6_start = slice(u64, bytes, &at, v6_count),
            .v6_place = slice(u32, bytes, &at, v6_count),
            .place_offset = slice(u32, bytes, &at, place_count),
            .place_len = slice(u32, bytes, &at, place_count),
            .strings = bytes[at..],
        };
        return out;
    }

    pub fn close(self: *Geo, io: std.Io) void {
        self.map.destroy(io);
        self.file.close(io);
        self.* = undefined;
    }

    pub fn lookup(self: *const Geo, address: []const u8) ?Place {
        const parsed = std.Io.net.IpAddress.parse(address, 0) catch return null;
        const index = switch (parsed) {
            .ip4 => |ip| self.place(self.v4_start, self.v4_place, std.mem.readInt(u32, &ip.bytes, .big)),
            .ip6 => |ip| blk: {
                // IPv4-mapped IPv6 addresses use the IPv4 table.
                if (std.mem.eql(u8, ip.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                    break :blk self.place(self.v4_start, self.v4_place, std.mem.readInt(u32, ip.bytes[12..16], .big));
                }
                break :blk self.place(self.v6_start, self.v6_place, std.mem.readInt(u64, ip.bytes[0..8], .big));
            },
        } orelse return null;
        if (index >= self.place_offset.len) return null;
        const offset = self.place_offset[index];
        const len = self.place_len[index];
        if (@as(usize, offset) + len > self.strings.len) return null;
        var parts = std.mem.splitScalar(u8, self.strings[offset..][0..len], 0);
        const country = parts.next() orelse return null;
        if (country.len != 2 or std.mem.eql(u8, country, "ZZ")) return null;
        return .{ .country = country, .region = parts.next() orelse "", .city = parts.next() orelse "" };
    }

    fn place(_: *const Geo, starts: anytype, places: []align(1) const u32, key: anytype) ?u32 {
        if (starts.len == 0) return null;
        // Last range starting at or before the key.
        var low: usize = 0;
        var high: usize = starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (starts[middle] <= key) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        return places[low - 1];
    }
};

fn slice(comptime T: type, bytes: []const u8, at: *usize, count: usize) []align(1) const T {
    const start = at.*;
    at.* += count * @sizeOf(T);
    return std.mem.bytesAsSlice(T, bytes[start..at.*]);
}

// ---------------------------------------------------------------- import

pub const ImportStats = struct { v4: usize, v6: usize, places: usize, bytes: usize };

const Range = struct { start: u64, place: u32 };

/// Converts a DB-IP "IP to City Lite" CSV (optionally gzip-compressed) into
/// `destination`. Columns: ip_start, ip_end, continent, country, region,
/// city, latitude, longitude. Coordinates are not kept.
pub fn import(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !ImportStats {
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    const file_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(file_buffer);
    var file_reader = file.reader(io, file_buffer);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress: std.compress.flate.Decompress = undefined;
    const gzipped = std.mem.endsWith(u8, source, ".gz");
    const reader: *std.Io.Reader = if (gzipped) blk: {
        decompress = .init(&file_reader.interface, .gzip, window);
        break :blk &decompress.reader;
    } else &file_reader.interface;

    var places: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var keys = places.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        places.deinit(allocator);
    }
    var place_list: std.ArrayList([]const u8) = .empty;
    defer place_list.deinit(allocator);
    var v4_ranges: Ranges = .{};
    defer v4_ranges.list.deinit(allocator);
    var v6_ranges: Ranges = .{};
    defer v6_ranges.list.deinit(allocator);
    const unknown = try intern(allocator, &places, &place_list, "ZZ\x00\x00");

    var line_number: usize = 0;
    var key_buffer: std.ArrayList(u8) = .empty;
    defer key_buffer.deinit(allocator);
    while (try reader.takeDelimiter('\n')) |raw| {
        line_number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields: [8][]const u8 = undefined;
        var scratch: [1024]u8 = undefined;
        const count = splitCsv(line, &fields, &scratch) catch return error.InvalidGeoCsv;
        if (count < 6) return error.InvalidGeoCsv;
        key_buffer.clearRetainingCapacity();
        try key_buffer.appendSlice(allocator, fields[3]);
        try key_buffer.append(allocator, 0);
        try key_buffer.appendSlice(allocator, fields[4]);
        try key_buffer.append(allocator, 0);
        try key_buffer.appendSlice(allocator, fields[5]);
        if (fields[3].len != 2) return error.InvalidGeoCsv;
        const index = try intern(allocator, &places, &place_list, key_buffer.items);
        const start = std.Io.net.IpAddress.parse(fields[0], 0) catch return error.InvalidGeoCsv;
        const end = std.Io.net.IpAddress.parse(fields[1], 0) catch return error.InvalidGeoCsv;
        switch (start) {
            .ip4 => |ip| {
                if (end != .ip4) return error.InvalidGeoCsv;
                // IPv4 values are widened; the last range ends the table.
                const last = std.mem.readInt(u32, &end.ip4.bytes, .big);
                try v4_ranges.append(allocator, std.mem.readInt(u32, &ip.bytes, .big), if (last == std.math.maxInt(u32)) std.math.maxInt(u64) else last, index, unknown);
            },
            .ip6 => |ip| {
                if (end != .ip6) return error.InvalidGeoCsv;
                try v6_ranges.append(allocator, std.mem.readInt(u64, ip.bytes[0..8], .big), std.mem.readInt(u64, end.ip6.bytes[0..8], .big), index, unknown);
            },
        }
    }
    const v4 = v4_ranges.list;
    const v6 = v6_ranges.list;
    if (v4.items.len == 0) return error.InvalidGeoCsv;

    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(allocator);
    const offsets = try allocator.alloc(u32, place_list.items.len);
    defer allocator.free(offsets);
    for (place_list.items, 0..) |place, index| {
        offsets[index] = @intCast(strings.items.len);
        try strings.appendSlice(allocator, place);
    }

    const out = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true, .permissions = @fromBackingInt(@intCast(0o644)) });
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    defer out.close(io);
    const write_buffer = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(write_buffer);
    var file_writer = out.writer(io, write_buffer);
    const w = &file_writer.interface;
    try w.writeAll(magic);
    try w.writeInt(u32, @intCast(v4.items.len), .little);
    try w.writeInt(u32, @intCast(v6.items.len), .little);
    try w.writeInt(u32, @intCast(place_list.items.len), .little);
    try w.writeInt(u32, @intCast(strings.items.len), .little);
    try w.writeAll(&@as([8]u8, @splat(0)));
    for (v4.items) |range| try w.writeInt(u32, @intCast(range.start), .little);
    for (v4.items) |range| try w.writeInt(u32, range.place, .little);
    for (v6.items) |range| try w.writeInt(u64, range.start, .little);
    for (v6.items) |range| try w.writeInt(u32, range.place, .little);
    for (offsets) |offset| try w.writeInt(u32, offset, .little);
    for (place_list.items) |place| try w.writeInt(u32, @intCast(place.len), .little);
    try w.writeAll(strings.items);
    try w.flush();
    try out.sync(io);
    return .{
        .v4 = v4.items.len,
        .v6 = v6.items.len,
        .places = place_list.items.len,
        .bytes = header_len + v4.items.len * 8 + v6.items.len * 12 + place_list.items.len * 8 + strings.items.len,
    };
}

const Ranges = struct {
    list: std.ArrayList(Range) = .empty,
    /// One past the end of the last appended range; null before the first.
    next: ?u64 = null,
    done: bool = false,

    /// Appends a range, filling any gap before it as unknown and merging it
    /// with the previous range when both name the same place.
    fn append(self: *Ranges, allocator: std.mem.Allocator, start: u64, end: u64, place: u32, unknown: u32) !void {
        if (end < start) return error.InvalidGeoCsv;
        if (self.done) return;
        const expected = self.next orelse 0;
        // Truncated IPv6 keys can overlap; the first range keeps the prefix.
        if (self.next != null and start < expected) {
            if (end >= expected) self.next = if (end == std.math.maxInt(u64)) null else end + 1;
            if (end == std.math.maxInt(u64)) self.done = true;
            return;
        }
        if (start > expected) try self.push(allocator, expected, unknown);
        try self.push(allocator, start, place);
        if (end == std.math.maxInt(u64)) {
            self.done = true;
        } else self.next = end + 1;
    }

    fn push(self: *Ranges, allocator: std.mem.Allocator, start: u64, place: u32) !void {
        if (self.list.items.len != 0 and self.list.items[self.list.items.len - 1].place == place) return;
        try self.list.append(allocator, .{ .start = start, .place = place });
    }
};

fn intern(allocator: std.mem.Allocator, places: *std.StringHashMapUnmanaged(u32), list: *std.ArrayList([]const u8), key: []const u8) !u32 {
    if (places.get(key)) |index| return index;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    const index: u32 = @intCast(list.items.len);
    try places.put(allocator, owned, index);
    try list.append(allocator, owned);
    return index;
}

/// Splits one CSV line into at most `out.len` fields. Quoted fields may
/// contain commas and doubled quotes; unescaped text goes into `scratch`.
fn splitCsv(line: []const u8, out: [][]const u8, scratch: []u8) !usize {
    var count: usize = 0;
    var index: usize = 0;
    var used: usize = 0;
    while (index <= line.len and count < out.len) {
        if (index < line.len and line[index] == '"') {
            const start = used;
            index += 1;
            while (true) {
                if (index >= line.len) return error.InvalidCsv;
                if (line[index] == '"') {
                    if (index + 1 < line.len and line[index + 1] == '"') {
                        if (used == scratch.len) return error.InvalidCsv;
                        scratch[used] = '"';
                        used += 1;
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                if (used == scratch.len) return error.InvalidCsv;
                scratch[used] = line[index];
                used += 1;
                index += 1;
            }
            out[count] = scratch[start..used];
            count += 1;
            if (index < line.len and line[index] != ',') return error.InvalidCsv;
            index += 1;
        } else {
            const comma = std.mem.findScalarPos(u8, line, index, ',') orelse line.len;
            out[count] = line[index..comma];
            count += 1;
            index = comma + 1;
        }
    }
    return count;
}

test "csv fields" {
    var fields: [8][]const u8 = undefined;
    var scratch: [128]u8 = undefined;
    const count = try splitCsv("1.0.0.0,1.0.0.255,OC,AU,Queensland,\"South Brisbane, East\",-27.4,153.0", &fields, &scratch);
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqualStrings("South Brisbane, East", fields[5]);
    _ = try splitCsv("41.76.0.0,41.76.3.255,AF,MZ,\"Maputo City\",\"Maputo (Polana Cimento\"\"A\"\")\",-25.9,32.5", &fields, &scratch);
    try std.testing.expectEqualStrings("Maputo (Polana Cimento\"A\")", fields[5]);
    try std.testing.expect(consentRegion("DE"));
    try std.testing.expect(consentRegion(null));
    try std.testing.expect(!consentRegion("US"));
}

/// English short names for ISO 3166-1 alpha-2 codes.
pub fn countryName(code: []const u8) []const u8 {
    for (countries) |entry| if (std.mem.eql(u8, entry[0], code)) return entry[1];
    return code;
}

const countries = [_][2][]const u8{
    .{ "AD", "Andorra" },                   .{ "AE", "United Arab Emirates" },     .{ "AF", "Afghanistan" },                      .{ "AG", "Antigua and Barbuda" },
    .{ "AI", "Anguilla" },                  .{ "AL", "Albania" },                  .{ "AM", "Armenia" },                          .{ "AO", "Angola" },
    .{ "AQ", "Antarctica" },                .{ "AR", "Argentina" },                .{ "AS", "American Samoa" },                   .{ "AT", "Austria" },
    .{ "AU", "Australia" },                 .{ "AW", "Aruba" },
    .{ "AX", "Åland Islands" },
    .{ "AZ", "Azerbaijan" },                .{ "BA", "Bosnia and Herzegovina" },   .{ "BB", "Barbados" },                         .{ "BD", "Bangladesh" },
    .{ "BE", "Belgium" },                   .{ "BF", "Burkina Faso" },             .{ "BG", "Bulgaria" },                         .{ "BH", "Bahrain" },
    .{ "BI", "Burundi" },                   .{ "BJ", "Benin" },
    .{ "BL", "Saint Barthélemy" },
    .{ "BM", "Bermuda" },                   .{ "BN", "Brunei" },                   .{ "BO", "Bolivia" },                          .{ "BQ", "Caribbean Netherlands" },
    .{ "BR", "Brazil" },                    .{ "BS", "Bahamas" },                  .{ "BT", "Bhutan" },                           .{ "BW", "Botswana" },
    .{ "BY", "Belarus" },                   .{ "BZ", "Belize" },                   .{ "CA", "Canada" },                           .{ "CC", "Cocos Islands" },
    .{ "CD", "DR Congo" },                  .{ "CF", "Central African Republic" }, .{ "CG", "Congo" },                            .{ "CH", "Switzerland" },
    .{ "CI", "Côte d’Ivoire" },
    .{ "CK", "Cook Islands" },              .{ "CL", "Chile" },                    .{ "CM", "Cameroon" },                         .{ "CN", "China" },
    .{ "CO", "Colombia" },                  .{ "CR", "Costa Rica" },               .{ "CU", "Cuba" },                             .{ "CV", "Cape Verde" },
    .{ "CW", "Curaçao" },
    .{ "CX", "Christmas Island" },          .{ "CY", "Cyprus" },                   .{ "CZ", "Czechia" },                          .{ "DE", "Germany" },
    .{ "DJ", "Djibouti" },                  .{ "DK", "Denmark" },                  .{ "DM", "Dominica" },                         .{ "DO", "Dominican Republic" },
    .{ "DZ", "Algeria" },                   .{ "EC", "Ecuador" },                  .{ "EE", "Estonia" },                          .{ "EG", "Egypt" },
    .{ "EH", "Western Sahara" },            .{ "ER", "Eritrea" },                  .{ "ES", "Spain" },                            .{ "ET", "Ethiopia" },
    .{ "FI", "Finland" },                   .{ "FJ", "Fiji" },                     .{ "FK", "Falkland Islands" },                 .{ "FM", "Micronesia" },
    .{ "FO", "Faroe Islands" },             .{ "FR", "France" },                   .{ "GA", "Gabon" },                            .{ "GB", "United Kingdom" },
    .{ "GD", "Grenada" },                   .{ "GE", "Georgia" },                  .{ "GF", "French Guiana" },                    .{ "GG", "Guernsey" },
    .{ "GH", "Ghana" },                     .{ "GI", "Gibraltar" },                .{ "GL", "Greenland" },                        .{ "GM", "Gambia" },
    .{ "GN", "Guinea" },                    .{ "GP", "Guadeloupe" },               .{ "GQ", "Equatorial Guinea" },                .{ "GR", "Greece" },
    .{ "GT", "Guatemala" },                 .{ "GU", "Guam" },                     .{ "GW", "Guinea-Bissau" },                    .{ "GY", "Guyana" },
    .{ "HK", "Hong Kong" },                 .{ "HN", "Honduras" },                 .{ "HR", "Croatia" },                          .{ "HT", "Haiti" },
    .{ "HU", "Hungary" },                   .{ "ID", "Indonesia" },                .{ "IE", "Ireland" },                          .{ "IL", "Israel" },
    .{ "IM", "Isle of Man" },               .{ "IN", "India" },                    .{ "IO", "British Indian Ocean Territory" },   .{ "IQ", "Iraq" },
    .{ "IR", "Iran" },                      .{ "IS", "Iceland" },                  .{ "IT", "Italy" },                            .{ "JE", "Jersey" },
    .{ "JM", "Jamaica" },                   .{ "JO", "Jordan" },                   .{ "JP", "Japan" },                            .{ "KE", "Kenya" },
    .{ "KG", "Kyrgyzstan" },                .{ "KH", "Cambodia" },                 .{ "KI", "Kiribati" },                         .{ "KM", "Comoros" },
    .{ "KN", "Saint Kitts and Nevis" },     .{ "KP", "North Korea" },              .{ "KR", "South Korea" },                      .{ "KW", "Kuwait" },
    .{ "KY", "Cayman Islands" },            .{ "KZ", "Kazakhstan" },               .{ "LA", "Laos" },                             .{ "LB", "Lebanon" },
    .{ "LC", "Saint Lucia" },               .{ "LI", "Liechtenstein" },            .{ "LK", "Sri Lanka" },                        .{ "LR", "Liberia" },
    .{ "LS", "Lesotho" },                   .{ "LT", "Lithuania" },                .{ "LU", "Luxembourg" },                       .{ "LV", "Latvia" },
    .{ "LY", "Libya" },                     .{ "MA", "Morocco" },                  .{ "MC", "Monaco" },                           .{ "MD", "Moldova" },
    .{ "ME", "Montenegro" },                .{ "MF", "Saint Martin" },             .{ "MG", "Madagascar" },                       .{ "MH", "Marshall Islands" },
    .{ "MK", "North Macedonia" },           .{ "ML", "Mali" },                     .{ "MM", "Myanmar" },                          .{ "MN", "Mongolia" },
    .{ "MO", "Macao" },                     .{ "MP", "Northern Mariana Islands" }, .{ "MQ", "Martinique" },                       .{ "MR", "Mauritania" },
    .{ "MS", "Montserrat" },                .{ "MT", "Malta" },                    .{ "MU", "Mauritius" },                        .{ "MV", "Maldives" },
    .{ "MW", "Malawi" },                    .{ "MX", "Mexico" },                   .{ "MY", "Malaysia" },                         .{ "MZ", "Mozambique" },
    .{ "NA", "Namibia" },                   .{ "NC", "New Caledonia" },            .{ "NE", "Niger" },                            .{ "NF", "Norfolk Island" },
    .{ "NG", "Nigeria" },                   .{ "NI", "Nicaragua" },                .{ "NL", "Netherlands" },                      .{ "NO", "Norway" },
    .{ "NP", "Nepal" },                     .{ "NR", "Nauru" },                    .{ "NU", "Niue" },                             .{ "NZ", "New Zealand" },
    .{ "OM", "Oman" },                      .{ "PA", "Panama" },                   .{ "PE", "Peru" },                             .{ "PF", "French Polynesia" },
    .{ "PG", "Papua New Guinea" },          .{ "PH", "Philippines" },              .{ "PK", "Pakistan" },                         .{ "PL", "Poland" },
    .{ "PM", "Saint Pierre and Miquelon" }, .{ "PR", "Puerto Rico" },              .{ "PS", "Palestine" },                        .{ "PT", "Portugal" },
    .{ "PW", "Palau" },                     .{ "PY", "Paraguay" },                 .{ "QA", "Qatar" },
    .{ "RE", "Réunion" },
    .{ "RO", "Romania" },                   .{ "RS", "Serbia" },                   .{ "RU", "Russia" },                           .{ "RW", "Rwanda" },
    .{ "SA", "Saudi Arabia" },              .{ "SB", "Solomon Islands" },          .{ "SC", "Seychelles" },                       .{ "SD", "Sudan" },
    .{ "SE", "Sweden" },                    .{ "SG", "Singapore" },                .{ "SI", "Slovenia" },                         .{ "SK", "Slovakia" },
    .{ "SL", "Sierra Leone" },              .{ "SM", "San Marino" },               .{ "SN", "Senegal" },                          .{ "SO", "Somalia" },
    .{ "SR", "Suriname" },                  .{ "SS", "South Sudan" },
    .{ "ST", "São Tomé and Príncipe" },
    .{ "SV", "El Salvador" },               .{ "SX", "Sint Maarten" },             .{ "SY", "Syria" },                            .{ "SZ", "Eswatini" },
    .{ "TC", "Turks and Caicos Islands" },  .{ "TD", "Chad" },                     .{ "TG", "Togo" },                             .{ "TH", "Thailand" },
    .{ "TJ", "Tajikistan" },                .{ "TL", "Timor-Leste" },              .{ "TM", "Turkmenistan" },                     .{ "TN", "Tunisia" },
    .{ "TO", "Tonga" },
    .{ "TR", "Türkiye" },
    .{ "TT", "Trinidad and Tobago" },       .{ "TV", "Tuvalu" },                   .{ "TW", "Taiwan" },                           .{ "TZ", "Tanzania" },
    .{ "UA", "Ukraine" },                   .{ "UG", "Uganda" },                   .{ "US", "United States" },                    .{ "UY", "Uruguay" },
    .{ "UZ", "Uzbekistan" },                .{ "VA", "Vatican City" },             .{ "VC", "Saint Vincent and the Grenadines" }, .{ "VE", "Venezuela" },
    .{ "VG", "British Virgin Islands" },    .{ "VI", "U.S. Virgin Islands" },      .{ "VN", "Vietnam" },                          .{ "VU", "Vanuatu" },
    .{ "WF", "Wallis and Futuna" },         .{ "WS", "Samoa" },                    .{ "XK", "Kosovo" },                           .{ "YE", "Yemen" },
    .{ "YT", "Mayotte" },                   .{ "ZA", "South Africa" },             .{ "ZM", "Zambia" },                           .{ "ZW", "Zimbabwe" },
};
