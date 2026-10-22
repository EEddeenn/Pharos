const shared = @import("domain/messages/gps/cnav_common/set");
const publications = @import("domain/messages/gps/cnav2/publications");
const dc = @import("domain/messages/gps/differential");
pub const Set = struct {
    navigation: shared.View,
    publications: []const publications.PreparedPublication = &.{},
    dc: ?dc.Source = null,

    pub const Inputs = struct {
        navigation: shared.View,
        publications: []const publications.PreparedPublication = &.{},
        dc: ?dc.Source = null,
    };

    pub fn init(input: Inputs) Set {
        return .{ .navigation = input.navigation, .publications = input.publications, .dc = input.dc };
    }
};
