const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const requests = @import("requests.zig");
const URI = @import("uri.zig");
const analysis = @import("analysis.zig");
const offsets = @import("offsets.zig");
const log = std.log.scoped(.store);
const Ast = std.zig.Ast;
const BuildAssociatedConfig = @import("BuildAssociatedConfig.zig");
const BuildConfig = @import("special/build_runner.zig").BuildConfig;
const tracy = @import("tracy.zig");
const Config = @import("Config.zig");
const translate_c = @import("translate_c.zig");

const DocumentStore = @This();

pub const Hasher = std.crypto.auth.siphash.SipHash128(1, 3);

/// Initial state, that can be copied.
pub const hasher_init: Hasher = Hasher.init(&[_]u8{0} ** Hasher.key_length);

const BuildFile = struct {
    refs: usize,
    uri: []const u8,
    config: BuildFileConfig,
    builtin_uri: ?[]const u8 = null,
    build_options: ?[]BuildAssociatedConfig.BuildOption = null,

    pub fn destroy(self: *BuildFile, allocator: std.mem.Allocator) void {
        if (self.builtin_uri) |builtin_uri| allocator.free(builtin_uri);
        if (self.build_options) |opts| {
            for (opts) |*opt| {
                opt.deinit(allocator);
            }
            allocator.free(opts);
        }
        allocator.destroy(self);
    }
};

pub const BuildFileConfig = struct {
    packages: []Pkg,
    include_dirs: []const []const u8,

    pub fn deinit(self: BuildFileConfig, allocator: std.mem.Allocator) void {
        for (self.packages) |pkg| {
            allocator.free(pkg.name);
            allocator.free(pkg.uri);
        }
        allocator.free(self.packages);

        for (self.include_dirs) |dir| {
            allocator.free(dir);
        }
        allocator.free(self.include_dirs);
    }

    pub const Pkg = struct {
        name: []const u8,
        uri: []const u8,
    };
};

pub const Handle = struct {
    count: usize,
    uri: []const u8,
    text: [:0]const u8,
    tree: Ast,
    document_scope: analysis.DocumentScope,
    /// Contains one entry for every import in the document
    import_uris: []const []const u8,
    /// Contains one entry for every cimport in the document
    cimports: []CImportHandle,
    /// Items in this array list come from `import_uris` and `cimports`
    imports_used: std.ArrayListUnmanaged([]const u8),

    associated_build_file: ?*BuildFile,
    is_build_file: ?*BuildFile,
};

pub const UriToHandleMap = std.StringHashMapUnmanaged(*Handle);
pub const BuildFileList = std.ArrayListUnmanaged(*BuildFile);

allocator: std.mem.Allocator,
handles: UriToHandleMap = .{},
build_files: BuildFileList = .{},

config: *Config,
std_uri: ?[]const u8,
// TODO make this configurable
// We can't figure it out ourselves since we don't know what arguments
// the user will use to run "zig build"
zig_cache_root: []const u8 = "zig-cache",
// Since we don't compile anything and no packages should put their
// files there this path can be ignored
zig_global_cache_root: []const u8 = "ZLS_DONT_CARE",

pub fn init(
    allocator: std.mem.Allocator,
    config: *Config,
) !DocumentStore {
    return DocumentStore{
        .allocator = allocator,
        .config = config,
        .std_uri = try stdUriFromLibPath(allocator, config.zig_lib_path),
    };
}

fn updateStdUri(store: *DocumentStore) !void {
    if (store.std_uri) |std_uri|
        store.allocator.free(std_uri);
    store.std_uri = try stdUriFromLibPath(store.allocator, store.config.zig_lib_path);
}

