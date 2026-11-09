const std = @import("std");
const root = @import("root");
const term = @import("term.zig");
const math = std.math;

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);
pub const RGB = Vec3;

const light = norm(Vec3{ 0, 0, -1 });
const camera = Vec3{ 0, 0, 0 };

/// Backface culling.
/// Returns true if the triangle should be culled.
pub inline fn backface_cull(v0: Vec3, v1: Vec3, v2: Vec3) bool {
    const n = cross(v1 - v0, v2 - v0);
    return dot(n, camera - v0) < 0;
}

/// Backface culling in NDC space.
/// Return true if should be culled.
pub inline fn backface_cull_ndc(v0: Vec3, v1: Vec3, v2: Vec3) bool {
    return (v1[0] - v0[0]) * (v2[1] - v0[1]) - (v1[1] - v0[1]) * (v2[0] - v0[0]) <= 0;
}

/// Return the normal of a triangle (a ray that points outwards).
pub inline fn normal(v0: Vec3, v1: Vec3, v2: Vec3) Vec3 {
    return norm(cross(v1 - v0, v2 - v0));
}

/// Cast a ray between point `p` and triangle `v` and return the dot product.
pub inline fn normdot(p: Vec3, v0: Vec3, v1: Vec3, v2: Vec3) f32 {
    return dot(normal(v0, v1, v2), norm(p - v0));
}

pub inline fn color_light(v: Vec3, c: RGB) RGB {
    return @max(@round(c * lumi(v)), Vec3{ 0, 0, 0 });
}

/// Return luminescence of triangle between 0.2..1.0
pub inline fn lumi(v0: Vec3, v1: Vec3, v2: Vec3) Vec3 {
    return @splat(math.clamp(normdot(light, v0, v1, v2), 0.2, 0.8));
}

/// From NDC (-1 to 1) space to screen space/view space.
/// On a real game: [-960, +960] = 1920px
/// this way we get centered pixels and can get buffer index easily.
pub inline fn screen_space2(ndc: Vec3) Vec3 {
    return ndc * term.halfcolsrows;
}

/// From world space to clip space.
pub fn project2(v: Vec3, aspect: f32) Vec4 {
    // deg = rad * 180 / PI
    // math.pi / 2 = 180/2 = 90°
    // math.pi / 3 = 180/3 = 60°
    const fov: f32 = math.pi / 2.0;
    const near: f32 = 0.1;
    const far = 300;

    const top = near * @tan(fov / 2);
    const bottom = -top;
    const right = top * aspect;
    const left = -right;

    const xc =
        v[0] * (2 * near / (right - left)) +
        v[2] * (right + left) / (right - left);
    const yc =
        v[1] * (2 * near) / (top - bottom) +
        v[2] * (top + bottom) / (top - bottom);
    const zc =
        v[2] * (far + near) / (near - far) +
        2 * far * near / (near - far);
    const w = -v[2];

    return .{ xc, yc, zc, w };
}

var clipbuf: [24]Vec3 = undefined;

const Plane = struct { axis: u2, sign: f32 };

// near, left, right, bottom, top — near first so w > 0 afterwards.
const planes = [_]Plane{
    // zig fmt: off
    .{ .axis = 2, .sign = 1.0 },  // near   z >= -w
    .{ .axis = 0, .sign = 1.0 },  // left   x >= -w
    .{ .axis = 0, .sign = -1.0 }, // right  x <=  w
    .{ .axis = 1, .sign = 1.0 },  // bottom y >= -w
    .{ .axis = 1, .sign = -1.0 }, // top    y <=  w
    // .{ .axis = 2, .sign = -1.0 }, // far    z <=  w
    // zig fmt: on
};

fn clip_plane(src: []const Vec4, dst: []Vec4, pl: Plane) usize {
    if (src.len == 0) return 0;

    var n: usize = 0;
    var prev = src[src.len - 1];
    const prev_arr: [4]f32 = prev;
    var dprev = pl.sign * prev_arr[pl.axis] + prev_arr[3];

    for (src) |curr| {
        const curr_arr: [4]f32 = curr;
        const dcurr = pl.sign * curr_arr[pl.axis] + curr_arr[3];
        const pin = dprev >= 0;
        const cin = dcurr >= 0;
        const t: Vec4 = @splat(dprev / (dprev - dcurr));

        if (pin and cin) {
            dst[n] = curr;
            n += 1;
        } else if (pin and !cin) {
            dst[n] = prev + t * (curr - prev);
            n += 1;
        } else if (!pin and cin) {
            dst[n] = prev + t * (curr - prev);
            n += 1;
            dst[n] = curr;
            n += 1;
        }
        prev = curr;
        dprev = dcurr;
    }
    return n;
}

// Clip a triangle in clip space to NDC [-1 1] and Z [0 1].
pub fn clip(c0: Vec4, c1: Vec4, c2: Vec4) []Vec3 {
    var a: [12]Vec4 = undefined;
    a[0] = c0;
    a[1] = c1;
    a[2] = c2;
    var b: [12]Vec4 = undefined;
    var len: usize = 3;
    var src: []Vec4 = &a;
    var dst: []Vec4 = &b;

    for (planes) |pl| {
        len = clip_plane(src[0..len], dst, pl);
        if (len == 0) return &.{};
        const t = src;
        src = dst;
        dst = t;
    }

    var ndc: [12]Vec3 = undefined;
    for (0..len) |i| {
        const v = src[i];
        ndc[i] = .{
            // clamp to make sure its always in bounds to NDC
            math.clamp(v[0] / v[3], -1.0, 1.0),
            math.clamp(v[1] / v[3], -1.0, 1.0),
            math.clamp(v[2] / v[3], -1.0, 1.0),
        };
    }

    // fan triangulate
    const tris = len - 2;
    for (0..tris) |i| {
        clipbuf[3 * i + 0] = ndc[0];
        clipbuf[3 * i + 1] = ndc[i + 1];
        clipbuf[3 * i + 2] = ndc[i + 2];
    }
    return clipbuf[0 .. tris * 3];
}

