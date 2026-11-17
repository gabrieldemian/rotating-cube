pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

const move_per_sec = 7.0;
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000 / @as(f32, fps)));
const buf_extra = 3;

pub var should_quit = std.atomic.Value(bool).init(false);
pub var should_resize = std.atomic.Value(bool).init(false);
var framebuf: [300 * 150 * term.cell_size + buf_extra]u8 = undefined;
var cleared_framebuf: [framebuf.len - buf_extra]u8 = undefined;
pub var zbuf_raw: [300 * 150]f32 = undefined;
var stdinbuf: [100]u8 = undefined;
var out_buf: [4096 * 10]Vec3 = undefined;

pub fn main(init: std.process.Init) !void {
    const stdout = Io.File.stdout();
    const stdin = Io.File.stdin();
    try term.init(stdout, init.io);
    term.resize(stdout);
    defer term.deinit(stdout, init.io) catch {};
    try term.raw_mode();
    defer term.leave_raw_mode() catch {};

    framebuf[0..buf_extra].* = [buf_extra]u8{ 0x1b, '[', 'H' };
    var buf =
        framebuf[buf_extra..(@as(usize, term.cols) * term.rows * term.cell_size + buf_extra)];

    const clock = std.Io.Clock.boot;
    var last = clock.now(init.io);
    var frames: u64 = 0;
    var fps_ns: u32 = 0;

    var curr_keys_down: packed struct(u10) {
        w: bool,
        a: bool,
        s: bool,
        d: bool,
        h: bool,
        j: bool,
        k: bool,
        l: bool,
        @" ": bool,
        q: bool,
    } = @fromBackingInt(0);

    var zbuf = zbuf_raw[0 .. @as(usize, term.cols) * term.rows];
    var cleared = cleared_framebuf[0..buf.len];
    for (0..zbuf.len) |i| {
        term.put_clear_cell(cleared, i);
    }

    // globals from the camera
    var translate: Vec3 = .{ 0, 0, 0 };
    var rotation: Vec2 = .{ 0, 0 };
    var last_fps: u64 = 0;

    var meshes = [_]Mesh{
        try mesh.Mesh.open(
            "cube.obj",
            init.arena,
            init.io,
        ),
        try mesh.MeshTexture.open(
            "squirrel.obj",
            "squirrel_uv.png",
            init.arena,
            init.io,
        ),
        try mesh.MeshTexture.open(
            "tiger.obj",
            "tiger_uv.png",
            init.arena,
            init.io,
        ),
    };

    meshes[0].translate[2] += -3.5;
    meshes[1].translate[2] += -3.5;
    meshes[2].translate[2] += -3.5;

    meshes[0].translate[0] += -3;
    meshes[2].translate[0] += 3;

    var out_len: usize = 0;
    for (meshes) |mesh_| {
        out_len += mesh_.mesh.len;
    }
    var out = out_buf[0..out_len];

    while (!should_quit.load(.acquire)) {
        if (should_resize.swap(false, .seq_cst)) {
            term.resize(stdout);
            buf = framebuf[buf_extra .. (@as(usize, term.cols) * term.rows * term.cell_size) + buf_extra];
            zbuf = zbuf_raw[0 .. @as(usize, term.cols) * term.rows];
            cleared = cleared_framebuf[0..buf.len];
            for (0..zbuf.len) |i| {
                term.put_clear_cell(cleared, i);
            }
        }
        const fr_until_now = last.untilNow(init.io, clock);
        const dt_ns = last.untilNow(init.io, clock).toNanoseconds();
        // nanos to millis
        const dt = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000;
        const now = clock.now(init.io);
        last = now;

        @memcpy(buf, cleared);
        @memset(zbuf, 1);

        const stdin_len = stdin.readStreaming(
            init.io,
            &[_][]u8{&stdinbuf},
        ) catch |e| switch (e) {
            error.WouldBlock => 0,
            error.EndOfStream => 0,
            else => 0, // TODO: handle errors?
        };
        if (stdin_len > 0) {
            var r = Io.Reader.fixed(stdinbuf[0..stdin_len]);
            // parse all key codes in stdin to see which keys are
            // pressed down and translate/transform all at once
            while (r.seek < r.end) {
                if (key.parse(&r)) |k| {
                    const key_is_down = k.event != .release;
                    inline for (@typeInfo(@TypeOf(curr_keys_down)).@"struct".field_names) |n| {
                        if (k.key == n[0]) @field(curr_keys_down, n) = key_is_down;
                        if (k.key == 'c' and k.mod.ctrl) should_quit.store(true, .release);
                    }
                }
            }
        }

        // --------------
        //     inputs
        // --------------

        const d = move_per_sec * dt;
        inline for (0.., @typeInfo(@TypeOf(curr_keys_down)).@"struct".field_names) |i, n| {
            if (@field(curr_keys_down, n)) {
                switch (i) {
                    0 => translate += yaw(Vec3{ 0, 0, d }, rotation[0]),
                    1 => translate += yaw(Vec3{ d, 0, 0 }, rotation[0]),
                    2 => translate += yaw(Vec3{ 0, 0, -d }, rotation[0]),
                    3 => translate += yaw(Vec3{ -d, 0, 0 }, rotation[0]),
                    4 => rotation[0] += d * 0.3,
                    5 => rotation[1] -= d * 0.3,
                    6 => rotation[1] += d * 0.3,
                    7 => rotation[0] -= d * 0.3,
                    8 => translate += Vec3{ 0, -d, 0 },
                    9 => translate += Vec3{ 0, d, 0 },
                    else => unreachable,
                }
            }
        }

        // --------------
        //    pipeline
        // --------------

        // "move camera" by transforming the meshes.
        // simulate movement and camera rotation.
        {
            var out_i: usize = 0;
            for (meshes) |mesh_| {
                for (0..mesh_.mesh.len) |i| {
                    out[out_i] = pitch(
                        yaw(mesh_.mesh[i] + translate + mesh_.translate, -rotation[0]),
                        -rotation[1],
                    );
                    out_i += 1;
                }
            }
        }

        // draw things on the screen
        // world space -> backface cull -> project (clip space, divide, NDC)
        // -> clip -> screen space 2D -> rasterize
        {
            var out_skip: usize = 0;
            for (meshes) |mesh_| {
                var face_i: usize = 0;
                while (face_i + 2 < mesh_.faces.len) : (face_i += 3) {
                    const tri = [_]Vec3{
                        out[out_skip..][mesh_.faces[face_i + 0]],
                        out[out_skip..][mesh_.faces[face_i + 1]],
                        out[out_skip..][mesh_.faces[face_i + 2]],
                    };
                    mesh_.rasterize(face_i, tri, buf);
                }
                out_skip += mesh_.mesh.len;
            }
        }

        // ---------------------
        //     fps and flush
        // ---------------------

        frames += 1;
        fps_ns += @intCast(fr_until_now.toNanoseconds());

        // 500ms in ns
        if (fps_ns >= 500_000_000) {
            last_fps = (frames * 1_000_000_000) / fps_ns;
            frames = 0;
            fps_ns = 0;
        }
        const v = last_fps % 10000;
        inline for (.{ 1000, 100, 10, 1 }, 0..) |div, i| {
            const num: u8 = @intCast((v / div) % 10);
            term.put_cell_fg(buf, i, colors.RED, '0' + num);
        }

        try stdout.writeStreamingAll(init.io, framebuf[0 .. buf.len + buf_extra]);
        // try init.io.sleep(
        //     Io.Duration.fromMilliseconds(ms_to_sleep),
        //     Io.Clock.boot,
        // );
    }
}