fn loadBuildAssociatedConfiguration(allocator: std.mem.Allocator, build_file: *BuildFile, build_file_path: []const u8) !void {
    const directory_path = build_file_path[0 .. build_file_path.len - "build.zig".len];

    const options = std.json.ParseOptions{ .allocator = allocator };
    var build_associated_config = blk: {
        const config_file_path = try std.fs.path.join(allocator, &[_][]const u8{ directory_path, "zls.build.json" });
        defer allocator.free(config_file_path);

        log.info("Attempting to load build-associated config from {s}", .{config_file_path});

        var config_file = std.fs.cwd().openFile(config_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer config_file.close();

        const file_buf = try config_file.readToEndAlloc(allocator, 0x1000000);
        defer allocator.free(file_buf);

        var token_stream = std.json.TokenStream.init(file_buf);

        break :blk try std.json.parse(BuildAssociatedConfig, &token_stream, options);
    };
    defer std.json.parseFree(BuildAssociatedConfig, build_associated_config, options);

    if (build_associated_config.relative_builtin_path) |relative_builtin_path| {
        var absolute_builtin_path = try std.mem.concat(allocator, u8, &.{ directory_path, relative_builtin_path });
        defer allocator.free(absolute_builtin_path);
        build_file.builtin_uri = try URI.fromPath(allocator, absolute_builtin_path);
    }

    if (build_associated_config.build_options) |opts| {
        build_file.build_options = opts;
        build_associated_config.build_options = null;
    }
}

const LoadBuildConfigContext = struct {
    build_file: *BuildFile,
    allocator: std.mem.Allocator,
    build_runner_path: []const u8,
    global_cache_path: []const u8,
    zig_exe_path: []const u8,
    build_file_path: ?[]const u8 = null,
    cache_root: []const u8,
    global_cache_root: []const u8,
};

fn loadBuildConfiguration(context: LoadBuildConfigContext) !void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const allocator = context.allocator;
    const build_file = context.build_file;
    const build_runner_path = context.build_runner_path;
    const global_cache_path = context.global_cache_path;
    const zig_exe_path = context.zig_exe_path;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const build_file_path = context.build_file_path orelse try URI.parse(allocator, build_file.uri);
    defer if (context.build_file_path == null) allocator.free(build_file_path);
    const directory_path = build_file_path[0 .. build_file_path.len - "build.zig".len];

    const standard_args = [_][]const u8{
        zig_exe_path,
        "run",
        build_runner_path,
        "--cache-dir",
        global_cache_path,
        "--pkg-begin",
        "@build@",
        build_file_path,
        "--pkg-end",
        "--",
        zig_exe_path,
        directory_path,
        context.cache_root,
        context.global_cache_root,
    };

    var args = try arena_allocator.alloc([]const u8, standard_args.len + if (build_file.build_options) |opts| opts.len else 0);
    defer arena_allocator.free(args);

    args[0..standard_args.len].* = standard_args;
    if (build_file.build_options) |opts| {
        for (opts) |opt, i| {
            args[standard_args.len + i] = try opt.formatParam(arena_allocator);
        }
    }

    const zig_run_result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = args,
    });

    defer {
        allocator.free(zig_run_result.stdout);
        allocator.free(zig_run_result.stderr);
    }

    errdefer blk: {
        const joined = std.mem.join(allocator, " ", args) catch break :blk;
        defer allocator.free(joined);

        log.err(
            "Failed to execute build runner to collect build configuration, command:\n{s}\nError: {s}",
            .{ joined, zig_run_result.stderr },
        );
    }

    switch (zig_run_result.term) {
        .Exited => |exit_code| {
            if (exit_code != 0) return error.RunFailed;

            const parse_options = std.json.ParseOptions{ .allocator = allocator };

            build_file.config.deinit(allocator);

            var token_stream = std.json.TokenStream.init(zig_run_result.stdout);

            const config: BuildConfig = std.json.parse(
                BuildConfig,
                &token_stream,
                parse_options,
            ) catch return error.RunFailed;
            defer std.json.parseFree(BuildConfig, config, parse_options);

            var packages = try std.ArrayListUnmanaged(BuildFileConfig.Pkg).initCapacity(allocator, config.packages.len);
            errdefer {
                for (packages.items) |pkg| {
                    allocator.free(pkg.name);
                    allocator.free(pkg.uri);
                }
                packages.deinit(allocator);
            }

            var include_dirs = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, config.include_dirs.len);
            errdefer {
                for (include_dirs.items) |dir| {
                    allocator.free(dir);
                }
                include_dirs.deinit(allocator);
            }

            for (config.packages) |pkg| {
                const pkg_abs_path = try std.fs.path.resolve(allocator, &[_][]const u8{ directory_path, pkg.path });
                defer allocator.free(pkg_abs_path);

                const uri = try URI.fromPath(allocator, pkg_abs_path);
                errdefer allocator.free(uri);

                const name = try allocator.dupe(u8, pkg.name);
                errdefer allocator.free(name);

                log.debug("Found package {s}: {s}", .{ name, uri });

                packages.appendAssumeCapacity(.{ .name = name, .uri = uri });
            }

            for (config.include_dirs) |dir| {
                const path = try allocator.dupe(u8, dir);
                errdefer allocator.free(path);

                include_dirs.appendAssumeCapacity(path);
            }

            build_file.config = .{
                .packages = packages.toOwnedSlice(allocator),
                .include_dirs = include_dirs.toOwnedSlice(allocator),
            };
        },
        else => return error.RunFailed,
    }
}

