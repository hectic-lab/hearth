use crate::geo::Country;

/// Render a zoomed-in ASCII map centered on the target country, showing borders and labels.
pub fn render_map(
    countries: &[Country],
    target_code: &str,
    width: usize,
    height: usize,
) -> String {
    // Find the target country and compute its bbox
    let target_idx = countries
        .iter()
        .position(|c| c.iso_a2 == target_code)
        .expect("Target country not found in GeoJSON");

    let (min_lon, min_lat, max_lon, max_lat) = countries[target_idx].bbox;

    // Add generous padding so the surrounding continent is visible
    let lon_span = (max_lon - min_lon).max(4.0);
    let lat_span = (max_lat - min_lat).max(4.0);
    let pad_lon = lon_span * 1.0;
    let pad_lat = lat_span * 1.0;

    let view_min_lon = (min_lon - pad_lon).max(-180.0);
    let view_max_lon = (max_lon + pad_lon).min(180.0);
    let view_min_lat = (min_lat - pad_lat).max(-90.0);
    let view_max_lat = (max_lat + pad_lat).min(90.0);

    // Adjust aspect ratio: terminal chars are ~2x taller than wide
    let lon_range = view_max_lon - view_min_lon;
    let lat_range = view_max_lat - view_min_lat;
    let char_aspect = 2.0;

    let (final_lon_range, final_lat_range);
    let desired_lon = lat_range * (width as f64) / (height as f64) / char_aspect;
    let desired_lat = lon_range * (height as f64) / (width as f64) * char_aspect;

    if desired_lon > lon_range {
        final_lon_range = desired_lon;
        final_lat_range = lat_range;
    } else {
        final_lon_range = lon_range;
        final_lat_range = desired_lat;
    }

    let center_lon = (view_min_lon + view_max_lon) / 2.0;
    let center_lat = (view_min_lat + view_max_lat) / 2.0;

    let vp_min_lon = (center_lon - final_lon_range / 2.0).max(-180.0);
    let vp_max_lat = (center_lat + final_lat_range / 2.0).min(90.0);

    let lon_per_col = final_lon_range / width as f64;
    let lat_per_row = final_lat_range / height as f64;

    // Grid of characters
    let mut grid = vec![vec![' '; width]; height];

    // Rasterize polygon edges onto the grid
    for (i, country) in countries.iter().enumerate() {
        let (c_min_lon, c_min_lat, c_max_lon, c_max_lat) = country.bbox;
        if c_max_lon < vp_min_lon
            || c_min_lon > vp_min_lon + final_lon_range
            || c_max_lat < vp_max_lat - final_lat_range
            || c_min_lat > vp_max_lat
        {
            continue;
        }

        let border_ch = if i == target_idx { '#' } else { '\u{00b7}' };

        for poly in &country.polygons {
            for ring in poly {
                if ring.len() < 2 {
                    continue;
                }
                for edge in ring.windows(2) {
                    rasterize_edge(
                        edge[0][0],
                        edge[0][1],
                        edge[1][0],
                        edge[1][1],
                        vp_min_lon,
                        vp_max_lat,
                        lon_per_col,
                        lat_per_row,
                        width,
                        height,
                        border_ch,
                        i == target_idx,
                        &mut grid,
                    );
                }
            }
        }
    }

    // Place country code labels at bbox center
    for (i, country) in countries.iter().enumerate() {
        if country.iso_a2 == "-99" {
            continue;
        }

        let (label_lon, label_lat) = country.label_pos;

        let col = ((label_lon - vp_min_lon) / lon_per_col) as isize;
        let row = ((vp_max_lat - label_lat) / lat_per_row) as isize;

        let label = &country.iso_a2;
        let start_col = col - (label.len() as isize / 2);

        for (j, ch) in label.chars().enumerate() {
            let c = start_col + j as isize;
            if c >= 0 && (c as usize) < width && row >= 0 && (row as usize) < height {
                let r = row as usize;
                let c = c as usize;
                let existing = grid[r][c];
                // Target label always writes; neighbor labels only on empty or neighbor border
                if i == target_idx || existing == ' ' || existing == '\u{00b7}' {
                    grid[r][c] = ch;
                }
            }
        }
    }

    // Render grid to string
    grid.iter()
        .map(|row| row.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Rasterize a line segment onto the grid using Bresenham's algorithm.
fn rasterize_edge(
    lon0: f64,
    lat0: f64,
    lon1: f64,
    lat1: f64,
    vp_min_lon: f64,
    vp_max_lat: f64,
    lon_per_col: f64,
    lat_per_row: f64,
    width: usize,
    height: usize,
    ch: char,
    is_target: bool,
    grid: &mut [Vec<char>],
) {
    let c0 = ((lon0 - vp_min_lon) / lon_per_col) as i32;
    let r0 = ((vp_max_lat - lat0) / lat_per_row) as i32;
    let c1 = ((lon1 - vp_min_lon) / lon_per_col) as i32;
    let r1 = ((vp_max_lat - lat1) / lat_per_row) as i32;

    let mut x = c0;
    let mut y = r0;
    let dx = (c1 - c0).abs();
    let dy = -(r1 - r0).abs();
    let sx = if c0 < c1 { 1 } else { -1 };
    let sy = if r0 < r1 { 1 } else { -1 };
    let mut err = dx + dy;

    loop {
        if x >= 0 && (x as usize) < width && y >= 0 && (y as usize) < height {
            let cell = &mut grid[y as usize][x as usize];
            // Target borders overwrite neighbor borders; neighbor borders only on empty
            if is_target || *cell == ' ' {
                *cell = ch;
            }
        }

        if x == c1 && y == r1 {
            break;
        }

        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x += sx;
        }
        if e2 <= dx {
            err += dx;
            y += sy;
        }
    }
}
