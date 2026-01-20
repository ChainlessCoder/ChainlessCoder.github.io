const std = @import("std");

pub fn state_change(x: u64) u64 {
    var z: u64 = @intCast(x);
    z +%= 0x9E3779B97F4A7C15;
    z ^= z >> 30;
    z *%= 0xBF58476D1CE4E5B9;
    z ^= z >> 27;
    z *%= 0x94D049BB133111EB;
    z ^= z >> 31;
    return z;
}
