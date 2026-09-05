# Dependency and License Inventory

RouteLens is implemented with Ruby and its standard library. It does not use neural-network models, hosted decision services, proprietary routing engines, or closed-source runtime dependencies.

## Runtime components

| Component | Purpose | License |
|---|---|---|
| Ruby | Runtime | Ruby License / BSD-2-Clause |
| `json` | JSON parsing and generation | Ruby standard library |
| `csv` | Historical-operation parsing | Ruby standard library |
| `yaml` / Psych | Policy configuration | Ruby standard library |
| `digest` | Deterministic simulation keys | Ruby standard library |
| `optparse` | Command-line interface | Ruby standard library |
| Minitest | Automated tests | MIT; shipped with Ruby |
| Rake | Test task | MIT; commonly shipped with Ruby |

## Compliance statement

- The routing decision is deterministic policy code, not an AI or machine-learning model.
- No operation or provider data is sent to an external service.
- The project can run offline after Ruby is installed.
- The implementation is primarily Ruby; any generated HTML/JavaScript visualization is an optional read-only presentation layer.
