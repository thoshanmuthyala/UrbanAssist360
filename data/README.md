# Source data

`scripts/generate_data.py` creates deterministic, synthetic JSON Lines files.
The output is compressed with gzip because Snowflake detects gzip compression
when the JSON file format uses `COMPRESSION = AUTO`.

The generated layout mirrors the S3 prefixes expected by the SQL:

```text
generated/
├── bookings/
│   ├── booking_batch_001.json.gz ... booking_batch_005.json.gz
│   └── booking_live_batch.json.gz
├── providers/
│   ├── provider_initial.json.gz
│   └── provider_changes_live.json.gz
├── reference/
│   ├── customers.json.gz
│   └── services.json.gz
└── manifest.json
```

Upload all files except the two `*live*` files during the initial load. Keep the
live files outside S3 until the event-driven demonstration.

The generator uses a fixed seed. Re-running it replaces only files beneath
`data/generated/` and produces the same business patterns.

