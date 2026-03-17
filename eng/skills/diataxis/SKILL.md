---
name: diataxis
description: >
  Write, review, or organize documentation following the Diátaxis framework.
  Use when writing docs, reviewing docs, creating tutorials, how-to guides,
  reference material, or explanatory content.
argument-hint: "[task description]"
allowed-tools: Read, Grep, Glob, Edit, Write
---

# Diátaxis documentation framework

You write and review documentation according to the Diátaxis framework by
Daniele Procida (https://diataxis.fr). Diátaxis identifies four modes of
documentation, each serving a distinct user need. **Never mix modes within a
single document.**

The source material in `${CLAUDE_SKILL_DIR}/diataxis-documentation-framework/`
is the RST source of the Diátaxis website itself. It is structured according to
its own principles: the pages on each documentation type are reference, the
compass and workflow pages are how-to guides, the foundations and map pages are
explanation, and the start-here page is a tutorial. Study the source not just
for what it says, but for how it's written.

## The compass: classifying content

Ask two questions to determine which mode content belongs to:

| Content...        | ...serves the user's... | ...belongs to |
|-------------------|-------------------------|---------------|
| informs action    | acquisition of skill    | tutorial      |
| informs action    | application of skill    | how-to guide  |
| informs cognition | application of skill    | reference     |
| informs cognition | acquisition of skill    | explanation   |

## The four modes at a glance

**Tutorial** — a lesson. Learning-oriented. The reader acquires skill by doing
things under your guidance. You are the teacher; all responsibility for success
is yours. Minimize explanation. Focus on concrete steps and visible results.

**How-to guide** — a recipe. Goal-oriented. The reader already has competence
and needs to accomplish a specific real-world task. No teaching, no explanation.
Address the user's problem, not the tool's features.

**Reference** — a map. Information-oriented. Austere, neutral, complete
technical description of the machinery. Structure mirrors the thing it
describes. One consults reference; one does not read it.

**Explanation** — a discussion. Understanding-oriented. Provides context,
background, reasoning, and connections. Answers "why?" questions. The only mode
where opinion, alternatives, and history belong.

## When to read the source material

Read the relevant page before writing or reviewing documentation of that type.
All paths are relative to `${CLAUDE_SKILL_DIR}/diataxis-documentation-framework/`.

| Task | Read |
|------|------|
| Quick overview of the framework | `start-here.rst` |
| Writing or reviewing a tutorial | `tutorials.rst` |
| Writing or reviewing a how-to guide | `how-to-guides.rst` |
| Writing or reviewing reference docs | `reference.rst` |
| Writing or reviewing explanatory docs | `explanation.rst` |
| Unsure what type of doc to write | `compass.rst` |
| Distinguishing tutorials from how-tos | `tutorials-how-to.rst` |
| Distinguishing reference from explanation | `reference-explanation.rst` |
| Organizing a large documentation set | `complex-hierarchies.rst` |
| Understanding the theory behind Diátaxis | `foundations.rst`, `map.rst` |
| Thinking about documentation quality | `quality.rst` |
| Workflow: applying Diátaxis iteratively | `how-to-use-diataxis.rst` |

## Applying this skill

When asked to write documentation:

1. **Classify** the content using the compass table above.
2. **Read** the relevant source page for the mode you're writing in.
3. **Write** following the principles in that page.
4. **Verify** that you haven't mixed modes. If a section drifts into another
   mode (e.g., explanation creeping into a how-to guide), split it out or
   remove it.

When asked to review documentation:

1. **Classify** each section by mode.
2. **Read** the relevant source pages.
3. **Assess** whether each section follows the principles for its mode.
4. **Report** mode violations, mixed content, and structural issues.

$ARGUMENTS
