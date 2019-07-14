const std = @import("std");
const testing = std.testing;
const allocator = std.heap.c_allocator;

const FlatHash = @import("../flat_hash.zig");
const Ctrl = @import("ctrl.zig").Ctrl;

fn noHash(v: usize) usize {
    return v;
}

test "set" {
    var set = FlatHash.StringSet.init(allocator);
    defer set.deinitAndFreeKeys();
    errdefer testing.expect(false);

    _ = try set.insert("hello");
    _ = try set.insert("world");

    testing.expectEqual(set.contains("hello"), true);
    testing.expectEqual(set.contains("world"), true);
    testing.expectEqual(set.size, 2);

    if(set.erase("hello")) |kv| {
        testing.expectEqualSlices(u8, "hello", kv.key);
        set.allocator.free(kv.key);
    }
    testing.expect(!set.contains("hello"));
    testing.expectEqual(set.size, 1);

    var it = set.iterator();
    if(it.next()) |kv| {
        testing.expectEqualSlices(u8, "world", kv.key);
    }
    else {
        testing.expect(false);
    }
    testing.expectEqual(it.next(), null);
}

test "rehash" {
    var set = FlatHash.Set(usize, null, noHash, null).init(allocator);
    defer set.deinit();
    errdefer testing.expect(false);
    
    try set.reserve(16);

    var i: usize = 0;
    while(set.growth_left > 0) : (i += 1) {
        _ = try set.insert(i);
    }
    var e = i;
    i = 0;
    while(i < e) : (i += 1) {
        testing.expect(set.ctrl[i] >= 0);
    }
    i = 0;
    while(i < 16) : (i += 1) {
        _ = set.erase(i);
    }
    i = 0;
    while(i < 16) : (i += 1) {
        testing.expect(set.ctrl[i] == Ctrl.kDeleted);
    }
    while(i < e) : (i += 1) {
        testing.expect(set.ctrl[i] >= 0);
    }
    _ = try set.insert(128*16);
    i = 0;
    while(i <= set.capacity) : (i += 1) {
        testing.expect(set.ctrl[i] != Ctrl.kDeleted);
    }
}
