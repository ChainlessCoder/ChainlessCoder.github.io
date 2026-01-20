const std = @import("std");

const SimplifiedFilter = @import("simplified_filter.zig").SimplifiedFilter;

/// Packetized erasure decoder.
///
/// Usage model:
/// - Both sides agree on (message_length, loss_rate, p_eff, packet_payload_bytes).
/// - Receiver collects any subset of packets (each includes an index).
/// - Receiver reconstructs the filter by setting missing packet regions to all 1s (0xFF).
/// - Then runs the standard Information Chaining decoder on the reconstructed filter.
pub fn ErasureDecoder(comptime Lineage: type, comptime Header: type) type {
    const SBF = SimplifiedFilter(Header);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        filter: SBF,

        message_length: usize,
        packet_payload_bytes: usize,
        packet_count: usize,

        pub const Packet = struct {
            index: u32,
            payload: []const u8,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            message_length: usize,
            loss_rate: f64,
            p_eff: f64,
            packet_payload_bytes: usize,
        ) !Self {
            if (message_length == 0) return error.InvalidMessageLength;
            if (packet_payload_bytes == 0) return error.InvalidPacketPayload;

            const n_bits: usize = message_length * 8;
            var byte_num: usize = try computeFilterSizeK1WithLoss(n_bits, loss_rate, p_eff);

            // Must match the encoder's rounding to whole packets.
            byte_num = try roundUp(byte_num, packet_payload_bytes);

            const pkt_count: usize = byte_num / packet_payload_bytes;
            std.debug.assert(byte_num % packet_payload_bytes == 0);

            return .{
                .allocator = allocator,
                .filter = try SBF.init(allocator, byte_num),
                .message_length = message_length,
                .packet_payload_bytes = packet_payload_bytes,
                .packet_count = pkt_count,
            };
        }

        pub fn deinit(self: *Self) void {
            self.filter.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn expected_packet_count(self: *const Self) usize {
            return self.packet_count;
        }

        /// Reconstruct the underlying filter from received packets.
        ///
        /// Any packet index that isn't present in `packets` remains all 1s (0xFF).
        pub fn reconstruct_filter(self: *Self, packets: []const Packet) !void {
            // Start with everything missing.
            @memset(self.filter.filter, 0xFF);

            for (packets) |pkt| {
                const idx: usize = @intCast(pkt.index);
                if (idx >= self.packet_count) return error.PacketIndexOutOfRange;
                if (pkt.payload.len != self.packet_payload_bytes) return error.BadPacketSize;

                const start: usize = idx * self.packet_payload_bytes;
                const end: usize = start + self.packet_payload_bytes;
                std.mem.copyForwards(u8, self.filter.filter[start..end], pkt.payload);
            }
        }

        /// Decode the original message from a set of received packets.
        ///
        /// `out` must be a buffer of length `message_length`.
        pub fn decode(
            self: *Self,
            nonce: Header,
            final_chain_header: Header,
            packets: []const Packet,
            out: []u8,
            state_change: fn (Header) Header,
        ) !void {
            if (out.len != self.message_length) return error.BadOutputSize;

            // Rebuild filter bytes (missing -> 0xFF) and run the normal decoder.
            try self.reconstruct_filter(packets);

            const message_bits: usize = self.message_length * 8;
            const L: usize = @bitSizeOf(Lineage);
            if (L == 0) return error.InvalidLineage;
            if (L > message_bits) return error.LineageTooLarge;

            const prefix_bits: usize = message_bits - L;
            @memset(out, 0);

            const Paths = paths(Lineage, Header);
            var current = Paths.init(self.allocator);
            defer current.deinit();
            var next = Paths.init(self.allocator);
            defer next.deinit();

            try current.addPath(nonce, 0);

            // Warm-up: fill lineage with the first L bits.
            for (0..L) |_| {
                next.clearRetainingCapacity();

                for (current.paths.items) |path| {
                    for (0..2) |b_usize| {
                        const bit_is_one = b_usize == 1;
                        const header = if (bit_is_one) state_change(path.header) else state_change(~path.header);

                        if (self.filter.contains(header)) {
                            const b: Lineage = @as(Lineage, @intCast(b_usize));
                            const lin: Lineage = (path.lineage << 1) | b;
                            try next.addPath(header, lin);
                        }
                    }
                }

                std.mem.swap(@TypeOf(current), &current, &next);
                if (current.len() == 0) return error.NoCandidatePaths;
            }

            // Emit prefix_bits bits.
            var out_bit_index: usize = 0;
            while (out_bit_index < prefix_bits) : (out_bit_index += 1) {
                if (current.len() == 0) return error.NoCandidatePaths;

                const root_bit: u1 = @truncate(current.get(0).lineage >> (L - 1));

                if (std.debug.runtime_safety) {
                    for (current.paths.items) |p| {
                        const rb: u1 = @truncate(p.lineage >> (L - 1));
                        if (rb != root_bit) return error.AmbiguousOutputBit;
                    }
                }

                writeBit(out, out_bit_index, root_bit);

                // Advance one step.
                next.clearRetainingCapacity();
                for (current.paths.items) |path| {
                    for (0..2) |b_usize| {
                        const bit_is_one = b_usize == 1;
                        const header = if (bit_is_one) state_change(path.header) else state_change(~path.header);
                        if (self.filter.contains(header)) {
                            const b: Lineage = @as(Lineage, @intCast(b_usize));
                            const lin: Lineage = (path.lineage << 1) | b;
                            try next.addPath(header, lin);
                        }
                    }
                }

                std.mem.swap(@TypeOf(current), &current, &next);
            }

            // Append last L bits from the correct final path.
            const shiftType = getLog2Type(Lineage);
            for (current.paths.items) |path| {
                if (path.header == final_chain_header) {
                    for (0..L) |i| {
                        const shift: shiftType = @truncate((L - 1) - i);
                        const bit: u1 = @truncate(path.lineage >> shift);
                        writeBit(out, prefix_bits + i, bit);
                    }
                    return;
                }
            }

            return error.PathNotFound;
        }
    };
}

