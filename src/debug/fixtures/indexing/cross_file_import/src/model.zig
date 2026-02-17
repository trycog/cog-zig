pub const Model = struct {
    amount: i32,
};

pub fn makeModel() Model {
    return .{ .amount = 12 };
}
