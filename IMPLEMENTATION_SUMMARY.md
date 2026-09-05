# RouteLens Implementation Summary

## Executive summary

RouteLens is a complete, deterministic, explainable payout-routing system implemented primarily in Ruby. It processes a queue of payout operations, removes providers that violate hard constraints, ranks the eligible providers through a configurable policy, safely updates provider state, retries after failures, uses SpacePayments only as the final fallback, and generates both operation-level explanations and aggregate business analytics.

The solution was built to address the complete hackathon rubric rather than only the public validator. It includes the routing engine, policy configuration, input validation, provider-state lifecycle, deterministic outcome simulation, retry and fallback logic, analytics, evidence-backed recommendations, automated tests, release checks, documentation, and an offline interactive Routing Observatory.

The supplied public queue passes the official validator with:

- **29 checks passed**
- **0 errors**
- **0 warnings**

The complete automated suite passes with:

- **81 tests**
- **378 assertions**
- **0 failures**
- **0 errors**

All generated public artifacts are deterministic: rerunning RouteLens with the same inputs, configuration, and seed produces byte-identical decision and report files.

---

## 1. Starting point

The initial workspace contained:

- the Russian-language hackathon brief;
- a provider-state snapshot;
- 100 historical operations;
- a public queue of ten operations;
- sample routing decisions;
- reference eligibility information;
- the public Ruby validator.

It did not contain:

- an application architecture;
- routing code;
- state-management logic;
- configurable policies;
- analytics generation;
- automated tests;
- a README;
- a release process;
- a visualization;
- an initialized Git repository.

The work therefore began as a greenfield implementation based on the task specification and scoring rubric.

---

## 2. What was achieved

### Core product

- Built an end-to-end payout router in Ruby.
- Implemented every hard constraint described in the brief.
- Implemented ten soft scoring factors covering all requested routing strategies.
- Added explicit conflict resolution through normalized weighted scoring.
- Added deterministic tie-breaking.
- Added correct reservation, approval, rejection, expiry, and release transitions.
- Added automatic retry with reranking after a provider failure.
- Isolated SpacePayments from normal routing and used it only as fallback.
- Added deterministic conversion-based outcome and latency simulation.
- Added complete decision receipts for every operation.

### Analytics and business value

- Generated count and volume distributions.
- Calculated actual, target, and deviation percentages.
- Reported approvals, rejections, expirations, retries, and fallback usage.
- Calculated average and p95 latency.
- Reported provider capacity utilization and remaining headroom.
- Separated hard exclusions from soft policy non-selections.
- Compared live conversion with historical approval performance.
- Generated human-readable and structured recommendations.

### Reliability and delivery

- Added strict JSON, CSV, and provider-schema validation.
- Added boundary, malformed-input, retry, fallback, analytics, and integration tests.
- Added an exact final-release command.
- Protected the required final filenames from accidental overrides.
- Added a release checker that validates coverage and required fields.
- Added full operational documentation.
- Initialized Git on the required `main` branch.
- Created a clean initial implementation commit.

### Judge-facing differentiation

- Built a self-contained Routing Observatory.
- Added actual-versus-target visual comparisons.
- Added capacity meters and business recommendations.
- Added an operation selector with ordered attempts.
- Added expandable score breakdowns.
- Verified the observatory in a browser at desktop and 360-pixel widths.
- Added a guaranteed retry/fallback demonstration fixture.

---

## 3. System architecture

The routing pipeline is:

```text
Load and validate inputs
        ↓
Create isolated mutable provider states
        ↓
Evaluate all hard constraints
        ↓
Rank eligible external providers with the active policy
        ↓
Reserve provider capacity and a requisite
        ↓
Execute or deterministically simulate an outcome
        ↓
Approved → settle and finish
Rejected/expired → release state and rerank remaining providers
        ↓
No external provider remains → SpacePayments fallback
        ↓
Persist decision receipts and build the aggregate report
```

The main components are intentionally separate:

