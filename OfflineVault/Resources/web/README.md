Offline map viewer. `map.html` is committed; the libraries next to it (MapLibre GL, pmtiles.js, Protomaps
basemaps, Noto Sans glyphs, sprites) are fetched by `scripts/fetch_web_assets.sh` and git-ignored. The app serves
this folder to a WKWebView over the `ovweb://` scheme and map files over `ovtiles://` with Range support.
