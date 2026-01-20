const std = @import("std");
const SimplifiedFilter = @import("simplified_filter.zig").SimplifiedFilter;

pub fn Encoder(comptime Header: type) type {
    const SBF = SimplifiedFilter(Header);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        filter: SBF,

        pub fn init(allocator: std.mem.Allocator, message_length: usize, fpr: f64) !Self {
            const n = message_length * 8;
            const byte_num = computeFilterSizeK1(n, fpr);
            try allowed_range(byte_num * 8, n);
            return .{
                .allocator = allocator,
                .filter = try SBF.init(allocator, byte_num),
            };
        }

        pub fn deinit(self: *Self) void {
            self.filter.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn encode(
            self: *Self,
            nonce: Header,
            input: []const u8,
            state_change: fn (Header) Header,
        ) Header {
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

        pub fn get_encoding(self: *Self) []const u8 {
            return self.filter.filter;
        }
    };
}

/// For the k=1 simplified filter:
///   p0 ≈ 1 - exp(-n/m)  =>  m ≈ -n / ln(1 - p0)
/// We return a byte count (rounded up).
fn computeFilterSizeK1(n: usize, fpr: f64) usize {
    const n_f: f64 = @floatFromInt(n);
    const m_bits_f: f64 = -n_f / @log(1.0 - fpr);
    const m_bits: usize = @intFromFloat(@ceil(m_bits_f));
    return (m_bits + 7) / 8;
}

fn allowed_range(m_bits: usize, n: usize) !void {
    const m_f = @as(f64, @floatFromInt(m_bits));
    const n_f = @as(f64, @floatFromInt(n));
    const ln2: f64 = @log(@as(f64, 2.0));
    const k_real: f64 = (m_f / n_f) * ln2;
    const k_rounded: usize = @intFromFloat(@round(k_real));
    if (k_rounded > 1) return error.InvalidFPR;
}