| Component | Responsibility |
|---|---|
| `InputLoader` | Parse and validate provider, operation, and history inputs |
| `ProviderState` | Own mutable counters, reservations, requisites, and settlements |
| `Eligibility::Evaluator` | Execute all hard rules and preserve every exclusion reason |
| `Scoring::Policy` | Combine normalized soft factors and rank providers |
| `OutcomeSimulator` | Produce reproducible outcomes and latency |
| `Router` | Orchestrate selection, state transitions, retries, and fallback |
| `HistoryAnalyzer` | Summarize historical success and latency |
| `ReportBuilder` | Reconcile decisions into business and operational metrics |
| `RecommendationEngine` | Turn measurements into concrete policy recommendations |
| `Observatory` | Generate the offline interactive dashboard |
| `CLI` | Provide one-command execution and atomic artifact writes |

This separation lets a new provider, hard rule, scoring factor, or recommendation be introduced without rewriting unrelated parts of the engine.

---

## 4. Input loading and validation

The input layer validates data before routing begins. Invalid input causes a clear error and prevents partially written final artifacts.

Validation includes:

- readable and valid JSON/CSV;
- required provider and operation fields;
- nonempty operation and provider identifiers;
- unique operation IDs;
- unique provider names;
- finite numeric values;
- positive operation amounts;
- nonnegative limits and counters;
- ISO 8601 operation timestamps;
- conversion inside `0..1`;
- traffic and volume percentages inside `0..100`;
- minimum amount not exceeding maximum amount;
- real booleans for bank and margin flags;
- an array for the provider bank list.

Provider status is accepted as any nonempty value for forward compatibility. The eligibility layer considers only the exact value `active` eligible, so a future status such as `unavailable` is safely excluded rather than crashing the entire batch.

Relevant implementation:

- `lib/route_lens/input_loader.rb`
- `lib/route_lens/provider_state.rb`

---

## 5. Hard constraints

Hard constraints answer: **Can this operation be sent to this provider at all?**

Each hard constraint is an independent Ruby rule. Every rule is evaluated, even after one fails, so the decision receipt can preserve the complete explanation. The first failure in the documented rule order becomes the stable primary reason expected by validators.

| Rule | Behavior | Reason code |
|---|---|---|
| Status | Requires `status == active` | `provider_inactive` |
| Self-provider | Excludes SpacePayments from normal ranking | `self_provider_reserved_for_fallback` |
| Traffic enabled | Excludes ordinary external providers with zero traffic | `traffic_disabled` |
| Minimum amount | Rejects amounts below provider minimum | `amount_below_minimum` |
| Maximum amount | Rejects amounts above provider maximum | `amount_exceeds_limit` |
| Daily maximum | Checks current approved amount plus the operation | `daily_amount_limit_exceeded` |
| In-progress count | Checks the next reservation against count capacity | `in_progress_count_limit_exceeded` |
| In-progress amount | Checks the next amount against in-progress capacity | `in_progress_amount_limit_exceeded` |
| Bank allowlist | Requires the bank to appear in an inclusive bank list | `bank_not_in_list` |
| Bank denylist | Rejects banks appearing in an exclusion list | `bank_excluded` |
| Margin | Prevents negative merchant economics unless allowed | `negative_margin_not_allowed` |
| Requisites | Requires at least one available requisite | `no_available_requisites` |
| Intensity | Enforces requests-per-minute capacity | `rate_limit_exceeded` |

Important boundary behavior:

- equal to a maximum is allowed;
- `null` limits are unbounded;
- an empty bank list supports all banks;
- an inclusive bank list is used when `exclude_banks` is false;
- a denylist is used when `exclude_banks` is true;
- soft policy weights can never override a hard exclusion.

Relevant implementation:

- `lib/route_lens/eligibility/evaluator.rb`
- `lib/route_lens/eligibility/rules.rb`
- `lib/route_lens/eligibility/result.rb`

---

## 6. Configurable soft-policy scoring

Soft policy answers: **Which eligible provider is currently preferable?**

The policy is configured in `config/routing.yml`. RouteLens calculates a normalized value for every enabled factor and combines them as:

