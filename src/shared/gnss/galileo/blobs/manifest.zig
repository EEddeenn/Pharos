const provenance = @import("../../../core.zig").provenance;

pub const e1_codes = provenance.blob(@embedFile("e1_codes.bin"), 51200, "9313f969ad5b6547c06814f2f88b8313402349a135816f759d234471b5f5c5f3");
pub const e6_codes = provenance.blob(@embedFile("e6_codes.bin"), 64000, "e6bfcd27a64f5609715cc8708898017420dc39560c0a5ac0efbea5ba6ec2eb8b");
