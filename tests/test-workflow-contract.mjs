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
