const provenance = @import("../provenance.zig");

pub const egm96_15 = provenance.derived(@embedFile("egm96_15.bin"), 2079364, "9f9d3cb322a50048c7d56e3dc2c99cc08202f342596298ce93f9cee2e2335d8f", .{ .name = "WW15MGH.GRD", .sha256_hex = "4bcc2c8b2314528530de6d1dccbd0ff26cd15912c892d48a6ad38b3ed79bdbae" });
