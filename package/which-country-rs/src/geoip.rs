use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(tag = "status")]
pub enum GeoIpResponse {
    #[serde(rename = "success")]
    Success {
        country: String,
        #[serde(rename = "countryCode")]
        country_code: String,
        lat: f64,
        lon: f64,
    },
    #[serde(rename = "fail")]
    Fail { message: String },
}

pub struct GeoIpResult {
    pub country: String,
    pub country_code: String,
    pub lat: f64,
    pub lon: f64,
}

pub fn lookup() -> Result<GeoIpResult, String> {
    let url = "http://ip-api.com/json/?fields=status,message,countryCode,country,lat,lon";
    let resp = reqwest::blocking::get(url).map_err(|e| format!("HTTP request failed: {e}"))?;
    let data: GeoIpResponse = resp.json().map_err(|e| format!("Failed to parse response: {e}"))?;

    match data {
        GeoIpResponse::Success {
            country,
            country_code,
            lat,
            lon,
        } => Ok(GeoIpResult {
            country,
            country_code,
            lat,
            lon,
        }),
        GeoIpResponse::Fail { message } => Err(format!("GeoIP lookup failed: {message}")),
    }
}
