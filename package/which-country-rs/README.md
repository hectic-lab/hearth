# which-country-rs

A CLI tool that detects your country from your IP address and renders an ASCII map zoomed into it, showing neighbouring borders and country codes.

## Example output

```bash
which-country-rs -c DE
```

```
You appear to be in: Germany (DE)

                            ··········    ··           ······ ·                ·
                            ·      NO       ·        ··       ·              ···
                             ·             ·          ····    ···   ···········
                             ·        ·····            ··        ············
       ·····                  ········   ·           ··           ···EE    ·
      ·  ······                    ······ ··        ·          LV····· ·····
     ··    ···                     ·DK ·· ···   ····          ···········  ···
 ···· ···   ···                    ·  · ··· ····             ···   LT   ···· ···
· ····· ····   ···                 ############ ···················   ···
IE  ··  ····GB    ·        ·····#####   ##     ##                  ····    BY
·  ··   ··         ···     ·NL  #              ##                 ··
···    ·····        ··  ····· ##                #       PL         ·············
      ····················BE ··#       DE  #######·····          ····
       ·      ·······     ···L##           ###  CZ    ····· ······
        ·······                 ####        ###·········SK ·······        ··
        ·····                   ·###### ######  AT  ········    ···············
             ··      FR       ··· CH ··#··············  HU    ··            MD··
               ·              · ····· ·    ····SI···  ·········    RO       ····
               ·                ·          ·  ···HR········ RS····           ···
········  ··   ·                ········ IT ···  ·····BA ··     ··············
·       ··  ·········  ··········   ··  ·      ·     ···ME··XK····         ··
·····               ··· ·          ·· ·  ···    ····     ·· ··MK··  ·BG ·····
·  ··              ·····           ···      ·····  ····   ·AL············ ······
· ··      ES      ·                ·  ·          ·· ····· ····   ····    ······

Coordinates: 51.15°N, 10.55°E
```

## Usage

```
# Auto-detect from IP
which-country-rs

# Specify a country code
which-country-rs -c JP

# Specify coordinates (supports negative values for south/west)
which-country-rs --lat 40 --lon -74

# Custom map size
which-country-rs -W 120 -H 40
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-W, --width` | Map width in characters | 80 |
| `-H, --height` | Map height in characters | 24 |
| `-c, --country` | ISO 3166-1 alpha-2 country code (skips IP lookup) | |
| `--lat` | Latitude (requires `--lon`) | |
| `--lon` | Longitude (requires `--lat`) | |
| `-V, --version` | Print version | |

## Building

```
cargo build --release
```

To build without IP geolocation support (drops the `reqwest` dependency):

```
cargo build --release --no-default-features
```

## Map data

Country borders from [Natural Earth](https://www.naturalearthdata.com/) 110m admin-0 countries (public domain).