pub fn paths(comptime lineageType: type, comptime headerType: type) type {
    const Allocator = std.mem.Allocator;
    const Path = struct { header: headerType, lineage: lineageType };

    return struct {
        const Self = @This();

        allocator: Allocator,
        paths: std.ArrayList(Path) = .{},

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .paths = .{} };
        }

        pub fn deinit(self: *Self) void {
            self.paths.deinit(self.allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.paths.clearRetainingCapacity();
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

fn roundUp(x: usize, multiple: usize) !usize {
    if (multiple == 0) return error.InvalidPacketPayload;
    return ((x + multiple - 1) / multiple) * multiple;
}

/// Computes the filter size in **bytes** (rounded up) for the k=1 simplified filter,
/// while accounting for a packet loss rate `loss_rate`.
fn computeFilterSizeK1WithLoss(n_bits: usize, loss_rate: f64, p_eff: f64) !usize {
    if (n_bits == 0) return error.InvalidMessageLength;
    if (!(loss_rate >= 0.0 and loss_rate < 1.0)) return error.InvalidLossRate;
    if (!(p_eff > 0.0 and p_eff < 0.5)) return error.InvalidFPR;
    if (!(p_eff > loss_rate)) return error.ImpossibleParameters;

    const n_f: f64 = @floatFromInt(n_bits);
    const ratio: f64 = (1.0 - p_eff) / (1.0 - loss_rate);
    const root: f64 = @exp(@log(ratio) / n_f);
    const denom: f64 = 1.0 - root;
    if (!(denom > 0.0)) return error.ImpossibleParameters;
    const m_bits_f: f64 = 1.0 / denom;
    const m_bits: usize = @intFromFloat(@ceil(m_bits_f));
    return (m_bits + 7) / 8;
}

fn writeBit(out: []u8, bit_index: usize, bit: u1) void {
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
