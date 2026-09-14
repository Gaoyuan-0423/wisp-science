# Skill → independent Workflow: CLI experiment

Related: [#1018](https://github.com/xuzhougeng/wisp-science/issues/1018).

## Design boundary

A Skill is conversion input. The resulting Workflow owns its instructions,
dependencies, capability requests and output contracts. A node does not mean
“load this Skill and interpret it again.” Source documents remain provenance,
not runtime dependencies. Main Agents can still use Skills directly.

The first implementation adds CLI tools `create_workflow`, `explain_workflow`
and `run_workflow`. The converter reads the source and Markdown references,
asks the configured LLM for the existing shared DTO proposal, and validates it
with the core capability resolver. The CLI runner uses the existing dependency
executor, fresh Agent contexts and filtered tools. No new Skill frontmatter
or sidecar is required. Nonempty legacy `skill_ids` are rejected by this path.

The CLI acceptance below established the shared execution boundary. The desktop
follow-up now uses the converter in its chat tool and Studio, replaces the node
Skill picker with source conversion, preserves legacy templates/history for
explicit migration, and routes child confirmations to the owning conversation.
See [Agent delegation](../../agent-delegation.md) for current desktop behavior.

## Real bear-support acceptance, 2026-09-14

- Source: `fei0810/bear-research-skills`, commit
  `c31d6eb9c63ca5b29de0f75f439ee43e51571f34`.
- Documents: `SKILL.md`, `references/sci-cli.md`,
  `references/output-system.md` (42,904 bytes total).
- Conversion-source SHA-256:
  `ce34894d3916ed94ed7f9760d5effef1d3e983db7ca7bb9e89b73dad63d91bab`.
- Configured model: `glm-5.2`; installed SciMaster CLI: `0.3.11`.
- The real CLI Agent called `create_workflow`, then `explain_workflow`.
  The test driver did not hand-author the proposal.
- Saved template ID: `de9bceb4-7f8d-41ea-b553-8148d1552b5c`.

The model generated these six nodes, all without Skill bindings:

| Node | Dependencies | Capabilities |
| --- | --- | --- |
| preflight | — | code_run |
| extract_claims | — | reasoning |
| run_searches | preflight, extract_claims | code_run |
| assess_evidence | run_searches | reasoning, code_run, project_read |
| render_reports | run_searches, assess_evidence | code_run, project_write, reasoning |
| verify_deliverables | run_searches, assess_evidence, render_reports | reasoning, code_run, project_read |

The source Skill directory was moved out of the test project before the full
execution. The request was a single claim, “开放获取论文通常获得更多引用”, limited
to one English query in low mode with limit 10. The search node executed
`sci search "open access citation advantage" --limit 10 --mode low ...` and
received five records. This is an observed test result, not an expected fixed
answer for future retrievals.

The Workflow produced `report.md`, self-contained `report.html`,
`references.bib`, an evidence ledger, raw JSON/BibTeX and a verification report.
The final execution result is **succeeded, six successful nodes**, with seven
verified file snapshots. It was **not a clean first attempt**:

1. An initial run exposed a host bug: the child prompt contained the generic
   role and global context but omitted `AgentSpec.goal`, which carries the
   assigned task. Preflight consequently attempted downstream work. The run
   was stopped, partial outputs retained, and the injection fixed. A regression
   now inspects the actual model request for each assigned node instruction.
2. The corrected full run completed the first five nodes. Verification hit
   the existing conservative command rule for the word `format` inside its
   Python script. The initial child adapter denied confirmations locally.
   The implementation now forwards these decisions to the console/RPC host
   without bypassing the safety rules.
3. A retry reused the five successful nodes only after rechecking the plan,
   contracts and file hashes. It executed just `verify_deliverables`; it did
   not repeat retrieval or rendering. Final run ID:
   `478436fc-14f0-458b-b880-60bf46adbb1b`.
4. The verification Agent corrected false positives in its own comparison
   script (author whitespace, asymmetric BibTeX extraction, quote glyphs and
   abbreviated author names). It recorded those corrections and reported
   seven checks passing. All scientific judgments remain Agent assessments;
   this is not a human peer review.

An independent inspection also checked evidence membership against raw
retrieval, citations in both report formats, unchanged BibTeX keys, absence
of external HTML assets, exactly one search in the retrieval node, no runtime
`use_skill` calls and the stored file hashes.

Local acceptance artifacts are under
`target/workflow-acceptance/bear-support/`: the generated `workflow.json`,
source hash manifest, reports, independent checks and complete attempt logs.
Upstream method documents are not bundled into the repository; their upstream
license remains applicable.

## Automated verification

Eleven offline Workflow regressions exercise the real Agent loop, conversion
tool, core resolver/executor and file tools with scripted providers. They cover
reference inclusion, independent execution after source removal, task prompt
injection, tool filtering, missing/escaped artifacts, unavailable capabilities,
legacy bindings, cyclic dependencies, failed command results, plan/child
approval denial, local synchronous Run enforcement and hash-checked retry.

Final CLI suite: **45 passed**. Formatting and whitespace checks passed.
All workspace packages were tested successfully, with Run tests run serially
and the rest tested using `--workspace --exclude wisp-runs`. The unchanged
`auto_harvest_skips_collect_when_already_harvested` test failed in concurrent
workspace runs with `Run lifecycle lease was lost`; it passed alone and in
the full serial Run suite (**174 passed**). Local fake HTTP servers and process
tests required running outside the restricted tool sandbox. No automated test
used the real search service or model key; the acceptance run above was manual.

## What this proves, and what it does not

The experiment demonstrates that Wisp CLI can call a conversion tool and run
an independently persisted Workflow derived from an unchanged third-party
Skill. It also demonstrates why role prompts alone are insufficient: the host
must supply the actual task, enforce resource boundaries, preserve approval
decisions, check results and support explicit failure recovery.

The process is not a deterministic compiler for arbitrary natural-language
methods. The model-generated verification script itself needed correction.
Converting and freezing reusable validation code, rather than recreating it
on each run, is a concrete follow-up to evaluate. The positive single-claim
run does not validate every ambiguity, empty-result or multi-claim branch of
bear-support.

The scope of this CLI experiment is local Native execution with reasoning, project file
tools and synchronous Runs. Packaged scripts/runtime sidecars, MCP, remote
execution, Specialist overrides, process-interruption recovery and desktop
timeline integration are not implemented in this path. Local commands are
not OS-sandboxed. Use a disposable project with clean output directories for
fresh acceptance runs; retries preserve and validate existing outputs.

See [headless testing instructions](../../headless-agent-testing.md) for usage.
