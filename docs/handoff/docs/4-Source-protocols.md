# Source protocols

Reference for the three kinds of provider login. None has an official public spec: the Stalker and Xtream details here come from open-source clients and community docs, so every call must be checked against a real provider before it ships.

## Compared

Stalker is the hardest of the three: it keeps a session, asks the portal for every stream link, and reports no stream count. Xtream is plain HTTP calls; M3U is one text file.

| | Stalker portal | Xtream Codes | M3U with XMLTV |
| --- | --- | --- | --- |
| Login | Portal URL and MAC; sometimes serial, device ids, signature, username and password | Server URL, username, password | Playlist URL or file, optional guide URL |
| Catalog | API calls returning JSON; movies and series paged | API calls returning JSON | Read from the file |
| Stream link | Asked of the portal at each play, short-lived | Built from a URL pattern | Written in the file |
| Guide | Short guide per channel | `xmltv.php`, or a short guide per stream | An XMLTV file |
| Catch-up | Archive flag per channel | `tv_archive` and `tv_archive_duration` per channel | `catchup` attributes |
| Streams allowed | Not reported | `max_connections` and `active_cons` | Not reported |
| Session | Token plus a keep-alive call | None | None |
| Spec | None public; known from open-source clients | None public; community docs | M3U by convention; XMLTV documented |

## Stalker portal

