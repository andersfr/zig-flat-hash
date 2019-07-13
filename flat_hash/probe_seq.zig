pub fn ProbeSeq(comptime width: usize) type {
    return struct {
        mask: usize,
        offset: usize,
        index: usize = 0,

        pub const Self = @This();
        pub const kWidth = width;

        pub fn init(mask: usize, hash: usize) Self {
            return Self{
                .mask = mask,
                .offset = hash & mask,
            };
        }

        pub fn next(self: *Self) void {
            self.index += kWidth;
            self.offset += self.index;
            self.offset &= self.mask;
        }

        pub fn offsetBy(self: Self, i: usize) usize {
            return (self.offset + i) & self.mask;
        }
    };
}
