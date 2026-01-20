const std = @import("std");

const decoder_prototype = @import("decoder_prototype.zig").decoder_prototype;
const Encoder = @import("encoder_prototype.zig").Encoder;
const state_change = @import("utils.zig").state_change;

fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

test "Information Chaining: encode/decode random string via simplified filter (fpr=0.48)" {
    const HeaderType = u64;
    const LineageType = u256;

    const message_length: usize = 1000; // bytes

    const fpr: f64 = 0.48;

    // Decoder type stays the same; we only changed how we produce/own the filter.
    const Dec = decoder_prototype(LineageType, HeaderType, message_length);

    var seed: u64 = 42;

    // Generate a "random string of characters" (printable-ish ASCII).
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ";

    // Run a few deterministic trials.
    const trials: usize = 10;

    var t: usize = 0;
    while (t < trials) : (t += 1) {
        var input: [message_length]u8 = undefined;
        for (&input) |*b| {
            const r = xorshift64(&seed);
            const idx: usize = @intCast(r % @as(u64, alphabet.len));
            b.* = alphabet[idx];
        }

        const nonce: HeaderType = xorshift64(&seed);

        // --- Encode (new pattern: init + encode + deinit) ---
        const Enc = Encoder(HeaderType);
        var enc = try Enc.init(std.testing.allocator, message_length, fpr);
        defer enc.deinit();

        const final_hdr: HeaderType = enc.encode(nonce, input[0..], state_change);

        // --- Decode ---
        var decoded: [message_length]u8 = undefined;
        try Dec.decode(std.testing.allocator, nonce, final_hdr, &enc.filter, &decoded, state_change);

        // Verify round-trip.
        try std.testing.expectEqualSlices(u8, &input, &decoded);
    }
}
