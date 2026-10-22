const std = @import("std");
const header = @import("base/cache/header");
const codec = @import("base/cache/codec");
const File = @import("phb/model/file").File;

pub fn write(w: *std.Io.Writer, value: *const File) std.Io.Writer.Error!void {
    try header.write(w, .phb);
    try codec.encode(w, File, value.*);
}