/// Draw line calculating slope and diffs.
fn draw_line(v0: anytype, v1: anytype, buf: []u8, rgb: colors.RGB) void {
    // -1 or 1
    const dx = v1[0] - v0[0];
    const dy = v1[1] - v0[1];
    const step: f32 = @max(@abs(dx), @abs(dy));
    if (step == 0) return;

    const stepX = dx / step;
    const stepY = dy / step;

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = term.half_rows - @as(isize, @round(
            v0[1] + ii * stepY,
        ));
        const col = term.half_cols + @as(isize, @round(
            v0[0] + ii * stepX,
        ));
        if (row >= 0 and row < term.rows and col >= 0 and col < term.cols) {
            term.put_cell_fg(buf, @intCast(row * term.cols + col), rgb, '#');
        }
    }
}

inline fn draw_line3(v0: anytype, v1: anytype, v2: anytype, buf: []u8, rgb: colors.RGB) void {
    draw_line(v0, v1, buf, rgb);
    draw_line(v1, v2, buf, rgb);
    draw_line(v2, v0, buf, rgb);
}

const std = @import("std");
const key = @import("key.zig");
const mesh = @import("mesh.zig");
const Mesh = mesh.Mesh;
const term = @import("term.zig");
const utils = @import("utils.zig");
const colors = @import("colors.zig");
const zigimg = @import("zigimg");
const normal = utils.normal;
const yaw = utils.yaw;
const pitch = utils.pitch;
const magnitude = utils.magnitude;
const dot = utils.dot;
const project = utils.project;
const screen_space = utils.screen_space;
const Io = std.Io;
const math = std.math;
const print = std.debug.print;
const posix = std.posix;
const expect = std.testing.expect;
