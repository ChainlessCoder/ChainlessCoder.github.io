//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;
const _erasure_encoder_import = @import("erasure_encoder.zig");
const _erasure_decoder_import = @import("erasure_decoder.zig");
const _erasure_encoder_tests = @import("erasure_encoder_test.zig");
const _erasure_decoder_tests = @import("erasure_decoder_test.zig");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
