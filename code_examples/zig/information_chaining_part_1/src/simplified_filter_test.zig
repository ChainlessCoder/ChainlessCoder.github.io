const std = @import("std");
const SimplifiedFilter = @import("simplified_filter.zig").SimplifiedFilter;

fn computeFilterSizeK1(n: usize, fpr: f64) usize {
    const n_f: f64 = @floatFromInt(n);
    const m_bits_f: f64 = -n_f / @log(1.0 - fpr);
    const m_bits: usize = @intFromFloat(@ceil(m_bits_f));
    return (m_bits + 7) / 8;
}

fn mix(x: usize) usize {
    var z: u64 = @as(u64, @intCast(x));
    z +%= 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    return @as(usize, @intCast(z));
}

test "bloomFilter basic functionality (runtime-sized SimplifiedFilter)" {
    const expect = std.testing.expect;

    const n: usize = 1000;
    const fpr: f64 = 0.4;

    const byte_num = computeFilterSizeK1(n, fpr);

    const FilterType = SimplifiedFilter(usize);
    var filter = try FilterType.init(std.testing.allocator, byte_num);
    defer filter.deinit(std.testing.allocator);

    // Insert n items (mixed so we get collisions like a real hashed filter).
    for (0..n) |s| {
        filter.insert(mix(s));
    }

    // Membership checks (no false negatives).
    for (0..n) |item| {
        try expect(filter.contains(mix(item)));
    }

    // False positives on unseen items.
    var false_positive_count: usize = 0;
    for (n..n + n) |item| {
        if (filter.contains(mix(item))) {
            false_positive_count += 1;
        }
    }

    // With fpr ~ 0.4 we expect ~400 FPs out of 1000 queries.
    // Keep your original loose bound.
    try expect(false_positive_count < 500);
}
