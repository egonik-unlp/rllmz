const std = @import("std");
const rllmz = @import("rllmz");
const glob = @import("glob");
const cwd = std.fs.cwd;
const Entry = std.fs.Dir.Walker.Entry;
const File = std.fs.File;
const Dir = std.fs.Dir;
const CodeFileExtension = enum { rs, ts, js, zig, py, sql, css, html, ml, mli, toml, opam, prisma, other };
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
        const extension = try getExtension(filename, "dumpExtensions.txt", allocator);
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
        var it = std.mem.splitBackwardsScalar(u8, path, '.');
        const extension = it.first();
        return std.meta.stringToEnum(CodeFileExtension, extension) orelse .other;
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
    defer file.close();
    const text = try file.readToEndAlloc(allocator, 4096000);
    defer allocator.free(text);
    var patterns = std.mem.splitScalar(u8, text, '\n');
    while (patterns.next()) |pat| {
        const pattern = try allocator.dupe(u8, pat);
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
    pub fn dumpProjectToFile(self: *CodeProject, filename: []const u8, log_filename: ?[]const u8) !void {
        var logBuffer: std.ArrayList([]const u8) = .empty;
        defer {
            for (logBuffer.items) |item| {
                self.allocator.free(item);
            }
            logBuffer.deinit(self.allocator);
        }

        const headerMsg = try self.allocator.dupe(u8, "List of patterns:\n");
        try logBuffer.append(self.allocator, headerMsg);
        for (self.gitignores.items) |globito| {
            const msg = try std.fmt.allocPrint(self.allocator, "{s}\n", .{globito});
            try logBuffer.append(self.allocator, msg);
        }
        var outFile = try self.rootPath.createFile(filename, .{ .truncate = true });
        defer outFile.close();
        for (self.files.items) |codeFile| {
            const globMatch = self.matchToGlobs(codeFile.path);
            //if (globMatch) {
            for (self.gitignores.items) |globPattern| {
                const match = glob.match(globPattern, codeFile.path);
                const msg = try std.fmt.allocPrint(self.allocator, "file {s} match with pattern {s} = {any}\n", .{ codeFile.path, globPattern, match });
                try logBuffer.append(self.allocator, msg);
            }
            // }
            if ((globMatch) | ((codeFile.extension != .other)) & (codeFile.category == .Code)) {
                const file = try self.rootPath.openFile(codeFile.path, .{});
                const fileString = try file.readToEndAlloc(self.allocator, 40960000);
                const header = try std.fmt.allocPrint(self.allocator, "\n\npath: ./{s}\n", .{codeFile.path});
                defer {
                    self.allocator.free(fileString);
                    self.allocator.free(header);
                }
                const msg = try std.fmt.allocPrint(self.allocator, "Wrote {s} to dump file\n", .{codeFile.filename});
                try logBuffer.append(self.allocator, msg);
                _ = try outFile.write(header);
                _ = try outFile.write(fileString);
            }
        }
        if (log_filename) |logFile| {
            var outLogFile = try self.rootPath.createFile(logFile, .{ .truncate = true });
            defer outLogFile.close();
            for (logBuffer.items) |logItem| {
                _ = try outLogFile.write(logItem);
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

fn getFilenames() struct { []const u8, ?[]const u8 } {
    var args = std.process.args();
    // First arg is the program name.
    _ = args.next();
    const filename = args.next() orelse "file_dump.txt";
    const logFilename = args.next();
    return .{ filename, logFilename };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const match = glob.match("node_modules/*", "node_modules/algo_mas");
    std.debug.print("{any}\n", .{match});
    const filename, const logFilename = getFilenames();
    std.debug.print("dump file: {s}\n\n", .{filename});

    var project = try CodeProject.parseProject(allocator, cwd(), ".");
    defer project.deinit();
    try project.dumpProjectToFile(filename, logFilename);
}