// walks the build.zig files above "uri"
const BuildDotZigIterator = struct {
    allocator: std.mem.Allocator,
    uri_path: []const u8,
    dir_path: []const u8,
    i: usize,

    fn init(allocator: std.mem.Allocator, uri_path: []const u8) !BuildDotZigIterator {
        const dir_path = std.fs.path.dirname(uri_path) orelse uri_path;

        return BuildDotZigIterator{
            .allocator = allocator,
            .uri_path = uri_path,
            .dir_path = dir_path,
            .i = std.fs.path.diskDesignator(uri_path).len + 1,
        };
    }

    // the iterator allocates this memory so you gotta free it
    fn next(self: *BuildDotZigIterator) !?[]const u8 {
        while (true) {
            if (self.i > self.dir_path.len)
                return null;

            const potential_build_path = try std.fs.path.join(self.allocator, &.{
                self.dir_path[0..self.i], "build.zig",
            });

            self.i += 1;
            while (self.i < self.dir_path.len and self.dir_path[self.i] != std.fs.path.sep) : (self.i += 1) {}

            if (std.fs.accessAbsolute(potential_build_path, .{})) {
                // found a build.zig file
                return potential_build_path;
            } else |_| {
                // nope it failed for whatever reason, free it and move the
                // machinery forward
                self.allocator.free(potential_build_path);
            }
        }
    }
};

fn createBuildFile(self: *DocumentStore, build_file_path: []const u8) !*BuildFile {
    var build_file = try self.allocator.create(BuildFile);
    errdefer build_file.destroy(self.allocator);

    log.debug("creating build file: {s}", .{build_file_path});

    build_file.* = .{
        .refs = 1,
        .uri = try URI.fromPath(self.allocator, build_file_path),
        .config = .{
            .packages = &.{},
            .include_dirs = &.{},
        },
    };

    loadBuildAssociatedConfiguration(self.allocator, build_file, build_file_path) catch |err| {
        log.debug("Failed to load config associated with build file {s} (error: {})", .{ build_file.uri, err });
    };
    if (build_file.builtin_uri == null) {
        if (self.config.builtin_path != null) {
            build_file.builtin_uri = try URI.fromPath(self.allocator, self.config.builtin_path.?);
            log.info("builtin config not found, falling back to default: {?s}", .{build_file.builtin_uri});
        }
    }

    // TODO: Do this in a separate thread?
    // It can take quite long.
    loadBuildConfiguration(.{
        .build_file = build_file,
        .allocator = self.allocator,
        .build_runner_path = self.config.build_runner_path.?,
        .global_cache_path = self.config.global_cache_path.?,
        .zig_exe_path = self.config.zig_exe_path.?,
        .build_file_path = build_file_path,
        .cache_root = self.zig_cache_root,
        .global_cache_root = self.zig_global_cache_root,
    }) catch |err| {
        log.err("Failed to load packages of build file {s} (error: {})", .{ build_file.uri, err });
    };

    return build_file;
}

fn uriAssociatedWithBuild(
    self: *DocumentStore,
    build_file: *BuildFile,
    uri: []const u8,
) bool {
    var checked_uris = std.StringHashMap(void).init(self.allocator);
    defer {
        var it = checked_uris.iterator();
        while (it.next()) |entry|
            self.allocator.free(entry.key_ptr.*);

        checked_uris.deinit();
    }

    for (build_file.config.packages) |package| {
        if (std.mem.eql(u8, uri, package.uri)) {
            return true;
        }

        if (self.uriInImports(&checked_uris, package.uri, uri))
            return true;
    }

    return false;
}

fn uriInImports(
    self: *DocumentStore,
    checked_uris: *std.StringHashMap(void),
    source_uri: []const u8,
    uri: []const u8,
) bool {
    return self.uriInImportsImpl(checked_uris, source_uri, uri) catch false;
}

fn uriInImportsImpl(
    self: *DocumentStore,
    checked_uris: *std.StringHashMap(void),
    source_uri: []const u8,
    uri: []const u8,
) !bool {
    if (checked_uris.contains(source_uri))
        return false;

    // consider it checked even if a failure happens
    try checked_uris.put(try self.allocator.dupe(u8, source_uri), {});

    const handle = self.handles.get(source_uri) orelse package_handle: {
        var ret = (try self.newDocumentFromUri(source_uri)) orelse return false;
        try self.handles.put(self.allocator, source_uri, ret);
        break :package_handle ret;
    };

    var import_uris = try self.collectImportUris(handle);
    defer {
        for (import_uris) |import_uri| {
            self.allocator.free(import_uri);
        }
        self.allocator.free(import_uris);
    }

    for (import_uris) |import_uri| {
        if (std.mem.eql(u8, uri, import_uri))
            return true;

        if (self.uriInImports(checked_uris, import_uri, uri))
            return true;
    }

    return false;
}

