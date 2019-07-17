const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;

const FlatHash = @import("flat_hash.zig");

const hashUint64 = std.hash.Murmur3_32.hashUint64;
const hashUint32 = std.hash.Murmur3_32.hashUint32;

// Wrapper necessary due to type mismatch
fn hashInt64(v: i64) u64 {
    return hashUint64(@bitCast(u64, v));
}

// Wrapper necessary due to type mismatch
fn hashInt32(v: i32) u32 {
    return hashUint32(@bitCast(u32, v));
}

// Implementation of a String->Index type that allows easy 2-way mapping from strings to 0-indexed integers
pub fn StringIndexMap(comptime IndexT: type) type {
    return IndexMap([]const u8, IndexT);
}

// Default implementation is suitable for 2-way mapping from integers to 0-indexed integers
const IntIndexMap = IndexMap;

fn IndexMap(comptime KeyT: type, comptime IndexT: type) type {
    const LoweredKeyT = switch(KeyT) {
        usize => @IntType(false, @sizeOf(usize)*8),
        isize => @IntType(true, @sizeOf(isize)*8),
        else => KeyT,
    };
    const LookupT = switch(LoweredKeyT) {
        []const u8 => FlatHash.Dictionary(IndexT),
        u64 => FlatHash.Map(KeyT, IndexT, null, hashUint64, null),
        i64 => FlatHash.Map(KeyT, IndexT, null, hashInt64, null),
        u32, u16, u8 => FlatHash.Map(KeyT, IndexT, null, hashUint32, null),
        i32, i16, i8 => FlatHash.Map(KeyT, IndexT, null, hashInt32, null),
        else => unreachable,
    };
    const MustFree = switch(KeyT) {
        []const u8 => true,
        else => false,
    };

    return struct {
        keys: [*]KeyT = undefined,
        capacity: usize = 0,
        lookup: LookupT,

        const Self = @This();

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{ .lookup = LookupT.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            if(self.capacity > 0) {
                self.lookup.allocator.free(self.keys[0..self.capacity]);
            }
            if(MustFree) {
                self.lookup.deinitAndFreeKeys();
            }
            else {
                self.lookup.deinit();
            }
        }

        pub fn insert(self: *Self, key: KeyT) !IndexT {
            const result = try self.lookup.insert(key);
            const index = self.lookup.size-1;
            if(result.is_new) {
                result.kv.value = @intCast(IndexT, index);
                if(index >= self.capacity) {
                    const new_keys = try self.lookup.allocator.alloc(KeyT, self.lookup.capacity);
                    var i: usize = 0;
                    while(i < index) : (i += 1) {
                        new_keys[i] = self.keys[i];
                    }
                    self.capacity = new_keys.len;
                    self.keys = new_keys.ptr;
                }
                self.keys[index] = result.kv.key;
                return result.kv.value;
            }
            return result.kv.value;
        }

        pub fn indexOf(self: Self, key: KeyT) ?IndexT {
            if(self.lookup.find(key)) |kv| {
                return kv.value;
            }
            return null;
        }

        pub fn keyOf(self: Self, index: IndexT) KeyT {
            const uindex = @intCast(usize, index);
            assert(index >= 0);
            assert(uindex < self.lookup.size);

            return self.keys[uindex];
        }

        pub fn keySlice(self: Self) []KeyT {
            return self.keys[0..self.lookup.size];
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self);
        }

        const Iterator = struct {
            owner: *Self,
            index: usize = 0,

            fn init(owner: *Self) Iterator {
                return Iterator{ .owner = owner };
            }

            fn next(self: *Iterator) ?KeyT {
                const index = self.index;
                if(index >= self.owner.lookup.size) {
                    return null;
                }
                self.index += 1;
                return self.owner.keys[index];
            }
        };
    };
}

test "int_index_map" {
    var map = IndexMap(isize, isize).init(std.heap.c_allocator);
    defer map.deinit();

    _ = try map.insert(-2);
    _ = try map.insert(20);
}

test "string_index_map" {
    var map = StringIndexMap(isize).init(std.heap.c_allocator);
    defer map.deinit();

    _ = try map.insert("hello");
    _ = try map.insert("world");
    _ = try map.insert("world");
    _ = try map.insert("world!");
}
