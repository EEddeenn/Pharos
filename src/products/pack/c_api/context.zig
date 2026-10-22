const c_context = @import("interface/c/context");
pub const Context = c_context.Context("pharos_pack", &.{ "input", "io", "bundle" });
