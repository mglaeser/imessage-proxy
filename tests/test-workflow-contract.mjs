// Checks that the release gate names checks that some workflow actually
// produces.
//
// This exists because of a specific failure: the release job required a check
// called "Caddy Unix-socket edge (ARM64)", the job that produced it was deleted
// with the Caddy edge itself, and nothing connected the two. The gate could then
// never pass, so v1.0.0 sat as a draft with no assets for a week while every
// other signal stayed green. Nothing in the repository could have told you -
// actionlint validates each workflow in isolation, and a required check that no
// workflow emits is valid YAML in a valid workflow.
//
// The rule is one sentence: every name release.yml waits for must be a job name
// some workflow declares. A check that cannot be produced is not a stricter
// gate, it is a gate that is closed forever.

import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const workflowDirectory = new URL("../.github/workflows/", import.meta.url);
const workflowFiles = (await readdir(workflowDirectory))
  .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  .sort();

const workflows = await Promise.all(
  workflowFiles.map(async (name) => ({
    name,
    text: await readFile(new URL(name, workflowDirectory), "utf8"),
  })),
);

// A job's display name sits at four spaces of indentation, directly under the
// two-space job key. A step's sits at six and starts with a dash, so anchoring
// on the exact indentation separates them without a YAML parser. The assertion
// below that every workflow yields at least one name is what keeps this honest:
// if the indentation convention ever changes, this file fails rather than
// quietly matching nothing and passing.
function jobNames(text) {
  return Array.from(text.matchAll(/^ {4}name: (.+)$/gm), (match) => match[1].trim().replace(/^['"]|['"]$/g, ""));
}

// The trigger block runs from `on:` to the next key at column zero. Read as text
// for the same reason job names are: one convention, checked, beats a dependency.
function triggerBlock(text) {
  const match = text.match(/^on:\n([\s\S]*?)(?=^\S)/m);
  return match === null ? "" : match[1];
}

// Whether a workflow runs when a commit lands on main. A gate waits on a check
// attached to one specific commit, so a workflow that runs only on a schedule or
// only on pull requests produces that check somewhere other than where the gate
// looks.
function runsOnPushToMain(text) {
  // Read line by line rather than by regex. The obvious pattern for "up to the
  // next key or the end" spells the end as `$`, which under /m is the end of a
  // line, so the push block gets cut to its first line and every workflow reads
  // as not running on main.
  const body = [];
  let inPush = false;
  let hasPush = false;
  for (const line of triggerBlock(text).split("\n")) {
    if (/^ {2}\S/.test(line)) {
      inPush = line.trimEnd() === "  push:";
      hasPush = hasPush || inPush;
    } else if (inPush && line.trim() !== "") {
      body.push(line);
    }
  }
  if (!hasPush) {
    return false;
  }
  // A push filtered by branch has to name main. A push filtered by tag - which
  // is what release.yml itself does - fires on no branch at all. Only a bare
  // push, filtered by neither, fires on every branch and so on main.
  if (body.some((line) => /^ {4}branches:/.test(line))) {
    return body.some((line) => /^ {6}- main$/.test(line));
  }
  return !body.some((line) => /^ {4}tags:/.test(line));
}

const releaseWorkflow = workflows.find((workflow) => workflow.name === "release.yml");

test("every workflow declares at least one named job", () => {
  assert.ok(workflows.length > 0, "no workflow files were found");
  for (const workflow of workflows) {
    assert.ok(
      jobNames(workflow.text).length > 0,
      `${workflow.name} yielded no job names; the four-space convention this file reads has changed`,
    );
  }
});

test("every check the release gate requires is a job some workflow produces", () => {
  assert.ok(releaseWorkflow, "release.yml must exist");

  // The gate is a bash for-loop of single-quoted names ending in `; do`.
  const loop = releaseWorkflow.text.match(/for required_check in \\\n([\s\S]*?); do\n/);
  assert.ok(loop, "release.yml must gate on a `for required_check in ...; do` list");

  const required = Array.from(loop[1].matchAll(/'([^']+)'/g), (match) => match[1]);
  assert.ok(required.length > 0, "the required-check list must not be empty");

  const produced = new Set(workflows.flatMap((workflow) => jobNames(workflow.text)));
  for (const name of required) {
    assert.ok(
      produced.has(name),
      `release.yml requires a check no workflow produces: ${name}. ` +
        `Produced names: ${[...produced].sort().join(", ")}`,
    );
  }
});

test("the release gate still requires the checks that carry the build", () => {
  // The inverse mistake is deleting a name from the gate to make a release go
  // out. These three are what actually compile, test and scan the artifact;
  // dropping one buys a green release that proves nothing.
  const loop = releaseWorkflow.text.match(/for required_check in \\\n([\s\S]*?); do\n/);
  const required = new Set(Array.from(loop[1].matchAll(/'([^']+)'/g), (match) => match[1]));
  for (const name of ["Build, lint, analyze, and test", "Workflows and API contract", "Gitleaks"]) {
    assert.ok(required.has(name), `release.yml no longer requires ${name}`);
  }
});

test("every check the release gate requires runs on a push to main", () => {
  // Producing the check somewhere is not enough. The gate reads the check runs
  // attached to the tagged commit, and a tag points at a commit on main, so a
  // required check has to be one that a push to main produces. A workflow moved
  // to schedule-only, or narrowed to pull_request, would still declare the job
  // and would still satisfy the test above, while deadlocking the release
  // exactly as the deleted Caddy job did - the gate would wait for a check that
  // never appears on that commit.
  const loop = releaseWorkflow.text.match(/for required_check in \\\n([\s\S]*?); do\n/);
  const required = Array.from(loop[1].matchAll(/'([^']+)'/g), (match) => match[1]);

  // Guard the reader itself: if the trigger convention changes shape, fail here
  // rather than silently deciding that nothing runs on main.
  const onMain = workflows.filter((workflow) => runsOnPushToMain(workflow.text));
  assert.ok(onMain.length > 0, "no workflow was read as running on a push to main; the `on:` convention has changed");

  for (const name of required) {
    const producers = workflows.filter((workflow) => jobNames(workflow.text).includes(name));
    assert.ok(producers.length > 0, `no workflow declares a job named ${name}`);
    assert.ok(
      producers.some((workflow) => runsOnPushToMain(workflow.text)),
      `${name} is declared by ${producers.map((w) => w.name).join(", ")}, none of which runs on a push to ` +
        `main, so the check will never appear on a tagged commit and the release gate cannot pass`,
    );
  }
});
