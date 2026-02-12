const std = @import("std");
const math = @import("root.zig");

pub fn checkCylinderLineSegmentIntersection(cylinder: math.Cylinder, line: math.LineSegment3) bool {
    const z_interval_1 = Interval{
        .min = cylinder.center.z() - cylinder.half_height,
        .max = cylinder.center.z() + cylinder.half_height,
    };
    const z_interval_2 = Interval{
        .min = @min(line.point_1.z(), line.point_2.z()),
        .max = @max(line.point_1.z(), line.point_2.z()),
    };
    const z_interval = findIntervalIntersection(z_interval_1, z_interval_2) orelse return false;

    const difference = line.point_2.subtract(line.point_1);
    if (difference.z() == 0) {
        return checkCircleLineSegmentIntersection(
            .{ .center = cylinder.center.swizzle("xy"), .radius = cylinder.radius },
            .{ .point_1 = line.point_1.swizzle("xy"), .point_2 = line.point_2.swizzle("xy") },
        );
    }

    const t1 = (z_interval.min - line.point_1.z()) / difference.z();
    const t2 = (z_interval.max - line.point_1.z()) / difference.z();
    const p1 = line.point_1.add(difference.scale(t1));
    const p2 = line.point_1.add(difference.scale(t2));
    return checkCircleLineSegmentIntersection(
        .{ .center = cylinder.center.swizzle("xy"), .radius = cylinder.radius },
        .{ .point_1 = p1.swizzle("xy"), .point_2 = p2.swizzle("xy") },
    );
}

pub fn checkCircleLineSegmentIntersection(circle: math.Circle, line: math.LineSegment2) bool {
    const p1 = line.point_1.subtract(circle.center);
    const p2 = line.point_2.subtract(circle.center);

    const radius_squared = circle.radius * circle.radius;
    const p1_squared = p1.lengthSquared();
    const p2_squared = p2.lengthSquared();

    if (p1_squared <= radius_squared or p2_squared <= radius_squared) {
        return true;
    }

    const difference = p2.subtract(p1);
    const a = difference.lengthSquared();
    const b = 2 * p1.dot(difference);
    const c = p1_squared - radius_squared;

    const discriminant_squared = b * b - 4 * a * c;
    if (discriminant_squared < 0) {
        return false;
    }
    const discriminant = std.math.sqrt(discriminant_squared);

    const t1 = (-b - discriminant) / (2 * a);
    const t2 = (-b + discriminant) / (2 * a);

    return (t1 >= 0 and t1 <= 1) or (t2 >= 0 and t2 <= 1);
}

const Interval = struct {
    min: f32,
    max: f32,
};

pub fn findIntervalIntersection(a: Interval, b: Interval) ?Interval {
    const start = @max(a.min, b.min);
    const end = @min(a.max, b.max);
    if (start <= end) {
        return .{ .min = start, .max = end };
    } else {
        return null;
    }
}

pub fn doSlicesIntersect(Element: type, a: []const Element, b: []const Element) bool {
    if (a.len == 0 or b.len == 0) {
        return false;
    }
    const a_min = @intFromPtr(&a[0]);
    const a_max = @intFromPtr(&a[a.len - 1]);
    const b_min = @intFromPtr(&b[0]);
    const b_max = @intFromPtr(&b[b.len - 1]);
    return (a_max >= b_min) and (b_max >= a_min);
}

pub fn findRayLineSegmentIntersection(ray: math.Ray2, line: math.LineSegment2) ?math.RayHit2 {
    const eps: f32 = 1e-6;
    const line_diff = line.point_2.subtract(line.point_1);
    const ray_cross_line = ray.direction.cross(line_diff);
    const origin_to_point_1 = line.point_1.subtract(ray.origin);
    const point_1_cross_direction = origin_to_point_1.cross(ray.direction);
    if (@abs(ray_cross_line) < eps) {
        return null;
    }
    const t = origin_to_point_1.cross(line_diff) / ray_cross_line;
    const u = point_1_cross_direction / ray_cross_line;
    if (t < 0 or u < 0 or u > 1) {
        return null;
    }
    const hit_pos = ray.origin.add(ray.direction.scale(t));
    var normal = math.Vec2.fromArray(.{ -line_diff.y(), line_diff.x() });
    normal = normal.normalize();
    if (normal.dot(ray.direction) > 0.0) {
        normal = normal.scale(-1.0);
    }
    return math.RayHit2{
        .position = hit_pos,
        .normal = normal,
        .t = t,
    };
}

