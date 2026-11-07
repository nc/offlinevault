# DEVELOPMENT licence keys, never ship these

`licence-private.key` / `licence-public.key` are a throw-away Ed25519 pair, key id `dev-2026`. They sign the unit-test
fixtures, `fixture/dev-licence-*.json` (what the fixture server hands out for `OV-DEV?-…` keys) and the Worker's
golden fixture. `Config.licencePublicKeys` trusts the public half only in DEBUG builds; release builds trust the
production key `prod-2026-10` alone, whose private half exists only as a Worker secret.

Regenerate everything signed with this key:

    cd Core && swift run licencetool fixtures --out ..

For production:

    cd Core
    swift run licencetool keygen --out /secure/location          # keep the private key offline; wrangler secret put LICENCE_PRIVATE_KEY
    # add the printed public key to Config.licencePublicKeys under a new key id, and set LICENCE_KEY_ID on the Worker
    swift run licencetool sign --key /secure/location/licence-private.key --key-id prod-2026-10 \
        --subscriber "Jane Doe" --plan core --days 365 --out jane.json
