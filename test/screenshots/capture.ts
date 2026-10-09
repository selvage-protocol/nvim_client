/**
 * The README's screenshot, taken from two real Neovim instances in one room on a real `selvaged`:
 * the host as a visible editor in a terminal on this run's display, the guest behind it but just
 * as real — headless, in the same room, with its selection on the same file. The host's window is
 * staged through the end-to-end proof's own driver scripts (`test/screenshots/scene-host.lua` and
 * `scene-guest.lua`, both of which reuse `test/e2e/harness.lua`), captured `import -window root`
 * once the display stops changing, and written to the output directory.
 *
 * A manual step, run when the plugin's look changes, and never part of the gate:
 *
 *   scripts/screenshots/capture.sh
 *   node test/screenshots/capture.ts <output directory>   # what that script runs for you
 *
 * It has the end-to-end proof's prerequisites — a `selvaged`, a `nvim`, a terminal to draw in and
 * a display to draw on — all of which `scripts/screenshots/capture.sh` supplies. The images are
 * recompressed and size-checked there, with the rest of what the run needs to say.
 *
 * Nothing here is named after the machine taking the picture: each editor's `HOME` is its own
 * sandbox under `.tmp/screenshots/`, and the host opens the project from inside its folder, so the
 * window's own statusline reads `src/board.lua` rather than a path of this checkout.
 */

import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { createWriteStream, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

import { RealServer } from '../helpers/selvaged.ts';

const ROOT = resolve(import.meta.dirname, '..', '..');
const TMP = resolve(ROOT, '.tmp');
const RUN = resolve(TMP, 'screenshots');
const NVIM = process.env['SELVAGE_NVIM'] ?? 'nvim';

/** The shared folder, as a host's window shows it: the project's own name, and one file of it. */
const FOLDER = 'taskboard';
const SEED_PATH = 'src/board.lua';

/**
 * Where each side of the picture stands, as the text the scene finds rather than a line number, so
 * that editing the project moves the two with it. Ada's caret is on the line `task` is looked up
 * on; Grace selects the line the room's whole business is about, the work-in-progress check.
 */
const HOST_AT = 'local task = self.tasks[id]';
const GUEST_SELECTS = '#self:column(to) >= limit';

/** The display the run draws on, as `scripts/screenshots/capture.sh` made it. */
const SCREEN = { width: 1280, height: 800 };
/** How many captures of the display in a row have to agree before one is taken. */
const STILL_SAMPLES = 3;

const DEADLINE_MS = Number(process.env['SELVAGE_E2E_DEADLINE_MS'] ?? '30000');
/** How long the two editors hold the scene for the capture once it is staged. */
const HOLD_MS = 600_000;
/** The bound on the whole run, so that a step with no bound of its own fails rather than hangs. */
const WATCHDOG_MS = 900_000;
const COMMAND_MS = 30_000;

/**
 * The display this run draws on is the one `scripts/screenshots/capture.sh` made, and nothing else:
 * `xvfb-run` sets `DISPLAY`, but it leaves the login session's Wayland variables in place, and a
 * terminal that finds them there opens its window on somebody's desktop rather than into the
 * picture. `XDG_SESSION_TYPE` is named rather than dropped because it is the hint a client falls
 * back on.
 */
const DISPLAY_ONLY_ENV: NodeJS.ProcessEnv = {
  WAYLAND_DISPLAY: undefined,
  WAYLAND_SOCKET: undefined,
  XDG_SESSION_TYPE: 'x11',
};

/**
 * The project the screenshot shows, as the same small kanban board the other clients' own
 * screenshots use — a person's real work, not a fixture. It is a Lua project because the client
 * is, so the editor draws its own language's highlighting rather than a file it has no parser
 * for, and it is written into the host's sandbox at the start of every run.
 */
const PROJECT: Record<string, string> = {
  'src/task.lua': `local Task = {}
Task.__index = Task

local statuses = { 'todo', 'in-progress', 'review', 'done' }

function Task.new(id, title, due)
  return setmetatable({ id = id, title = title, status = statuses[1], due = due }, Task)
end

function Task:is_overdue(today)
  return self.status ~= statuses[4] and self.due ~= nil and self.due < today
end

return Task
`,
  'src/board.lua': `local Task = require('task.task')

local Board = {}
Board.__index = Board

--- How many tasks a column may hold at once.
local default_limits = { ['in-progress'] = 3, review = 2 }

function Board.new(limits)
  return setmetatable({ tasks = {}, next_id = 1, limits = limits or default_limits }, Board)
end

function Board:add(title, due)
  local task = Task.new(self.next_id, title, due)
  self.next_id = self.next_id + 1
  self.tasks[task.id] = task
  return task
end

function Board:column(status)
  local column = {}
  for _, task in pairs(self.tasks) do
    if task.status == status then
      column[#column + 1] = task
    end
  end
  return column
end

function Board:move(id, to)
  local task = self.tasks[id]
  if task == nil then
    return nil, ('no task %d'):format(id)
  end
  local limit = self.limits[to]
  if limit ~= nil and #self:column(to) >= limit then
    return nil, ('%s is full (%d)'):format(to, limit)
  end
  task.status = to
  return task
end

function Board:overdue(today)
  local late = {}
  for _, task in pairs(self.tasks) do
    if task:is_overdue(today) then
      late[#late + 1] = task
    end
  end
  return late
end

return Board
`,
  'README.md': `# taskboard

A small kanban board for Lua: tasks move from To do to Done, and a column refuses a
task once it is at its work-in-progress limit.

    lua -e "print(require('board').new():add('write the release notes').title)"
`,
  'main.lua': `local Board = require('board')
local Task = require('task')

local function today()
  return os.date('*t')
end

local board = Board.new()
board:add('Write the release notes', { year = 2026, month = 10, day = 8 })
board:add('Fix the login redirect')
board:move(1, 'in-progress')
`,
};

/** What the run is doing, for the watchdog to report when a step outlives its bound. */
let phase = 'startup';
let lastLogged = '(nothing logged yet)';

function log(...parts: unknown[]): void {
  lastLogged = parts.map((part) => String(part)).join(' ');
  console.log('[screenshots]', ...parts);
}

function fail(message: string): never {
  throw new Error(message);
}

/** Every process this run started, so that every way out takes them down with it. */
const running = new Set<ChildProcess>();

function spawnTracked(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv },
): ChildProcess {
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  running.add(child);
  child.on('exit', () => {
    running.delete(child);
  });
  return child;
}

