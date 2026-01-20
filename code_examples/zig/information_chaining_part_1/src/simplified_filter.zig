const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SimplifiedFilter(
    comptime T: type,
) type {
    return struct {
        const Self = @This();

        filter: []u8,
        m: usize,

        pub fn init(allocator: Allocator, byte_num: usize) !Self {
            const memory = try allocator.alloc(u8, byte_num);
            @memset(memory, 0);
            return .{ .filter = memory, .m = byte_num * 8 };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.filter);
        }

        pub fn insert(self: *Self, item: T) void {
            const bit_index = @as(usize, @intCast(item)) % self.m;
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;
            self.filter[byte_index] |= mask;
        }

        pub fn contains(self: *const Self, item: T) bool {
            const bit_index = @as(usize, @intCast(item)) % self.m;
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;
            return (self.filter[byte_index] & mask) != 0;
        }
    };
}