/// This function asserts the document is not open yet and takes ownership
/// of the uri and text passed in.
fn newDocument(self: *DocumentStore, uri: []const u8, text: [:0]u8) anyerror!*Handle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var handle = try self.allocator.create(Handle);
    errdefer self.allocator.destroy(handle);

    defer {
        if (handle.associated_build_file) |build_file| {
            log.debug("Opened document `{s}` with build file `{s}`", .{ handle.uri, build_file.uri });
        } else {
            log.debug("Opened document `{s}` without a build file", .{handle.uri});
        }
    }

    var tree = try std.zig.parse(self.allocator, text);
    errdefer tree.deinit(self.allocator);

    var document_scope = try analysis.makeDocumentScope(self.allocator, tree);
    errdefer document_scope.deinit(self.allocator);

    handle.* = Handle{
        .count = 1,
        .uri = uri,
        .text = text,
        .tree = tree,
        .document_scope = document_scope,
        .import_uris = &.{},
        .cimports = &.{},
        .imports_used = .{},
        .associated_build_file = null,
        .is_build_file = null,
    };

    // TODO: Better logic for detecting std or subdirectories?
    const in_std = std.mem.indexOf(u8, uri, "/std/") != null;
    if (self.config.zig_exe_path != null and std.mem.endsWith(u8, uri, "/build.zig") and !in_std) {
        log.debug("Document is a build file, extracting packages...", .{});
        // This is a build file.

        const build_file_path = try URI.parse(self.allocator, uri);
        defer self.allocator.free(build_file_path);

        const build_file = try self.createBuildFile(build_file_path);
        errdefer build_file.destroy(self.allocator);

        try self.build_files.append(self.allocator, build_file);
        handle.is_build_file = build_file;
    } else if (self.config.zig_exe_path != null and !in_std) {
        log.debug("Going to walk down the tree towards: {s}", .{uri});
        // walk down the tree towards the uri. When we hit build.zig files
        // determine if the uri we're interested in is involved with the build.
        // This ensures that _relevant_ build.zig files higher in the
        // filesystem have precedence.
        const uri_path = try URI.parse(self.allocator, uri);
        defer self.allocator.free(uri_path);

        var prev_build_file: ?*BuildFile = null;
        var build_it = try BuildDotZigIterator.init(self.allocator, uri_path);
        while (try build_it.next()) |build_path| {
            defer self.allocator.free(build_path);

            log.debug("found build path: {s}", .{build_path});
            // if it's found or created
            const build_file = for (self.build_files.items) |build_file| {
                const entry_build_path = try URI.parse(self.allocator, build_file.uri);
                defer self.allocator.free(entry_build_path);

                if (std.mem.eql(u8, build_path, entry_build_path))
                    break build_file;
            } else build_file: {
                var ret = try self.createBuildFile(build_path);
                errdefer ret.destroy(self.allocator);

                try self.build_files.append(self.allocator, ret);
                break :build_file ret;
            };

            // TODO: is this needed?
            // Check if the build file already exists
            if (self.handles.get(build_file.uri) == null) {
                // Read the build file, create a new document, set the candidate to the new build file.
                const file = try std.fs.openFileAbsolute(build_path, .{});
                defer file.close();

                const build_file_text = try file.readToEndAllocOptions(
                    self.allocator,
                    std.math.maxInt(usize),
                    null,
                    @alignOf(u8),
                    0,
                );
                errdefer self.allocator.free(build_file_text);

                _ = try self.newDocument(build_file.uri, build_file_text);
            }

            if (self.uriAssociatedWithBuild(build_file, uri)) {
                build_file.refs += 1;
                handle.associated_build_file = build_file;
                break;
            } else {
                prev_build_file = build_file;
            }
        }

        // if there was no direct imports found, use the closest build file if possible
        if (handle.associated_build_file == null) {
            if (prev_build_file) |build_file| {
                build_file.refs += 1;
                handle.associated_build_file = build_file;
            }
        }
    }

    handle.import_uris = try self.collectImportUris(handle);
    errdefer {
        for (handle.import_uris) |imp_uri| {
            self.allocator.free(imp_uri);
        }
        self.allocator.free(handle.import_uris);
    }

    handle.cimports = try self.collectCIncludes(handle);
    errdefer {
        for (handle.cimports) |*item| {
            item.result.deinit(self.allocator);
        }
        self.allocator.free(handle.cimports);
    }

    try self.handles.putNoClobber(self.allocator, uri, handle);
    return handle;
}

pub fn openDocument(self: *DocumentStore, uri: []const u8, text: []const u8) !*Handle {
    if (self.handles.getEntry(uri)) |entry| {
        entry.value_ptr.*.count += 1;
        log.debug("Document already open: {s}, new count: {}", .{ uri, entry.value_ptr.*.count });
        if (entry.value_ptr.*.is_build_file) |build_file| {
            build_file.refs += 1;
        }
        return entry.value_ptr.*;
    }

    const duped_text = try self.allocator.dupeZ(u8, text);
    errdefer self.allocator.free(duped_text);
    const duped_uri = try self.allocator.dupeZ(u8, uri);
    errdefer self.allocator.free(duped_uri);

    return try self.newDocument(duped_uri, duped_text);
}

