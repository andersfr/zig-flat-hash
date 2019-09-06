const std = @import("std");
const hash = std.hash;
const warn = std.debug.warn;
const assert = std.debug.assert;

const FlatHash = @import("flat_hash/base.zig").FlatHash;

const CityNative = switch(@sizeOf(usize)) {
    8 => hash.CityHash64,
    else => hash.CityHash32,
};

pub const DefaultHash = CityNative;

// Wrapper to force value field to void for set-like flat hashes
pub fn Set(comptime Key: type, comptime transferFn: var, comptime hashFn: var, comptime equalFn: var) type {
    return FlatHash(Key, void, transferFn, hashFn, equalFn);
}

// Wrapper for better name forwarding
pub const Map = FlatHash;

// Implementation of the very common String set type
pub const StringSet = Set([]const u8, dupe_u8, CityNative.hash, std.mem.eql);

// Implementation of the very common String->Value map type
pub fn Dictionary(comptime Value: type) type {
    return Map([]const u8, Value, dupe_u8, CityNative.hash, std.mem.eql);
}

fn dupe_u8(allocator: *std.mem.Allocator, src: []const u8) ![]u8 {
    return std.mem.dupe(allocator, u8, src);
}

test "flat_hash" {
    _ = @import("flat_hash/tests.zig");
}
