const std = @import("std");

const products = [_][]const u8{ "traj", "pack", "run", "obs" };

const Import = struct { name: []const u8, line: usize };

const Sources = struct {
    digest: u64,
    files: std.StringHashMapUnmanaged([]const Import),

    fn read(b: *std.Build) !Sources {
        const io = b.graph.io;
        var src = try b.root.openDir(io, "src", .{ .iterate = true });
        defer src.close(io);
        var walker = try src.walkSelectively(b.allocator);
        defer walker.deinit();
        var paths: std.ArrayList([]u8) = .empty;
        b.dependOnDirectoryContents(b.path("src"));
        while (try walker.next(io)) |entry| {
            if (entry.basename[0] == '.') continue;
            const path = try b.allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
            switch (entry.kind) {
                .directory => {
                    try walker.enter(io, entry);
                    b.dependOnDirectoryContents(b.path(b.fmt("src/{s}", .{path})));
                },
                .file => try paths.append(b.allocator, path),
                else => {},
            }
        }
        std.mem.sortUnstable([]u8, paths.items, {}, struct {
            fn lessThan(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lessThan);

        // Same-source caches use every non-hidden src file, in path order: path, zero byte, little-endian length, bytes.
        var hash: std.hash.Wyhash = .init(0);
        var files: std.StringHashMapUnmanaged([]const Import) = .empty;
        for (paths.items) |path| {
            const bytes = try src.readFileAllocOptions(io, path, b.allocator, .unlimited, .of(u8), 0);
            defer b.allocator.free(bytes);
            b.dependOnFileContents(b.path(b.fmt("src/{s}", .{path})));
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            hash.update(path);
            hash.update(&.{0});
            hash.update(&len);
            hash.update(bytes);
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            const key = path[0 .. path.len - 4];
            if (provided(key) or std.mem.eql(u8, key, "root")) std.process.fatal("src/{s}: reserved module name '{s}'", .{ path, key });
            try files.put(b.allocator, key, try scanImports(b.allocator, path, bytes));
        }
        var entries = files.iterator();
        while (entries.next()) |entry| {
            for (entry.value_ptr.*) |dependency| {
                if (!provided(dependency.name) and !files.contains(dependency.name))
                    badImport(entry.key_ptr.*, dependency, "unknown module key");
            }
        }
        return .{ .digest = hash.final(), .files = files };
    }
};

const Modules = struct {
    b: *std.Build,
    sources: *const Sources,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    info: *std.Build.Module,
    exposure: Exposure,
    cache: std.StringHashMapUnmanaged(*std.Build.Module) = .empty,

    const Exposure = enum { private, products };

    fn init(b: *std.Build, sources: *const Sources, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, info: *std.Build.Step.Options, exposure: Exposure) Modules {
        return .{ .b = b, .sources = sources, .target = target, .optimize = optimize, .info = info.createModule(), .exposure = exposure };
    }

    fn module(self: *Modules, key: []const u8) std.mem.Allocator.Error!*std.Build.Module {
        if (self.cache.get(key)) |cached| return cached;
        const public_name = if (self.exposure == .products) publicModuleName(key) else null;
        const options = self.moduleOptions(key);
        const result = if (public_name) |name| self.b.addModule(name, options) else self.b.createModule(options);
        // Cache before connecting dependencies: mutually referring source files still own exactly one Module each.
        try self.cache.put(self.b.allocator, key, result);
        try self.connect(result, key, null);
        return result;
    }

    fn productEntry(self: *Modules, key: []const u8, product: []const u8) std.mem.Allocator.Error!*std.Build.Module {
        const result = self.b.createModule(self.moduleOptions(key));
        const options = self.b.addOptions();
        options.addOption([]const u8, "product", product);
        try self.connect(result, key, options.createModule());
        return result;
    }

    fn moduleOptions(self: *const Modules, key: []const u8) std.Build.Module.CreateOptions {
        if (!self.sources.files.contains(key)) std.process.fatal("unknown entry module '{s}'", .{key});
        return .{
            .root_source_file = self.b.path(self.b.fmt("src/{s}.zig", .{key})),
            .target = self.target,
            .optimize = self.optimize,
            .strip = true,
        };
    }

    fn connect(self: *Modules, consumer: *std.Build.Module, key: []const u8, product_options: ?*std.Build.Module) std.mem.Allocator.Error!void {
        for (self.sources.files.get(key).?) |dependency| {
            const name = dependency.name;
            if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin")) continue;
            const imported = if (std.mem.eql(u8, name, "build_info"))
                self.info
            else if (std.mem.eql(u8, name, "product_options"))
                product_options orelse badImport(key, dependency, "only a configured product entry can import")
            else
                try self.module(name);
            consumer.addImport(name, imported);
        }
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sources = try Sources.read(b);
    const info = try buildInfo(b, sources.digest);

    var host = Modules.init(b, &sources, b.graph.host, .debug, info, .private);
    const headers = b.addExecutable(.{
        .name = "headers",
        .root_module = try host.module("codegen/c_headers"),
    });
    const emit_headers = b.addRunArtifact(headers);
    const headers_dir = emit_headers.addOutputDirectoryArg2("headers", .{});
    for (products) |product| {
        const name = b.fmt("pharos_{s}.h", .{product});
        const path = headers_dir.path(b, name);
        b.addNamedLazyPath(name, path);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(path, name).step);
    }

    var native = Modules.init(b, &sources, target, optimize, info, .products);
    for (products) |product| {
        const exe_name = b.fmt("pharos-{s}", .{product});
        const lib_name = b.fmt("pharos_{s}", .{product});
        _ = try native.module(b.fmt("products/{s}/root", .{product}));
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = try native.module(b.fmt("products/{s}/main", .{product})),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(product, b.fmt("Run {s} (pass args after --)", .{exe_name})).dependOn(&run.step);
        const lib = b.addLibrary(.{
            .name = lib_name,
            .root_module = try native.productEntry("interface/c/root", product),
            .linkage = .static,
        });
        b.addNamedLazyPath(lib_name, lib.getEmittedBin());
        b.installArtifact(lib);
    }

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    var wasm_modules = Modules.init(b, &sources, wasm_target, optimize, info, .private);
    const wasm_step = b.step("wasm", "Install the three WebAssembly modules and the JSON Schemas of their inputs into lib/");
    for (products) |product| {
        if (std.mem.eql(u8, product, "run")) continue;
        const name = b.fmt("pharos_{s}", .{product});
        const wasm = b.addExecutable(.{
            .name = name,
            .root_module = try wasm_modules.productEntry("interface/wasm/exports", product),
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        b.addNamedLazyPath(b.fmt("{s}.wasm", .{name}), wasm.getEmittedBin());
        wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } }).step);
    }

    const schemas = b.addExecutable(.{
        .name = "schemas",
        .root_module = try host.module("codegen/json_schema"),
    });
    const emit = b.addRunArtifact(schemas);
    const schemas_dir = emit.addOutputDirectoryArg2("schemas", .{});
    for ([_][]const u8{ "trajectory.schema.json", "scenario.schema.json" }) |name| {
        const schema = schemas_dir.path(b, name);
        b.addNamedLazyPath(name, schema);
        wasm_step.dependOn(&b.addInstallLibFile(schema, name).step);
    }

    const fmt_paths = b.pathList(&.{ "build.zig", "build.zig.zon", "src" });
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    const fmt_check_step = b.step("fmt-check", "Fail if any source is not zig fmt clean");
    fmt_check_step.dependOn(&fmt_check.step);
    const fmt = b.addFmt(.{ .paths = fmt_paths });
    const fmt_step = b.step("fmt", "Format build.zig, build.zig.zon and src/ in place");
    fmt_step.dependOn(&fmt.step);
}

