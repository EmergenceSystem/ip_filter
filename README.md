# ip_filter
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An [em_filter](https://hex.pm/packages/em_filter) agent that resolves IP geolocation and network information via [ipwho.is](https://ipwho.is/) (free, no key required).


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## Query

An IPv4 or IPv6 address, optionally prefixed with text. The agent extracts the first valid IP found in the query string.

| Input form | Example |
|---|---|
| Plain IPv4 | `8.8.8.8` |
| With prefix | `ip 1.1.1.1` or `lookup 8.8.4.4` |
| IPv6 | `2606:4700:4700::1111` |

| Field | Example |
|---|---|
| title | `8.8.8.8 — Mountain View, California, United States` |
| resume | `ISP: Google LLC \| ASN: 15169 \| lat: 37.4056 \| lon: -122.0775 \| tz: America/Los_Angeles \| type: IPv4` |
| source | `ipwho.is` |

## Usage

**Via curl (direct to em_disco):**

```bash
# IPv4 lookup
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"value": "8.8.8.8", "capabilities": ["ip"]}'

# With prefix text
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"value": "lookup 1.1.1.1", "capabilities": ["ip"]}'

# IPv6
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"value": "2606:4700:4700::1111", "capabilities": ["ip"]}'
```

**Via Erlang shell:**

```erlang
emquest_cli:query(<<"8.8.8.8">>).
emquest_cli:query(<<"ip 208.67.222.222">>).
```

## Installation

```bash
git clone https://github.com/EmergenceSystem/ip_filter.git
cd ip_filter
rebar3 shell --apps ip_filter
```

Requires `em_disco` running on `localhost:8080` (configured in `emergence.conf`).

## Capabilities

`search`, `query`, `ip`, `geolocation`, `network`, `asn`, `isp`

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
