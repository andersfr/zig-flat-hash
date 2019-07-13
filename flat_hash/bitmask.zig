pub fn Bitmask(comptime T: type) type {
    return struct {
        mask: T,

        pub const Self = @This();

        pub fn init(mask: T) Self {
            return Self{ .mask = mask };
        }

        pub fn next(self: *Self) T {
            const r = @ctz(T, self.mask);
            self.mask &= self.mask - 1;
            return r;
        }

        pub fn is_zero(self: Self) bool {
            return self.mask == 0;
        }

        pub fn has_bits(self: Self) bool {
            return self.mask != 0;
        }

        pub fn leadingZeros(self: Self) T {
            return @clz(T, self.mask);
        }

        pub fn trailingZeros(self: Self) T {
            return @ctz(T, self.mask);
        }
    };
}

