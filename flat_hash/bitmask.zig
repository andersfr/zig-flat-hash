const warn = @import("std").debug.warn;

pub fn Bitmask(comptime T: type) type {
    return struct {
        mask: u32,

        pub const Self = @This();

        pub fn init(mask: u32) Self {
            return Self{ .mask = mask };
        }

        pub fn next(self: *Self) u32 {
            const r = @ctz(u32, self.mask);
            self.mask &= self.mask - 1;
            return r;
        }

        pub fn is_zero(self: Self) bool {
            return self.mask == 0;
        }

        pub fn has_bits(self: Self) bool {
            return self.mask != 0;
        }

        pub fn leadingZeros(self: Self) u32 {
            return @clz(u32, self.mask) - (4 - @sizeOf(T))*8;
        }

        pub fn trailingZeros(self: Self) u32 {
            return @ctz(u32, self.mask);
        }
    };
}