fn decrementBuildFileRefs(self: *DocumentStore, build_file: *BuildFile) void {
    build_file.refs -= 1;
    if (build_file.refs == 0) {
        log.debug("Freeing build file {s}", .{build_file.uri});

        build_file.config.deinit(self.allocator);

        // Decrement count of the document since one count comes
        // from the build file existing.
        self.decrementCount(build_file.uri);
        self.allocator.free(build_file.uri);

        // Remove the build file from the array list
        _ = self.build_files.swapRemove(std.mem.indexOfScalar(*BuildFile, self.build_files.items, build_file).?);
        build_file.destroy(self.allocator);
    }
}

fn decrementCount(self: *DocumentStore, uri: []const u8) void {
    if (self.handles.getEntry(uri)) |entry| {
        const handle = entry.value_ptr.*;
        if (handle.count == 0) return;
        handle.count -= 1;

        if (handle.count > 0)
            return;

        log.debug("Freeing document: {s}", .{uri});

        if (handle.associated_build_file) |build_file| {
            self.decrementBuildFileRefs(build_file);
        }

        if (handle.is_build_file) |build_file| {
            self.decrementBuildFileRefs(build_file);
        }

        handle.tree.deinit(self.allocator);
        self.allocator.free(handle.text);

        for (handle.imports_used.items) |import_uri| {
            self.decrementCount(import_uri);
        }

        for (handle.import_uris) |import_uri| {
            self.allocator.free(import_uri);
        }

        for (handle.cimports) |*item| {
            item.result.deinit(self.allocator);
        }

        handle.document_scope.deinit(self.allocator);
        handle.imports_used.deinit(self.allocator);
        self.allocator.free(handle.import_uris);
        self.allocator.free(handle.cimports);
        self.allocator.destroy(handle);
        const uri_key = entry.key_ptr.*;
        std.debug.assert(self.handles.remove(uri));
        self.allocator.free(uri_key);
    }
}

pub fn closeDocument(self: *DocumentStore, uri: []const u8) void {
    self.decrementCount(uri);
}

pub fn getHandle(self: *DocumentStore, uri: []const u8) ?*Handle {
    return self.handles.get(uri);
}

fn collectImportUris(self: *DocumentStore, handle: *Handle) ![]const []const u8 {
    var imports = try analysis.collectImports(self.allocator, handle.tree);
    errdefer {
        for (imports.items) |imp| {
            self.allocator.free(imp);
        }
        imports.deinit(self.allocator);
    }

    // Convert to URIs
    var i: usize = 0;
    while (i < imports.items.len) {
        if (try self.uriFromImportStr(self.allocator, handle.*, imports.items[i])) |uri| {
            // The raw import strings are owned by the document and do not need to be freed here.
            imports.items[i] = uri;
            i += 1;
        } else {
            _ = imports.swapRemove(i);
        }
    }
    return imports.toOwnedSlice(self.allocator);
}

pub const CImportSource = struct {
    /// the `@cImport` node
    node: Ast.Node.Index,
    /// hash of c source file
    hash: [Hasher.mac_length]u8,
    /// c source file
    source: []const u8,
};

/// Collects all `@cImport` nodes and converts them into c source code
/// the translation process is defined in `translate_c.convertCInclude`
/// Caller owns returned memory.
fn collectCIncludeSources(self: *DocumentStore, handle: *Handle) ![]CImportSource {
    var cimport_nodes = try analysis.collectCImportNodes(self.allocator, handle.tree);
    defer self.allocator.free(cimport_nodes);

    var sources = try std.ArrayListUnmanaged(CImportSource).initCapacity(self.allocator, cimport_nodes.len);
    errdefer {
        for (sources.items) |item| {
            self.allocator.free(item.source);
        }
        sources.deinit(self.allocator);
    }

    for (cimport_nodes) |node| {
        const c_source = translate_c.convertCInclude(self.allocator, handle.tree, node) catch |err| switch (err) {
            error.Unsupported => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };

        var hasher = hasher_init;
        hasher.update(c_source);
        var hash: [Hasher.mac_length]u8 = undefined;
        hasher.final(&hash);

        sources.appendAssumeCapacity(.{
            .node = node,
            .hash = hash,
            .source = c_source,
        });
    }

    return sources.toOwnedSlice(self.allocator);
}

pub const CImportHandle = struct {
    /// the `@cImport` node
    node: Ast.Node.Index,
    /// hash of the c source file
    hash: [Hasher.mac_length]u8,
    /// the result from calling zig translate-c
    /// see `translate_c.translate`
    result: translate_c.Result,
};

