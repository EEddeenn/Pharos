const std = @import("std");

const products = [_][]const u8{ "traj", "pack", "run", "obs" };

const Modules = struct {
    shared: *std.Build.Module,
    products: [products.len]*std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host_modules = modules(b, b.graph.host, .Debug, .private);
    const headers = b.addExecutable(.{
        .name = "headers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headers.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .strip = true,
            .imports = &.{.{ .name = "shared", .module = host_modules.shared }},
        }),
    });
    for (products, host_modules.products) |dir, module| headers.root_module.addImport(b.fmt("pharos_{s}", .{dir}), module);
    const emit_headers = b.addRunArtifact(headers);
    for (products) |dir| {
        const name = b.fmt("pharos_{s}.h", .{dir});
        const path = emit_headers.addOutputFileArg(name);
        b.addNamedLazyPath(name, path);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(path, name).step);
    }

    const native = modules(b, target, optimize, .public);
    for (products, native.products) |dir, module| {
        const exe_name = b.fmt("pharos-{s}", .{dir});
        const lib_name = b.fmt("pharos_{s}", .{dir});
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}/main.zig", .{dir})),
                .target = target,
                .optimize = optimize,
                .strip = true,
                .imports = &.{.{ .name = lib_name, .module = module }},
            }),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(dir, b.fmt("Run {s} (pass args after --)", .{exe_name})).dependOn(&run.step);
        const object = b.addObject(.{
            .name = lib_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}/capi.zig", .{dir})),
                .target = target,
                .optimize = optimize,
                .strip = true,
                .imports = &.{.{ .name = "shared", .module = native.shared }},
            }),
        });
        const archive_name = b.fmt("{s}{s}{s}", .{ target.result.libPrefix(), lib_name, target.result.staticLibSuffix() });
        const ar = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "rcs" });
        const archive = ar.addOutputFileArg(archive_name);
        ar.addArtifactArg(object);
        b.addNamedLazyPath(lib_name, archive);
        b.getInstallStep().dependOn(&b.addInstallLibFile(archive, archive_name).step);
    }

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const wasm_modules = modules(b, wasm_target, optimize, .private);
    const wasm_step = b.step("wasm", "Install the three WebAssembly modules and the JSON Schemas of their inputs into lib/");
    for (products, wasm_modules.products) |dir, module| {
        if (std.mem.eql(u8, dir, "run")) continue;
        const name = b.fmt("pharos_{s}", .{dir});
        const options = b.addOptions();
        options.addOption([]const u8, "product", dir);
        const wasm = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm.zig"),
                .target = wasm_target,
                .optimize = optimize,
                .strip = true,
                .imports = &.{
                    .{ .name = "shared", .module = wasm_modules.shared },
                    .{ .name = name, .module = module },
                },
            }),
        });
        wasm.root_module.addOptions("wasm_options", options);
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        b.addNamedLazyPath(b.fmt("{s}.wasm", .{name}), wasm.getEmittedBin());
        wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } }).step);
    }

    const schemas = b.addExecutable(.{
        .name = "schemas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/schema.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .strip = true,
            .imports = &.{.{ .name = "shared", .module = host_modules.shared }},
        }),
    });
    for (products, host_modules.products) |dir, module| schemas.root_module.addImport(b.fmt("pharos_{s}", .{dir}), module);
    const emit = b.addRunArtifact(schemas);
    for ([_][]const u8{ "trajectory.schema.json", "scenario.schema.json" }) |name| {
        const schema = emit.addOutputFileArg(name);
        b.addNamedLazyPath(name, schema);
        wasm_step.dependOn(&b.addInstallLibFile(schema, name).step);
    }

    const fmt_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    const fmt_check_step = b.step("fmt-check", "Fail if any source is not zig fmt clean");
    fmt_check_step.dependOn(&fmt_check.step);
    const fmt = b.addFmt(.{ .paths = fmt_paths });
    const fmt_step = b.step("fmt", "Format build.zig, build.zig.zon and src/ in place");
    fmt_step.dependOn(&fmt.step);
}

fn modules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, visibility: enum { public, private }) Modules {
    const shared = b.createModule(.{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    var set: Modules = .{ .shared = shared, .products = undefined };
    for (products, &set.products) |dir, *module| {
        const options: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{dir})),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "shared", .module = shared }},
        };
        module.* = switch (visibility) {
            .public => b.addModule(b.fmt("pharos_{s}", .{dir}), options),
            .private => b.createModule(options),
        };
    }
    return set;
}
