/**
 * `scripts/bump-version.sh`, the file set it exists to keep in step, and the release workflow's
 * `version` input.
 *
 * The 0.5.1 bump is the case this pins. It moved `package.json`, its lockfile and the README,
 * and it left the release workflow's `version` default behind at 0.4.6, so a dispatch that took
 * the default failed the workflow's own assertion — `package.json version 0.5.1 != release
 * 0.4.6` — before it reached a tag. The default is gone; the input is required, and the last
 * test here holds it that way.
 *
 * The script is run, for real, on a copy of the checkout that this file takes itself under
 * `.tmp/` — never on the working tree, which no case below can reach. The copy is taken with
 * `cpSync`, so it carries no history and the test needs no `git`; what it compares is the copy's
 * own file set before and after the run, hashed, so a script that starts editing a third file
 * fails here rather than in someone's release.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, readlinkSync, rmSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const ROOT = resolve(here, '..');

/** Every file this repository keeps its own version in, and no other. */
const CARRIES_THE_VERSION = ['package.json', 'package-lock.json'];

/** Never copied into the copy: dependencies, history, the vendored engine, and this test's area. */
const NOT_COPIED = new Set(['node_modules', '.git', '.tmp', '.worktrees']);

/** The version a case bumps to, which is not one this repository has ever carried. */
const BUMPED_TO = '9.8.7';

function freshCopy(name: string): string {
  const dest = join(ROOT, '.tmp', `bump-version-${name}-${String(process.pid)}`);
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(ROOT, { withFileTypes: true })) {
    if (NOT_COPIED.has(entry.name)) continue;
    cpSync(join(ROOT, entry.name), join(dest, entry.name), {
      recursive: true,
      filter: (source) => !relative(ROOT, source).split(sep).some((part) => NOT_COPIED.has(part)),
    });
  }
  return dest;
}

/** Every file under `root`, by path, as its content's digest. A symbolic link is its target. */
function tree(root: string): Map<string, string> {
  const files = new Map<string, string>();
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(path);
      } else if (entry.isSymbolicLink()) {
        files.set(relative(root, path), `link -> ${readlinkSync(path)}`);
      } else {
        const digest = createHash('sha256').update(readFileSync(path)).digest('hex');
        files.set(relative(root, path), digest);
      }
    }
  };
  walk(root);
  return files;
}

/** The files two readings of a tree disagree about, added and removed ones included. */
function changed(before: Map<string, string>, after: Map<string, string>): string[] {
  const names = new Set([...before.keys(), ...after.keys()]);
  return [...names].filter((name) => before.get(name) !== after.get(name)).sort();
}

interface Run {
  status: number | null;
  stdout: string;
  stderr: string;
  output: string;
}

/**
 * The script, as the coordinator runs it: the file itself, executed, with the repository as the
 * working directory. `bash` names the interpreter rather than the script's own `#!` line, so
 * this needs no `/usr/bin/env`.
 */
function runIn(copy: string, args: string[]): Run {
  const result = spawnSync('bash', [join(copy, 'scripts', 'bump-version.sh'), ...args], {
    cwd: copy,
    encoding: 'utf8',
  });
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';
  return {
    status: result.status,
    stdout,
    stderr,
    output: `exit ${String(result.status)}\n--- stdout\n${stdout}--- stderr\n${stderr}`,
  };
}

function versionOf(copy: string): string {
  const manifest = JSON.parse(readFileSync(join(copy, 'package.json'), 'utf8')) as { version?: string };
  assert.ok(typeof manifest.version === 'string', 'the copy carries no version in package.json');
  return manifest.version;
}