/// Collects all `@cImport` nodes and converts them into zig files using translate-c
/// Caller owns returned memory.
fn collectCIncludes(self: *DocumentStore, handle: *Handle) ![]CImportHandle {
    var cimport_nodes = try analysis.collectCImportNodes(self.allocator, handle.tree);
    defer self.allocator.free(cimport_nodes);

    var cimports = try std.ArrayListUnmanaged(CImportHandle).initCapacity(self.allocator, cimport_nodes.len);
    errdefer {
        for (cimports.items) |*item| {
            item.result.deinit(self.allocator);
        }
        cimports.deinit(self.allocator);
    }

    for (cimport_nodes) |node| {
        const c_source = translate_c.convertCInclude(self.allocator, handle.tree, node) catch |err| switch (err) {
            error.Unsupported => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(c_source);

        const result = (try self.translate(handle, c_source)) orelse continue;
        errdefer result.deinit(self.allocator);

        var hasher = hasher_init;
        hasher.update(c_source);
        var hash: [Hasher.mac_length]u8 = undefined;
        hasher.final(&hash);

        cimports.appendAssumeCapacity(.{
            .node = node,
            .hash = hash,
            .result = result,
        });
    }

    return cimports.toOwnedSlice(self.allocator);
}

fn translate(self: *DocumentStore, handle: *Handle, source: []const u8) error{OutOfMemory}!?translate_c.Result {
    const include_dirs: []const []const u8 = if (handle.associated_build_file) |build_file| build_file.config.include_dirs else &.{};

    const maybe_result = try translate_c.translate(
        self.allocator,
        self.config.*,
        include_dirs,
        source,
    );

    if (maybe_result) |result| {
        switch (result) {
            .success => |uri| log.debug("Translated cImport into {s}", .{uri}),
            else => {},
        }
    }

    return maybe_result;
}

fn refreshDocument(self: *DocumentStore, handle: *Handle) !void {
    log.debug("New text for document {s}", .{handle.uri});
    handle.tree.deinit(self.allocator);
    handle.tree = try std.zig.parse(self.allocator, handle.text);

    handle.document_scope.deinit(self.allocator);
    handle.document_scope = try analysis.makeDocumentScope(self.allocator, handle.tree);

    var old_imports = handle.import_uris;
    var old_cimports = handle.cimports;

    handle.import_uris = try self.collectImportUris(handle);

    handle.cimports = try self.refreshDocumentCIncludes(handle);

    defer {
        for (old_imports) |uri| {
            self.allocator.free(uri);
        }
        self.allocator.free(old_imports);

        for (old_cimports) |*old_cimport| {
            old_cimport.result.deinit(self.allocator);
        }
        self.allocator.free(old_cimports);
    }

    var i: usize = 0;
    while (i < handle.imports_used.items.len) {
        const old = handle.imports_used.items[i];

        const found_new = found: {
            for (handle.import_uris) |new| {
                if (!std.mem.eql(u8, new, old)) continue;
                break :found new;
            }
            for (handle.cimports) |cimport| {
                if (cimport.result != .success) continue;
                const new = cimport.result.success;

                if (!std.mem.eql(u8, old, new)) continue;
                break :found new;
            }
            break :found null;
        };

        if (found_new) |new| {
            handle.imports_used.items[i] = new;
            i += 1;
        } else {
            log.debug("Import removed: {s}", .{old});
            self.decrementCount(old);
            _ = handle.imports_used.swapRemove(i);
        }
    }
}

fn refreshDocumentCIncludes(self: *DocumentStore, handle: *Handle) ![]CImportHandle {
    const new_sources: []CImportSource = try self.collectCIncludeSources(handle);
    defer {
        for (new_sources) |new_source| {
            self.allocator.free(new_source.source);
        }
        self.allocator.free(new_sources);
    }

    var old_cimports = handle.cimports;
    var new_cimports = try std.ArrayListUnmanaged(CImportHandle).initCapacity(self.allocator, new_sources.len);
    errdefer {
        for (new_cimports.items) |*new_cimport| {
            new_cimport.result.deinit(self.allocator);
        }
        new_cimports.deinit(self.allocator);
    }

    outer: for (new_sources) |new_source| {
        // look for a old cimport with identical source hash
        for (old_cimports) |old_cimport| {
            if (!std.mem.eql(u8, &new_source.hash, &old_cimport.hash)) continue;

            new_cimports.appendAssumeCapacity(.{
                .node = old_cimport.node,
                .hash = old_cimport.hash,
                .result = try old_cimport.result.dupe(self.allocator),
            });
            continue :outer;
        }

        const c_source = translate_c.convertCInclude(self.allocator, handle.tree, new_source.node) catch |err| switch (err) {
            error.Unsupported => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(c_source);

        var hasher = hasher_init;
        var hash: [Hasher.mac_length]u8 = undefined;
        hasher.update(c_source);
        hasher.final(&hash);

        const new_result = (try self.translate(handle, new_source.source)) orelse continue;
        errdefer new_result.deinit(self.allocator);

        new_cimports.appendAssumeCapacity(.{
            .node = new_source.node,
            .hash = hash,
            .result = new_result,
        });
    }

    return new_cimports.toOwnedSlice(self.allocator);
}

pub fn applySave(self: *DocumentStore, handle: *Handle) !void {
    if (handle.is_build_file) |build_file| {
        loadBuildConfiguration(.{
            .build_file = build_file,
            .allocator = self.allocator,
            .build_runner_path = self.config.build_runner_path.?,
            .global_cache_path = self.config.global_cache_path.?,
            .zig_exe_path = self.config.zig_exe_path.?,
            .cache_root = self.zig_cache_root,
            .global_cache_root = self.zig_global_cache_root,
        }) catch |err| {
            log.err("Failed to load build configuration for {s} (error: {})", .{ build_file.uri, err });
        };
    }
}

pub fn applyChanges(
    self: *DocumentStore,
    handle: *Handle,
    content_changes: []const requests.TextDocumentContentChangeEvent,
    encoding: offsets.Encoding,
) !void {
    var last_full_text_change: ?usize = null;
    var i: usize = content_changes.len;
    while (i > 0) {
        i -= 1;
        if (content_changes[i].range == null) {
            last_full_text_change = i;
        }
    }

    var text_array = std.ArrayListUnmanaged(u8){};
    errdefer text_array.deinit(self.allocator);

    try text_array.appendSlice(self.allocator, if (last_full_text_change) |index| content_changes[index].text else handle.text);

    // don't even bother applying changes before a full text change
    const changes = content_changes[if (last_full_text_change) |index| index + 1 else 0..];

    for (changes) |item| {
        const range = item.range.?; // every element is guaranteed to have `range` set
        const text = item.text;

        const loc = offsets.rangeToLoc(text_array.items, range, encoding);
        try text_array.replaceRange(self.allocator, loc.start, loc.end - loc.start, text);
    }

    const new_text = try text_array.toOwnedSliceSentinel(self.allocator, 0);
    self.allocator.free(handle.text);
    handle.text = new_text;

    try self.refreshDocument(handle);
}

pub fn uriFromImportStr(self: *DocumentStore, allocator: std.mem.Allocator, handle: Handle, import_str: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, import_str, "std")) {
        if (self.std_uri) |uri| return try allocator.dupe(u8, uri) else {
            log.debug("Cannot resolve std library import, path is null.", .{});
            return null;
        }
    } else if (std.mem.eql(u8, import_str, "builtin")) {
        if (handle.associated_build_file) |build_file| {
            if (build_file.builtin_uri) |builtin_uri| {
                return try allocator.dupe(u8, builtin_uri);
            }
        }
        if (self.config.builtin_path) |_| {
            return try URI.fromPath(allocator, self.config.builtin_path.?);
        }
        return null;
    } else if (!std.mem.endsWith(u8, import_str, ".zig")) {
        if (handle.associated_build_file) |build_file| {
            for (build_file.config.packages) |pkg| {
                if (std.mem.eql(u8, import_str, pkg.name)) {
                    return try allocator.dupe(u8, pkg.uri);
                }
            }
        }
        return null;
    } else {
        const base = handle.uri;
        var base_len = base.len;
        while (base[base_len - 1] != '/' and base_len > 0) {
            base_len -= 1;
        }
        base_len -= 1;
        if (base_len <= 0) {
            return error.UriBadScheme;
        }
        return try URI.pathRelative(allocator, base[0..base_len], import_str);
    }
}

