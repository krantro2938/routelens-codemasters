# RouteLens Submission Guide

**Team: Codemasters**

## What we will actually turn in

The official submission should be the complete RouteLens Git repository on the `main` branch, with the two hidden-test JSON artifacts in the repository root.

The essential hand-in is:

```text
RouteLens repository on main
├── routing_decisions_test.json   REQUIRED
├── routing_report_test.json      REQUIRED
├── README.md                     Entry point for judges
├── bin/                          Runnable commands
├── config/                       Routing policy
├── lib/                          Ruby implementation
├── scripts/                      Validation and release checks
├── test/                         Automated evidence
├── data/                         Supplied inputs and references
├── demo/                         Retry/fallback evidence
├── routing_observatory.html      Judge-facing dashboard
├── IMPLEMENTATION_SUMMARY.md     Complete achievement report
├── SUBMISSION_GUIDE.md           Final release playbook
├── presentation/                 Russian-language defense deck
└── LICENSES.md                   Compliance evidence
```

The submission is not merely two JSON files. The JSON files are mandatory scoring artifacts, while the code, tests, configuration, documentation, dashboard, and demo prove the remaining technical and industry criteria.

---

## 1. Mandatory final artifacts

### `routing_decisions_test.json`

This must:

- be named exactly `routing_decisions_test.json`;
- be located in the repository root;
- exist on the remote `main` branch;
- contain every operation from `operations_queue_test.json` exactly once;
- contain no unrelated operation IDs;
- be valid JSON;
- be a JSON array;
- preserve all required fields.

Required decision structure:

```json
{
  "operation_id": "op_123",
  "selected_provider": "provider_name",
  "attempts": [
    {
      "provider": "provider_name",
      "decision": "selected",
      "reason": "highest_policy_score"
    }
  ],
  "simulated_result": "approved",
  "latency_sec": 30
}
```

RouteLens adds explanation fields, but the mandatory fields must never be removed or renamed.

### `routing_report_test.json`

This must:

- be named exactly `routing_report_test.json`;
- be located in the repository root;
- exist on remote `main`;
- be valid JSON;
- be a JSON object;
- describe the same hidden-test decisions;
- contain correct totals and distributions;
- contain routing recommendations.

The report will include the required fields plus extended evidence:

- count distribution;
- volume distribution;
- target deviations;
- outcome metrics;
- latency;
- hard skip reasons;
- soft policy non-selections;
- retries and fallbacks;
- provider capacity;
- historical comparison;
- unmet goals;
- human-readable recommendations;
- structured recommendation details.

These two files are worth **40 technical-jury points** and must receive the highest release priority.

---

## 2. What is ready now versus what is final

### Ready public evidence

The repository currently contains:

- `routing_decisions.json` — results for the supplied public ten-operation queue;
- `routing_report.json` — analytics for that public run;
- `routing_observatory.html` — dashboard for the public run;
- `demo/resilience_decisions.json` — controlled external retry and fallback demonstration;
- `demo/resilience_report.json` — final-outcome and provider-attempt analytics;
- `demo/resilience_observatory.html` — judge-facing resilience and policy replay view;
- `demo/policy_comparison.json` — deterministic preset and recommendation comparison.

These files are useful for development, checkpoints, and the defense. They do **not** replace the two final hidden-test artifacts.

### Not available yet

The competition has not yet supplied `operations_queue_test.json`. Therefore, the repository should not pretend that the public queue is the hidden queue or rename public artifacts as final answers.

When the real hidden queue arrives, run the official release command and commit the newly generated test artifacts.

---

## 3. One-command final generation

Place the competition file here:

```text
./operations_queue_test.json
```

Then run from the repository root:

```bash
bin/release_test_case
```

The command is intentionally protected. It always uses:

```text
Input queue:  operations_queue_test.json
Decisions:    routing_decisions_test.json
Report:       routing_report_test.json
Branch goal:  main
```

The required paths cannot be overridden through the release command. Use `bin/route` only for custom experiments.

The release command performs two stages:

1. Route the hidden queue and atomically write both JSON artifacts.
2. Run `scripts/release_check.rb` against the hidden queue and outputs.

Success ends with:

```text
Release check passed: decisions and report are structurally and semantically complete.
```

---

## 4. Final-hour procedure

One person must be designated **release captain**. That person owns the final queue file, commands, commit, push, and remote verification. The release captain should not be simultaneously changing the routing engine.

### Minute 00–05: receive the queue

- Download or copy the official `operations_queue_test.json`.
- Place it in the repository root.
- Do not edit its contents manually.
- Confirm the filename has no duplicate extension or trailing characters.

Check:

```bash
ls -l operations_queue_test.json
ruby -rjson -e 'data=JSON.parse(File.read("operations_queue_test.json")); abort "expected array" unless data.is_a?(Array); puts "operations=#{data.size}"'
```