test('an invalid version is refused, with the tree unchanged', () => {
  const copy = freshCopy('invalid');
  try {
    const before = tree(copy);
    for (const invalid of ['', '1.2', 'v1.2.3', '1.2.3-rc1', '1.2.3.4', '1.2.x', '0.5.1/../x']) {
      const run = runIn(copy, [invalid]);
      assert.notEqual(run.status, 0, `${JSON.stringify(invalid)} was accepted:\n${run.output}`);
      assert.notEqual(run.stderr, '', `${JSON.stringify(invalid)} was refused without saying why`);
      assert.deepEqual(changed(before, tree(copy)), [], `${JSON.stringify(invalid)} moved the tree`);
    }
  } finally {
    rmSync(copy, { recursive: true, force: true });
  }
});

test('the version the tree already carries is a no-op', () => {
  const copy = freshCopy('noop');
  try {
    const before = tree(copy);
    const run = runIn(copy, [versionOf(copy)]);
    assert.equal(run.status, 0, `bumping to the version present failed:\n${run.output}`);
    assert.deepEqual(changed(before, tree(copy)), [], 'the tree moved');
    assert.match(run.stdout, /already/, 'the run did not say the version was already there');
  } finally {
    rmSync(copy, { recursive: true, force: true });
  }
});

test('a bump writes exactly the files that carry the version', () => {
  const copy = freshCopy('bump');
  try {
    const current = versionOf(copy);
    const before = tree(copy);
    const run = runIn(copy, [BUMPED_TO]);
    assert.equal(run.status, 0, `the bump failed:\n${run.output}`);
    assert.deepEqual(
      changed(before, tree(copy)),
      [...CARRIES_THE_VERSION].sort(),
      `the bump did not write exactly the version's homes:\n${run.output}`,
    );

    const manifest = JSON.parse(readFileSync(join(copy, 'package.json'), 'utf8')) as { version?: string };
    assert.equal(manifest.version, BUMPED_TO, 'the manifest does not carry the new version');

    const lock = readFileSync(join(copy, 'package-lock.json'), 'utf8').split('\n');
    assert.equal(lock.filter((line) => line === `  "version": "${BUMPED_TO}",`).length, 1, 'the lockfile\'s own version');
    assert.equal(
      lock.filter((line) => line === `      "version": "${BUMPED_TO}",`).length,
      1,
      'the version in the lockfile\'s `packages.""`',
    );

    // The strongest form of "and nothing else": put the old version back in the copy's file and
    // the result is this repository's own file, byte for byte.
    for (const file of CARRIES_THE_VERSION) {
      const written = readFileSync(join(copy, file), 'utf8').split(BUMPED_TO).join(current);
      assert.equal(written, readFileSync(join(ROOT, file), 'utf8'), `${file} changed beyond the version string`);
    }

    for (const file of CARRIES_THE_VERSION) {
      assert.ok(run.stdout.includes(file), `the run did not name ${file} among the files it wrote`);
    }
  } finally {
    rmSync(copy, { recursive: true, force: true });
  }
});

/**
 * The `version` input's own block from `on.workflow_dispatch.inputs`, up to the next input at the
 * same indentation. This repository's dependency set carries no YAML parser, so the block is
 * taken by indentation; the caller checks that it read an input's body before reading it.
 */
function versionInput(workflow: string): string {
  const lines = workflow.split('\n');
  const start = lines.indexOf('      version:');
  assert.notEqual(start, -1, 'no `version` input under `on.workflow_dispatch.inputs`');
  const body = lines.slice(start + 1);
  const end = body.findIndex((line) => /^ {6}\S/.test(line));
  return (end === -1 ? body : body.slice(0, end)).join('\n');
}

test('the release workflow requires the version and carries no default', () => {
  const workflow = readFileSync(join(ROOT, '.github', 'workflows', 'release.yml'), 'utf8');
  const input = versionInput(workflow);
  assert.match(input, /^\s*description:/m, 'the block read is not a workflow input');
  assert.match(
    input,
    /^\s*required:\s*true\s*$/m,
    'the version input is not required, so a dispatch could reach the assertion without naming one',
  );
  assert.doesNotMatch(
    input,
    /^\s*default:/m,
    'the version input carries a default: a second copy of the version that no bump moves',
  );
});
