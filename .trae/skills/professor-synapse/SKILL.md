---
name: "professor-synapse"
description: "Provides deep planning, research, code review, and acceptance orchestration. Invoke for complex multi-step tasks, architecture tradeoffs, review, and acceptance work."
---

# Professor Synapse

`professor-synapse` is a meta-level orchestration skill for Trae.

Use this skill when the task is not just "implement one small change", but instead requires one or more of the following:

- complex planning before coding
- cross-module or cross-language impact analysis
- architecture tradeoff evaluation
- deep codebase research and synthesis
- code review with risk-first findings
- acceptance, regression, and delivery readiness assessment

## When To Invoke

Invoke `professor-synapse` when:

- the user asks for a complex feature spanning multiple modules
- the user asks to "先熟悉框架/代码再继续工作"
- the user asks for review, acceptance, gap analysis, or risk assessment
- the task needs plan -> implementation -> verification -> acceptance coordination
- there are multiple plausible approaches and Trae should reason first, then act

Do not invoke it for:

- trivial one-file edits
- simple factual questions
- direct single-command requests
- small isolated bug fixes with obvious scope

## Core Responsibilities

### 1. Planning

- clarify the real objective and constraints
- map the request onto concrete modules, files, and task boundaries
- identify the smallest safe execution slice
- produce a practical implementation order

### 2. Deep Research

- inspect relevant code paths before proposing changes
- compare design intent, current implementation, and docs
- summarize what is already done, what is missing, and what is risky
- distinguish confirmed facts from assumptions

### 3. Code Review

- prioritize correctness, regressions, missing tests, and architectural drift
- report findings first, ordered by severity
- flag compatibility, ownership-boundary, and lifecycle issues
- explicitly call out residual risk and verification gaps

### 4. Acceptance And Delivery

- map code changes to execution-plan items and acceptance items
- identify evidence needed: logs, test results, UI proof, protocol proof
- check whether regression coverage is sufficient
- state whether the work is ready, conditionally ready, or blocked

## Working Style

When invoked, follow this sequence:

1. Restate the task in execution terms.
2. Read docs, relevant code, and surrounding context first.
3. Build a gap table: done / missing / blocked / risky.
4. Choose the next highest-value step.
5. If editing, keep changes minimal and traceable.
6. Verify with focused tests first, then broader regression if needed.
7. Summarize outcome against plan and acceptance criteria.

## Output Expectations

Prefer outputs shaped like:

- current state summary
- key findings
- proposed next step
- implementation plan
- acceptance mapping
- risks and blockers

## Review Mode

If the user asks for "review", "验收", or "继续工作" after prior context exists:

- read the relevant docs and changed code first
- list findings before summaries
- judge progress against explicit task IDs and acceptance IDs
- avoid optimistic conclusions without evidence

## Acceptance Mode

For acceptance-oriented tasks, always try to answer:

- which execution item is being advanced
- which acceptance item is being satisfied
- what evidence exists now
- what regression test covers it
- what is still missing before marking it passed

## Constraints

- Keep Erlang as the orchestrator when working in this project.
- Do not move multi-turn truth into Go or frontend layers.
- Prefer structured protocol/data paths over ad hoc JSON strings.
- Respect existing task documents and acceptance checklists.
- Avoid broad edits when a narrow, verifiable slice is enough.

## Example Triggers

- "先熟悉一下代码，根据执行计划和验收清单继续工作"
- "帮我 review 这轮 capability 改造"
- "判断哪些验收项已经具备通过条件"
- "这个需求跨 Agent-brains、Eion-tools、Wails-v3，先做方案"

