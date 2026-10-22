const provenance = @import("base/provenance");

pub const gpt3_5 = provenance.derived(@embedFile("gpt3_5.bin"), 435456, "2d9f7e8d96d397bae424f6b26fcd5f54d56e790c51bce4e3d24076e36ae5a1a1", .{ .name = "gpt3_5.grd", .sha256_hex = "3bf35c611e7cd5c42a0650ee14652a8f36430127ec213ed7b7b867bd29245b3d" });
pub const vmf3_bc = provenance.derived(@embedFile("vmf3_bc.bin"), 29120, "ca27738633d5231442ec592f0e18c9392a7d8fb6fba78b3c2dd9fc333ef7be51", .{ .name = "vmf3_ht.f90", .sha256_hex = "e49ba01805cf0da8a91146596f3456d5c6995b0d1e38faf9d37d5b3894d11488" });
