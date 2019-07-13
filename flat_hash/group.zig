pub const Bitmask = @import("bitmask.zig").Bitmask;

pub const Group = struct {
    ctrl: Xmm,

    pub const Self = @This();
    pub const Xmm = @Vector(16, i8);
    pub const Mask = Bitmask(u32);

    pub const kWidth: usize = 16;

    pub fn init(ctrl: [*]i8) Self {
        var xmm: Xmm = undefined;
        // Memcpy necessary to emit unaligned read instruction
        @memcpy(@ptrCast([*]u8, &xmm), @ptrCast([*]const u8, ctrl), 16);
        return Self{ .ctrl = xmm };
    }

    pub fn match(self: Self, h2: i8) Mask {
        return Mask.init(pmovmskb(pcmpeqb(self.ctrl, set1_epi8(h2))));
    }

    pub fn matchEmpty(self: Self) Mask {
        // return Mask.init(pmovmskb(psignb(self.ctrl)));
        return Mask.init(pmovmskb(-%self.ctrl));
    }

    pub fn matchEmptyOrDeleted(self: Self) Mask {
        return Mask.init(pmovmskb(pcmpgtb(set1_epi8(-1), self.ctrl)));
    }

    pub fn convertSpecialToEmptyAndFullToDeleted(self: Self, ctrl: [*]i8) void {
        const x126: Xmm = set1_epi8(126);
        const msbs: Xmm = set1_epi8(-128);
        const zero: Xmm = set1_epi8(0);

        const special: Xmm = pcmpgtb(zero, self.ctrl);
        // const converted = msbs | (pnot(special) & x126);
        const converted = msbs | (@bitCast(Xmm, ~@bitCast(u128, special)) & x126);

        @memcpy(@ptrCast([*]u8, ctrl), @ptrCast([*]const u8, &converted), 16);
    }

    fn set1_epi8(v: i8) Xmm {
        var xmm: Xmm = undefined;
        @memset(@ptrCast([*]align(16) u8, &xmm), @bitCast(u8, v), 16);
        return xmm;
    }

    fn pmovmskb(mask: Xmm) u32 {
        return asm ("pmovmskb %[mask], %[ret]"
            : [ret] "=r" (-> u32)
            : [mask] "x" (mask)
        );
    }

    // Software emulation of SSE instruction (optimizer will vectorize)
    fn pcmpeqb(left: Xmm, right: Xmm) Xmm {
        const vl = @ptrCast([*]const i8, &left);
        const vr = @ptrCast([*]const i8, &right);
        var xmm: Xmm = undefined;
        const arr = @ptrCast([*]i8, &xmm);

        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (vl[i] == vr[i]) {
                arr[i] = -1;
            } else {
                arr[i] = 0;
            }
        }

        return xmm;
    }

    // Software emulation of SSE instruction (optimizer will vectorize)
    fn pcmpgtb(left: Xmm, right: Xmm) Xmm {
        const vl = @ptrCast([*]const i8, &left);
        const vr = @ptrCast([*]const i8, &right);
        var xmm: Xmm = undefined;
        const arr = @ptrCast([*]i8, &xmm);

        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (vl[i] > vr[i]) {
                arr[i] = -1;
            } else {
                arr[i] = 0;
            }
        }

        return xmm;
    }

    // fn pnot(left: Xmm) Xmm {
    //     const vl = @ptrCast([*]const i8, &left);
    //     var xmm: Xmm = undefined;
    //     const arr = @ptrCast([*]i8, &xmm);

    //     var i: usize = 0;
    //     while (i < 16) : (i += 1) {
    //         arr[i] = ~vl[i];
    //     }

    //     return xmm;
    // }

    // fn psignb(xmm: Xmm) Xmm {
    //     return asm ("psignb %[xmm], %[ret]"
    //         : [ret] "=x" (-> Xmm)
    //         : [xmm] "x" (xmm)
    //     );
    // }
};

