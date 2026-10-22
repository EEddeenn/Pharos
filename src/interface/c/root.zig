const options = @import("product_options");
const catalog = @import("interface/abi/catalog");
const exports = @import("interface/c/exports");
const product = @field(catalog, options.product);

comptime {
    exports.exportCommon(product.context);
    for (product.modules) |namespace| exports.exportFunctions(product.context.prefix, namespace);
}
