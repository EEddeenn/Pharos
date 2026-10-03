const provenance = @import("../../../core.zig").provenance;

pub const b1c_gen2 = provenance.blob(@embedFile("b1c_gen2.bin"), 10000, "0fc1961e28aa038f9c2653ba76170c15eaba2a12b0ae35e82a1f378a65d77853");
pub const b1c_gen3 = provenance.blob(@embedFile("b1c_gen3.bin"), 1936, "4fc715ada4042735ef6b2e0be72a169e05da626c1d7e8d5b2e55bc2a5dab6456");
pub const b2a_gen = provenance.blob(@embedFile("b2a_gen.bin"), 2304, "8bfb401eea50864fb88d7ca52ef91b426b909d699c984cba0739edfea53841e9");
pub const b2b_gen = provenance.blob(@embedFile("b2b_gen.bin"), 6561, "40131b67939fab6d04632b94d6b0fccdeff5b25d523de6973d54490fd6a83b05");
