const std = @import("std");
const log = std.log;
const process = std.process;
const os = std.os;
const fs = std.fs;

const temp_file_name = "asdf.tmp";

var mk_backup = false;

const Action = enum { toCRLF, toLF };

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer serr("leaked: {}\n", .{ gpa.deinit() });
    const malloc = gpa.allocator();

    const argv = try getArgv(malloc);
    defer malloc.free(argv);

    if ( argv.len <= 1 ) {
        sout("warning: no arguments\n", .{});
        os.exit(0);
    }

    var input_file_name: []const u8 = undefined;
    var action: Action = .toCRLF;
    var help: bool = false;
    for ( argv ) |arg, i| {
        // TODO: better argument parsing
        if ( i == 0 ) continue
        else if ( std.mem.eql(u8, arg, "--help")
                or std.mem.eql(u8, arg, "--help") )
            help = true
        else if ( i == 1 )
            input_file_name = arg
        else if ( std.mem.eql(u8, arg, "--to-crlf") )
            action = .toCRLF
        else if ( std.mem.eql(u8, arg, "--to-lf") )
            action = .toLF
        else if ( std.mem.eql(u8, arg, "--backup") )
            mk_backup = true
        else sout("warning: unused argument [{d}]: {s}\n", .{ i, arg });
    }

    if ( help ) {
        print_help(argv[0]);
        os.exit(0);
    }

    const cwd = std.fs.cwd();
    var dir = cwd.openDir(input_file_name, .{
        .access_sub_paths = true, .iterate = true,
    }) catch |err| switch (err) {
            error.NotDir => {
                try doAction(action, cwd, input_file_name, malloc);
                os.exit(0);
            },
            else => return err,
    };
    defer dir.close();

    try traverse(dir, action, malloc);

    os.exit(0);
}

fn traverse(dir: fs.Dir, action: Action,
            alloc: std.mem.Allocator) anyerror!void {
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
            .File => try doAction(action, dir, name, alloc),
            else  => {},
        }
    }
}

fn doAction(action: Action, dir: fs.Dir,
            input_file_name: []const u8,
            alloc: std.mem.Allocator) !void {
    try actOnTemp(action, dir, input_file_name, alloc);

    if ( mk_backup ) {
        const backup_name = try alloc.alloc(u8, input_file_name.len + 1);
        defer alloc.free(backup_name);
        for ( input_file_name ) |c, i| {
            backup_name[i] = c;
        }
        backup_name[input_file_name.len] = '~';
        try dir.rename(input_file_name, backup_name);
    }
    try dir.rename(temp_file_name, input_file_name);
}

fn actOnTemp(action: Action, dir: fs.Dir,
            input_file_name: []const u8,
            alloc: std.mem.Allocator) !void {
    const fin = dir.openFile(input_file_name, .{ .read = true }) catch
        |err| {
            serr("Couldn't open file {s}: {s}", .{ input_file_name, err });
            os.exit(1);
    };
    defer fin.close();

    const ftmp = dir.createFile(
            temp_file_name, .{ .exclusive = true, }
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const realpath = try dir.realpathAlloc(alloc, temp_file_name);
                defer alloc.free(realpath);
                serr("{s}: already exists.\n" ++
                    "If you are sure that nobody is using this file. " ++
                    "Consider deleating `{s}` and try again.",
                    .{ realpath, temp_file_name });
                return;
            },
            else => return err,
    };
    defer ftmp.close();

    try copyWithAction(action, fin, ftmp, alloc);
}

fn copyWithAction(action: Action, fin: fs.File, fout: fs.File,
            alloc: std.mem.Allocator) !void {
    const fit_in_memory = fin.readToEndAlloc(alloc, 0xFF_FF_FF_FF) catch
        |err| switch (err) {
            error.FileTooBig => null,
            else => return err,
    };

    if ( fit_in_memory ) |input| {
        try actOnFullBuffer(action, input, fout);
        alloc.free(input);
    } else { // use small buffer
        try fin.seekFromEnd(0);
        var bytesLeft: usize = try fin.getPos();
        try fin.seekTo(0);
        var buffer: [0xFF_FF]u8 = undefined;
        var lastc: ?u8 = null;
        while ( bytesLeft > 0 ) {
            const read = try fin.read(&buffer);
            bytesLeft -= read;
            try actOnBuffer(action, lastc, bytesLeft == 0,
                buffer[0..read], fout);
            lastc = buffer[read-1];
        }
    }
}

fn actOnFullBuffer(action: Action, buffer: []const u8, fout: fs.File) !void {
    return actOnBuffer(action, null, true, buffer, fout);
}

fn actOnBuffer(action: Action, lastc: ?u8, isLastBuffer: bool,
            buffer: []const u8, fout: fs.File) !void {
    const debugging = false;

    var c: ?u8 = lastc;
    var last_i: usize = 0;
    var i: usize = 0;
    const limit = if (isLastBuffer) buffer.len else buffer.len - 1;

    if ( debugging )
        sout("DEBUG: limit={d} len={d}\n\n", .{ limit, buffer.len });
    while ( last_i < limit ) : ( i += 1 ) {
        var stop = false;
        while ( i < buffer.len and !stop ) : ( i += 1 ) {
            stop = switch ( action ) {
                .toCRLF   => buffer[i] == '\n'
                    and ( c == null or c.? != '\r' ),
                .toLF => buffer[i] == '\r',
            };
            if ( debugging )
                sout(">>> i={d} c=({x:0>2})" ++
                    "buffer[i]=({x:0>2}) write=\"{s}\"\n",
                    .{ i, c, buffer[i], buffer[last_i..i] });
            c = buffer[i];
        }
        if ( stop ) i -= 1;

        if ( debugging ) {
            sout("\nDEBUG: last_i={d} i={d}\n", .{ last_i, i });
            sout("....write=\"{s}\" buffer[i]={c}({d})\n", .{
                buffer[last_i..i],
                if (stop) buffer[i] else '1',
                if (stop) buffer[i] else '1',
            });
        }
        try fout.writeAll(buffer[last_i..i]);
        switch ( action ) {
            .toCRLF   => {
                if ( stop ) try fout.writeAll("\r");
                last_i = i;
            },
            .toLF =>
                last_i = if ( stop ) i + 1 else i,
        }

        if ( debugging ) sout("----------\n", .{});
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

fn nextArg(argIter: *process.ArgIterator,
            alloc: std.mem.Allocator) ?[]u8 {
    return argIter.next(alloc) catch |err| blk: {
        serr("Found err: {}", .{ err });
        break :blk null;
    };
}

fn print_help(prog: []const u8) void {
    sout("usage: {s} <target-file> [--to-crlf|--to-lf] [--backup]\n",
        .{ prog });
    sout("Converts file or directory subtree"
        ++ " from linux to windows text file format"
        ++ " or the other way around\n", .{});
    sout("\n    Options:\n", .{});
    sout("    --to-crlf (default)\n", .{});
    sout("        adds '\\r' before '\\n' (when missing)\n", .{});
    sout("    --to-lf\n", .{});
    sout("        removes '\\r' before '\\n'\n", .{});
    sout("    --backup\n", .{});
    sout("        backups the old file to <target-file>~\n", .{});
    sout("    --help\n", .{});
    sout("        prints this message\n", .{});
}

fn sout(comptime format: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch |err| switch (err) {
        else => log.info("sout: {}", .{ err }),
    };
}

fn serr(comptime format: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format, args) catch |err| switch (err) {
        else => log.info("serr: {}", .{ err }),
    };
}
