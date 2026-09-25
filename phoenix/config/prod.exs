import Config

# TLS terminates at Caddy; the app speaks plain HTTP on the loopback and reads
# the forwarded scheme. force_ssl is left off for that reason — Caddy already
# redirects http:// to https:// for every host it serves.
config :logger, level: :info
