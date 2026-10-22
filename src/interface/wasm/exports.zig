const options = @import("product_options");
const catalog = @import("interface/abi/catalog");
const exports = @import("interface/c/exports");
const wasm_layout = @import("interface/abi/layout");
const memory = @import("interface/wasm/memory");
const product = @field(catalog, options.product);
const layout = wasm_layout.text(product);

export fn pharos_wasm_layout() [*:0]const u8 {
    return layout.ptr;
}

comptime {
    exports.exportCommon(product.context);
    for (product.modules) |namespace| exports.exportFunctions(product.context.prefix, namespace);
    @export(&memory.alloc, .{ .name = "pharos_alloc" });
    @export(&memory.free, .{ .name = "pharos_free" });
}