pub fn findRayRectangleIntersection(ray: math.Ray2, rect: math.Rectangle) ?math.RayHit2 {
    const eps_1 = 1e-6;
    const eps_2 = 0.01;
    const local_ray = math.Ray2{
        .origin = ray.origin.subtract(rect.center).rotateZ(-rect.rotation),
        .direction = ray.direction.rotateZ(-rect.rotation),
    };
    const min = rect.half_size.scale(-1.0);
    const max = rect.half_size;
    var t_min: f32 = -std.math.inf(f32);
    var t_max: f32 = std.math.inf(f32);
    var local_hit_normal = math.Vec2.zero;
    if (@abs(local_ray.direction.x()) < eps_1) {
        if (local_ray.origin.x() - min.x() < eps_2 or local_ray.origin.x() - max.x() > -eps_2) {
            return null;
        }
    } else {
        const inv_dx = 1.0 / local_ray.direction.x();
        var tx1 = (min.x() - local_ray.origin.x()) * inv_dx;
        var tx2 = (max.x() - local_ray.origin.x()) * inv_dx;
        var nx = math.Vec2.minus_x;
        if (tx1 > tx2) {
            std.mem.swap(f32, &tx1, &tx2);
            nx = math.Vec2.plus_x;
        }
        if (tx1 > t_min) {
            t_min = tx1;
            local_hit_normal = nx;
        }
        t_max = @min(t_max, tx2);
        if (t_min > t_max) {
            return null;
        }
    }
    if (@abs(local_ray.direction.y()) < eps_1) {
        if (local_ray.origin.y() - min.y() < eps_2 or local_ray.origin.y() - max.y() > -eps_2) {
            return null;
        }
    } else {
        const inv_dy = 1.0 / local_ray.direction.y();
        var ty1 = (min.y() - local_ray.origin.y()) * inv_dy;
        var ty2 = (max.y() - local_ray.origin.y()) * inv_dy;
        var ny = math.Vec2.minus_y;
        if (ty1 > ty2) {
            std.mem.swap(f32, &ty1, &ty2);
            ny = math.Vec2.plus_y;
        }
        if (ty1 > t_min) {
            t_min = ty1;
            local_hit_normal = ny;
        }
        t_max = @min(t_max, ty2);
        if (t_min > t_max) {
            return null;
        }
    }
    if (t_min < 0.0) {
        return null;
    }
    const local_hit_position = local_ray.origin.add(local_ray.direction.scale(t_min));
    return .{
        .position = local_hit_position.rotateZ(rect.rotation).add(rect.center),
        .normal = local_hit_normal.rotateZ(rect.rotation),
        .t = t_min,
    };
}

const testing = std.testing;

test "checkCylinderLineSegmentIntersection should return correct value" {
    const vec = struct {
        fn call(x: f32, z: f32) math.Vec3 {
            return math.Vec3.fromArray(.{ x, 0, z });
        }
    }.call;
    const cylinder = struct {
        fn call(center: math.Vec3, radius: f32, half_height: f32) math.Cylinder {
            return .{ .center = center, .radius = radius, .half_height = half_height };
        }
    }.call;
    const line = struct {
        fn call(point_1: math.Vec3, point_2: math.Vec3) math.LineSegment3 {
            return .{ .point_1 = point_1, .point_2 = point_2 };
        }
    }.call;
    const intersection = checkCylinderLineSegmentIntersection;
    try testing.expectEqual(false, intersection(cylinder(vec(6, 12), 2, 4), line(vec(9, 5), vec(11, 7))));
    try testing.expectEqual(false, intersection(cylinder(vec(6, 12), 2, 4), line(vec(5, 5), vec(7, 7))));
    try testing.expectEqual(false, intersection(cylinder(vec(6, 12), 2, 4), line(vec(9, 8), vec(11, 10))));
    try testing.expectEqual(false, intersection(cylinder(vec(6, 12), 2, 4), line(vec(5, 4), vec(11, 11))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(7, 7), vec(9, 9))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(8, 8), vec(10, 6))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(5, 8), vec(7, 6))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(8, 9), vec(10, 10))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(2, 13), vec(9, 6))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(5, 9), vec(7, 7))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(7, 10), vec(9, 11))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(5, 10), vec(7, 14))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(7, 8), vec(9, 8))));
    try testing.expectEqual(true, intersection(cylinder(vec(6, 12), 2, 4), line(vec(8, 7), vec(8, 9))));
}

