const std = @import("std");

const SimplifiedFilter = @import("simplified_filter.zig").SimplifiedFilter;

/// Erasure encoder built on top of the runtime-sized SimplifiedFilter and the Encoder prototype logic.
///
/// - Sizes the filter for a target **effective** false positive rate `p_eff` after a packet loss rate `loss_rate`.
/// - Rounds the filter size up to a whole number of packets.
/// - Encodes the message using Information Chaining (same bit-walk as Code Example 2).
/// - Exposes the encoded filter as packet payloads (zero-copy views).
pub fn ErasureEncoder(comptime Header: type) type {
    const SBF = SimplifiedFilter(Header);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        filter: SBF,

        message_length: usize, // bytes
        packet_payload_bytes: usize,

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

            // 1) Compute the filter size in bytes using the erasure-aware sizing rule.
            var byte_num: usize = try computeFilterSizeK1WithLoss(n_bits, loss_rate, p_eff);

            // 2) Round up to an integer number of packets.
            byte_num = try roundUp(byte_num, packet_payload_bytes);

            // 3) Keep k = 1 in this simplified variant.
            try allowed_range(byte_num * 8, n_bits);

            return .{
                .allocator = allocator,
                .filter = try SBF.init(allocator, byte_num),
                .message_length = message_length,
                .packet_payload_bytes = packet_payload_bytes,
            };
        }

        pub fn deinit(self: *Self) void {
            self.filter.deinit(self.allocator);
            self.* = undefined;
        }

        /// Encode `input` into the underlying filter.
        /// Returns the final chain header.
        pub fn encode(
            self: *Self,
            nonce: Header,
            input: []const u8,
            state_change: fn (Header) Header,
        ) Header {
            // For this prototype, require the encoder was sized for this message length.
            std.debug.assert(input.len == self.message_length);

            // reuse memory
            @memset(self.filter.filter, 0);

            var hdr: Header = nonce;
            for (input) |byte| {
                var bit_shift: u3 = 7;
                while (true) {
                    const bit: bool = ((byte >> bit_shift) & 1) == 1;
                    hdr = if (bit) state_change(hdr) else state_change(~hdr);
                    self.filter.insert(hdr);
                    if (bit_shift == 0) break;
                    bit_shift -= 1;
                }
            }

            return hdr;
        }

        /// Raw encoded filter bytes.
        pub fn get_encoding(self: *const Self) []const u8 {
            return self.filter.filter;
        }

        pub fn packet_count(self: *const Self) usize {
            // filter size is always rounded to a multiple of packet_payload_bytes.
            return self.filter.filter.len / self.packet_payload_bytes;
        }

        /// Get a zero-copy view of packet `index`.
        pub fn packet(self: *const Self, index: usize) Packet {
            std.debug.assert(index < self.packet_count());

            const start: usize = index * self.packet_payload_bytes;
            const end: usize = start + self.packet_payload_bytes;

            return .{
                .index = @intCast(index),
                .payload = self.filter.filter[start..end],
            };
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

fn allowed_range(m_bits: usize, n_bits: usize) !void {
    if (m_bits == 0 or n_bits == 0) return error.InvalidMessageLength;

    const m_f = @as(f64, @floatFromInt(m_bits));
    const n_f = @as(f64, @floatFromInt(n_bits));
    const ln2: f64 = @log(@as(f64, 2.0));
    const k_real: f64 = (m_f / n_f) * ln2;
    const k_rounded: usize = @intFromFloat(@round(k_real));
    if (k_rounded > 1) return error.InvalidFPR;
}