fn scanImports(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]const Import {
    var tokenizer = std.zig.Tokenizer.init(source);
    var imports: std.ArrayList(Import) = .empty;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .builtin or !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import")) continue;
        const line = std.zig.findLineColumn(source, token.loc.start).line + 1;
        const open = tokenizer.next();
        const literal = tokenizer.next();
        var close = tokenizer.next();
        if (close.tag == .comma) close = tokenizer.next();
        if (open.tag != .l_paren or literal.tag != .string_literal or close.tag != .r_paren)
            std.process.fatal("src/{s}:{d}: import must name one literal module key", .{ path, line });
        const name = source[literal.loc.start + 1 .. literal.loc.end - 1];
        if (std.mem.findScalar(u8, name, '\\') != null or std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon") or std.mem.eql(u8, name, "root"))
            std.process.fatal("src/{s}:{d}: use a canonical module key, not '{s}'", .{ path, line, name });
        try imports.append(allocator, .{ .name = try allocator.dupe(u8, name), .line = line });
    }
    return imports.toOwnedSlice(allocator);
}

fn provided(name: []const u8) bool {
    return std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin") or
        std.mem.eql(u8, name, "build_info") or std.mem.eql(u8, name, "product_options");
}

fn badImport(key: []const u8, dependency: Import, message: []const u8) noreturn {
    std.process.fatal("src/{s}.zig:{d}: {s} '{s}'", .{ key, dependency.line, message, dependency.name });
}

fn publicModuleName(key: []const u8) ?[]const u8 {
    inline for (products) |product| {
        if (std.mem.eql(u8, key, "products/" ++ product ++ "/root")) return "pharos_" ++ product;
    }
    return null;
}

fn buildInfo(b: *std.Build, source_digest: u64) !*std.Build.Step.Options {
    var root = try b.root.openDir(b.graph.io, ".", .{});
    defer root.close(b.graph.io);
    const source = try root.readFileAllocOptions(b.graph.io, "build.zig.zon", b.allocator, .unlimited, .of(u8), 0);
    defer b.allocator.free(source);
    b.dependOnFileContents(b.path("build.zig.zon"));
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(struct { version: []const u8 }, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseZon => diagnostics.fatal("build.zig.zon"),
    };
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", try std.SemanticVersion.parse(manifest.version));
    options.addOption(u64, "source_digest", source_digest);
    return options;
}
