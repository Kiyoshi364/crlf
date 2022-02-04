const std = @import("std");
const log = std.log;
const process = std.process;
const os = std.os;
const fs = std.fs;

const temp_file_name = "asdf.tmp";

const mk_backup = false;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer out("leaked: {}\n", .{ gpa.deinit() });
    const malloc = gpa.allocator();

    const argv = try getArgv(malloc);
    defer malloc.free(argv);

    var input_file_name: []const u8 = undefined;
    for ( argv ) |arg, i| {
        // TODO: parse arguments
        if ( i == 0 ) continue
        else if ( i == 1 ) input_file_name = arg
        else out("warning: unused argument [{d}]: {s}\n", .{ i, arg });
    }

    const cwd = std.fs.cwd();
    var dir = cwd.openDir(input_file_name, .{
        .access_sub_paths = true, .iterate = true,
    }) catch |err| switch (err) {
            error.NotDir => {
                try addCRTemp(cwd, input_file_name, malloc);
                if ( mk_backup ) {
                    const backup_name = try malloc.alloc(u8, input_file_name.len + 1);
                    defer malloc.free(backup_name);
                    for ( input_file_name ) |c, i| {
                        backup_name[i] = c;
                    }
                    backup_name[input_file_name.len] = '~';
                    try cwd.rename(input_file_name, backup_name);
                }
                try cwd.rename(temp_file_name, input_file_name);
                os.exit(0);
            },
            else => return err,
    };
    defer dir.close();

    try traverse(dir, .toCRLF, malloc);

    os.exit(0);
}

const Action = enum { toCRLF, fromCRLF };

fn traverse(dir: fs.Dir, action: Action, alloc: std.mem.Allocator) anyerror!void {
    var iter = dir.iterate();
    while ( try iter.next() ) |entry| {
        const name = entry.name;
        if ( std.mem.eql(u8, temp_file_name, name) ) continue;
        switch ( entry.kind ) {
            .Directory => {
                var new_dir = try dir.openDir(name, .{
                    .access_sub_paths = true, .iterate = true,
                });
                defer new_dir.close();
                try traverse(new_dir, action, alloc);
            },
            .File => {
                try addCRTemp(dir, name, alloc);
                if ( mk_backup ) {
                    const backup_name = try alloc.alloc(u8, name.len + 1);
                    defer alloc.free(backup_name);
                    for ( name ) |c, i| {
                        backup_name[i] = c;
                    }
                    backup_name[name.len] = '~';
                    try dir.rename(name, backup_name);
                }
                try dir.rename(temp_file_name, name);
            },
            else => {},
        }
    }
}

fn addCRTemp(dir: fs.Dir, input_file_name: []const u8, alloc: std.mem.Allocator) !void {
    const fin = dir.openFile(input_file_name, .{ .read = true }) catch
        |err| {
            out("Couldn't open file {s}: {s}", .{ input_file_name, err });
            os.exit(1);
    };
    defer fin.close();

    const ftmp = dir.createFile(
            temp_file_name, .{ .exclusive = true, }
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                out("{s}: already exists.\n" ++
                    "If you are sure that nobody is using this file. " ++
                    "Consider deleating `{s}` and try again.",
                    .{ temp_file_name, temp_file_name });
                os.exit(1);
            },
            else => return err,
    };
    defer ftmp.close();

    try addCRToFile(fin, ftmp, alloc);
}

fn addCRToFile(fin: fs.File, fout: fs.File, alloc: std.mem.Allocator) !void {
    const fit_in_memory = fin.readToEndAlloc(alloc, 0xFF_FF_FF_FF) catch
        |err| switch (err) {
            error.FileTooBig => null,
            else => return err,
    };

    if ( fit_in_memory ) |input| {
        try writeCRFromBuffer(input, fout);
        alloc.free(input);
    } else { // use small buffer
        try fin.seekFromEnd(0);
        var bytesLeft: usize = try fin.getPos();
        try fin.seekTo(0);
        var buffer: [0xFF_FF]u8 = undefined;
        while ( bytesLeft > 0 ) {
            const read = try fin.read(&buffer);
            try writeCRFromBuffer(buffer[0..read], fout);
            bytesLeft -= read;
        }
    }
}

fn writeCRFromBuffer(buffer: []const u8, fout: fs.File) !void {
    var last_i: usize = 0;
    var i: usize = 0;
    while ( last_i < buffer.len ) : ( i += 1 ) {
        while ( i < buffer.len and !( buffer[i] == '\n'
            and ( i == 0 or buffer[i-1] != '\r' ) ) ) : ( i += 1 ) {}
        try fout.writeAll(buffer[last_i..i]);
        if ( i < buffer.len ) {
            try fout.writeAll("\r");
        }
        last_i = i;
    }
}

fn getArgc(alloc: std.mem.Allocator) usize {
    var argIter = process.args();
    var argc: usize = 0;
    while ( nextArg(&argIter, alloc) ) |_| {
        argc += 1;
    }
    return argc;
}

fn getArgv(alloc: std.mem.Allocator) ![][]const u8 {
    var argIter = process.args();
    const argc = getArgc(alloc);
    const argv = try alloc.alloc([]const u8, argc);
    var i: u8 = 0;
    while ( nextArg(&argIter, alloc) ) |arg| {
        argv[i] = arg;
        i += 1;
    }
    return argv;
}

fn nextArg(argIter: *process.ArgIterator, alloc: std.mem.Allocator) ?[]u8 {
    return argIter.next(alloc) catch |err| blk: {
        out("Found err: {}", .{ err });
        break :blk null;
    };
}

fn out(comptime format: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch |err| switch (err) {
        else => log.info("out: {}", .{ err }),
    };
}
