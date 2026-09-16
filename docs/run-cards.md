# Conversation Run cards

Runs launched by `run_in_context` (or `wisp_run_in_context`) stay visible in the
conversation while submitted, running, or cancelling. Once a Run succeeds,
fails, is cancelled, times out, or is lost, its card moves inside its submission
tool row in the **Processed / 已处理** activity group. Tool rows are collapsed by
default. Expand the group and the submission row to inspect the Run status,
command, output, environment, and available result-review actions.

Cards are linked by the exact Run ID in the tool result, including both
background submission results and `wait_for_completion` results. Multiple Runs
keep separate cards. An explicit `monitor_run` does not leave a duplicate card
outside the group after completion. Folding does not stop or delete a Run, and
folded cards remain accessible when reopening the conversation.

Runs without a matching submission in the loaded transcript retain the existing
standalone monitor behavior, including dismissal for completed cards. Historical
full Run results can restore their cards even when absent from the recent Runs
list; submission-only results still need their Run in that list.