### Minute 05–10: protect the working state

```bash
git status --short --branch
git branch --show-current
```

Required result:

- current branch is `main`;
- no unexplained local changes exist;
- the queue is the only expected new competition input.

### Minute 10–20: generate final artifacts

```bash
bin/release_test_case
```

Do not rename generated files manually.

### Minute 20–30: validate structure and coverage

```bash
ruby scripts/release_check.rb \
  --queue operations_queue_test.json \
  --decisions routing_decisions_test.json \
  --report routing_report_test.json
```

If the organizers provide a hidden-test validator, run it exactly as documented.

### Minute 30–40: independent semantic review

A second team member should inspect:

- every operation ID is present;
- unique-provider cases select the only eligible provider;
- no selected external provider violates amount, bank, status, margin, capacity, requisite, or RPM rules;
- SpacePayments appears only after the external pool is exhausted;
- retry sequences release failed providers correctly;
- final selected providers match final attempt outcomes;
- reason codes and details match the actual constraint;
- report totals equal the decision file;
- distributions sum to the complete batch;
- recommendations are supported by report metrics.

Useful checks:

```bash
jq 'length' operations_queue_test.json
jq 'length' routing_decisions_test.json
jq '.total_operations' routing_report_test.json
jq '[.[].operation_id] | length == unique.length' routing_decisions_test.json
```

### Minute 40–45: regenerate the dashboard

```bash
bin/observatory \
  --decisions routing_decisions_test.json \
  --report routing_report_test.json \
  --output routing_observatory.html
```

Open it and inspect at least:

- one normal multi-provider decision;
- one unique-provider decision;
- one retry or fallback, if present;
- the highest-utilization provider;
- the leading recommendation.

### Minute 45–50: stage and inspect

```bash
git add operations_queue_test.json \
  routing_decisions_test.json \
  routing_report_test.json \
  routing_observatory.html

git diff --cached --check
git status --short
```

Confirm that the two required JSON files appear with their exact names in the repository root.

### Minute 50–54: commit

```bash
git commit -m "feat: add final test routing artifacts"
```

### Minute 54–57: push

```bash
git push origin main
```

### Minute 57–60: verify the remote submission

Use the remote repository interface to verify:

- branch shown is `main`;
- latest commit is the final artifact commit;
- `routing_decisions_test.json` is visible at repository root;
- `routing_report_test.json` is visible at repository root;
- both files open as valid JSON;
- the commit timestamp is before stop code.

Do not use the last minutes for feature changes.

---

## 5. Complete technical hand-in

### Required implementation

The complete `lib/route_lens/` directory should be submitted. It contains:

- input validation;
- provider state;
- hard constraints;
- configurable scoring;
- routing and retries;
- deterministic simulation;
- historical analysis;
- reporting;
- recommendations;
- observatory generation.

### Required commands

Submit the `bin/` directory:

| Command | Purpose |
|---|---|
| `bin/route` | General routing command |
| `bin/release_test_case` | Protected final hidden-queue generation |
| `bin/observatory` | Offline dashboard generation |

### Configuration

Submit `config/routing.yml`. It proves that:

- strategy weights can change without engine changes;
- preferred amount bands are soft business preferences;
- volume targets are distinct from count targets;
- minimum turnover obligations are configurable;
- normalizers are configurable.

### Tests

Submit the complete `test/` directory. It is direct evidence for engineering quality, extensibility, failure handling, boundary behavior, and correctness.

### Validation scripts

Submit:

- the supplied `scripts/validate_10.rb`;
- the added `scripts/release_check.rb`.

### Documentation

Submit:

- `README.md` as the judge entry point;
- `IMPLEMENTATION_SUMMARY.md` as the detailed achievement report;
- `LICENSES.md` as open-source and no-neural-network evidence;
- this `SUBMISSION_GUIDE.md` as the release playbook.

---

## 6. Checkpoint package

At each expert checkpoint, show the repository in a runnable state rather than presenting future architecture.

Recommended evidence:

1. Run `ruby bin/route`.
2. Run the public validator.
3. Open `routing_observatory.html`.
4. Inspect `op_103` to show hard amount exclusions.
5. Show Payflow near its daily limit.
6. Open the resilience demo and show `vipay → payflow → quickpay`, then Quickpay-to-SpacePayments fallback.
7. Show the Policy Lab comparison and the replayed 40/10/50 target recommendation.
8. Run the test suite.

Checkpoint files to have immediately accessible:

- `README.md`
- `routing_decisions.json`
- `routing_report.json`
- `routing_observatory.html`
- `demo/resilience_decisions.json`
- `demo/resilience_observatory.html`
- `demo/policy_comparison.json`
- `config/routing.yml`

---

## 7. Defense package

