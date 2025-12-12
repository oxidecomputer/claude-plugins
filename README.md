# Oxide Claude Code Plugins

This repo is a Claude [plugin
marketplace](https://code.claude.com/docs/en/plugin-marketplaces) for Oxide. For
now, there is only one plugin, called `eng`, and the point of it is to collect
[skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview). A skill is a directory containing a markdown file that tells Claude
how to do a task, plus whatever additional scripts and reference documents it might need. Skills are are not loaded into context unless they are needed. The [skill docs](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) explain when skills are loaded into context.

## Installation

```
/plugin marketplace add oxidecomputer/claude-plugins
/plugin install eng@oxide
```

This will make the skills in the plugin available to Claude. To use a skill, you
can say "use the ... skill to ...". Claude can also decide on its own when to
use a skill based on the skill's name and description.

## Updating

After new skills are pushed to this repo, pull updates with:

```
/plugin marketplace update oxide
```

## Adding a skill

Add skills that might be useful to others. Add a directory `eng/skills` with a `SKILL.md` in it, like `eng/skills/my-new-skill/SKILL.md`. Make sure the skill has a `description` in the YAML frontmatter that will help Claude decide when to use it.

See the [skills overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) and [skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices) from Anthropic.
