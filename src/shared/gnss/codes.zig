const std = @import("std");
const types = @import("../core.zig").types;
const gps = @import("gps/codes.zig");
const galileo = @import("galileo/codes.zig");
const glonass = @import("glonass/codes.zig");
const bds = @import("bds/codes.zig");

const Error = error{OutOfMemory};

pub fn dataCode(gpa: std.mem.Allocator, signal: types.Signal, sat: types.SatId) Error![]u8 {
    switch (signal) {
        .l1ca => {
            const code = try gpa.alloc(u8, gps.l1ca_chips);
            gps.l1ca(sat, code[0..gps.l1ca_chips]);
            return code;
        },
        .g1, .g2 => {
            const code = try gpa.alloc(u8, glonass.chips);
            glonass.code(code[0..glonass.chips]);
            return code;
        },
        .l5 => {
            const code = try gpa.alloc(u8, gps.l5_chips);
            gps.l5(sat, false, code[0..gps.l5_chips]);
            return code;
        },
        .l2c => {
            const code = try gpa.alloc(u8, gps.l2cm_chips);
            gps.l2cm(sat, code[0..gps.l2cm_chips]);
            return code;
        },
        .l1c => {
            const code = try gpa.alloc(u8, gps.l1c_chips);
            gps.l1c(sat, false, code[0..gps.l1c_chips]);
            return code;
        },
        .e1 => {
            const code = try gpa.alloc(u8, galileo.e1_chips);
            galileo.e1(sat, false, code[0..galileo.e1_chips]);
            return code;
        },
        .e5a => {
            const code = try gpa.alloc(u8, galileo.e5a_chips);
            galileo.e5a(sat, false, code[0..galileo.e5a_chips]);
            return code;
        },
        .e5b => {
            const code = try gpa.alloc(u8, galileo.e5b_chips);
            galileo.e5b(sat, false, code[0..galileo.e5b_chips]);
            return code;
        },
        .e6 => {
            const code = try gpa.alloc(u8, galileo.e6_chips);
            galileo.e6(sat, false, code[0..galileo.e6_chips]);
            return code;
        },
        .b1i, .b2i => {
            const code = try gpa.alloc(u8, bds.b1i_chips);
            bds.b1i(sat, code[0..bds.b1i_chips]);
            return code;
        },
        .b3i => {
            const code = try gpa.alloc(u8, bds.b3i_chips);
            bds.b3i(sat, code[0..bds.b3i_chips]);
            return code;
        },
        .b1c => {
            const code = try gpa.alloc(u8, bds.b1c_chips);
            bds.b1c(sat, false, code[0..bds.b1c_chips]);
            return code;
        },
        .b2a => {
            const code = try gpa.alloc(u8, bds.b2a_chips);
            bds.b2a(sat, false, code[0..bds.b2a_chips]);
            return code;
        },
        .b2b => {
            const code = try gpa.alloc(u8, bds.b2b_chips);
            bds.b2b(sat, code[0..bds.b2b_chips]);
            return code;
        },
    }
}

pub fn pilotCode(gpa: std.mem.Allocator, signal: types.Signal, sat: types.SatId) Error!?[]u8 {
    switch (signal) {
        .l5 => {
            const code = try gpa.alloc(u8, gps.l5_chips);
            gps.l5(sat, true, code[0..gps.l5_chips]);
            return code;
        },
        .l2c => {
            const code = try gpa.alloc(u8, gps.l2cl_chips);
            gps.l2cl(sat, code[0..gps.l2cl_chips]);
            return code;
        },
        .l1c => {
            const code = try gpa.alloc(u8, gps.l1c_chips);
            gps.l1c(sat, true, code[0..gps.l1c_chips]);
            return code;
        },
        .b1c => {
            const code = try gpa.alloc(u8, bds.b1c_chips);
            bds.b1c(sat, true, code[0..bds.b1c_chips]);
            return code;
        },
        .b2a => {
            const code = try gpa.alloc(u8, bds.b2a_chips);
            bds.b2a(sat, true, code[0..bds.b2a_chips]);
            return code;
        },
        .e1 => {
            const code = try gpa.alloc(u8, galileo.e1_chips);
            galileo.e1(sat, true, code[0..galileo.e1_chips]);
            return code;
        },
        .e5a => {
            const code = try gpa.alloc(u8, galileo.e5a_chips);
            galileo.e5a(sat, true, code[0..galileo.e5a_chips]);
            return code;
        },
        .e5b => {
            const code = try gpa.alloc(u8, galileo.e5b_chips);
            galileo.e5b(sat, true, code[0..galileo.e5b_chips]);
            return code;
        },
        .e6 => {
            const code = try gpa.alloc(u8, galileo.e6_chips);
            galileo.e6(sat, true, code[0..galileo.e6_chips]);
            return code;
        },
        .l1ca, .b1i, .b2i, .b3i, .b2b, .g1, .g2 => return null,
    }
}

pub fn secondaryCode(signal: types.Signal, sat: types.SatId) ?[]const u1 {
    return switch (signal) {
        .l5 => &gps.nh20,
        .l1c => gps.l1cSecondary(sat),
        .e1 => &galileo.cs25,
        .e5a => galileo.e5aSecondary(sat),
        .e5b => galileo.e5bSecondary(sat),
        .e6 => galileo.e6Secondary(sat),
        .b1c => bds.b1cSecondary(sat),
        .b2a => bds.b2aSecondary(sat),
        .l1ca, .l2c, .b1i, .b2i, .b3i, .b2b, .g1, .g2 => null,
    };
}