A Stalker client behaves like a MAG set-top box: fixed headers and cookies, a token from a handshake, then GET calls named by `type` and `action` that answer JSON wrapped in `js`. Rows marked verified were read in the source of [stalkerhek](https://github.com/kidpoleon/stalkerhek), an open-source client; rows marked unverified are from memory and must be checked with the probe.

**Where to send calls.** The user types a portal URL, often ending `/c/`. The API answers at `<host>/portal.php`, `<host>/load.php` or `<host>/stalker_portal/server/portal.php (or load.php)`; try each until the handshake returns JSON. Every call adds `JsHttpRequest=1-xml`.

| Header | Value |
| --- | --- |
| User-Agent | `Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko)` followed by a MAG200 stbapp identifier (stalkerhek sends ver 4, rev 2116) |
| X-User-Agent | `Model: <model>; Link: Ethernet`, model MAG254 by default |
| Cookie | `sn=<serial>; mac=<MAC>; stb_lang=en; timezone=<time zone>` |
| Referer, Origin | The portal's scheme and host |
| Authorization | `Bearer <token>` on every call after the handshake |

| Step | Request | Read from the answer | Status |
| --- | --- | --- | --- |
| Handshake | `type=stb&action=handshake&token=` | `js.token` | Verified |
| Profile | `type=stb&action=get_profile&hd=1&sn=…&stb_type=<model>&device_id=…&device_id2=…&auth_second_step=1` | Signed in when `js.id` is set | Verified |
| Login, where required | POST form `type=stb&action=do_auth&login=…&password=…&device_id=…&device_id2=…` | `js` is true | Verified |
| Categories | `type=itv&action=get_genres` | `js[]`: id, title | Verified |
| Channels | `type=itv&action=get_all_channels` | `js.data[]`: name, cmd, logo, tv_genre_id, cmds[0].id and ch_id | Verified |
| Live link | `type=itv&action=create_link&cmd=<cmd>` | `js.cmd`; the URL is its last space-separated word, which drops an `ffmpeg` prefix | Verified |
| Short guide | `type=itv&action=get_short_epg&ch_id=<id>&size=<n>`, or `action=get_epg_info&ch_id=<id>` | An array in `js`, `js.epg` or `js.data`; title as name or title, times as start or start_timestamp and end or stop_timestamp, descr | Verified |
| Movie and series categories | `type=vod` or `type=series`, `action=get_categories` | id, title, alias | Verified |
| Movie and series lists | `action=get_ordered_list&category=<id>&p=<page>`; series add movie_id, season_id, episode_id | `js.total_items` and `js.data[]` (some portals send a bare array): id, name, cmd, screenshot_uri, is_series, is_season, series_number, container_extension | Verified |
| Movie link | `type=vod&action=create_link&cmd=<cmd>`, plus `series=<n>` for an episode | `js.url`, else a URL in `js.cmd`, else build `play/movie.php` from `js.id` and `js.play_token` | Verified |
| Keep-alive | `type=watchdog&action=get_events&event_active_id=0&init=0&cur_play_type=1` | Nothing needed; stalkerhek repeats it every 5 minutes by default | Verified |
| Account expiry | `type=account_info&action=get_main_info` | An expiry field | Unverified |
| Catch-up link | `type=tv_archive&action=create_link` with the programme | A link like a live one | Unverified |

**Quirks to build in**

- A movie `cmd` with no leading `/` or `ffmpeg` is wrapped as `/media/file_<cmd>.mpg` before `create_link`, as stalkerhek does.
- Links expire: never store one; ask for a fresh link at every play and retry.
- Field names drift between portals, especially guide times: read every known spelling.
- Guide times without an offset are in the portal's `timezone`.
- On an auth error, handshake again once before failing; stalkerhek doesn't, and its sessions stop after the token lapses.
- Advanced-field defaults seen in stalkerhek: MAC like `00:1A:79:AA:BB:CC`, serial `0000000000000`, device ids and signature 64 `f` characters.

## Xtream Codes

Plain HTTP calls with the username and password on each one, no session. Most of this is from a [community thread](https://github.com/AndreyPavlenko/Fermata/discussions/434) and a sample server script, not an official spec; providers differ in what they support.

**Account.** `GET /player_api.php?username=U&password=P` with no action returns `user_info` (username, password, auth, status, exp_date, is_trial, active_cons, created_at, max_connections, allowed_output_formats) and `server_info` (url, port, server_protocol, timezone).

| Action on `player_api.php` | Parameters | Returns |
| --- | --- | --- |
| `get_live_categories` | | Live categories |
| `get_live_streams` | `category_id`, optional | Live channels, with `tv_archive` and `tv_archive_duration` for catch-up |
| `get_vod_categories` | | Movie categories |
| `get_vod_streams` | `category_id`, optional | Movies |
| `get_vod_info` | `vod_id` | One movie's details |
| `get_series_categories` | | Series categories |
| `get_series` | `category_id`, optional | Series |
| `get_series_info` | `series_id` (not `series`) | Seasons and episodes |
| `get_short_epg` | `stream_id`, `limit` (4 by default; some providers ignore it) | The next few programmes |
| `get_simple_data_table` | `stream_id` | The full guide for one stream |

The whole guide for every stream comes from `xmltv.php?username=U&password=P`, which not every provider offers.

| Stream | URL | Confidence |
| --- | --- | --- |
| Live | `/live/U/P/<stream_id>.ts`, or `.m3u8` when `allowed_output_formats` lists it | Confirmed in the thread; ask for `.m3u8` so AVPlayer can play it |
| Movie | `/movie/U/P/<stream_id>.<container_extension>` | Common convention; the thread shows it failing for one user. Check with the probe |
| Episode | `/series/U/P/<episode_id>.<container_extension>` | Common convention. Check with the probe |
| Catch-up | `/timeshift/U/P/<minutes>/<YYYY-MM-DD:HH-MM>/<stream_id>.ts` | Common convention, unconfirmed; the thread only says timeshift parameters are appended |

**Quirks to build in**

- Guide titles and descriptions may arrive base64-encoded; decode when the text decodes cleanly.
- Numbers and dates often arrive as strings (`exp_date` is a Unix time in a string).
- An empty object may arrive as `[]`.

## M3U playlists and XMLTV guides

An M3U playlist is a text file with an `#EXTINF` line of attributes before each stream URL; the guide is a separate XMLTV file matched by `tvg-id`. The attribute names follow [Kodi's IPTV Simple](https://github.com/kodi-pvr/pvr.iptvsimple), which most players copy.

```text
#EXTM3U x-tvg-url="https://example.com/guide.xml.gz"
#EXTINF:-1 tvg-id="cityline.news" tvg-name="Cityline News" tvg-logo="https://example.com/cn.png" tvg-chno="101" group-title="News" catchup="default" catchup-days="7" catchup-source="https://example.com/archive/cn?start={utc}&duration={duration}",Cityline News
https://example.com/live/cn.m3u8
```

| Attribute | Meaning |
| --- | --- |
| `x-tvg-url` on `#EXTM3U` | The guide's URL; many playlists write `url-tvg` instead, so read both |
| `tvg-id` | The channel's id in the XMLTV guide |
| `tvg-name`, `tvg-logo`, `tvg-chno` | Name, logo, channel number |
| `group-title` | The category |
| `catchup` | How to build an archive URL: `default` (use `catchup-source` as the full URL), `append` (add `catchup-source` to the channel URL), plus Shift, Flussonic and Xtream codes styles |
| `catchup-days` | How far back the archive goes |
| `catchup-source` | The archive URL or suffix, with placeholders such as `{utc}` (programme start), `{lutc}` (now), `{duration}`, `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}`, `{utcend}` |
| `#EXTVLCOPT` lines | `key=value` options for the stream that follows, such as a user agent or referrer to send |

```text
<tv>
  <channel id="cityline.news"><display-name>Cityline News</display-name><icon src="https://example.com/cn.png"/></channel>
  <programme start="20261024200000 +0000" stop="20261024210000 +0000" channel="cityline.news"><title>Evening Bulletin</title><desc>Tonight's news.</desc></programme>
</tv>
```

- XMLTV times are `YYYYMMDDhhmmss` plus an offset; files are often gzipped and can run to hundreds of megabytes, so parse as a stream.
- A channel with no `tvg-id`, or one the guide doesn't know, is matched by normalised name, and the match is shown so the owner can correct it.

## Stable ids

Favorites and progress are synced by item key, so a key must outlive a refresh, a renumbering and a new stream token. Every key starts with the source's UUID; stream URLs never go into a key, because many carry a token that changes.

| Source | Channel | Movie | Episode |
| --- | --- | --- | --- |
| Stalker | Channel `id` | Movie `id` | Series id + season + episode number |
| Xtream | `stream_id` | `stream_id` | `series_id` + season + episode number |
| M3U | `tvg-id`, else a hash of the normalised name and `group-title` | Same as a channel | Series name + season + episode, parsed from the title |

1. After each refresh, look up every favorite and progress key in the new catalog.
2. A key that is gone: search the same source for one item with the same normalised name and kind.
3. Exactly one match: rewrite the key once (one synced write) and keep going.
4. None or several: keep the row, show the item as unavailable, and look again next refresh.
5. Episodes are keyed by season and number, never by the episode's own id, which some providers reissue.

## Verification checklist

Run the probe against each real provider before its source type ships, and save each answer as a scrubbed fixture. A failed line is a bug in this file first, then in the code.

- [ ] Stalker: which API path answers the handshake
- [ ] Stalker: does the portal sign in with the MAC alone, or need serial, device ids, signature, or `do_auth`
- [ ] Stalker: how many streams one MAC allows (play on two devices at once)
- [ ] Stalker: the format `create_link` returns for live, movie and episode, and how long a link lasts
- [ ] Stalker: the account expiry call, and the catch-up link call
- [ ] Stalker: how long the token lives without the keep-alive
- [ ] Xtream: the account call's `max_connections`, `active_cons` and `allowed_output_formats`
- [ ] Xtream: movie, episode and catch-up URL shapes play
- [ ] Xtream: whether `xmltv.php` answers, and whether short guide titles are base64
- [ ] M3U: the guide header name, catch-up attributes, any `#EXTVLCOPT` headers the streams need
- [ ] All: the stream format of each kind of item (HLS, MPEG-TS, MP4, MKV), which picks the player engine
- [ ] All: catalog size and the time a full import takes

## Sources

- [stalkerhek source](https://github.com/kidpoleon/stalkerhek): `stalker/authentication.go`, `channels.go`, `epg.go`, `vod.go` and `stalker.go` read for the verified Stalker rows
- [stalkerhek on pkg.go.dev](https://pkg.go.dev/github.com/kidpoleon/stalkerhek): API paths and advanced-field defaults
- [StalkerWeb](https://github.com/rangoDJ/stalkerweb): confirms handshake, token auth and a keep-alive watchdog
- [Xtream API thread in Fermata's discussions](https://github.com/AndreyPavlenko/Fermata/discussions/434): Xtream actions, account fields, live URL shape
- [Kodi IPTV Simple](https://github.com/kodi-pvr/pvr.iptvsimple): M3U attributes, catch-up modes and placeholders
- [Apple Developer Forums: AVPlayer and MPEG-TS](https://developer.apple.com/forums/thread/710481) and [VLCKit issue 119](https://code.videolan.org/videolan/VLCKit/issues/119): why raw MPEG-TS needs VLCKit
