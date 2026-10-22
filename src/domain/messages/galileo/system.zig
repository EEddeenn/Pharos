const ionosphere = @import("domain/messages/galileo/fields/ionosphere");
const time = @import("domain/messages/galileo/fields/time");
pub const System = struct { iono: ionosphere.Codes, utc: ?time.UtcCodes, ggto: time.GgtoCodes };
