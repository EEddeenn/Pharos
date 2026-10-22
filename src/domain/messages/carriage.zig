/// Why a family cannot carry a leg's reference.
pub const Unfit = union(enum) {
    /// The family carries its own records only, and the leg flies another family's.
    record,
    /// A value falls outside its field in the family's messages: the field's name.
    field: []const u8,
    /// The reference declares no health of the named signals.
    health: []const u8,
    /// No D1/D2 orbit fits the reference over the leg.
    fit,
};

/// The first preparation's decision, retained with its source facts.
pub const Choice = union(enum) { carried, unfit: Unfit };

/// A family's answer for a leg: the value its messages broadcast, or why it cannot carry the leg's reference.
pub fn Carriage(comptime T: type) type {
    return union(enum) {
        carried: T,
        unfit: Unfit,

        pub fn value(self: *const @This()) ?*const T {
            return switch (self.*) {
                .carried => |*v| v,
                .unfit => null,
            };
        }
    };
}