```text
score = Σ(normalized factor × configured weight × direction)
```

Positive factors increase a provider's score. Load, latency, and cost use an explicit negative direction.

### Implemented factors

| Factor | What it measures |
|---|---|
| Count target gain | How much the assignment improves the count-share distribution |
| Volume target gain | How much it improves the monetary-volume distribution |
| Conversion | Current `conversion_24h` quality |
| Priority | Cascade position among current eligible candidates |
| Amount preference | Whether the check is inside a configurable preferred band |
| Capacity | Remaining daily and in-progress capacity after the operation |
| Turnover obligation | Urgency to fulfill a configured minimum daily turnover |
| Load | Current in-progress count and amount pressure |
| Latency | Relative expected provider latency |
| Cost | Provider margin relative to merchant margin |

Count and volume scoring evaluate the **gain created by the current assignment**. They do not simply reward large target percentages. This allows sequential decisions to move the complete batch toward its configured targets.

The default policy deliberately has different count and volume targets. That forces the engine to reconcile genuine business objectives rather than treating both strategies as aliases.

When total scores are equal, providers are ordered deterministically by:

1. Lower numerical priority
2. Lower latency
3. Provider name

Every score result includes the raw value, weight, direction, and weighted contribution of every factor.

Relevant implementation:

- `config/routing.yml`
- `lib/route_lens/scoring/policy.rb`
- `lib/route_lens/scoring/`

---

## 7. Provider-state lifecycle

Provider state is copied from the input snapshot so the source data is never modified. Each provider has an isolated, thread-safe `ProviderState` object.

### Reservation

Before an actual attempt, RouteLens atomically:

- increments in-progress count;
- increments in-progress amount;
- consumes one available requisite;
- records one request in the correct minute bucket;
- associates the changes with a unique reservation ID.

### Approval

On approval, RouteLens:

- releases the in-progress count and amount;
- returns the requisite;
- adds the amount to daily approved turnover;
- closes the reservation.

### Rejection or expiry

On rejection or expiry, RouteLens:

- releases in-progress count and amount;
- returns the requisite;
- does not increase approved turnover;
- closes the reservation;
- removes that provider from the operation's candidate pool;
- reevaluates and reranks the remaining providers.

Reservation IDs prevent double release and amount mismatches. Tests verify that failed attempts leave provider capacity exactly as it was before the reservation, except for the recorded request-rate event.

Relevant implementation:

- `lib/route_lens/provider_state.rb`
- `lib/route_lens/router.rb`

---

## 8. Retry and SpacePayments fallback

Retry is part of the routing engine rather than a separate scripted demonstration.

After a rejection or expiry:

1. The failed provider is settled and released.
2. Attempt metrics are updated for provider-load diagnostics; failed attempts do not satisfy final allocation targets.
3. The provider is excluded only for the current operation.
4. Eligibility is recalculated against current provider state.
5. Remaining candidates are rescored.
6. The next candidate is reserved and attempted.
7. Count and volume target metrics are updated exactly once for the provider that ultimately receives the operation.

If no eligible external provider remains, RouteLens evaluates SpacePayments with explicit fallback context. SpacePayments is never included in ordinary provider scoring.

The judge-facing demonstration includes an external retry chain and a final fallback:

```text
vipay (rejected) → payflow (expired) → quickpay (approved)
quickpay (expired) → spacepayments (approved)
```

Demo artifacts:

- `demo/resilience_decisions.json`
- `demo/resilience_report.json`
- `demo/resilience_observatory.html`
- `demo/policy_comparison.json`
- `test/fixtures/resilience_outcomes.json`

The defense artifact is `presentation/RouteLens_Defense_RU.pptx`: five Russian-language slides with editable native tables, an editable native chart, and repository source notes.

---

## 9. Deterministic simulation

Outcome simulation uses a stable SHA-256 digest derived from:

- the configured seed;
- the operation ID;
- the provider name;
- the value being simulated.

The digest is converted into a reproducible unit interval and compared with provider conversion. A separate deterministic value produces latency around the configured average.

Two modes are available:

