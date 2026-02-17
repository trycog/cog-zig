const std = @import("std");

fn accumulate(items: []const i32) i32 {
    var total: i32 = 0;
    for (items) |item| {
        total += item;
    }
    return total;
}

pub fn main() !void {
    const data = [_]i32{ 3, 4, 5 };
    const total = accumulate(&data);
    try std.io.getStdOut().writer().print("total={d}\n", .{total});
}