pub fn move_z(v: Vec3, d: f32) Vec3 {
    return .{ v[0], v[1], v[2] + d };
}

/// Rotate around Y
pub fn yaw(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos + v[2] * sin, v[1], -v[0] * sin + v[2] * cos };
}

/// Rotate around X
pub fn pitch(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0], v[1] * cos - v[2] * sin, v[1] * sin + v[2] * cos };
}

/// Rotate around Z
pub fn roll(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos - v[1] * sin, v[0] * sin + v[1] * cos, v[2] };
}

pub fn rotate_y(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0], v[1] * cos - v[2] * sin, v[2] };
}

/// Normalize vector `v`
pub inline fn norm(v: anytype) @TypeOf(v) {
    return v / @as(@TypeOf(v), @splat(magnitude(v)));
}

/// |v|
pub inline fn magnitude(v: anytype) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

/// a × b
pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// a · b
pub inline fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

/// Return a positive number if `p` is on the left side of `a` and `b`
pub inline fn edge_cross(a: Vec2, b: Vec2, p: Vec2) f32 {
    const ab = b - a;
    const ap = p - a;
    return ab[0] * ap[1] - ab[1] * ap[0];
}

/// Barycentric coordinates
pub fn bary(v0: Vec2, v1: Vec2, v2: Vec2, p: Vec2) Vec3 {
    const area: Vec3 = @splat(edge_cross(v0, v1, v2) / 1);
    const alpha = edge_cross(v1, v2, p) / 1;
    const beta = edge_cross(v2, v0, p) / 1;
    const gamma = edge_cross(v0, v1, p) / 1;
    return Vec3{ alpha, beta, gamma } / area;
}

const expect = std.testing.expect;

test "cull" {
    // front triangle
    const a = move_z(Vec3{ 1, 1, 1 }, -3.5);
    const b = move_z(Vec3{ -1, 1, 1 }, -3.5);
    const c = move_z(Vec3{ -1, -1, 1 }, -3.5);
    try expect(!backface_cull(a, b, c));
}

test "cull_2" {
    // back triangle
    const a = Vec3{ -3, 3, -3 };
    const b = Vec3{ 3, 3, -3 };
    const c = Vec3{ 3, -3, -3 };
    try expect(backface_cull(a, b, c));

    // rotated back triangle -> front triangle
    //
    // either put them on the origin or just do a half
    // rotation and move towards the camera.
    //
    // const center = (a + b + c) / @as(Vec3, @splat(3));
    const move_to_camera = Vec3{ 1, 1, -3 };
    try expect(!backface_cull(
        yaw(a, math.pi) * move_to_camera,
        yaw(b, math.pi) * move_to_camera,
        yaw(c, math.pi) * move_to_camera,
    ));
}

test "cross" {
    const a = Vec3{ 2, 3, 4 };
    const b = Vec3{ 5, 6, 7 };
    const c = cross(a, b);
    try expect(c[0] == -3);
    try expect(c[1] == 6);
    try expect(c[2] == -3);
}

test "normalize" {
    const v = Vec3{ 10, 10, 10 };
    const n = norm(v);
    // a normalized vector has a length of ~1
    const sum = @reduce(.Add, n * n);
    try expect(sum > 0.999999 and sum < 1.000001);
    try expect(n[0] == 0.57735026);
    try expect(n[1] == 0.57735026);
    try expect(n[2] == 0.57735026);
}

test "magnitude" {
    const v = Vec3{ 10, 10, 10 };
    const vlen = magnitude(v);
    try expect(vlen == 17.320509);
}

test "dot_product" {
    const a = Vec2{ -12, 16 };
    const b = Vec2{ 12, 9 };
    const d = dot(a, b);
    try expect(d == 0);
}

test "dot_product_1" {
    const a = Vec3{ 0, 0, -1 };
    const b = Vec3{ 0, 0, -1 };
    const d = dot(a, b);
    // same direction
    try expect(d == 1);
}

test "dot_product_2" {
    const a = Vec3{ 0, 0, -1 };
    const b = Vec3{ 0, 0, 1 };
    const d = dot(a, b);
    // pointing to each other (opposite directions)
    try expect(d == -1);
}

// hide cursor \x1b[?25l
// show l -> h

// clear screen and put cursor at top left
// "\x1b[2J\x1b[H"

// writes hello at the same position if called in a loop
// \x1b[Hhello

// true color
//
// background = 19 bytes + text bytes
// \x1b[48;2;025;010;200mTRUECOLOR
//
// foreground
// \x1b[38;2;25;10;200mTRUECOLOR
//
// ";2" means
// 2 = direct color / RGB
// 5 = indexed palette index 0..255 color
// 3 = CMY
// 4 = CMYK
//
// ";38" means
//
// cool pattern \/
// @round(
//     math.lerp(RED, GREEN, alpha) +
//     math.lerp(GREEN, BLUE, beta) +
//     math.lerp(BLUE, RED, gamma)
// );
