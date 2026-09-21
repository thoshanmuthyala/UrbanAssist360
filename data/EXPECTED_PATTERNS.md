# Expected analytical patterns

The generator deliberately introduces stable patterns for validation:

- Home Cleaning has the largest booking share and is expected to lead revenue.
- Plumbing bookings in Pune have a higher cancellation probability.
- Appliance Repair in Bengaluru receives lower ratings more often.
- Premium providers receive a small completion and rating advantage.
- Weekend demand is higher than weekday demand.
- Punctuality and service quality appear frequently in negative reviews.
- The live provider file upgrades several Standard providers to Premium, moves
  a smaller set to another zone or city, and marks three providers inactive.

Exact aggregates can vary only if the generator seed or probabilities change.
Use `sql/05_operations/01_monitoring_and_validation.sql` for executable
assertions.
