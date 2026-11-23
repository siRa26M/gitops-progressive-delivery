# 15-minute live walkthrough

Pre-flight (before the call): `./bootstrap.sh` done, all apps `Synced/Healthy`.
Open three panes: **A** Argo CD UI, **B** `make watch ENV=prod` (or the Rollouts dashboard), **C** a terminal.

| Time | Segment | Command (pane C) | What to point at |
|---|---|---|---|
| 0:00 | **Orientation** | `tree -L 3 -I app` · `make status` | platform/ vs apps/ split, ApplicationSet = 1 app per overlay dir, AppProjects |
| 2:00 | **Version update (dev)** | `make release ENV=dev TAG=1.1.0` | commit → Argo CD OutOfSync → Rollout canary 50% → `make traffic ENV=dev` shows the split → promoted |
| 4:30 | **Promote forward** | `make promote FROM=dev TO=prod` | same artifact, prod's slower 10/25/50/75 profile, AnalysisRun `Running` → `Successful` |
| 7:00 | **Secret rotation** | `make rotate ENV=prod` then `watch -n5 curl -s prod.127.0.0.1.nip.io/secret` | only ciphertext in the diff (`git show --stat`), fingerprint flips, **no pod restart** |
| 9:30 | **Drift** | `make drift ENV=prod` | replicas, deleted NetworkPolicy, broken Service port all reverted; prints seconds-to-heal |
| 11:00 | **Bonus: auto-rollback** | `make bad-release ENV=prod TAG=1.2.0` | canary at 10% → 5xx ratio > 5% → AnalysisRun `Failed` → weights snap to stable 100 → `Degraded`; `make traffic ENV=prod` is clean again |
| 13:30 | **Close the loop** | `make revert` | Git == reality, app returns to `Healthy`; recap the evaluation matrix |

## Talking points / likely questions

- **"Why not CI push-deploys?"** CI has no cluster credentials. The cluster pulls, so the cluster's state is always explained by a Git commit, and drift is detectable.
- **"What if the Sealed Secrets key is lost?"** It's backed up outside Git. In production it lives in a KMS. Losing it means resealing from the source of truth, not data loss.
- **"Why does the app stay Degraded after rollback?"** By design: Git says 1.2.0 but the cluster runs 1.0.0. The revert commit makes intent and reality agree again, and leaves an audit trail.
- **"Blue/Green?"** Change `strategy.canary` to `strategy.blueGreen` with `activeService`/`previewService` and a `prePromotionAnalysis` using the same AnalysisTemplate. It's one overlay patch.
- **"Scaling to many services/clusters?"** Add a list or cluster generator to the ApplicationSet. Base and overlay stay per service. Platform values are shared.
- **"Why ignoreDifferences on TraefikService?"** Rollouts owns runtime weights. Without the exclusion, self-heal would reset the canary to 0% mid-rollout.