pub fn resolveImport(self: *DocumentStore, handle: *Handle, import_str: []const u8) !?*Handle {
    const allocator = self.allocator;
    const final_uri = (try self.uriFromImportStr(
        self.allocator,
        handle.*,
        import_str,
    )) orelse return null;
    defer allocator.free(final_uri);

    for (handle.imports_used.items) |uri| {
        if (std.mem.eql(u8, uri, final_uri)) {
            return self.getHandle(final_uri) orelse return null;
        }
    }
    // The URI must be somewhere in the import_uris or the package uris
    const handle_uri = find_uri: {
        for (handle.import_uris) |uri| {
            if (std.mem.eql(u8, uri, final_uri)) {
                break :find_uri uri;
            }
        }
        if (handle.associated_build_file) |bf| {
            for (bf.config.packages) |pkg| {
                if (std.mem.eql(u8, pkg.uri, final_uri)) {
                    break :find_uri pkg.uri;
                }
            }
        }
        return null;
    };

    // New import.
    // Check if the import is already opened by others.
    if (self.getHandle(final_uri)) |new_handle| {
        // If it is, append it to our imports, increment the count, set our new handle
        // and return the parsed tree root node.
        try handle.imports_used.append(self.allocator, handle_uri);
        new_handle.count += 1;
        return new_handle;
    }

    // New document, read the file then call into openDocument.
    var document_handle = try self.newDocumentFromUri(final_uri);

    // Add to import table of current handle.
    try handle.imports_used.append(allocator, handle_uri);

    return document_handle;
}

