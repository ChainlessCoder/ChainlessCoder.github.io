const std = @import("std");
const Allocator = std.mem.Allocator;
const SimplifiedFilter = @import("simplified_filter.zig").SimplifiedFilter;

pub fn decoder_prototype(
    comptime lineageType: type,
    comptime headerType: type,
    comptime message_length: usize, // in bytes
) type {
    return struct {
        const Self = @This();

        const SBF: type = SimplifiedFilter(headerType);

        pub fn decode(
            allocator: Allocator,
            nonce: headerType,
            final_chain_header: headerType,
            sbf: *const SBF,
            out: *[message_length]u8,
            state_change: fn (headerType) headerType,
        ) !void {
            const Paths = paths(lineageType, headerType);

            const message_bits: usize = message_length * 8;
            const L: usize = @bitSizeOf(lineageType);

            const prefix_bits: usize = message_bits - L;

            out.* = [_]u8{0} ** message_length;

            var current = Paths.init(allocator);
            defer current.deinit();
            var next = Paths.init(allocator);
            defer next.deinit();

            try current.addPath(nonce, 0);

            // Warm-up: fill up the lineage register with the first L bits.
            for (0..L) |_| {
                next.paths.clearRetainingCapacity();

                for (current.paths.items) |path| {
                    for (0..2) |b_usize| {
                        const bit = b_usize == 1;
                        const header = if (bit) state_change(path.header) else state_change(~path.header);

                        // Encoder inserted usize(hdr); mirror that here.
                        if (sbf.contains(header)) {
                            const b: lineageType = @as(lineageType, @intCast(b_usize));
                            const lin: lineageType = (path.lineage << 1) | b;
                            try next.addPath(header, lin);
                        }
                    }
                }

                std.mem.swap(Paths, &current, &next);

                if (current.len() == 0) return error.NoCandidatePaths;
            }

            // Emit the first (message_bits - L) bits by repeatedly reading the MSB of lineage,
            // then advancing one step. This avoids stepping past the true end of the message.
            var out_bit_index: usize = 0;
            while (out_bit_index < prefix_bits) : (out_bit_index += 1) {
                if (current.len() == 0) return error.NoCandidatePaths;

                const root_bit: u1 = @truncate(current.get(0).lineage >> (L - 1));

                // In debug/runtime-safety builds, ensure all candidates agree on the output bit.
                // better heuristics can be used in practice (e.g. majority count, or reading only the first element while increasing linage size for better speed)
                if (std.debug.runtime_safety) {
                    for (current.paths.items) |p| {
                        const rb: u1 = @truncate(p.lineage >> (L - 1));
                        if (rb != root_bit) return error.AmbiguousOutputBit;
                    }
                }

                writeBit(message_length, out, out_bit_index, root_bit);

                // Advance one step.
                next.paths.clearRetainingCapacity();
                for (current.paths.items) |path| {
                    for (0..2) |b_usize| {
                        const bit = b_usize == 1;
                        const header = if (bit) state_change(path.header) else state_change(~path.header);
                        if (sbf.contains(header)) {
                            const b: lineageType = @as(lineageType, @intCast(b_usize));
                            const lin: lineageType = (path.lineage << 1) | b;
                            try next.addPath(header, lin);
                        }
                    }
                }
                std.mem.swap(Paths, &current, &next);
            }

            // At this point we've advanced exactly message_bits steps total (L warm-up + prefix_bits).
            // So we're at the true end of the message. Find the path with the correct final header,
            // and append the remaining L bits that are still sitting inside its lineage.
            const shiftType = getLog2Type(lineageType);
            for (current.paths.items) |path| {
                if (path.header == final_chain_header) {
                    for (0..L) |i| {
                        const shift: shiftType = @truncate((L - 1) - i);
                        const bit: u1 = @truncate(path.lineage >> shift);
                        writeBit(message_length, out, prefix_bits + i, bit);
                    }
                    return;
                }
            }

            return error.PathNotFound;
        }
    };
}

pub fn paths(comptime lineageType: type, comptime headerType: type) type {
    const Path = struct { header: headerType, lineage: lineageType };

    return struct {
        const Self = @This();

        allocator: Allocator,
        paths: std.ArrayList(Path) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .paths = .empty };
        }

        pub fn deinit(self: *Self) void {
            self.paths.deinit(self.allocator);
        }

        pub fn addPath(self: *Self, h: headerType, l: lineageType) !void {
            try self.paths.append(self.allocator, .{ .header = h, .lineage = l });
        }

        pub fn len(self: *const Self) usize {
            return self.paths.items.len;
        }

        pub fn get(self: *const Self, i: usize) *const Path {
            return &self.paths.items[i];
        }
    };
}

fn writeBit(
    comptime message_length: usize,
    out: *[message_length]u8,
    bit_index: usize, // 0..message_length*8
    bit: u1,
) void {
    const byte_index: usize = bit_index / 8;
    const bit_in_byte: u3 = @intCast(7 - (bit_index % 8)); // msb-first
    const mask: u8 = @as(u8, 1) << bit_in_byte;
    if (bit == 1) out[byte_index] |= mask;
}

pub inline fn getLog2Type(comptime T: type) type {
    comptime {
        if (@typeInfo(T).int.signedness != .unsigned) @compileError("getLog2Type: T must be an unsigned integer type");
        const bits = @typeInfo(T).int.bits;
        if (bits == 0 or (bits & (bits - 1)) != 0) @compileError("getLog2Type: bit-width must be a power of two");
        const log2_bits = @log2(@as(f16, bits));
        return @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = log2_bits,
            },
        });
    }
}
