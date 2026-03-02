const std = @import("std");
const rllmz = @import("rllmz");
const glob = @import("glob");
const cwd = std.fs.cwd;
const Entry = std.fs.Dir.Walker.Entry;
const File = std.fs.File;
const Dir = std.fs.Dir;
const CodeFileExtension = enum { rs, ts, js, zig, py, sql, css, html, other };
const Category = enum { Code, Ignore };
const ingnorableDirectories: [3][]const u8 = .{ "node_modules", "target", "zig-out" };

const CodeFile = struct {
    path: []const u8,
    filename: []const u8,
    category: Category,
    extension: CodeFileExtension,
    pub fn new(entry: Entry, allocator: std.mem.Allocator) !CodeFile {
        const path = try allocator.dupe(u8, entry.path);
        const filename = try allocator.dupe(u8, entry.basename);
        const extension = getExtension(filename);
        const category: Category = if (isIgnorable(entry.path)) Category.Ignore else Category.Code;
        return .{
            .path = path,
            .filename = filename,
            .category = category,
            .extension = extension,
        };
    }
    pub fn deinit(self: CodeFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.filename);
    }

    fn getExtension(path: []const u8) CodeFileExtension {
        if (std.mem.endsWith(u8, path, ".rs")) return .rs;
        if (std.mem.endsWith(u8, path, ".ts")) return .ts;
        if (std.mem.endsWith(u8, path, ".js")) return .js;
        if (std.mem.endsWith(u8, path, ".zig")) return .zig;
        if (std.mem.endsWith(u8, path, ".py")) return .py;
        if (std.mem.endsWith(u8, path, "sql")) return .sql;
        if (std.mem.endsWith(u8, path, "css")) return .css;
        if (std.mem.endsWith(u8, path, "html")) return .html;
        return .other;
    }

    fn isIgnorable(path: []const u8) bool {
        var ignorable = false;
        var it = std.mem.splitAny(u8, path, "/");
        while (it.next()) |pathElement| {
            for (ingnorableDirectories) |ignoreDir| {
                if (std.mem.eql(u8, pathElement, ignoreDir)) ignorable = true;
                if (std.mem.startsWith(u8, pathElement, ".")) ignorable = true;
            }
        }
        return ignorable;
    }
};

fn getGitIgnore(allocator: std.mem.Allocator, rootPath: Dir) !std.ArrayList([]const u8) {
    var checkablePatterns: std.ArrayList([]const u8) = .empty;
    const file = rootPath.openFile(".gitignore", .{}) catch |err| {
        switch (err) {
            File.OpenError.FileNotFound => {
                std.debug.print("No .gitignore found", .{});
                return .{};
            },
            else => return err,
        }
    };
    const text = try file.readToEndAlloc(allocator, 4096000);
    var patterns = std.mem.splitScalar(u8, text, '\n');
    while (patterns.next()) |pattern| {
        try checkablePatterns.append(allocator, pattern);
    }
    return checkablePatterns;
}

const CodeProject = struct {
    files: std.ArrayList(CodeFile),
    rootPath: Dir,
    exploredPath: ?[]const u8,
    allocator: std.mem.Allocator,
    gitignores: std.ArrayList([]const u8),

    pub fn parseProject(allocator: std.mem.Allocator, rootPath: Dir, exploredPath: ?[]const u8) !CodeProject {
        var files: std.ArrayList(CodeFile) = .empty;
        const projectPath = if (exploredPath != null)
            try rootPath.openDir(exploredPath.?, .{ .iterate = true })
        else
            try rootPath.openDir(".", .{ .iterate = true });
        var walk = try projectPath.walk(allocator);
        defer walk.deinit();
        const gitignores = try getGitIgnore(allocator, rootPath);
        while (try walk.next()) |node| {
            if (node.kind == .file) {
                const file = try CodeFile.new(node, allocator);
                try files.append(allocator, file);
            }
        }
        return .{
            .files = files,
            .rootPath = rootPath,
            .exploredPath = exploredPath,
            .allocator = allocator,
            .gitignores = gitignores,
        };
    }

    fn matchToGlobs(self: CodeProject, codeFileName: []const u8) bool {
        return glob.matchAny(self.gitignores.items, codeFileName);
    }
    pub fn dumpProjectToFile(self: *CodeProject, filename: []const u8) !void {
        std.debug.print("List of globs:\n", .{});
        var outFile = try self.rootPath.createFile(filename, .{ .truncate = true });
        defer outFile.close();
        for (self.files.items) |codeFile| {
            const gitignoreMatch = self.matchToGlobs(codeFile.path);
            if (gitignoreMatch & (codeFile.extension != .other)) {
                const file = try self.rootPath.openFile(codeFile.path, .{});
                const fileString = try file.readToEndAlloc(self.allocator, 40960000);
                const header = try std.fmt.allocPrint(self.allocator, "\n\npath: ./{s}\n", .{codeFile.path});
                defer {
                    self.allocator.free(fileString);
                    self.allocator.free(header);
                }
                std.debug.print("Wrote {s} to dump file\n", .{codeFile.filename});
                _ = try outFile.write(header);
                _ = try outFile.write(fileString);
            }
        }
    }
    pub fn deinit(self: *CodeProject) void {
        for (self.files.items) |file| {
            file.deinit(self.allocator);
        }

        for (self.gitignores.items) |file| {
            self.allocator.free(file);
        }
        self.gitignores.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }
};

fn getFilename() []const u8 {
    var args = std.process.args();
    _ = args.next();
    const filename = args.next() orelse "file_dump.txt";
    return filename;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const filename = getFilename();
    std.debug.print("dump file: {s}\n\n", .{filename});

    var project = try CodeProject.parseProject(allocator, cwd(), ".");
    defer project.deinit();
    try project.dumpProjectToFile(filename);
}