- `deterministic` — conversion-based, reproducible outcomes;
- `approve_all` — useful for format-only or non-failure test runs.

Explicit outcome overrides exist only for controlled fixtures and demos. Official public output is generated without forced outcomes.

Relevant implementation:

- `lib/route_lens/outcome_simulator.rb`

---

## 10. Decision receipts

Each decision preserves all mandatory challenge fields:

- `operation_id`
- `selected_provider`
- `attempts`
- `simulated_result`
- `latency_sec`

It also adds:

- active policy name;
- ordered routing sequence;
- complete selected-provider score breakdown;
- score and ranking for eligible non-selected providers;
- precise reason and evidence for every hard exclusion;
- every failure cause when several hard rules fail;
- attempt outcome and latency;
- provider state before and after each actual attempt;
- unmet-goal information.

The `attempts` array distinguishes:

- hard exclusions;
- soft policy non-selections;
- actual selected attempts;
- failed attempts followed by retries;
- final self-provider fallback.

The decision receipt lets a judge answer both “Why was this provider chosen?” and “Why was every other provider not chosen?” without reading the source code.

Public artifact:

- `routing_decisions.json`

---

## 11. Analytics and recommendations

The analytics report is generated from providers, operations, decisions, final state, and historical data.

### Distribution analytics

For each provider, the report contains:

- selected-operation count;
- actual count share;
- target count share;
- count-share deviation;
- routed amount;
- actual volume share;
- target volume share;
- volume-share deviation.

### Outcome and resilience analytics

The report contains:

- approved, rejected, expired, and unknown outcomes;
- approval and failure rates;
- average, p95, and maximum latency;
- retry count;
- operations retried;
- fallback count and share.

### Provider analytics

The report contains:

- daily approved amount;
- daily limit;
- utilization percentage;
- remaining headroom;
- in-progress count and amount;
- live conversion;
- historical approval rate;
- conversion drift in percentage points;
- provider-specific outcomes and latency;
- provider-specific hard exclusions.

### Correct classification

Hard eligibility exclusions are reported under `skip_reasons`. Soft choices such as `lower_policy_score` are reported separately under `policy_nonselections`. This prevents the report from falsely describing a lower ranking as a hard technical failure.

### Recommendations

Each structured recommendation contains:

- type and severity;
- affected provider;
- numeric evidence;
- current parameter value;
- proposed parameter value or investigation;
- expected impact;
- a human-readable message.

The public report detects, among other things:

- Payflow reaching approximately **99.6% daily utilization**;
- a large difference between Payflow's live 91% conversion and its 47.4% historical approval rate;
- forced distribution deviations caused by bank and amount eligibility.

Public artifact:

- `routing_report.json`

Relevant implementation:

- `lib/route_lens/analytics/history_analyzer.rb`
- `lib/route_lens/analytics/report_builder.rb`
- `lib/route_lens/analytics/recommendation_engine.rb`

---

## 12. Routing Observatory

The Routing Observatory is generated from persisted decision and report JSON. It is a single self-contained HTML file with no external assets, APIs, CDN requests, or server dependency.

It presents:

- operation, approval, retry, and fallback indicators;
- actual-versus-target count bars;
- daily-capacity utilization and headroom;
- evidence-backed recommendations;
- an operation selector;
- final provider, outcome, latency, and attempt count;
- every considered provider in sequence;
- expandable score-breakdown tables.

Security and usability measures include:

- restrictive Content Security Policy;
- escaped embedded JSON and static text;
- dynamic insertion through `textContent`;
- native keyboard-accessible controls;
- semantic headings, regions, meters, and tables;
- light and dark appearance support;
- responsive layouts down to 320 pixels;
- no horizontal overflow at the tested 360-pixel viewport.

The observatory was verified through real browser interaction. The operation selector correctly updated the visible decision receipt, and the `op_103` view correctly showed ViPay and Payflow exclusions followed by Quickpay selection.

Artifact:

- `routing_observatory.html`

Relevant implementation:

- `lib/route_lens/observatory.rb`
- `bin/observatory`

