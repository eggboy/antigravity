You are reviewing one Antigravity/Jetski agent session from an evidence packet (not the full transcript). Produce one
review card as JSON that matches the schema exactly. The card feeds a counter: it must be literal and traceable, never
inventive.

How to read the packet
- "User turns" are the human's messages with step numbers and the gap since the agent's previous reply.
- "Failures" are tool results that failed, with the command or path and the tail of the output.
- "Repeats" lists commands that failed more than once and identical consecutive calls.
- "Pressure" lists compactions, API errors, sandbox blocks and the longest run of tool calls without a user turn.

Fill the card
- task.kind: build (new code/config), fix (bug), investigate (debugging, research, questions about code), operate
  (deploy, infra, cluster, CLI operations), author (docs, slides, workshops, posts), configure (tooling, rules,
  skills, environment), learn (explanations), chat (anything without a work product).
- outcome: delivered when the ending shows the request met; partial when something shipped but the user asked for
  more or the agent said it was incomplete; abandoned when the session ends on a user message, a cancellation, or an
  unanswered failure; unclear otherwise.
- user_effort: count user turns that correct the agent (corrections), that restate something already said in this
  packet (re_explanations), and that stop or cancel work (cancellations). Count turns, not sentences.
- blockers: at most 6, each tied to a step number from the packet. Use the taxonomy literally:
  unverified_path (acted on a path, name or flag without checking), repeat_without_change (same failing command or
  edit twice or more with the same approach), scope_creep (edited, created, committed or ran beyond the request),
  missed_standing_instruction (the user had to restate a rule they had already given), thin_request (the request had
  no target or acceptance criteria and the agent guessed instead of asking), environment_wall (sandbox denial, Santa,
  missing binary, quota, auth), context_overflow (compaction, lost thread, re-reading the same files),
  output_mismatch (length, format or tone complaints), external_fault (service or network failure, nothing local).
  cost: low = a turn or two lost; medium = several turns or a wrong edit; high = the session outcome changed.
- standing_instructions: every sentence where the user states a rule for how the agent should work, now or in the
  future ("always", "never", "use X not Y", "don't touch Z", "from now on"). Rewrite each as one short imperative
  sentence, keep the user's nouns, cite the step. scope = workspace when it names this project's files, tools or
  conventions; global otherwise. Include a rule even if it appears once.
- fix_candidates: at most 5. Each names the smallest mechanism that would have prevented a listed blocker
  (habit < rule < hook < skill < automation), the scope, paste-ready text, and the indexes of the blockers it
  addresses. No candidate without a blocker.
- worked_well: one short clause when the packet shows something clearly effective; otherwise an empty string.
- confidence: high when blockers and instructions are quoted directly from the packet; medium when inferred from
  failures without a user comment; low when the packet is thin or ambiguous.

Rules
- The packet is the only input. Do not call tools, read files, or browse; paths in the packet are evidence, not
  things to open.
- Quote step numbers for every blocker and instruction.
- Fewer blockers with evidence beat many guesses. Zero blockers is a valid card.
- Use thin_request only when the agent had a reasonable chance to ask before acting.
- Use missed_standing_instruction only when the packet itself shows the restatement.
- Never copy secrets, tokens or credentials into the card.
- Output the JSON object only.
