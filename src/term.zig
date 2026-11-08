const std = @import("std");
const posix = std.posix;
const root = @import("root");
const RGB = root.RGB;

const ColorType = enum(u8) { fg = '3', bg = '4' };

pub const cell_size = 20;
pub var cols: u16 = 1;
pub var rows: u16 = 1;
pub var half_cols: i32 = 0;
pub var half_rows: i32 = 0;

// \x1b[38;2;25;10;200mtext_go_here
fn put_cell(buf: []u8, i: usize, rgb: RGB, char: u8, code: ColorType) void {
    const offset: usize = i * cell_size;
    if (offset + cell_size > buf.len) return;
    buf[offset..][0..7].* = .{ 0x1b, '[', @backingInt(code), '8', ';', '2', ';' };
    buf[offset..][10..11].* = .{';'};
    buf[offset..][14..15].* = .{';'};
    buf[offset..][18..19].* = .{'m'};
    buf[offset..][19..20].* = .{char};
    _ = std.mem.print(buf[offset..][7..10], "{d:0>3}", .{rgb[0]}) catch unreachable;
    _ = std.mem.print(buf[offset..][11..14], "{d:0>3}", .{rgb[1]}) catch unreachable;
    _ = std.mem.print(buf[offset..][15..18], "{d:0>3}", .{rgb[2]}) catch unreachable;
}

pub fn put_clear_cell(buf: []u8, i: usize) void {
    const offset: usize = i * cell_size;
    buf[offset..][0..20].* = .{
        0x1b, '[', '0', '0', '0', '0', '0', '0', '0', '0',
        ';',  '0', '0', '0', ';', '0', '0', '0', 'm', ' ',
    };
}

pub fn put_cell_fg(buf: []u8, i: usize, rgb: RGB, char: u8) void {
    put_cell(buf, i, rgb, char, .fg);
}

pub fn put_cell_bg(buf: []u8, i: usize, rgb: RGB) void {
    put_cell(buf, i, rgb, ' ', .bg);
}

pub fn raw_mode() !void {
    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.iflag.IXON = false;
    raw.cc[@backingInt(posix.V.MIN)] = 0;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
}

pub fn leave_raw_mode() !void {
    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    defer posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};
}

fn handle_sigint(_: posix.SIG) callconv(.c) void {
    root.should_quit.store(true, .release);
}
fn handle_sigwinch(_: posix.SIG) callconv(.c) void {
    root.should_resize.store(true, .seq_cst);
}

pub fn handle_signals() void {
    const action_sigint = posix.Sigaction{
        .flags = 0,
        .mask = posix.sigemptyset(),
        .handler = .{ .handler = handle_sigint },
    };
    posix.sigaction(posix.SIG.INT, &action_sigint, null);
    const action_sigwinch = posix.Sigaction{
        .flags = 0,
        .mask = posix.sigemptyset(),
        .handler = .{ .handler = handle_sigwinch },
    };
    posix.sigaction(posix.SIG.WINCH, &action_sigwinch, null);
}

pub fn init(stdout: std.Io.File, io: std.Io) !void {
    const toflush = [_]u8{
        0x1b, '[', '?', '2', '5', 'l', // hide cursor
        0x1b, '[', '>', '1', '0', 'u', // kitty keyboard protocol
    };
    try stdout.writeStreamingAll(io, &toflush);
}

pub fn deinit(stdout: std.Io.File, io: std.Io) !void {
    // show cursor, clear screen, place cursor at the top,
    // remove kitty keyboard protocol flag
    return stdout.writeStreamingAll(io, "\x1b[2J\x1b[H\x1b[?25h\x1b[<u");
}

var winsize: posix.winsize = undefined;

pub fn resize(stdout: std.Io.File) void {
    _ = posix.system.ioctl(
        stdout.handle,
        posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    if (winsize.col != cols or winsize.row != rows) {
        cols = winsize.col;
        rows = winsize.row;
        half_cols = cols / 2;
        half_rows = rows / 2;
    }
}
