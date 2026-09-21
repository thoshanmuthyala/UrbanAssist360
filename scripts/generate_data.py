#!/usr/bin/env python3
"""Generate deterministic UrbanAssist JSON Lines source files.

The script uses only the Python standard library. It creates 50,000 historical
bookings, 1,000 live bookings, realistic booking updates, four reference data
sets, controlled operational patterns, and a manifest with file-level record
counts.

Run from the project root:
    python3 scripts/generate_data.py
"""

from __future__ import annotations

import argparse
import gzip
import json
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable


SEED = 3602026
HISTORICAL_BOOKINGS = 50_000
LIVE_BOOKINGS = 1_000
CUSTOMER_COUNT = 5_000
PROVIDER_COUNT = 250

CITIES = ["Bengaluru", "Hyderabad", "Pune", "Chennai", "Mumbai", "Delhi", "Kolkata", "Ahmedabad"]
ZONES = ["North", "South", "East", "West", "Central"]
SEGMENTS = ["NEW", "REGULAR", "LOYAL"]
PAYMENTS = ["UPI", "CARD", "CASH", "WALLET"]

SERVICES = [
    ("S001", "Basic Home Cleaning", "Home Cleaning", 899, 120, "BASIC"),
    ("S002", "Deep Home Cleaning", "Home Cleaning", 2499, 240, "ADVANCED"),
    ("S003", "Bathroom Cleaning", "Home Cleaning", 599, 75, "BASIC"),
    ("S004", "Kitchen Cleaning", "Home Cleaning", 749, 90, "BASIC"),
    ("S005", "Tap and Leak Repair", "Plumbing", 399, 45, "BASIC"),
    ("S006", "Kitchen Plumbing", "Plumbing", 799, 90, "ADVANCED"),
    ("S007", "Bathroom Plumbing", "Plumbing", 699, 75, "ADVANCED"),
    ("S008", "Pipe Replacement", "Plumbing", 1499, 150, "EXPERT"),
    ("S009", "Switch and Socket Repair", "Electrical", 349, 45, "BASIC"),
    ("S010", "Fan Installation", "Electrical", 549, 60, "BASIC"),
    ("S011", "Electrical Wiring", "Electrical", 1799, 180, "EXPERT"),
    ("S012", "Inverter Service", "Electrical", 999, 100, "ADVANCED"),
    ("S013", "AC Service", "Appliance Repair", 699, 90, "ADVANCED"),
    ("S014", "AC Repair", "Appliance Repair", 1399, 150, "EXPERT"),
    ("S015", "Washing Machine Repair", "Appliance Repair", 999, 120, "ADVANCED"),
    ("S016", "Refrigerator Repair", "Appliance Repair", 1199, 135, "EXPERT"),
    ("S017", "Salon Essential", "Beauty at Home", 799, 75, "BASIC"),
    ("S018", "Salon Premium", "Beauty at Home", 1599, 120, "ADVANCED"),
    ("S019", "Massage Therapy", "Beauty at Home", 1299, 90, "ADVANCED"),
    ("S020", "Grooming Package", "Beauty at Home", 999, 90, "BASIC"),
]

CATEGORY_WEIGHTS = {
    "Home Cleaning": 0.30,
    "Plumbing": 0.20,
    "Electrical": 0.17,
    "Appliance Repair": 0.21,
    "Beauty at Home": 0.12,
}

POSITIVE_REVIEWS = {
    "Professionalism": [
        "The professional was polite, skilled, and handled everything carefully.",
        "Very professional service and clear communication throughout the visit.",
    ],
    "Service Quality": [
        "Excellent quality of work and the problem was completely resolved.",
        "The service quality exceeded expectations and everything works perfectly now.",
    ],
    "Punctuality": [
        "Arrived exactly on time and completed the work quickly.",
        "Very punctual and finished within the promised time.",
    ],
}

NEGATIVE_REVIEWS = {
    "Punctuality": [
        "The provider arrived very late and I had to change my schedule.",
        "The appointment started late with no advance communication.",
    ],
    "Service Quality": [
        "The issue returned the next day and the service quality was disappointing.",
        "The work was incomplete and I need another visit to fix the problem.",
    ],
    "Pricing": [
        "The final price was higher than expected and the charges were not explained.",
        "The service felt too expensive for the amount of work completed.",
    ],
    "Communication": [
        "Communication was poor and I did not receive a clear status update.",
        "It was difficult to reach the provider before the appointment.",
    ],
}


@dataclass(frozen=True)
class Provider:
    provider_id: str
    provider_name: str
    primary_city: str
    operating_zone: str
    provider_tier: str
    experience_level: str
    active_status: str
    primary_service_category: str


def iso(value: datetime | None) -> str | None:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value else None


