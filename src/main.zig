const std = @import("std");
const rllmz = @import("rllmz");
const Entry = std.fs.Dir.Walker.Entry;
const File = std.fs.File;
const Dir = std.fs.Dir;
const CodeFileExtension = enum { rs, ts, js, zig, py, other };
const Category = enum { Code, Ignore };
const ingnorableDirectories: [3][]const u8 = .{ "node_modules", "target", "zig-cache" };

const CodeFile = struct {
    path: []const u8,
    filename: []const u8,
    category: Category,
    file: File,
    extension: CodeFileExtension,
    pub fn new(entry: Entry, allocator: std.mem.Allocator) !CodeFile {
        const path = try allocator.dupe(u8, entry.path);
        const filename = try allocator.dupe(u8, entry.basename);
        const dir = std.fs.cwd();
        const file = try dir.openFile(path, .{ .mode = .read_only });
        const extension = getExtension(filename);
        const category: Category = if (isIgnorable(entry.path)) Category.Ignore else Category.Code;

        return .{
            .file = file,
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
        return .other;
    }

    fn isIgnorable(path: []const u8) bool {
        var ignorable = false;
        var it = std.mem.splitAny(u8, path, "/");
        while (it.next()) |pathElement| {
            for (ingnorableDirectories) |ignoreDir| {
                if (std.mem.eql(u8, pathElement, ignoreDir)) ignorable = true;
            }
        }
        return ignorable;
    }
};

const CodeProject = struct {
    files: std.ArrayList(CodeFile),
    rootPath: Dir,
    exploredPath: ?[]const u8,
    allocator: std.mem.Allocator,
    pub fn parseProject(allocator: std.mem.Allocator, rootPath: Dir, exploredPath: ?[]const u8) !CodeProject {
        var files = std.ArrayList(CodeFile){};
        const projectPath = if (exploredPath != null)
            try rootPath.openDir(exploredPath.?, .{ .iterate = true })
        else
            try rootPath.openDir(".", .{ .iterate = true });
        var walk = try projectPath.walk(allocator);
        defer walk.deinit();
        while (try walk.next()) |node| {
            if (node.kind == .file) {
                const file = try CodeFile.new(node, allocator);
                try files.append(allocator, file);
            }
        }
        return .{ .files = files, .rootPath = rootPath, .exploredPath = exploredPath, .allocator = allocator };
    }

    pub fn dumpProjectToFile(self: *CodeProject, filename: []const u8) !void {
        var file = try self.rootPath.createFile(filename, .{ .truncate = true });
        defer file.close();
        for (self.files.items) |codeFile| {
            if ((codeFile.category == .Code) & (codeFile.extension != .other)) {
                const fileString = try codeFile.file.readToEndAlloc(self.allocator, 40960000);
                const header = try std.fmt.allocPrint(self.allocator, "path: ./{s}\n", .{codeFile.path});
                defer {
                    self.allocator.free(fileString);
                    self.allocator.free(header);
                }
                std.debug.print("Wrote {s} to dump file\n", .{codeFile.filename});
                _ = try file.write(header);
                _ = try file.write(fileString);
            }
        }
    }
    pub fn deinit(self: *CodeProject) void {
        for (self.files.items) |file| {
            file.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var args = std.process.args();
    _ = args.next();
    const filename = args.next() orelse "file_dump.txt";
    std.debug.print("dump file: {s}\n\n", .{filename});
    const cwd = std.fs.cwd();
    var project = try CodeProject.parseProject(allocator, cwd, ".");
    defer project.deinit();
    try project.dumpProjectToFile(filename);
}
