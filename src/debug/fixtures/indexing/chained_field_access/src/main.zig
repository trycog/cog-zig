const Data = struct {
    value: i32,
};

fn make() Data {
    return .{ .value = 42 };
}

pub fn main() void {
    const x = make().value;
    _ = x;
}
