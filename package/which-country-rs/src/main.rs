mod geo;
#[cfg(feature = "geoip")]
mod geoip;
mod render;

use clap::Parser;

#[derive(Parser)]
#[command(name = "which-country-rs", version, about = "Detect your country by IP and render an ASCII world map")]
struct Args {
    /// Map width in characters
    #[arg(short = 'W', long, default_value_t = 80)]
    width: usize,

    /// Map height in characters
    #[arg(short = 'H', long, default_value_t = 24)]
    height: usize,

    /// Country code to display (e.g. "US", "FR", "JP") — skips IP lookup
    #[arg(short, long)]
    country: Option<String>,

    /// Latitude (requires --lon too) — skips IP lookup, derives country from coordinates
    #[arg(long, requires = "lon", allow_hyphen_values = true)]
    lat: Option<f64>,

    /// Longitude (requires --lat too)
    #[arg(long, requires = "lat", allow_hyphen_values = true)]
    lon: Option<f64>,
}

static GEOJSON: &str = include_str!("../data/countries.geojson");

fn main() {
    let args = Args::parse();
    let countries = geo::load_countries(GEOJSON);

    let (country_name, country_code, lat, lon) = if let Some(code) = &args.country {
        // Direct country code — find it in the data
        let code_upper = code.to_uppercase();
        let c = countries
            .iter()
            .find(|c| c.iso_a2 == code_upper)
            .unwrap_or_else(|| {
                eprintln!("Unknown country code: {code_upper}");
                std::process::exit(1);
            });
        let (label_lon, label_lat) = c.label_pos;
        (c.name.clone(), code_upper, label_lat, label_lon)
    } else if let (Some(lat), Some(lon)) = (args.lat, args.lon) {
        // Coordinates provided — find which country contains the point
        let idx = geo::find_country(lon, lat, &countries)
            .unwrap_or_else(|| {
                eprintln!("No country found at {lat}, {lon} (ocean?)");
                std::process::exit(1);
            });
        (
            countries[idx].name.clone(),
            countries[idx].iso_a2.clone(),
            lat,
            lon,
        )
    } else {
        // IP geolocation
        #[cfg(feature = "geoip")]
        {
            eprint!("Looking up your location... ");
            match geoip::lookup() {
                Ok(loc) => {
                    eprintln!("done.");
                    (loc.country, loc.country_code, loc.lat, loc.lon)
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        #[cfg(not(feature = "geoip"))]
        {
            eprintln!("IP geolocation requires the 'geoip' feature. Use --country or --lat/--lon instead.");
            std::process::exit(1);
        }
    };

    let map = render::render_map(&countries, &country_code, args.width, args.height);

    println!("You appear to be in: {country_name} ({country_code})");
    println!();
    println!("{map}");
    println!();
    println!(
        "Coordinates: {:.2}\u{00b0}{}, {:.2}\u{00b0}{}",
        lat.abs(),
        if lat >= 0.0 { "N" } else { "S" },
        lon.abs(),
        if lon >= 0.0 { "E" } else { "W" },
    );
}
