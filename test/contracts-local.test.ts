import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const name = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).name;
const consumer = name === 'selvage-mcp' ? 'mcp' : 'nvim_client';
const BASH = spawnSync('bash', ['-c', 'command -v bash'], { encoding: 'utf8' }).stdout.trim();
const SHA = '1234567890123456789012345678901234567890';

function fixture() {
  mkdirSync(join(ROOT, '.tmp'), { recursive: true });
  const dir = mkdtempSync(join(ROOT, '.tmp', 'contracts-local-'));
  const bin = join(dir, 'bin');
  const workspace = join(dir, 'workspace with spaces');
  mkdirSync(bin);
  mkdirSync(join(workspace, 'specification'), { recursive: true });
  const log = join(dir, 'calls.log');
  writeFileSync(log, '');
  for (const [tool, body] of Object.entries({
    git: `printf 'git %s\\n' "$*" >> "$MOCK_LOG"
if [ "\${MOCK_GIT_FAIL:-0}" != 0 ]; then exit "$MOCK_GIT_FAIL"; fi
case "$3" in
  rev-parse) printf '%s\\n' '${SHA}' ;;
  show) printf '%s\\n' 'committed checker bytes' ;;
  *) exit 99 ;;
esac`,
    python3: `printf 'checker %s\\n' "$(< "$1")" >> "$MOCK_LOG"
shift
printf 'python %s\\n' "$*" >> "$MOCK_LOG"
exit "\${MOCK_PYTHON_FAIL:-0}"`,
  })) {
    const path = join(bin, tool);
    writeFileSync(path, `#!${BASH}\nset -euo pipefail\n${body}\n`);
    chmodSync(path, 0o755);
  }
  const run = (args: string[], env: Record<string, string> = {}) => spawnSync(
    BASH, [join(ROOT, 'scripts', 'ci-local.sh'), 'contracts', ...args],
    { encoding: 'utf8', timeout: 10_000, env: {
      ...process.env, PATH: `${bin}:${process.env.PATH ?? ''}`, MOCK_LOG: log, ...env,
    } },
  );
  return { dir, workspace, log, run };
}

test('contracts extracts the explicitly selected committed checker and forwards revisions', () => {
  const f = fixture();
  try {
    const result = f.run([f.workspace, 'checker-ref', '--revision', `${consumer}=candidate`,
      '--revision', 'vscode_client=canonical', '--revision', 'specification=canonical-spec']);
    assert.equal(result.status, 0, result.stderr);
    const calls = readFileSync(f.log, 'utf8');
    assert.match(calls, /rev-parse --verify (?:--end-of-options )?checker-ref\^\{commit\}/);
    assert.ok(calls.includes(`show ${SHA}:scripts/check-workspace.py`), calls);
    assert.ok(calls.includes('checker committed checker bytes'), calls);
    assert.ok(calls.includes(`--workspace ${f.workspace} --consumer ${consumer} --revision ${consumer}=candidate --revision vscode_client=canonical --revision specification=canonical-spec`), calls);
    assert.ok(!calls.includes(`--revision specification=${SHA}`), 'checker revision must not select canonical data');
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});

test('contracts fails on missing explicit inputs, invalid refs, and checker failures', () => {
  const f = fixture();
  try {
    assert.equal(f.run([]).status, 2);
    const args = [f.workspace, 'checker-ref', '--revision', `${consumer}=candidate`,
      '--revision', 'vscode_client=canonical', '--revision', 'specification=canonical-spec'];
    assert.equal(f.run(args, { MOCK_GIT_FAIL: '23' }).status, 23);
    assert.ok(!readFileSync(f.log, 'utf8').includes('python '));
    assert.equal(f.run(args, { MOCK_PYTHON_FAIL: '37' }).status, 37);
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});