def write_jsonl_gz(path: Path, rows: Iterable[dict]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with gzip.open(path, "wt", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n")
            count += 1
    return count


def weighted_choice(rng: random.Random, weights: dict[str, float]) -> str:
    return rng.choices(list(weights), weights=list(weights.values()), k=1)[0]


def customer_rows(rng: random.Random) -> list[dict]:
    rows = []
    start = datetime(2024, 1, 1, tzinfo=timezone.utc)
    for index in range(1, CUSTOMER_COUNT + 1):
        rows.append(
            {
                "customer_id": f"C{index:06d}",
                "customer_name": f"Customer {index:05d}",
                "customer_segment": rng.choices(SEGMENTS, [0.25, 0.55, 0.20], k=1)[0],
                "home_city": rng.choice(CITIES),
                "signup_date": (start + timedelta(days=rng.randrange(730))).date().isoformat(),
                "is_active": rng.random() > 0.03,
            }
        )
    return rows


def service_rows() -> list[dict]:
    return [
        {
            "service_id": service_id,
            "service_name": name,
            "service_category": category,
            "standard_price": price,
            "expected_duration_minutes": duration,
            "skill_level_required": skill,
            "is_active": True,
        }
        for service_id, name, category, price, duration, skill in SERVICES
    ]


def provider_rows(rng: random.Random) -> tuple[list[Provider], list[dict]]:
    providers: list[Provider] = []
    rows: list[dict] = []
    categories = list(CATEGORY_WEIGHTS)
    for index in range(1, PROVIDER_COUNT + 1):
        provider = Provider(
            provider_id=f"P{index:05d}",
            provider_name=f"Service Partner {index:03d}",
            primary_city=CITIES[(index - 1) % len(CITIES)],
            operating_zone=ZONES[(index - 1) % len(ZONES)],
            provider_tier=rng.choices(["STANDARD", "PREMIUM"], [0.72, 0.28], k=1)[0],
            experience_level=rng.choices(["JUNIOR", "EXPERIENCED", "EXPERT"], [0.25, 0.55, 0.20], k=1)[0],
            active_status="ACTIVE",
            primary_service_category=categories[(index - 1) % len(categories)],
        )
        providers.append(provider)
        rows.append({**provider.__dict__, "effective_at": "2026-01-01T00:00:00Z", "record_updated_at": "2026-01-01T00:00:00Z"})
    return providers, rows


def provider_change_rows(providers: list[Provider]) -> list[dict]:
    changes: list[dict] = []
    for offset, provider in enumerate(providers[:30]):
        changed = dict(provider.__dict__)
        if offset < 15:
            changed["provider_tier"] = "PREMIUM"
        elif offset < 22:
            changed["operating_zone"] = ZONES[(ZONES.index(provider.operating_zone) + 1) % len(ZONES)]
        elif offset < 27:
            changed["primary_city"] = CITIES[(CITIES.index(provider.primary_city) + 1) % len(CITIES)]
        else:
            changed["active_status"] = "INACTIVE"
        changes.append({**changed, "effective_at": "2026-09-01T00:00:00Z", "record_updated_at": "2026-09-01T00:00:00Z"})
    return changes


def build_review(rng: random.Random, rating: int) -> tuple[str | None, str | None, str | None]:
    if rng.random() > 0.18:
        return None, None, None
    if rating >= 4:
        category = rng.choices(list(POSITIVE_REVIEWS), [0.30, 0.45, 0.25], k=1)[0]
        return rng.choice(POSITIVE_REVIEWS[category]), "positive", category
    category = rng.choices(list(NEGATIVE_REVIEWS), [0.40, 0.32, 0.16, 0.12], k=1)[0]
    return rng.choice(NEGATIVE_REVIEWS[category]), "negative", category


def booking_rows(
    rng: random.Random,
    providers: list[Provider],
    start_index: int,
    count: int,
    start_at: datetime,
    end_at: datetime,
    include_updates: bool,
) -> list[dict]:
    service_by_category: dict[str, list[tuple]] = {}
    for service in SERVICES:
        service_by_category.setdefault(service[2], []).append(service)
    providers_by_category: dict[str, list[Provider]] = {}
    for provider in providers:
        providers_by_category.setdefault(provider.primary_service_category, []).append(provider)

    rows: list[dict] = []
    span_seconds = int((end_at - start_at).total_seconds())
    for sequence in range(start_index, start_index + count):
        category = weighted_choice(rng, CATEGORY_WEIGHTS)
        service = rng.choice(service_by_category[category])
        provider = rng.choice(providers_by_category[category])
        city = provider.primary_city if rng.random() < 0.80 else rng.choice(CITIES)
        created = start_at + timedelta(seconds=rng.randrange(max(span_seconds, 1)))
        if created.weekday() >= 5 and rng.random() < 0.35:
            created = created - timedelta(days=2)
        scheduled = created + timedelta(hours=rng.randint(2, 72))

        cancel_probability = 0.11
        if city == "Pune" and category == "Plumbing":
            cancel_probability = 0.29
        if provider.provider_tier == "PREMIUM":
            cancel_probability -= 0.025
        draw = rng.random()
        if draw < cancel_probability:
            status = "CANCELLED"
        elif draw < cancel_probability + 0.04:
            status = "IN_PROGRESS"
        elif draw < cancel_probability + 0.06:
            status = "BOOKED"
        else:
            status = "COMPLETED"

        expected_duration = service[4]
        started = scheduled + timedelta(minutes=rng.randint(-10, 50)) if status == "COMPLETED" else None
        completed = started + timedelta(minutes=max(20, int(rng.gauss(expected_duration, expected_duration * 0.15)))) if started else None
        base_rating = 4.25 + (0.20 if provider.provider_tier == "PREMIUM" else 0)
        if city == "Bengaluru" and category == "Appliance Repair":
            base_rating -= 1.05
        if status == "COMPLETED":
            rating = max(1, min(5, round(rng.gauss(base_rating, 0.75))))
        else:
            rating = None
        review, expected_sentiment, expected_category = build_review(rng, rating) if rating else (None, None, None)

        gross = round(service[3] * rng.uniform(0.90, 1.25), 2)
        discount = round(gross * rng.choice([0, 0, 0.05, 0.10, 0.15]), 2)
        tax = round((gross - discount) * 0.18, 2)
        final = round(gross - discount + tax, 2)
        updated = (completed or scheduled) + timedelta(minutes=rng.randint(5, 180))
        booking = {
            "booking_id": f"B{sequence:08d}",
            "customer_id": f"C{rng.randint(1, CUSTOMER_COUNT):06d}",
            "provider_id": provider.provider_id,
            "service_id": service[0],
            "booking_city": city,
            "booking_created_at": iso(created),
            "scheduled_at": iso(scheduled),
            "service_started_at": iso(started),
            "service_completed_at": iso(completed),
            "booking_status": status,
            "gross_amount": gross,
            "discount_amount": discount,
            "tax_amount": tax,
            "final_amount": final,
            "payment_method": rng.choice(PAYMENTS),
            "rating": rating,
            "review_text": review,
            "expected_sentiment": expected_sentiment,
            "expected_complaint_category": expected_category,
            "record_updated_at": iso(updated),
        }
        rows.append(booking)

        # Append a later snapshot for a controlled subset. Bronze retains both;
        # the Silver Dynamic Table keeps the latest record_updated_at.
        if include_updates and sequence % 10 == 0:
            changed = dict(booking)
            if status == "BOOKED":
                changed["booking_status"] = "IN_PROGRESS"
            elif status == "IN_PROGRESS":
                changed["booking_status"] = "COMPLETED"
                changed["service_started_at"] = iso(scheduled + timedelta(minutes=15))
                changed["service_completed_at"] = iso(scheduled + timedelta(minutes=15 + expected_duration))
                changed["rating"] = 4
            changed["record_updated_at"] = iso(updated + timedelta(hours=2))
            rows.append(changed)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/generated"))
    args = parser.parse_args()
    output = args.output.resolve()
    rng = random.Random(SEED)

    customers = customer_rows(rng)
    services = service_rows()
    providers, provider_initial = provider_rows(rng)
    provider_changes = provider_change_rows(providers)

    files: list[tuple[Path, int]] = []
    files.append((output / "reference/customers.json.gz", write_jsonl_gz(output / "reference/customers.json.gz", customers)))
    files.append((output / "reference/services.json.gz", write_jsonl_gz(output / "reference/services.json.gz", services)))
    files.append((output / "providers/provider_initial.json.gz", write_jsonl_gz(output / "providers/provider_initial.json.gz", provider_initial)))
    files.append((output / "providers/provider_changes_live.json.gz", write_jsonl_gz(output / "providers/provider_changes_live.json.gz", provider_changes)))

    history_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    history_end = datetime(2026, 9, 1, tzinfo=timezone.utc)
    for batch in range(5):
        batch_rows = booking_rows(
            rng,
            providers,
            1 + batch * 10_000,
            10_000,
            history_start + timedelta(days=batch * 48),
            min(history_end, history_start + timedelta(days=(batch + 1) * 48)),
            include_updates=True,
        )
        path = output / f"bookings/booking_batch_{batch + 1:03d}.json.gz"
        files.append((path, write_jsonl_gz(path, batch_rows)))

    live_rows = booking_rows(
        rng,
        providers,
        HISTORICAL_BOOKINGS + 1,
        LIVE_BOOKINGS,
        datetime(2026, 9, 1, tzinfo=timezone.utc),
        datetime(2026, 9, 11, tzinfo=timezone.utc),
        include_updates=True,
    )
    live_path = output / "bookings/booking_live_batch.json.gz"
    files.append((live_path, write_jsonl_gz(live_path, live_rows)))

    manifest = {
        "seed": SEED,
        "unique_historical_bookings": HISTORICAL_BOOKINGS,
        "unique_live_bookings": LIVE_BOOKINGS,
        "files": [
            {
                "path": str(path.relative_to(output)),
                "physical_records": count,
                "bytes": path.stat().st_size,
            }
            for path, count in files
        ],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