async function stopRunning(signal: NodeJS.Signals = 'SIGTERM'): Promise<void> {
  for (const child of running) {
    try {
      child.kill(signal);
    } catch {
      // It exited between the scan and the signal.
    }
  }
  await delay(1000);
}

/**
 * One command, bounded, with its output read back: what `xdotool` and `import` answer with is the
 * run's own reading of the display, and a command that never returns is a failure here rather than
 * a run that says nothing for as long as something else is willing to wait.
 */
async function command(
  program: string,
  args: string[],
  options: { want?: 'text' | 'bytes' } = {},
): Promise<Buffer> {
  return new Promise<Buffer>((resolvePromise, reject) => {
    const child = spawn(program, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`\`${program} ${args.join(' ')}\` did not finish within ${COMMAND_MS}ms`));
    }, COMMAND_MS);
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        const said = Buffer.concat(stderr).toString().trim();
        reject(new Error(`\`${program} ${args.join(' ')}\` exited with ${String(code)}: ${said}`));
        return;
      }
      const out = Buffer.concat(stdout);
      resolvePromise(options.want === 'text' ? Buffer.from(out.toString().trim()) : out);
    });
  });
}

async function xdotool(args: string[]): Promise<string> {
  return (await command('xdotool', args, { want: 'text' })).toString();
}

async function pollFor<T>(
  label: string,
  check: () => T | Promise<T> | undefined,
  deadlineMs = DEADLINE_MS,
): Promise<T> {
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    // Awaited, so an asynchronous check is polled rather than answered with its own promise: a
    // promise is never `undefined`, and a poll that takes one for an answer asks exactly once.
    const value = await check();
    if (value !== undefined) {
      return value;
    }
    if (Date.now() >= deadline) {
      fail(`timed out after ${String(deadlineMs)}ms waiting for ${label}`);
    }
    await delay(200);
  }
}

