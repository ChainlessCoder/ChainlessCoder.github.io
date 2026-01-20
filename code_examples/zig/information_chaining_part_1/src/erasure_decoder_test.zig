const std = @import("std");
const testing = std.testing;

const ErasureEncoder = @import("erasure_encoder.zig").ErasureEncoder;
const ErasureDecoder = @import("erasure_decoder.zig").ErasureDecoder;
const state_change = @import("utils.zig").state_change;

fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

test "Information Chaining erasure: encode -> drop packets -> decode (fpr=0.48)" {
    const Header = u64;
    const Lineage = u256;

    // Keep this small enough for a unit test but large enough to have multiple packets.
    // With these parameters the sized filter ends up being 27 packets of 2 bytes each.
    const message_length: usize = 32; // bytes
    const loss_rate_design: f64 = 0.05; // encoder/decoder are sized for this
    const p_eff: f64 = 0.48;
    const packet_payload_bytes: usize = 2;

    const Enc = ErasureEncoder(Header);
    const Dec = ErasureDecoder(Lineage, Header);

    var enc = try Enc.init(
        testing.allocator,
        message_length,
        loss_rate_design,
        p_eff,
        packet_payload_bytes,
    );
    defer enc.deinit();

    var dec = try Dec.init(
        testing.allocator,
        message_length,
        loss_rate_design,
        p_eff,
        packet_payload_bytes,
    );
    defer dec.deinit();

    // Deterministic pseudo-random message.
    var seed: u64 = 0x1234_5678_9ABC_DEF0;
    var msg: [message_length]u8 = undefined;
    for (&msg) |*b| {
        b.* = @as(u8, @truncate(xorshift64(&seed)));
    }

    const nonce: Header = xorshift64(&seed);
    const final_hdr: Header = enc.encode(nonce, msg[0..], state_change);

    const pkt_count = enc.packet_count();
    try testing.expect(pkt_count > 1);
    try testing.expectEqual(pkt_count, dec.expected_packet_count());

    // Drop exactly one packet. This keeps the *actual* loss rate below the design loss rate.
    // For the chosen parameters, pkt_count is typically 27, so 1/27 ~= 3.7% < 5%.
    const drop_index: usize = 0;

    const recv_count: usize = pkt_count - 1;
    var packets = try testing.allocator.alloc(Dec.Packet, recv_count);
    defer testing.allocator.free(packets);

    var j: usize = 0;
    for (0..pkt_count) |i| {
        if (i == drop_index) continue;
        const pkt = enc.packet(i);
        packets[j] = .{ .index = pkt.index, .payload = pkt.payload };
        j += 1;
    }
    try testing.expectEqual(recv_count, j);

    var decoded: [message_length]u8 = undefined;
    try dec.decode(nonce, final_hdr, packets[0..], decoded[0..], state_change);

    try testing.expectEqualSlices(u8, msg[0..], decoded[0..]);
}