test "checkCircleLineSegmentIntersection should return correct value" {
    const vec = struct {
        fn call(x: f32, y: f32) math.Vec2 {
            return math.Vec2.fromArray(.{ x, y });
        }
    }.call;
    const circle = struct {
        fn call(center: math.Vec2, radius: f32) math.Circle {
            return .{ .center = center, .radius = radius };
        }
    }.call;
    const line = struct {
        fn call(point_1: math.Vec2, point_2: math.Vec2) math.LineSegment2 {
            return .{ .point_1 = point_1, .point_2 = point_2 };
        }
    }.call;
    const intersection = checkCircleLineSegmentIntersection;
    try testing.expectEqual(false, intersection(circle(vec(8, 12), 4), line(vec(13, 23), vec(18, 17))));
    try testing.expectEqual(false, intersection(circle(vec(8, 12), 4), line(vec(10, 7), vec(14, 13))));
    try testing.expectEqual(true, intersection(circle(vec(8, 12), 4), line(vec(12, 8), vec(12, 16))));
    try testing.expectEqual(true, intersection(circle(vec(8, 12), 4), line(vec(12, 12), vec(16, 13))));
    try testing.expectEqual(true, intersection(circle(vec(8, 12), 4), line(vec(10, 11), vec(13, 9))));
    try testing.expectEqual(true, intersection(circle(vec(8, 12), 4), line(vec(8, 10), vec(10, 12))));
}

test "findIntervalIntersection should return correct value" {
    const interval = struct {
        fn call(min: f32, max: f32) Interval {
            return .{ .min = min, .max = max };
        }
    }.call;
    const intersection = findIntervalIntersection;
    try testing.expectEqual(null, intersection(interval(1, 2), interval(3, 4)));
    try testing.expectEqual(null, intersection(interval(3, 4), interval(1, 2)));
    try testing.expectEqual(interval(2, 3), intersection(interval(1, 3), interval(2, 4)));
    try testing.expectEqual(interval(2, 3), intersection(interval(2, 4), interval(1, 3)));
    try testing.expectEqual(interval(2, 3), intersection(interval(1, 4), interval(2, 3)));
    try testing.expectEqual(interval(2, 3), intersection(interval(2, 3), interval(1, 4)));
}

test "doSlicesIntersect should return correct value" {
    const data = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    try testing.expectEqual(false, doSlicesIntersect(i32, data[5..5], data[5..5]));
    try testing.expectEqual(false, doSlicesIntersect(i32, data[0..5], data[5..10]));
    try testing.expectEqual(false, doSlicesIntersect(i32, data[5..10], data[0..5]));
    try testing.expectEqual(false, doSlicesIntersect(i32, data[1..4], data[6..9]));
    try testing.expectEqual(false, doSlicesIntersect(i32, data[6..9], data[1..4]));

    try testing.expectEqual(true, doSlicesIntersect(i32, data[0..6], data[5..10]));
    try testing.expectEqual(true, doSlicesIntersect(i32, data[4..10], data[0..5]));
    try testing.expectEqual(true, doSlicesIntersect(i32, data[1..8], data[2..9]));
    try testing.expectEqual(true, doSlicesIntersect(i32, data[2..9], data[1..8]));
    try testing.expectEqual(true, doSlicesIntersect(i32, data[1..9], data[4..6]));
    try testing.expectEqual(true, doSlicesIntersect(i32, data[4..6], data[1..9]));
}

