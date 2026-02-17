const User = struct {
    name: []const u8,
};

fn maybeUser() ?User {
    return .{ .name = "cog" };
}

pub fn main() void {
    const from_optional = maybeUser().?.name;
    _ = from_optional;

    var u = User{ .name = "zig" };
    const p = &u;
    const from_pointer = p.name;
    _ = from_pointer;
}