pub fn resolveCImport(self: *DocumentStore, handle: *Handle, node: Ast.Node.Index) !?*Handle {
    const uri = blk: {
        for (handle.cimports) |item| {
            if (item.node != node) continue;

            switch (item.result) {
                .success => |uri| break :blk uri,
                .failure => return null,
            }
        }
        return null;
    };

    // Check if the import is already opened by others.
    if (self.getHandle(uri)) |new_handle| {
        // If it is, append it to our imports, increment the count, set our new handle
        // and return the parsed tree root node.
        try handle.imports_used.append(self.allocator, uri);
        new_handle.count += 1;
        return new_handle;
    }

    // New document, read the file then call into openDocument.
    var document_handle = try self.newDocumentFromUri(uri);

    // Add to cimport table of current handle.
    try handle.imports_used.append(self.allocator, uri);

    return document_handle;
}

fn newDocumentFromUri(self: *DocumentStore, uri: []const u8) !?*Handle {
    const file_path = try URI.parse(self.allocator, uri);
    defer self.allocator.free(file_path);

    var file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        log.debug("Cannot open file '{s}': {}", .{ file_path, err });
        return null;
    };
    defer file.close();

    const file_contents = file.readToEndAllocOptions(
        self.allocator,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.debug("Could not read from file {s}", .{file_path});
            return null;
        },
    };
    errdefer self.allocator.free(file_contents);

    return try self.newDocument(try self.allocator.dupe(u8, uri), file_contents);
}

fn stdUriFromLibPath(allocator: std.mem.Allocator, zig_lib_path: ?[]const u8) !?[]const u8 {
    if (zig_lib_path) |zpath| {
        const std_path = std.fs.path.resolve(allocator, &[_][]const u8{
            zpath, "./std/std.zig",
        }) catch |first_std_err| blk: {
            // workaround for https://github.com/ziglang/zig/issues/12516
            break :blk std.fs.path.resolve(allocator, &[_][]const u8{
                zpath, "./zig/std/std.zig",
            }) catch {
                log.debug("Failed to resolve zig std library path, error: {}", .{first_std_err});
                return null;
            };
        };

        defer allocator.free(std_path);
        // Get the std_path as a URI, so we can just append to it!
        return try URI.fromPath(allocator, std_path);
    }

    return null;
}

pub fn deinit(self: *DocumentStore) void {
    var entry_iterator = self.handles.iterator();
    while (entry_iterator.next()) |entry| {
        entry.value_ptr.*.document_scope.deinit(self.allocator);
        entry.value_ptr.*.tree.deinit(self.allocator);
        self.allocator.free(entry.value_ptr.*.text);
        for (entry.value_ptr.*.import_uris) |uri| {
            self.allocator.free(uri);
        }
        self.allocator.free(entry.value_ptr.*.import_uris);
        for (entry.value_ptr.*.cimports) |*cimport| {
            cimport.result.deinit(self.allocator);
        }
        self.allocator.free(entry.value_ptr.*.cimports);
        entry.value_ptr.*.imports_used.deinit(self.allocator);
        self.allocator.free(entry.key_ptr.*);
        self.allocator.destroy(entry.value_ptr.*);
    }

    self.handles.deinit(self.allocator);
    for (self.build_files.items) |build_file| {
        build_file.config.deinit(self.allocator);
        self.allocator.free(build_file.uri);
        build_file.destroy(self.allocator);
    }
    if (self.std_uri) |std_uri| {
        self.allocator.free(std_uri);
    }
    self.build_files.deinit(self.allocator);
}

fn tagStoreCompletionItems(self: DocumentStore, arena: *std.heap.ArenaAllocator, base: *DocumentStore.Handle, comptime name: []const u8) ![]types.CompletionItem {
    // TODO Better solution for deciding what tags to include
    var max_len: usize = @field(base.document_scope, name).count();
    for (base.imports_used.items) |uri| {
        max_len += @field(self.handles.get(uri).?.document_scope, name).count();
    }

    var result_set = analysis.CompletionSet{};
    try result_set.ensureTotalCapacity(arena.allocator(), max_len);
    for (@field(base.document_scope, name).entries.items(.key)) |completion| {
        result_set.putAssumeCapacityNoClobber(completion, {});
    }

    for (base.imports_used.items) |uri| {
        const curr_set = &@field(self.handles.get(uri).?.document_scope, name);
        for (curr_set.entries.items(.key)) |completion| {
            result_set.putAssumeCapacity(completion, {});
        }
    }

    return result_set.entries.items(.key);
}

pub fn errorCompletionItems(self: DocumentStore, arena: *std.heap.ArenaAllocator, base: *DocumentStore.Handle) ![]types.CompletionItem {
    return try self.tagStoreCompletionItems(arena, base, "error_completions");
}

pub fn enumCompletionItems(self: DocumentStore, arena: *std.heap.ArenaAllocator, base: *DocumentStore.Handle) ![]types.CompletionItem {
    return try self.tagStoreCompletionItems(arena, base, "enum_completions");
}