test "findRayLineSegmentIntersection should return correct value" {
    const vec = struct {
        fn call(x: f32, y: f32) math.Vec2 {
            return math.Vec2.fromArray(.{ x, y });
        }
    }.call;
    const ray = struct {
        fn call(origin: math.Vec2, direction: math.Vec2) math.Ray2 {
            return .{
                .origin = origin,
                .direction = direction,
            };
        }
    }.call;
    const line = math.LineSegment2{
        .point_1 = .fromArray(.{ 8, 2 }),
        .point_2 = .fromArray(.{ 2, 5 }),
    };

    const hit_1 = findRayLineSegmentIntersection(ray(vec(2, 0), vec(1, 2)), line);
    try testing.expect(hit_1 != null);
    try testing.expectEqual(vec(4, 4), hit_1.?.position);
    try testing.expectEqual(vec(-1, -2).normalize(), hit_1.?.normal);
    try testing.expectEqual(2, hit_1.?.t);

    const hit_2 = findRayLineSegmentIntersection(ray(vec(8, 3), vec(-1, 0)), line);
    try testing.expect(hit_2 != null);
    try testing.expectEqual(vec(6, 3), hit_2.?.position);
    try testing.expectEqual(vec(1, 2).normalize(), hit_2.?.normal);
    try testing.expectEqual(2, hit_2.?.t);

    const hit_3 = findRayLineSegmentIntersection(ray(vec(0, 3), vec(1, 1)), line);
    try testing.expect(hit_3 != null);
    try testing.expectEqual(vec(2, 5), hit_3.?.position);
    try testing.expectEqual(vec(-1, -2).normalize(), hit_3.?.normal);
    try testing.expectEqual(2, hit_3.?.t);

    const hit_4 = findRayLineSegmentIntersection(ray(vec(6, 0), vec(1, 1)), line);
    try testing.expect(hit_4 != null);
    try testing.expectEqual(vec(8, 2), hit_4.?.position);
    try testing.expectEqual(vec(-1, -2).normalize(), hit_4.?.normal);
    try testing.expectEqual(2, hit_4.?.t);

    try testing.expectEqual(null, findRayLineSegmentIntersection(ray(vec(3, 6), vec(2, -1)), line));
    try testing.expectEqual(null, findRayLineSegmentIntersection(ray(vec(6, 4), vec(2, 1)), line));
    try testing.expectEqual(null, findRayLineSegmentIntersection(ray(vec(9, 1), vec(1, 1)), line));
}

test "findRayRectangleIntersection should return correct value" {
    const vec = struct {
        fn call(x: f32, y: f32) math.Vec2 {
            return math.Vec2.fromArray(.{ x, y });
        }
    }.call;
    const ray = struct {
        fn call(origin: math.Vec2, direction: math.Vec2) math.Ray2 {
            return .{
                .origin = origin,
                .direction = direction,
            };
        }
    }.call;
    const rect = math.Rectangle{
        .center = .fromArray(.{ 10, 11 }),
        .half_size = .fromArray(.{ 5, 10 }),
        .rotation = -std.math.atan2(@as(f32, 6), @as(f32, 8)),
    };

    const hit_1 = findRayRectangleIntersection(ray(vec(1, -1), vec(3, 4)), rect);
    try testing.expect(hit_1 != null);
    try testing.expectEqual(vec(4, 3), hit_1.?.position);
    try testing.expectEqual(vec(0, -1).rotateZ(rect.rotation), hit_1.?.normal);
    try testing.expectEqual(1, hit_1.?.t);

    const hit_2 = findRayRectangleIntersection(ray(vec(4, 18), vec(1, -2)), rect);
    try testing.expect(hit_2 != null);
    try testing.expectEqual(vec(6, 14), hit_2.?.position);
    try testing.expectEqual(vec(-1, 0).rotateZ(rect.rotation), hit_2.?.normal);
    try testing.expectEqual(2, hit_2.?.t);

    const hit_3 = findRayRectangleIntersection(ray(vec(16, 21), vec(0, -1)), rect);
    try testing.expect(hit_3 != null);
    try testing.expectEqual(vec(16, 19), hit_3.?.position);
    try testing.expectEqual(vec(0, 1).rotateZ(rect.rotation), hit_3.?.normal);
    try testing.expectApproxEqAbs(2, hit_3.?.t, 0.00001);

    const hit_4 = findRayRectangleIntersection(ray(vec(19, 12), vec(-1, 0)), rect);
    try testing.expect(hit_4 != null);
    try testing.expectEqual(vec(17, 12), hit_4.?.position);
    try testing.expectEqual(vec(1, 0).rotateZ(rect.rotation), hit_4.?.normal);
    try testing.expectApproxEqAbs(2, hit_3.?.t, 0.00001);

    try testing.expectEqual(null, findRayRectangleIntersection(ray(vec(10, 1), vec(3, 4)), rect));
    try testing.expectEqual(null, findRayRectangleIntersection(ray(vec(5, -4), vec(3, 4)), rect));
    try testing.expectEqual(null, findRayRectangleIntersection(ray(vec(1, -1), vec(1, 0)), rect));
    try testing.expectEqual(null, findRayRectangleIntersection(ray(vec(1, -1), vec(-3, -4)), rect));
    try testing.expectEqual(null, findRayRectangleIntersection(ray(vec(4, 18), vec(-1, 2)), rect));
}
