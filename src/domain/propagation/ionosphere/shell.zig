pub fn elevation(layer_height_m: f64, rx_height_m: f64, el_rad: f64) ?f64 {
    if (rx_height_m >= layer_height_m) return null;
    return @max(el_rad, 0.0);
}
