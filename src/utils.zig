const std = @import("std");
const root = @import("root");
const term = @import("term.zig");
const math = std.math;

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const RGB = Vec3;

const light = norm(Vec3{ 0, 0, -1 });
const camera = Vec3{ 0, 0, 0 };

/// Backface culling.
/// Returns true if the triangle is visible.
pub fn is_visible(v0: Vec3, v1: Vec3, v2: Vec3) bool {
    if (v0[2] >= -0.1 or v1[2] >= -0.1 or v2[2] >= -0.1) return false;
    return normdot(camera, v0, v1, v2) > 0;
}

/// Return the normal of a triangle (a ray that points outwards).
pub fn normal(v0: Vec3, v1: Vec3, v2: Vec3) Vec3 {
    return norm(cross(v1 - v0, v2 - v0));
}

/// Cast a ray between point `p` and triangle `v` and return the dot product.
pub fn normdot(p: Vec3, v0: Vec3, v1: Vec3, v2: Vec3) f32 {
    return dot(normal(v0, v1, v2), norm(p - v0));
}

pub fn color_light(v: Vec3, c: RGB) RGB {
    return @max(@round(c * lumi(v)), Vec3{ 0, 0, 0 });
}

/// Return luminescence of triangle between 0.2..1.0
pub fn lumi(v0: Vec3, v1: Vec3, v2: Vec3) Vec3 {
    return @splat(@max(@min(normdot(light, v0, v1, v2), 1.0), 0.2));
}

/// From NDC space to screen space
pub fn screen_space(ndc: Vec3) Vec3 {
    const w: f32 = @floatFromInt(term.cols);
    const h: f32 = @floatFromInt(term.rows);
    return .{ ndc[0] * w, ndc[1] * h, ndc[2] };
}

/// Project vector and return NDC
pub fn project(v: Vec3, a: f32) Vec3 {
    const fov: f32 = math.pi / 3.0;
    const near: f32 = 0.1;
    const far = 100;

    const top = near * @tan(fov / 2);
    const bottom = -top;
    const right = top * a;
    const left = -right;

    const x1 =
        v[0] * (2 * near / (right - left)) +
        v[2] * (right + left) / (right - left);
    const y1 =
        v[1] * (2 * near) / (top - bottom) +
        v[2] * (top + bottom) / (top - bottom);
    const z1 =
        v[2] * (far + near) / (near - far) +
        2 * far * near / (near - far);
    const w = -v[2];

    // clip space before the divide by w

    return .{ x1 / w, y1 / w, z1 / w };
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
pub fn norm(v: anytype) @TypeOf(v) {
    return v / @as(@TypeOf(v), @splat(magnitude(v)));
}

/// |v|
pub fn magnitude(v: anytype) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

/// a × b
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// a · b
pub fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

/// Return a positive number if `p` is on the left side of `a` and `b`
pub fn edge_cross(a: Vec2, b: Vec2, p: Vec2) f32 {
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
    try expect(is_visible(a, b, c));
}

test "cull_2" {
    // back triangle
    const a = Vec3{ -3, 3, -3 };
    const b = Vec3{ 3, 3, -3 };
    const c = Vec3{ 3, -3, -3 };
    try expect(!is_visible(a, b, c));

    // rotated back triangle -> front triangle
    //
    // either put them on the origin or just do a half
    // rotation and move towards the camera.
    //
    // const center = (a + b + c) / @as(Vec3, @splat(3));
    const move_to_camera = Vec3{ 1, 1, -3 };
    try expect(is_visible(
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