/** Reads a file the scene wrote, or nothing while it is not there yet. */
function readIfThere(path: string): string | undefined {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return undefined;
  }
}

/** The last lines of a log, for a failure that has one behind it. */
function tail(path: string, lines = 12): string {
  const text = readIfThere(path);
  if (text === undefined) {
    return `${path} (no log)`;
  }
  return `${path}:\n${text.split('\n').slice(-lines).join('\n')}`;
}

/**
 * A scene's own output, kept in a log file and shown here as it arrives: what a scene that fails
 * said is what the failure is read from, and a run that is going well should not be silent.
 */
function tee(child: ChildProcess, logFile: string): void {
  const out = createWriteStream(logFile);
  child.stdout?.on('data', (chunk: Buffer) => {
    out.write(chunk);
    process.stdout.write(chunk);
  });
  child.stderr?.on('data', (chunk: Buffer) => {
    out.write(chunk);
    process.stderr.write(chunk);
  });
  child.on('exit', () => {
    out.end();
  });
}

function writeProject(root: string): void {
  for (const [path, text] of Object.entries(PROJECT)) {
    const file = join(root, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  }
}

/** `Xvfb`'s screen, as the shell that started it made it: a capture of the root does not say. */
async function assertScreen(): Promise<void> {
  const [width, height] = (await xdotool(['getdisplaygeometry'])).split(' ').map(Number);
  if (width !== SCREEN.width || height !== SCREEN.height) {
    fail(
      `the display is ${String(width)}x${String(height)}, not ${String(SCREEN.width)}x${String(SCREEN.height)}: ` +
        'scripts/screenshots/capture.sh starts Xvfb at that size',
    );
  }
}

/** The terminal fills the display: a picture of a desktop with a small window on it says nothing. */
async function assertFrameFillsDisplay(window: string, label: string): Promise<void> {
  const geometry = await xdotool(['getwindowgeometry', '--shell', window]);
  const read = (name: string): number => {
    const match = new RegExp(`^${name}=(-?\\d+)$`, 'm').exec(geometry);
    return match === null ? NaN : Number(match[1]);
  };
  const [x, y, width, height] = [read('X'), read('Y'), read('WIDTH'), read('HEIGHT')];
  if (x !== 0 || y !== 0 || width !== SCREEN.width || height !== SCREEN.height) {
    fail(
      `${label} stands at ${String(x)},${String(y)} ${String(width)}x${String(height)}, and the ` +
        `screenshot is of a window filling ${String(SCREEN.width)}x${String(SCREEN.height)} at 0,0`,
    );
  }
}

/** One capture of the whole display, as the raw bytes `import` hands back. */
async function frame(): Promise<Buffer> {
  return command('import', ['-display', process.env['DISPLAY'] ?? '', '-window', 'root', 'ppm:-']);
}

/**
 * How many of the 256 byte values a capture holds. A blank display holds the black every channel
 * is, the cursor and the header of the format itself — a handful — while a terminal with text in it
 * holds a shade for every glyph: this is what tells a picture of a window from a picture of
 * nothing, which stillness alone cannot, since a blank display is perfectly still.
 */
function distinctBytes(capture: Buffer): number {
  const seen = new Uint8Array(256);
  for (const byte of capture) {
    seen[byte] = 1;
  }
  let count = 0;
  for (const value of seen) {
    count += value;
  }
  return count;
}

/** Saves the display once `STILL_SAMPLES` captures in a row are byte-for-byte the same. */
async function captureStillness(label: string, out: string): Promise<void> {
  let last: Buffer | undefined;
  let same = 0;
  const deadline = Date.now() + DEADLINE_MS;
  for (;;) {
    const current = await frame();
    if (distinctBytes(current) < 16) {
      fail(`${label} is blank: the terminal drew nothing into it, so there is no picture to take`);
    }
    same = last !== undefined && current.equals(last) ? same + 1 : 0;
    last = current;
    if (same >= STILL_SAMPLES - 1) {
      break;
    }
    if (Date.now() >= deadline) {
      fail(`${label} keeps changing: ${String(STILL_SAMPLES)} captures of it in a row never agreed`);
    }
    await delay(500);
  }
  await command('import', ['-display', process.env['DISPLAY'] ?? '', '-window', 'root', out]);
  log('ok:', out);
}

function armWatchdog(): void {
  const timer = setTimeout(() => {
    log(`the watchdog fired after ${String(WATCHDOG_MS)}ms in phase ${phase}; last line: ${lastLogged}`);
    void stopRunning('SIGKILL').finally(() => {
      process.exit(1);
    });
  }, WATCHDOG_MS);
  timer.unref();
}

async function main(): Promise<void> {
  const out = resolve(process.argv[2] ?? RUN);
  const display = process.env['DISPLAY'];
  if (display === undefined || display === '') {
    fail('no DISPLAY: run this through scripts/screenshots/capture.sh, which makes one');
  }

  rmSync(RUN, { recursive: true, force: true });
  mkdirSync(RUN, { recursive: true });
  mkdirSync(TMP, { recursive: true });
  mkdirSync(out, { recursive: true });

  const hostHome = join(RUN, 'host');
  const guestHome = join(RUN, 'guest');
  const project = join(hostHome, FOLDER);
  writeProject(project);
  mkdirSync(guestHome, { recursive: true });

  const inviteFile = join(RUN, 'invite.txt');
  // Two files, not one: each side says it is staged when its own part is on screen, and the host's
  // part is the one the picture is taken of.
  const guestReady = join(RUN, 'guest-ready.txt');
  const hostReady = join(RUN, 'host-ready.txt');
  const doneFile = join(RUN, 'done.txt');
  const hostResult = join(RUN, 'host-result.json');
  const guestResult = join(RUN, 'guest-result.json');
  const hostLog = join(RUN, 'host.log');
  const guestLog = join(RUN, 'guest.log');

  /** What both scenes are told: the room's own facts, and where to say what they reached. */
  const shared: NodeJS.ProcessEnv = {
    ...process.env,
    ...DISPLAY_ONLY_ENV,
    SELVAGE_E2E_PLUGIN_ROOT: ROOT,
    SELVAGE_E2E_SEED_PATH: SEED_PATH,
    SELVAGE_E2E_INVITE_FILE: inviteFile,
    SELVAGE_E2E_DEADLINE_MS: String(DEADLINE_MS),
    SELVAGE_SHOT_HOST_AT: HOST_AT,
    SELVAGE_SHOT_GUEST_SELECTS: GUEST_SELECTS,
    SELVAGE_SHOT_READY_FILE: guestReady,
    SELVAGE_SHOT_STAGED_FILE: hostReady,
    SELVAGE_SHOT_DONE_FILE: doneFile,
    SELVAGE_SHOT_HOLD_MS: String(HOLD_MS),
  };

  phase = 'starting the real selvaged';
  log('starting the real selvaged');
  const server = await RealServer.start();
  log('selvaged listening at', server.wsBase);

  phase = 'starting the host editor';
  log(`starting the host editor in a terminal on ${display}, at ${String(SCREEN.width)}x${String(SCREEN.height)}`);
  const host = spawnTracked(
    'kitty',
    [
      // No configuration of the machine taking the picture: what a reader sees is this client in
      // a terminal's own defaults.
      '--config',
      'NONE',
      '--title',
      'Selvage',
      // The window is asked for in pixels and not remembered from anywhere: kitty's own default is
      // 640x400, and a remembered size would come from the state of whoever runs this.
      '-o',
      'remember_window_size=no',
      '-o',
      `initial_window_width=${String(SCREEN.width)}`,
      '-o',
      `initial_window_height=${String(SCREEN.height)}`,
      '-o',
      'font_family=JetBrainsMono Nerd Font Mono',
      '-o',
      'font_size=13',
      '-o',
      'window_padding_width=8',
      '-o',
      'background_opacity=1',
      '-o',
      'cursor_shape=block',
      // A blinking caret is a display that never stops changing, and one capture of it would be
      // taken mid-blink.
      '-o',
      'cursor_blink_interval=0',
      '--',
      NVIM,
      // A stock editor: no configuration of the machine taking the picture, so the window holds
      // this client's own drawing and nothing else.
      '--clean',
      '-c',
      `luafile ${resolve(import.meta.dirname, 'scene-host.lua')}`,
    ],
    {
      cwd: project,
      env: {
        ...shared,
        HOME: hostHome,
        SELVAGE_E2E_SERVER_URL: server.wsBase,
        SELVAGE_E2E_RESULT_FILE: hostResult,
        SELVAGE_SHOT_LOG: hostLog,
      },
    },
  );
  tee(host, hostLog);

  phase = 'waiting for the invite';
  await pollFor('the host to publish its invite', () => readIfThere(inviteFile));
  log('the host published its invite');

  phase = 'starting the guest editor';
  log('starting the guest editor, headless in the same room');
  const guest = spawnTracked(
    NVIM,
    ['--clean', '--headless', '-l', resolve(import.meta.dirname, 'scene-guest.lua')],
    {
    cwd: guestHome,
    env: {
      ...shared,
      HOME: guestHome,
      SELVAGE_E2E_RESULT_FILE: guestResult,
    },
  });
  tee(guest, guestLog);
  guest.on('exit', (code) => {
    if (readIfThere(doneFile) === undefined && code !== 0) {
      log('the guest editor left before the capture was taken:', tail(guestLog));
    }
  });

  phase = 'waiting for the scene';
  await pollFor('the guest to stage its selection', () => readIfThere(guestReady));
  // The host is staged only once the guest's own row is drawn in its window, so this is the gate
  // the picture is taken behind: the caret, the fill and the sign are on screen.
  await pollFor('the host to be staged with the guest drawn in it', () => readIfThere(hostReady));
  log('both scenes are staged');

  phase = 'framing the host window';
  const window = await xdotool(['search', '--name', '^Selvage$']).then((ids) => ids.split('\n')[0] ?? '');
  if (window === '') {
    fail(`the host's terminal window is not there; ${tail(hostLog)}`);
  }
  await assertScreen();
  // The terminal opens filling the display, and its own redraw for the size it has is what the
  // frame is; a window that has not drawn yet would be captured blank.
  await delay(2000);
  await assertFrameFillsDisplay(window, "the host's terminal");

  phase = 'capturing the display';
  // The picture is of a room both editors are in, so one that left before the frame — or while the
  // display was being read — fails the run rather than passing with an empty window in the output.
  const present = (): void => {
    if (host.exitCode !== null) {
      fail(`the host editor left before the capture was done; ${tail(hostLog)}`);
    }
    if (guest.exitCode !== null) {
      fail(`the guest editor left before the capture was done; ${tail(guestLog)}`);
    }
  };
  present();
  await captureStillness("the host's display", join(out, 'host-editing.png'));
  present();

  if (readIfThere(guestResult) === undefined) {
    fail(`the guest editor left no result behind: ${tail(guestLog)}`);
  }

  phase = 'stopping';
  writeFileSync(doneFile, 'done\n');
  await delay(2000);
  await stopRunning();
  await server.stop();
  log('PASS: one screenshot in', out);
}

armWatchdog();

main()
  .then(async () => {
    await stopRunning('SIGKILL');
    process.exit(0);
  })
  .catch(async (error: unknown) => {
    log(`FAIL: ${String(error)}`);
    log(`  phase: ${phase}`);
    // What a visible editor has to say about a failure is on its screen rather than in its log,
    // so a failed run saves the screen as well: `.tmp/screenshots/host-failure.png`.
    if (process.env['DISPLAY'] !== undefined) {
      try {
        await command('import', [
          '-display',
          process.env['DISPLAY'],
          '-window',
          'root',
          join(RUN, 'host-failure.png'),
        ]);
        log('  the host screen as it stood:', join(RUN, 'host-failure.png'));
      } catch (alsoFailed: unknown) {
        log(`  the host screen could not be saved: ${String(alsoFailed)}`);
      }
    }
    await stopRunning('SIGKILL');
    process.exit(1);
  });
