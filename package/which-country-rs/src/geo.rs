use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct FeatureCollection {
    features: Vec<Feature>,
}

#[derive(Debug, Deserialize)]
struct Feature {
    properties: Properties,
    geometry: Geometry,
}

#[derive(Debug, Deserialize)]
struct Properties {
    #[serde(rename = "ISO_A2_EH")]
    iso_a2: String,
    #[serde(rename = "NAME")]
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Geometry {
    Polygon {
        coordinates: Vec<Vec<[f64; 2]>>,
    },
    MultiPolygon {
        coordinates: Vec<Vec<Vec<[f64; 2]>>>,
    },
}

#[allow(dead_code)]
pub struct Country {
    pub iso_a2: String,
    pub name: String,
    /// Each polygon is a list of rings; ring 0 = outer, rest = holes
    pub polygons: Vec<Vec<Vec<[f64; 2]>>>,
    pub bbox: (f64, f64, f64, f64), // (min_lon, min_lat, max_lon, max_lat)
    pub label_pos: (f64, f64),      // (lon, lat) — centroid of largest polygon
}

/// Signed area of a ring (positive = CCW).
fn ring_signed_area(ring: &[[f64; 2]]) -> f64 {
    let n = ring.len();
    if n < 3 {
        return 0.0;
    }
    let mut area = 0.0;
    let mut j = n - 1;
    for i in 0..n {
        area += (ring[j][0] - ring[i][0]) * (ring[j][1] + ring[i][1]);
        j = i;
    }
    area / 2.0
}

/// Ray-casting point-in-ring test.
fn point_in_ring(lon: f64, lat: f64, ring: &[[f64; 2]]) -> bool {
    let mut inside = false;
    let n = ring.len();
    if n < 3 {
        return false;
    }
    let mut j = n - 1;
    for i in 0..n {
        let xi = ring[i][0];
        let yi = ring[i][1];
        let xj = ring[j][0];
        let yj = ring[j][1];
        if ((yi > lat) != (yj > lat)) && (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Find horizontal interior spans at a given latitude.
/// Returns sorted pairs of (enter_lon, exit_lon).
fn horizontal_spans(lat: f64, ring: &[[f64; 2]]) -> Vec<(f64, f64)> {
    let n = ring.len();
    if n < 3 {
        return Vec::new();
    }
    let mut crossings = Vec::new();
    let mut j = n - 1;
    for i in 0..n {
        let yi = ring[i][1];
        let yj = ring[j][1];
        if (yi > lat) != (yj > lat) {
            let xi = ring[i][0];
            let xj = ring[j][0];
            crossings.push((xj - xi) * (lat - yi) / (yj - yi) + xi);
        }
        j = i;
    }
    crossings.sort_by(|a, b| a.partial_cmp(b).unwrap());
    crossings.chunks_exact(2).map(|p| (p[0], p[1])).collect()
}

/// Find vertical interior spans at a given longitude.
/// Returns sorted pairs of (enter_lat, exit_lat).
fn vertical_spans(lon: f64, ring: &[[f64; 2]]) -> Vec<(f64, f64)> {
    let n = ring.len();
    if n < 3 {
        return Vec::new();
    }
    let mut crossings = Vec::new();
    let mut j = n - 1;
    for i in 0..n {
        let xi = ring[i][0];
        let xj = ring[j][0];
        if (xi > lon) != (xj > lon) {
            let yi = ring[i][1];
            let yj = ring[j][1];
            crossings.push((yj - yi) * (lon - xi) / (xj - xi) + yi);
        }
        j = i;
    }
    crossings.sort_by(|a, b| a.partial_cmp(b).unwrap());
    crossings.chunks_exact(2).map(|p| (p[0], p[1])).collect()
}

/// Find a good interior label point for a ring.
/// Scans a grid of candidate points and picks the one that maximizes
/// min(half_width, half_height) — the "most interior" point.
fn ring_label_point(ring: &[[f64; 2]]) -> (f64, f64) {
    let min_lon = ring.iter().map(|c| c[0]).fold(f64::MAX, f64::min);
    let max_lon = ring.iter().map(|c| c[0]).fold(f64::MIN, f64::max);
    let min_lat = ring.iter().map(|c| c[1]).fold(f64::MAX, f64::min);
    let max_lat = ring.iter().map(|c| c[1]).fold(f64::MIN, f64::max);

    let steps = 24;
    let mut best = ((min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0);
    let mut best_score = 0.0f64;

    for row in 1..steps {
        let lat = min_lat + (max_lat - min_lat) * row as f64 / steps as f64;
        let h_spans = horizontal_spans(lat, ring);

        for &(span_left, span_right) in &h_spans {
            let mid_lon = (span_left + span_right) / 2.0;
            let half_w = (span_right - span_left) / 2.0;

            // Measure vertical extent at this longitude
            let v_spans = vertical_spans(mid_lon, ring);
            for &(span_bot, span_top) in &v_spans {
                if lat >= span_bot && lat <= span_top {
                    let half_h = ((lat - span_bot).min(span_top - lat)).min(half_w);
                    let score = half_w.min(half_h);
                    if score > best_score {
                        best_score = score;
                        best = (mid_lon, lat);
                    }
                    break;
                }
            }
        }
    }

    best
}

pub fn load_countries(geojson: &str) -> Vec<Country> {
    let fc: FeatureCollection = serde_json::from_str(geojson).expect("Failed to parse GeoJSON");

    fc.features
        .into_iter()
        .map(|f| {
            let polygons = match f.geometry {
                Geometry::Polygon { coordinates } => vec![coordinates],
                Geometry::MultiPolygon { coordinates } => coordinates,
            };

            let mut min_lon = f64::MAX;
            let mut min_lat = f64::MAX;
            let mut max_lon = f64::MIN;
            let mut max_lat = f64::MIN;

            for poly in &polygons {
                for ring in poly {
                    for coord in ring {
                        let lon = coord[0];
                        let lat = coord[1];
                        if lon < min_lon {
                            min_lon = lon;
                        }
                        if lon > max_lon {
                            max_lon = lon;
                        }
                        if lat < min_lat {
                            min_lat = lat;
                        }
                        if lat > max_lat {
                            max_lat = lat;
                        }
                    }
                }
            }

            // Label inside the largest polygon
            let label_pos = polygons
                .iter()
                .filter(|p| !p.is_empty() && p[0].len() >= 3)
                .max_by(|a, b| {
                    ring_signed_area(&a[0])
                        .abs()
                        .partial_cmp(&ring_signed_area(&b[0]).abs())
                        .unwrap()
                })
                .map(|p| ring_label_point(&p[0]))
                .unwrap_or(((min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0));

            Country {
                iso_a2: f.properties.iso_a2,
                name: f.properties.name,
                polygons,
                bbox: (min_lon, min_lat, max_lon, max_lat),
                label_pos,
            }
        })
        .collect()
}

/// Check if a point is inside a polygon (outer ring minus holes).
fn point_in_polygon(lon: f64, lat: f64, rings: &[Vec<[f64; 2]>]) -> bool {
    if rings.is_empty() || !point_in_ring(lon, lat, &rings[0]) {
        return false;
    }
    // Must be outside all holes
    !rings[1..].iter().any(|hole| point_in_ring(lon, lat, hole))
}

/// Check if a point falls inside a country.
pub fn point_in_country(lon: f64, lat: f64, country: &Country) -> bool {
    let (min_lon, min_lat, max_lon, max_lat) = country.bbox;
    if lon < min_lon || lon > max_lon || lat < min_lat || lat > max_lat {
        return false;
    }
    country
        .polygons
        .iter()
        .any(|poly| point_in_polygon(lon, lat, poly))
}

/// Find which country contains the given point, with a nearest-country
/// fallback for when low-res coastlines cause a near miss.
pub fn find_country(lon: f64, lat: f64, countries: &[Country]) -> Option<usize> {
    // Exact hit
    if let Some(idx) = countries.iter().position(|c| point_in_country(lon, lat, c)) {
        return Some(idx);
    }
    // Search in expanding rings up to ~1 degree
    for &offset in &[0.25, 0.5, 1.0] {
        for &(dlon, dlat) in &[
            (offset, 0.0),
            (-offset, 0.0),
            (0.0, offset),
            (0.0, -offset),
            (offset, offset),
            (offset, -offset),
            (-offset, offset),
            (-offset, -offset),
        ] {
            if let Some(idx) = countries
                .iter()
                .position(|c| point_in_country(lon + dlon, lat + dlat, c))
            {
                return Some(idx);
            }
        }
    }
    None
}
