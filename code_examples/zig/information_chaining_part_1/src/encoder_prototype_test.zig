const std = @import("std");
const testing = std.testing;

const state_change = @import("utils.zig").state_change;
const Encoder = @import("encoder_prototype.zig").Encoder;

fn expectAllZero(bytes: []const u8) !void {
    for (bytes) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

fn countNonZero(bytes: []const u8) usize {
    var c: usize = 0;
    for (bytes) |b| {
        if (b != 0) c += 1;
    }
    return c;
}

test "encoder: encode two bytes inserts all chain headers" {
    const Header = u64;
    const nonce: Header = 42;
    const fpr: f64 = 0.4;

    var input: [2]u8 = .{ 0b10110001, 0b10110001 };

    const Enc = Encoder(Header);
    var enc = try Enc.init(testing.allocator, input.len, fpr);
    defer enc.deinit();

    const final_hdr = enc.encode(nonce, input[0..], state_change);

    // Recompute the exact chain-header sequence the encoder should have inserted.
    var hdr: Header = nonce;
    for (input) |byte| {
        var bit_shift: u3 = 7;
        while (true) {
            const bit: bool = ((byte >> bit_shift) & 1) == 1;
            hdr = if (bit) state_change(hdr) else state_change(~hdr);

            // No false negatives: every inserted header must be present.
            try testing.expect(enc.filter.contains(hdr));

            if (bit_shift == 0) break;
            bit_shift -= 1;
        }
    }

    // The returned final header should match the last header we computed.
    try testing.expectEqual(hdr, final_hdr);
}

test "encoder: encode clears filter between calls" {
    const Header = u64;
    const nonce: Header = 123;
    const fpr: f64 = 0.48;

    var input: [4]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF };

    const Enc = Encoder(Header);
    var enc = try Enc.init(testing.allocator, input.len, fpr);
    defer enc.deinit();

    _ = enc.encode(nonce, input[0..], state_change);

    // After encoding a non-empty message, we should typically see at least some bits set.
    // (Not a strict guarantee for pathological sizes, but a good smoke test.)
    try testing.expect(countNonZero(enc.get_encoding()) > 0);

    // Encoding an empty message should clear the filter and then insert nothing.
    const empty: []const u8 = &[_]u8{};
    const final_hdr = enc.encode(nonce, empty, state_change);
    try testing.expectEqual(nonce, final_hdr);

    try expectAllZero(enc.get_encoding());
}

test "encoder: init rejects fpr that implies k>1 for k=1 variant" {
    const Header = u64;
    const Enc = Encoder(Header);

    // For small fpr, the computed m/n becomes large and k_opt rounds above 1.
    // The encoder intentionally rejects this in the Part-1 simplified (k=1) variant.
    try testing.expectError(error.InvalidFPR, Enc.init(testing.allocator, 2, 0.1));
}
