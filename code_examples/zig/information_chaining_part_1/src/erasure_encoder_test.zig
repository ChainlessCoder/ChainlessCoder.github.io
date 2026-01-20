const std = @import("std");
const testing = std.testing;

const ErasureEncoder = @import("erasure_encoder.zig").ErasureEncoder;
const state_change = @import("utils.zig").state_change;

fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn allBytesEqual(bytes: []const u8, value: u8) bool {
    for (bytes) |b| {
        if (b != value) return false;
    }
    return true;
}

fn computeFinalHeaderManual(nonce: u64, input: []const u8) u64 {
    var hdr: u64 = nonce;
    for (input) |byte| {
        var bit_shift: u3 = 7;
        while (true) {
            const bit: bool = ((byte >> bit_shift) & 1) == 1;
            hdr = if (bit) state_change(hdr) else state_change(~hdr);
            if (bit_shift == 0) break;
            bit_shift -= 1;
        }
    }
    return hdr;
}

test "erasure encoder: init rounds to whole packets and packet() views cover encoding" {
    const Header = u64;
    const Enc = ErasureEncoder(Header);

    const message_length: usize = 512; // bytes
    const loss_rate: f64 = 0.10;
    const p_eff: f64 = 0.48;
    const payload: usize = 256;

    var enc = try Enc.init(testing.allocator, message_length, loss_rate, p_eff, payload);
    defer enc.deinit();

    // The backing encoding must be an integer number of payload blocks.
    const encoding = enc.get_encoding();
    try testing.expect(encoding.len % payload == 0);
    try testing.expectEqual(encoding.len / payload, enc.packet_count());

    // Encode a deterministic pseudo-random message.
    var seed: u64 = 12345;
    var msg: [message_length]u8 = undefined;
    for (&msg) |*b| {
        b.* = @as(u8, @truncate(xorshift64(&seed)));
    }

    const nonce: Header = 0xBADC0FFEE;
    const final_hdr = enc.encode(nonce, msg[0..], state_change);

    // Final header should match a manual recomputation.
    try testing.expectEqual(computeFinalHeaderManual(nonce, msg[0..]), final_hdr);

    // Every packet must reference the correct contiguous segment.
    var i: usize = 0;
    while (i < enc.packet_count()) : (i += 1) {
        const pkt = enc.packet(i);
        try testing.expectEqual(@as(u32, @intCast(i)), pkt.index);
        try testing.expectEqual(@as(usize, payload), pkt.payload.len);

        const start: usize = i * payload;
        const end: usize = start + payload;
        try testing.expect(std.mem.eql(u8, pkt.payload, encoding[start..end]));
    }

    // Smoke check: after encoding a non-empty message, we should not be all zeros.
    try testing.expect(!allBytesEqual(encoding, 0));
}

test "erasure encoder: reconstruct filter from packets with losses (missing regions -> 0xFF)" {
    const Header = u64;
    const Enc = ErasureEncoder(Header);

    const message_length: usize = 512;
    const loss_rate: f64 = 0.10;
    const p_eff: f64 = 0.48;
    const payload: usize = 256;

    var enc = try Enc.init(testing.allocator, message_length, loss_rate, p_eff, payload);
    defer enc.deinit();

    // Make a deterministic message.
    var seed: u64 = 999;
    var msg: [message_length]u8 = undefined;
    for (&msg) |*b| {
        b.* = @as(u8, @truncate(xorshift64(&seed)));
    }

    const nonce: Header = 777;
    _ = enc.encode(nonce, msg[0..], state_change);

    const encoding = enc.get_encoding();
    const pkt_count = enc.packet_count();

    var reconstructed = try testing.allocator.alloc(u8, encoding.len);
    defer testing.allocator.free(reconstructed);

    // Drop every 3rd packet (deterministic).
    var i: usize = 0;
    while (i < pkt_count) : (i += 1) {
        const start: usize = i * payload;
        const end: usize = start + payload;

        const dropped = (i % 3) == 0;
        if (dropped) {
            @memset(reconstructed[start..end], 0xFF);
        } else {
            const pkt = enc.packet(i);
            std.mem.copyForwards(u8, reconstructed[start..end], pkt.payload);
        }
    }

    // Verify reconstruction semantics: received packets match exactly; missing are all 1s.
    i = 0;
    while (i < pkt_count) : (i += 1) {
        const start: usize = i * payload;
        const end: usize = start + payload;
        const dropped = (i % 3) == 0;

        if (dropped) {
            try testing.expect(allBytesEqual(reconstructed[start..end], 0xFF));
        } else {
            try testing.expect(std.mem.eql(u8, reconstructed[start..end], encoding[start..end]));
        }
    }
}

test "erasure encoder: re-encode reuse matches a fresh encoder" {
    const Header = u64;
    const Enc = ErasureEncoder(Header);

    const message_length: usize = 512;
    const loss_rate: f64 = 0.10;
    const p_eff: f64 = 0.48;
    const payload: usize = 256;

    var enc_reuse = try Enc.init(testing.allocator, message_length, loss_rate, p_eff, payload);
    defer enc_reuse.deinit();

    var enc_fresh = try Enc.init(testing.allocator, message_length, loss_rate, p_eff, payload);
    defer enc_fresh.deinit();

    // Two different messages of the same length.
    var msg_a: [message_length]u8 = [_]u8{0} ** message_length;
    var msg_b: [message_length]u8 = [_]u8{0xFF} ** message_length;

    const nonce: Header = 123456;

    _ = enc_reuse.encode(nonce, msg_a[0..], state_change);
    const final_b_reuse = enc_reuse.encode(nonce, msg_b[0..], state_change);

    const final_b_fresh = enc_fresh.encode(nonce, msg_b[0..], state_change);

    try testing.expectEqual(final_b_fresh, final_b_reuse);
    try testing.expect(std.mem.eql(u8, enc_reuse.get_encoding(), enc_fresh.get_encoding()));
}

test "erasure encoder: init rejects invalid parameters" {
    const Header = u64;
    const Enc = ErasureEncoder(Header);

    // packet payload cannot be 0
    try testing.expectError(
        error.InvalidPacketPayload,
        Enc.init(testing.allocator, 64, 0.1, 0.48, 0),
    );

    // message length cannot be 0
    try testing.expectError(
        error.InvalidMessageLength,
        Enc.init(testing.allocator, 0, 0.1, 0.48, 128),
    );

    // effective FPR must be > loss_rate
    try testing.expectError(
        error.ImpossibleParameters,
        Enc.init(testing.allocator, 64, 0.2, 0.2, 128),
    );

    // p_eff must be < 0.5 in this Part-1 variant
    try testing.expectError(
        error.InvalidFPR,
        Enc.init(testing.allocator, 64, 0.1, 0.5, 128),
    );

    // Very small p_eff implies k_opt rounds above 1 after sizing => rejected
    try testing.expectError(
        error.InvalidFPR,
        Enc.init(testing.allocator, 512, 0.0, 0.01, 128),
    );
}