---

## 13. Commands and release safety

### Standard public run

```bash
ruby bin/route
```

### Public validator

```bash
ruby scripts/validate_10.rb routing_decisions.json
```

### Dashboard generation

```bash
bin/observatory \
  --decisions routing_decisions.json \
  --report routing_report.json \
  --output routing_observatory.html
```

### Final hidden test run

```bash
bin/release_test_case
```

The release command intentionally protects the required input and output paths from accidental overrides. It always reads the root `operations_queue_test.json` and writes the exact required root filenames.

After generation, `scripts/release_check.rb` verifies:

- all three files exist;
- decisions and report are valid JSON;
- queue and decisions are arrays of the expected type;
- the report is an object;
- all queue operation IDs are covered exactly once;
- no extra operation IDs appear;
- mandatory decision and attempt fields exist;
- attempt decisions use only allowed values;
- report totals match the queue;
- required analytics and recommendations exist.

Writes are atomic: each JSON artifact is completed in a temporary sibling file and then renamed into place.

---

## 14. Testing and verification

### Automated coverage

The suite covers:

- public eligible-provider sets;
- all four deterministic public cases;
- every hard rule;
- exact-limit boundary behavior;
- bank allowlists and denylists;
- invalid, negative, and non-finite inputs;
- provider-state reservation and settlement;
- requisite consumption and restoration;
- RPM tracking;
- every scoring factor;
- policy combination and tie-breaking;
- rejection followed by a second provider;
- direct and post-failure SpacePayments fallback;
- deterministic CLI artifacts;
- protected final-release filenames;
- history calculations;
- report reconciliation;
- hard versus soft skip classification;
- recommendation evidence;
- observatory content, escaping, and responsive behavior.

### Final verification results

| Verification | Result |
|---|---|
| Ruby syntax | 56 executable/source files valid |
| Automated suite | 81 tests, 378 assertions, all passing |
| Public validator | 29 passed, 0 errors, 0 warnings |
| Release structure check | Passed |
| Deterministic replay | Byte-identical outputs |
| Desktop observatory | Visually and interactively verified |
| 360px observatory | No horizontal overflow; interaction verified |
| Git branch | Clean `main` branch |

---

## 15. Compliance

RouteLens complies with the challenge restrictions:

- the implementation is primarily Ruby;
- routing uses deterministic policy code rather than neural networks;
- no AI model is used at runtime;
- no operation or provider data is transmitted externally;
- no proprietary routing or hosted decision service is used;
- the runtime can operate offline;
- runtime dependencies are Ruby standard-library components;
- dependency and license information is documented in `LICENSES.md`.

---

## 16. Repository map

```text
bin/                         Executable entry points
config/routing.yml           Routing policy and business targets
data/                        Supplied public data and references
demo/                        Guaranteed retry/fallback demonstration
lib/route_lens/eligibility/  Hard rules and evaluations
lib/route_lens/scoring/      Soft-policy factors and combination
lib/route_lens/analytics/    History, reports, and recommendations
lib/route_lens/router.rb      End-to-end routing orchestration
lib/route_lens/observatory.rb Dashboard generator
scripts/release_check.rb     Final artifact verification
test/                        Unit and integration tests
routing_decisions.json       Generated public decisions
routing_report.json          Generated public report
routing_observatory.html     Generated public dashboard
```

Additional documentation:

- `README.md` — operation and development guide
- `SUBMISSION_GUIDE.md` — exact hand-in package and final-hour procedure
- `LICENSES.md` — dependency and compliance inventory

---

## 17. Release state

The product is prepared for publication on a clean `main` branch containing only RouteLens source, tests, supplied data, generated evidence, presentation, and judge-facing documentation. Local agent metadata, checkpoint scripts, planning notes, source-brief working files, and presentation build intermediates are excluded.

The only unavailable external input is the competition's hidden `operations_queue_test.json`. No correct final hidden-test artifacts can be generated until that queue is issued. Once it arrives, the protected release command will generate and semantically verify the exact required files; they can then be committed and pushed to `main`.
