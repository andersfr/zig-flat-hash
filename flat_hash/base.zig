const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Group = @import("group.zig").Group;
const ProbeSeq = @import("probe_seq.zig").ProbeSeq;
const Ctrl = @import("ctrl.zig").Ctrl;

pub fn FlatHash(comptime Key: type, comptime SlotValue: type, comptime transferFn: var, comptime hashFn: var, comptime equalFn: var) type {
    const Hash = @typeInfo(@typeOf(hashFn)).Fn.return_type.?;
    assert(@sizeOf(Hash) > 0);

    const SlotKeyDetect = slotkey_detect_blk: {
        switch (@typeInfo(@typeOf(transferFn))) {
            builtin.TypeId.Fn => |proto| {
                if (proto.return_type) |slotkey_type| {
                    break :slotkey_detect_blk slotkey_type;
                }
            },
            builtin.TypeId.Null, builtin.TypeId.Undefined => {
                break :slotkey_detect_blk Key;
            },
            else => {
                unreachable;
            },
        }
    };
    const SlotKey = slotkey_blk: {
        switch (@typeInfo(SlotKeyDetect)) {
            builtin.TypeId.ErrorUnion => |error_union| {
                break :slotkey_blk error_union.payload;
            },
            else => {
                break :slotkey_blk SlotKeyDetect;
            },
        }
    };
    const SlotKeyTransferCanErr = @typeId(SlotKeyDetect) != @typeId(SlotKey);
    const SlotKeyTransferIsTrivial = transfer_blk: {
        switch(@typeId(@typeOf(transferFn))) {
            builtin.TypeId.Null, builtin.TypeId.Undefined => {
                break :transfer_blk true;
            },
            else => {
                break :transfer_blk false;
            },
        }
    };
    const SlotKeyEqualityIsTrivial = equality_blk: {
        switch(@typeId(@typeOf(equalFn))) {
            builtin.TypeId.Null, builtin.TypeId.Undefined => {
                break :equality_blk true;
            },
            else => {
                break :equality_blk false;
            },
        }
    };

    return struct {
        ctrl: [*]i8,
        slots: [*]align(@alignOf(Slot)) Slot,
        capacity: usize = 0,
        size: usize = 0,
        growth_left: usize = 0,
        allocator: *std.mem.Allocator,

        const Self = @This();

        const SlotKV = struct {
            key: SlotKey,
            value: SlotValue,
        };

        const Slot = struct {
            hash: Hash,
            kv: SlotKV,
        };

        const FindOrInsertResult = struct {
            index: usize,
            is_new: bool,
        };

        pub const InsertResult = struct {
            kv: *SlotKV,
            is_new: bool,
        };

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                // The weird casting is to drop the const from the placeholder ctrl
                .ctrl = @intToPtr([*]i8, @ptrToInt(&empty_ctrl[0])),
                .slots = undefined,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.ctrl[0..self.capacity]);
                self.allocator.free(self.slots[0..self.capacity]);
                self.capacity = 0;
            }
        }

        pub fn deinitAndFreeKeys(self: *Self) void {
            var it = self.iterator();
            while(it.next()) |kv| {
                self.allocator.free(kv.key);
            }
            self.deinit();
        }

        pub fn insert(self: *Self, key: Key) !InsertResult {
            const hash = hashFn(key);
            return try self.insertWithHash(key, hash);
        }

        pub fn insertWithHash(self: *Self, key: Key, hash: Hash) !InsertResult {
            const target = try self.findOrPrepareInsert(hash, key);
            self.slots[target.index].hash = hash;
            if(target.is_new) {
                if(SlotKeyTransferIsTrivial) {
                    self.slots[target.index].kv.key = key;
                }
                else if(SlotKeyTransferCanErr) {
                    self.slots[target.index].kv.key = try transferFn(self.allocator, key);
                    errdefer {
                        self.ctrl[target.index] = Ctrl.kDeleted;
                        self.size -= 1;
                    }
                }
                else {
                    self.slots[target.index].kv.key = transferFn(self.allocator, key);
                }
            }

            return InsertResult{ .kv = &self.slots[target.index].kv, .is_new = target.is_new };
        }

        pub fn insertWithValue(self: *Self, key: Key, value: SlotValue) !bool {
            const hash = hashFn(key);
            return self.insertWithHashAndValue(self, key, hash, value);
        }

        pub fn insertWithHashAndValue(self: *Self, key: Key, hash: Hash, value: SlotValue) !bool {
            const result = try self.insertWithHash(key, hash);
            result.kv.value = value;
            return result.is_new;
        }

        pub fn erase(self: *Self, key: Key) ?*SlotKV {
            const hash = hashFn(key);
            return self.eraseWithHash(key, hash);
        }

        pub fn eraseWithHash(self: *Self, key: Key, hash: Hash) ?*SlotKV {
            const h2 = H2(hash);
            var probe = ProbeSeq(Group.kWidth).init(self.capacity, H1(hash));

            while (true) {
                assert(self.capacity == 0 or probe.index < self.capacity);
                const g = Group.init(self.ctrl + probe.offset);
                var bits = g.match(h2);
                while (bits.has_bits()) {
                    const target = probe.offsetBy(bits.next());
                    if (self.slots[target].hash == hash) {
                        const is_equal = equal_blk: {
                            if(SlotKeyEqualityIsTrivial) {
                                break :equal_blk key == self.slots[target].kv.key;
                            }
                            else {
                                break :equal_blk equalFn(key, self.slots[target].kv.key);
                            }
                        };
                        if(is_equal) {
                            const index_before = (target -% Group.kWidth) & self.capacity;
                            const empty_before = Group.init(self.ctrl + index_before).matchEmpty();
                            const empty_after = Group.init(self.ctrl + target).matchEmpty();
                            // std.debug.warn("before: {x} {}\n", empty_before.mask, empty_before.leadingZeros());
                            // std.debug.warn("after: {x} {}\n", empty_after.mask, empty_after.trailingZeros());
                            const was_never_full: bool = 
                                empty_before.has_bits() and
                                empty_after.has_bits() and
                                (empty_after.trailingZeros() + empty_before.leadingZeros()) < Group.kWidth;

                            if (was_never_full) {
                                self.setCtrl(target, Ctrl.kEmpty);
                                self.growth_left += 1;
                            } else {
                                self.setCtrl(target, Ctrl.kDeleted);
                            }
                            self.size -= 1;
                            return &self.slots[target].kv;
                        }
                    }
                }
                const e = g.matchEmpty();
                if (e.has_bits()) break;
                probe.next();
            }
            return null;
        }

        pub fn reserve(self: *Self, n: usize) !void {
            if (n > 0)
                try self.resize(normalizeCapacity(growthToLowerBoundCapacity(n)));
        }

        fn H1(hash: Hash) Hash {
            return hash >> 7;
        }

        fn H2(hash: Hash) i8 {
            return @bitCast(i8, @truncate(u8, hash & 0x7f));
        }

        pub fn contains(self: Self, key: Key) bool {
            const hash = hashFn(key);
            return self.containsWithHash(key, hash);
        }

        pub fn containsWithHash(self: Self, key: Key, hash: Hash) bool {
            if(self.findWithHash(key, hash)) |kv| {
                return true;
            }
            return false;
        }

        pub fn find(self: Self, key: Key) ?*SlotKV {
            const hash = hashFn(key);
            return self.findWithHash(key, hash);
        }

        pub fn findWithHash(self: Self, key: Key, hash: Hash) ?*SlotKV {
            const h1 = H1(hash);
            const h2 = H2(hash);
            var probe = ProbeSeq(Group.kWidth).init(self.capacity, h1);

            while (true) {
                assert(self.capacity == 0 or probe.index < self.capacity);
                const g = Group.init(self.ctrl + probe.offset);
                var bits = g.match(h2);
                while (bits.has_bits()) {
                    const target = probe.offsetBy(bits.next());
                    if (self.slots[target].hash == hash) {
                        const is_equal = equal_blk: {
                            if(SlotKeyEqualityIsTrivial) {
                                break :equal_blk key == self.slots[target].kv.key;
                            }
                            else {
                                break :equal_blk equalFn(key, self.slots[target].kv.key);
                            }
                        };
                        if(is_equal)
                            return &self.slots[target].kv;
                    }
                }
                const empty = g.matchEmpty();
                if (empty.has_bits()) break;
                probe.next();
            }
            return null;
        }

        fn findFirstNonFull(self: Self, hash: Hash) usize {
            var probe = ProbeSeq(Group.kWidth).init(self.capacity, H1(hash));

            while (true) {
                assert(self.capacity == 0 or probe.index < self.capacity);
                const g = Group.init(self.ctrl + probe.offset);
                var bits = g.matchEmptyOrDeleted();
                if (bits.has_bits()) {
                    return probe.offsetBy(bits.next());
                }
                probe.next();
            }
        }

        fn findOrPrepareInsert(self: *Self, hash: Hash, key: Key) !FindOrInsertResult {
            const h2 = H2(hash);
            var probe = ProbeSeq(Group.kWidth).init(self.capacity, H1(hash));

            while (true) {
                assert(self.capacity == 0 or probe.index < self.capacity);
                const g = Group.init(self.ctrl + probe.offset);
                var bits = g.match(h2);
                while (bits.has_bits()) {
                    const target = probe.offsetBy(bits.next());
                    if (self.slots[target].hash == hash) {
                        const is_equal = equal_blk: {
                            if(SlotKeyEqualityIsTrivial) {
                                break :equal_blk key == self.slots[target].kv.key;
                            }
                            else {
                                break :equal_blk equalFn(key, self.slots[target].kv.key);
                            }
                        };
                        if(is_equal)
                            return FindOrInsertResult{ .index = target, .is_new = false };
                    }
                }
                const e = g.matchEmpty();
                if (e.has_bits()) break;
                probe.next();
            }
            return FindOrInsertResult{ .index = try self.prepareInsert(hash), .is_new = true };
        }

        fn prepareInsert(self: *Self, hash: Hash) !usize {
            var target = self.findFirstNonFull(hash);
            if (self.growth_left == 0 and self.ctrl[target] != Ctrl.kDeleted) {
                try self.rehashAndGrowIfNecessary();
                target = self.findFirstNonFull(hash);
            }
            self.size += 1;
            if (self.ctrl[target] == Ctrl.kEmpty)
                self.growth_left -= 1;
            self.setCtrl(target, H2(hash));
            return target;
        }

        fn capacityToGrowth(capacity: usize) usize {
            return capacity - (capacity >> 3);
        }

        fn resetGrowthLeft(self: *Self) void {
            self.growth_left = capacityToGrowth(self.capacity) - self.size;
        }

        fn normalizeCapacity(n: usize) usize {
            if (n == 0)
                return 1;
            return @bitCast(usize, @intCast(isize, -1)) >> @truncate(u6, @clz(usize, n));
        }

        fn growthToLowerBoundCapacity(growth: usize) usize {
            return growth + ((growth - 1) / 7);
        }

        fn rehashAndGrowIfNecessary(self: *Self) !void {
            if (self.capacity == 0) {
                try self.resize(1);
            } else if (self.size <= capacityToGrowth(self.capacity) / 2) {
                self.dropDeletesWithoutResize();
            } else {
                try self.resize(self.capacity * 2 + 1);
            }
        }

        fn probeIndex(self: Self, hash: Hash, pos: usize) usize {
            return ((pos -% ProbeSeq(Group.kWidth).init(self.capacity, H1(hash)).offset) & self.capacity) / Group.kWidth;
        }

        fn convertSpecialToEmptyAndFullToDeleted(self: *Self) void {
            var i: usize = 0;
            while (i < self.capacity + 1) : (i += Group.kWidth) {
                Group.init(self.ctrl + i).convertSpecialToEmptyAndFullToDeleted(self.ctrl + i);
            }
            @memcpy(@ptrCast([*]u8, self.ctrl + self.capacity + 1), @ptrCast([*]u8, self.ctrl), Group.kWidth);
            self.ctrl[self.capacity] = Ctrl.kSentinel;
        }

        fn dropDeletesWithoutResize(self: *Self) void {
            self.convertSpecialToEmptyAndFullToDeleted();

            var i: usize = 0;
            while (i < self.capacity) : (i += 1) {
                if (self.ctrl[i] != Ctrl.kDeleted) continue;
                const hash = self.slots[i].hash;
                const new_i = self.findFirstNonFull(hash);

                if (self.probeIndex(hash, new_i) == self.probeIndex(hash, i)) {
                    self.setCtrl(i, H2(hash));
                    continue;
                }

                if (self.ctrl[new_i] == Ctrl.kEmpty) {
                    self.setCtrl(new_i, H2(hash));
                    self.slots[new_i] = self.slots[i];
                    self.setCtrl(i, Ctrl.kEmpty);
                } else {
                    self.setCtrl(new_i, H2(hash));
                    var slot: Slot = self.slots[i];
                    self.slots[i] = self.slots[new_i];
                    self.slots[new_i] = slot;
                    i -= 1;
                }
            }

            self.resetGrowthLeft();
        }

        fn resize(self: *Self, new_size: usize) !void {
            const old_ctrl = self.ctrl;
            const old_slots = self.slots;
            const old_capacity = self.capacity;

            self.ctrl = (try self.allocator.alloc(i8, new_size + Group.kWidth + 1)).ptr;
            errdefer self.ctrl = old_ctrl;
            self.slots = (try self.allocator.alloc(Slot, new_size)).ptr;
            errdefer self.slots = old_slots;

            self.capacity = new_size;
            self.resetCtrl();
            self.resetGrowthLeft();

            var i: usize = 0;
            while (i < old_capacity) : (i += 1) {
                if (old_ctrl[i] >= 0) {
                    const hash = old_slots[i].hash;
                    const target = self.findFirstNonFull(hash);
                    self.slots[target] = old_slots[i];
                    self.setCtrl(target, old_ctrl[i]);
                }
            }

            if (old_capacity > 0) {
                self.allocator.free(old_ctrl[0 .. old_capacity + Group.kWidth + 1]);
                self.allocator.free(old_slots[0..old_capacity]);
            }
        }

        fn setCtrl(self: *Self, i: usize, h2: i8) void {
            self.ctrl[i] = h2;
            self.ctrl[((i -% Group.kWidth) & self.capacity) + 1 + ((Group.kWidth - 1) & self.capacity)] = h2;
        }

        fn resetCtrl(self: *Self) void {
            @memset(@ptrCast([*]u8, self.ctrl), @bitCast(u8, Ctrl.kEmpty), self.capacity + Group.kWidth + 1);
            self.ctrl[self.capacity] = Ctrl.kSentinel;
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self);
        }

        const Iterator = struct {
            owner: *Self,
            index: usize,

            pub fn init(owner: *Self) Iterator {
                return Iterator{ .owner = owner, .index = 0 };
            }

            pub fn next(self: *Iterator) ?*SlotKV {
                while (self.owner.ctrl[self.index] < 0) : (self.index += 1) {
                    if (self.owner.ctrl[self.index] == Ctrl.kSentinel)
                        return null;
                }
                const kv = &self.owner.slots[self.index].kv;
                self.index += 1;
                return kv;
            }
        };
    };
}

const empty_ctrl: [16]i8 = [16]i8{
    Ctrl.kSentinel,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
    Ctrl.kEmpty,
};