The final defense should use four proof surfaces:

The prepared five-slide Russian deck is `presentation/RouteLens_Defense_RU.pptx`. It is backed by the generated public and resilience artifacts and keeps its evidence tables and policy comparison chart editable.

### 1. Architecture

Show the pipeline from hard filtering to policy scoring, reservation, retry, and reporting. Keep this to one diagram.

### 2. Normal decision

Use a decision with multiple eligible providers. Show:

- selected provider;
- lower-ranked eligible alternatives;
- raw factors and weighted contributions;
- final provider-state update.

### 3. Forced failure

Use the provided retry demonstration:

```text
quickpay (expired) → spacepayments (approved)
```

Explain that the failed reservation was fully released before fallback.

### 4. Business analytics

Show:

- actual versus target distribution;
- Payflow capacity at approximately 99.6%;
- live-versus-historical conversion drift;
- the exact recommendation and proposed parameter value.

Recommended closing line:

> RouteLens does not only choose a provider. It proves that the choice was valid, shows how business policy affected it, survives provider failure, and tells operators what to improve next.

---

## 8. What not to do

- Do not rename public files to `_test` and present them as hidden-test results.
- Do not manually edit generated provider selections unless the engine is fixed and rerun.
- Do not remove mandatory fields to make JSON smaller.
- Do not place required files inside `data/`, `output/`, or `demo/`.
- Do not submit only a development branch.
- Do not assume a successful local commit means the remote contains the files.
- Do not include neural-network or hosted AI functionality in the runtime.
- Do not add a closed-source dependency for the presentation.
- Do not bypass a hard rule to improve a traffic target.
- Do not use SpacePayments as a normal high-conversion candidate.
- Do not make feature changes during the final remote-verification minutes.

---

## 9. Failure handling during final submission

### The release command reports invalid input

- Do not edit the queue blindly.
- Read the precise validation error.
- Compare the hidden field with the documented public schema.
- If the hidden schema legitimately extends the public schema, update only the input adapter and add a regression test.

### The provided validator rejects a selected provider

- Inspect that operation's `attempts` and `all_reasons`.
- Recalculate the selected provider's hard constraints against state at that point in sequence.
- Fix the hard rule or state transition.
- Rerun the entire queue from the original provider snapshot.
- Never patch one output row manually.

### Report totals do not match decisions

- Delete neither source input nor decisions.
- Rerun the report from the complete RouteLens command.
- Run `scripts/release_check.rb` again.

### Push fails

- Preserve the local commit.
- Check the remote URL and current branch.
- Retry the non-destructive push.
- Verify the remote after success.

### Time is almost exhausted

Priority order:

1. Valid `routing_decisions_test.json`
2. Valid `routing_report_test.json`
3. Commit on `main`
4. Push and remote verification
5. Dashboard regeneration
6. Any optional presentation polish

---

## 10. Final checklist

### Repository

- [ ] Remote repository is configured.
- [ ] Current branch is `main`.
- [ ] Working tree contains no unexplained changes.
- [ ] Latest implementation and documentation are committed.
- [ ] Ruby remains the clear majority of implementation code.
- [ ] No neural-network or proprietary runtime dependency was added.

### Hidden input

- [ ] Official `operations_queue_test.json` is in repository root.
- [ ] File is valid JSON and contains an array.
- [ ] Operation IDs are unique.
- [ ] Original competition file was not manually modified.

### Required artifacts

- [ ] `routing_decisions_test.json` exists in repository root.
- [ ] `routing_report_test.json` exists in repository root.
- [ ] Both files parse as JSON.
- [ ] Every hidden operation has exactly one decision.
- [ ] No extra operations appear.
- [ ] Every decision contains the required fields.
- [ ] Every attempt contains provider, decision, and reason.
- [ ] Report total equals decision count.
- [ ] Report distributions and recommendations are present.

### Verification

- [ ] `bin/release_test_case` completes successfully.
- [ ] Organizer validator completes successfully.
- [ ] Independent team member reviewed deterministic and boundary cases.
- [ ] Dashboard was regenerated from final test artifacts.
- [ ] Final commit was created on `main`.
- [ ] Final commit was pushed before stop code.
- [ ] Both required files were opened and verified on the remote repository.

---

## 11. Current submission status

At the time this guide was written:

- the RouteLens implementation is complete;
- public decisions and analytics are generated;
- the public validator passes with 29 checks, 0 errors, and 0 warnings;
- 81 tests and 378 assertions pass;
- deterministic replay is verified;
- the observatory is generated and browser-tested;
- the clean product-only repository is published from `main`;
- the official hidden `operations_queue_test.json` has not yet been provided.

When the hidden queue arrives, run `bin/release_test_case`, review the results, commit the exact test artifacts, push `main`, and verify them remotely.
