// The page half of the WebUI. Every decision lives in lib/angle_webui.sh and
// lib/options_webui.sh; this file runs them and renders what they print.
//
// Written against the API as it is actually injected, read out of a module
// already installed on the target rather than from the published guide, which
// documents exec without its signature:
//
//     ksu.exec(command, optionsJson, callbackName)
//     ksu.toast(message)
//
// exec is asynchronous and answers by calling a function it looks up by name on
// window, so the name has to be unique per call and deleted after.

'use strict';

const MODULE_DIR = '/data/adb/modules/noemulator';
const HELPER = `sh ${MODULE_DIR}/lib/angle_webui.sh`;
const OPTIONS_HELPER = `sh ${MODULE_DIR}/lib/options_webui.sh`;

let callSequence = 0;

function exec(command) {
    return new Promise((resolve) => {
        const callbackName = `__noemulator_cb_${Date.now()}_${callSequence++}`;
        const release = () => { delete window[callbackName]; };

        window[callbackName] = (errno, stdout, stderr) => {
            release();
            resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
        };

        // A missing ksu is the ordinary case when the file is opened outside the
        // manager, so it resolves like any other failure rather than throwing.
        try {
            if (typeof ksu === 'undefined' || !ksu.exec) {
                release();
                resolve({ errno: 1, stdout: '', stderr: 'not running inside the KernelSU manager' });
                return;
            }
            ksu.exec(command, '{}', callbackName);
        } catch (error) {
            release();
            resolve({ errno: 1, stdout: '', stderr: error && error.message ? error.message : 'exec failed' });
        }
    });
}

function toast(message) {
    try {
        if (typeof ksu !== 'undefined' && ksu.toast) ksu.toast(message);
    } catch (error) {
        // A toast is a courtesy. Losing one must not take the page down.
    }
}

function lines(text) {
    return text.split('\n').map((line) => line.trim()).filter(Boolean);
}

// The name goes into a string that ksu.exec runs as root, so it is checked here
// as well as in angle_webui.sh. The helper's check cannot protect this: the shell
// parses the command before the helper exists to reject anything. Android will
// not install a package whose name is not a dotted Java identifier, so this
// should never fire -- which is the reason to fail closed rather than quote
// harder and hope.
const PACKAGE_NAME = /^[A-Za-z0-9._]+$/;

function angleCommand(verb, packageName) {
    if (!PACKAGE_NAME.test(packageName)) {
        throw new Error(`not a package name: ${packageName}`);
    }
    return `${HELPER} ${verb} '${packageName}'`;
}

const state = {
    packages: [],      // every installed package, as names
    selection: new Map(), // package -> 'ours' | 'theirs'
    busy: false,
    // Adopting is the one action with a consequence the user cannot see coming:
    // afterwards, uninstalling NoEmulator takes a package off ANGLE that it did
    // not put there. So the button arms on the first tap and commits on the
    // second, with the warning in the status line between the two. A confirm()
    // would be shorter, but nothing guarantees the manager's WebView answers
    // one, and a dialog that never returns is a page that looks frozen.
    armedAdopt: null,
};

const ui = {
    subtitle: document.getElementById('angle-subtitle'),
    status: document.getElementById('angle-status'),
    filter: document.getElementById('filter'),
    showSystem: document.getElementById('show-system'),
    list: document.getElementById('packages'),
};

function setStatus(message) {
    ui.status.textContent = message;
}

function render() {
    const needle = ui.filter.value.trim().toLowerCase();
    const matching = state.packages.filter((name) => name.toLowerCase().includes(needle));

    // On ANGLE first, so the thing the page is about is not buried under a
    // few hundred packages the user has to scroll past.
    matching.sort((a, b) => {
        const onA = state.selection.has(a) ? 0 : 1;
        const onB = state.selection.has(b) ? 0 : 1;
        return onA - onB || a.localeCompare(b);
    });

    ui.list.replaceChildren(...matching.map(renderRow));

    const ours = [...state.selection.values()].filter((owner) => owner === 'ours').length;
    const theirs = state.selection.size - ours;
    ui.subtitle.textContent =
        `${state.packages.length} packages, ${ours} on ANGLE via NoEmulator` +
        (theirs ? `, ${theirs} set outside it` : '');
}

function renderRow(packageName) {
    const owner = state.selection.get(packageName);

    const row = document.createElement('li');

    // The name and its tag stack in one column, so a tag never squeezes the
    // name into breaking mid-word beside the button.
    const info = document.createElement('span');
    info.className = 'name';
    info.textContent = packageName;
    row.append(info);

    // A package someone else put on ANGLE is never taken off here: that would
    // undo a choice this module did not make, which is the rule uninstall
    // follows. It can be adopted, which is the opposite direction and changes
    // nothing the app can see.
    if (owner === 'theirs') {
        const tag = document.createElement('span');
        tag.className = 'tag';
        tag.textContent = 'set outside NoEmulator';
        info.append(tag);

        const adopt = document.createElement('button');
        adopt.type = 'button';
        const armed = state.armedAdopt === packageName;
        adopt.textContent = armed ? 'Confirm' : 'Adopt';
        adopt.dataset.armed = armed ? 'yes' : 'no';
        adopt.disabled = state.busy;
        adopt.addEventListener('click', () => (armed ? adoptPackage(packageName) : armAdopt(packageName)));
        row.append(adopt);
        return row;
    }

    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = owner === 'ours' ? 'On ANGLE' : 'Off';
    button.dataset.on = owner === 'ours' ? 'yes' : 'no';
    button.disabled = state.busy;
    button.addEventListener('click', () => toggle(packageName, owner === 'ours'));
    row.append(button);

    return row;
}

function armAdopt(packageName) {
    state.armedAdopt = packageName;
    setStatus(
        `Tap Confirm to let NoEmulator manage ${packageName}. It stays on ANGLE ` +
        'either way; what changes is that uninstalling will take it back off.'
    );
    render();
}

async function adoptPackage(packageName) {
    if (state.busy) return;
    state.busy = true;
    state.armedAdopt = null;
    render();

    let result;
    try {
        result = await exec(angleCommand('adopt', packageName));
    } catch (error) {
        state.busy = false;
        setStatus(error.message);
        toast(error.message);
        render();
        return;
    }
    state.busy = false;

    if (result.errno !== 0) {
        const reason = result.stderr.trim() || `exit ${result.errno}`;
        setStatus(`Could not adopt ${packageName}: ${reason}`);
        toast(reason);
        render();
        return;
    }

    if (await loadSelection()) setStatus(`${packageName} is now managed by NoEmulator.`);
    render();
}

async function toggle(packageName, isOn) {
    if (state.busy) return;
    state.busy = true;
    render();

    const verb = isOn ? 'remove' : 'add';
    setStatus(`${isOn ? 'Removing' : 'Adding'} ${packageName}...`);

    let result;
    try {
        result = await exec(angleCommand(verb, packageName));
    } catch (error) {
        state.busy = false;
        setStatus(error.message);
        toast(error.message);
        render();
        return;
    }
    state.busy = false;

    if (result.errno !== 0) {
        // The helper's own message is the useful one; errno alone says nothing.
        const reason = result.stderr.trim() || `exit ${result.errno}`;
        setStatus(`Could not ${verb} ${packageName}: ${reason}`);
        toast(reason);
        render();
        return;
    }

    const written = isOn
        ? `${packageName} is off ANGLE. It takes effect next time the app starts.`
        : `${packageName} is on ANGLE. It takes effect next time the app starts.`;

    // The write succeeded even if reading the selection back does not, so its
    // failure message must not replace the one that says so.
    if (await loadSelection()) setStatus(written);
    render();
}

async function loadSelection() {
    const result = await exec(`${HELPER} selection`);
    if (result.errno !== 0) {
        setStatus(`Could not read the ANGLE selection: ${result.stderr.trim() || `exit ${result.errno}`}`);
        return false;
    }

    state.selection = new Map();
    for (const line of lines(result.stdout)) {
        // 'package value ours|theirs'
        const parts = line.split(' ');
        if (parts.length >= 3) state.selection.set(parts[0], parts[parts.length - 1]);
    }
    return true;
}

async function loadPackages() {
    const flag = ui.showSystem.checked ? ' --all' : '';
    const result = await exec(`${HELPER} packages${flag}`);
    if (result.errno !== 0) {
        setStatus(`Could not list packages: ${result.stderr.trim() || `exit ${result.errno}`}`);
        return false;
    }
    state.packages = lines(result.stdout);
    return true;
}

async function reload() {
    state.armedAdopt = null;
    setStatus('Reading...');
    const ok = (await loadSelection()) && (await loadPackages());
    if (!ok) return;

    // A package on ANGLE that is not installed cannot be shown in a list of
    // installed packages, and silently dropping it would hide a stale entry.
    for (const packageName of state.selection.keys()) {
        if (!state.packages.includes(packageName)) state.packages.push(packageName);
    }

    setStatus('');
    render();
}

ui.filter.addEventListener('input', () => {
    state.armedAdopt = null;
    render();
});
ui.showSystem.addEventListener('change', reload);

// --- Home ------------------------------------------------------------------

// options_webui.sh status prints 'key value' lines; a stage line is
// 'stage <name> done|missing'.
function parseStatus(text) {
    const status = { stages: [] };
    for (const line of lines(text)) {
        const [key, ...rest] = line.split(' ');
        if (key === 'stage') status.stages.push({ name: rest[0], done: rest[1] === 'done' });
        else status[key] = rest.join(' ');
    }
    return status;
}

const STAGE_LABELS = {
    'post-fs-data': 'Properties, before zygote',
    'post-mount': 'Redirects',
    'after-wifi': 'Wi-Fi property, once wlan0 is up',
    'once-set': 'vendor.qemu properties, once set',
};

function infoRow(label, value, bad) {
    const row = document.createElement('div');
    row.className = 'row';
    const name = document.createElement('span');
    name.className = 'label';
    name.textContent = label;
    const shown = document.createElement('span');
    shown.className = bad ? 'value bad' : 'value';
    shown.textContent = value;
    row.append(name, shown);
    return row;
}

// The verdict is the helper's, the same one the module card in the manager
// shows (lib/module_status.sh), so the two never disagree.
async function loadHealth() {
    const card = document.getElementById('status-card');
    const title = document.getElementById('status-title');
    const detail = document.getElementById('status-detail');
    const icon = document.getElementById('status-icon');

    const result = await exec(`${OPTIONS_HELPER} health`);
    const healthy = result.errno === 0 && lines(result.stdout).includes('health ok');
    card.dataset.state = healthy ? 'ok' : 'warn';
    icon.dataset.icon = healthy ? 'check_circle' : 'error';
    if (result.errno !== 0) {
        title.textContent = 'Status unavailable';
        detail.textContent = result.stderr.trim() || `exit ${result.errno}`;
    } else {
        title.textContent = healthy ? 'Working' : 'Needs attention';
        detail.textContent = lines(result.stdout)
            .filter((line) => line.startsWith('detail '))
            .map((line) => line.slice('detail '.length))
            .join(' ');
    }
    renderIcons(card);
}

// A long list would push everything else off the page, so Home shows the first
// few and the Log page holds the rest.
const HOME_FAILURES_SHOWN = 5;

async function loadFailures() {
    const result = await exec(`${OPTIONS_HELPER} failures`);
    const failed = result.errno === 0 ? lines(result.stdout) : [];
    const items = failed.slice(0, HOME_FAILURES_SHOWN).map((line) => {
        const item = document.createElement('li');
        item.textContent = line.slice('failed: '.length);
        return item;
    });
    if (failed.length > HOME_FAILURES_SHOWN) {
        const more = document.createElement('li');
        more.textContent = `and ${failed.length - HOME_FAILURES_SHOWN} more, on the Log page`;
        items.push(more);
    }
    document.getElementById('home-failures').replaceChildren(...items);
    document.getElementById('home-problems').hidden = failed.length === 0;
}

async function loadHome() {
    await loadHealth();
    loadFailures();

    const result = await exec(`${OPTIONS_HELPER} status`);
    if (result.errno !== 0) return;

    const status = parseStatus(result.stdout);
    const failures = Number(status.failures || 0);

    document.getElementById('home-module').replaceChildren(
        infoRow('Version', status.version || 'unknown'),
        infoRow('susfs kernel module', status.susfs === 'yes' ? 'Loaded' : 'Not loaded', status.susfs !== 'yes'),
        infoRow('NoMount', status.nomount === 'yes' ? 'Active' : 'Not active', status.nomount !== 'yes'),
        infoRow('Redirects applied', status.redirects || '0'),
        infoRow('App property view', status.view_areas ? status.view_areas.split(' ').join(', ') : 'Off'),
    );
    document.getElementById('home-boot').replaceChildren(
        ...status.stages.map((stage) =>
            infoRow(STAGE_LABELS[stage.name] || stage.name, stage.done ? 'Done' : 'Did not finish', !stage.done)),
        infoRow('Failed rules', String(failures), failures > 0),
    );
}

// --- Options -----------------------------------------------------------------

// Each switch changes the user config and acts at the next boot. The helper
// reports what is configured and what is running; "Reboot to apply" shows while
// they differ.
const SWITCHES = {
    arm: {
        saved: {
            on: 'Saved. ARM apps can run after the next reboot.',
            off: 'Saved. The ARM translator is hidden again after the next reboot.',
        },
    },
    clipboard: {
        saved: {
            on: 'Saved. The host clipboard syncs after the next reboot.',
            off: 'Saved. The emulator flag is hidden again after the next reboot.',
        },
    },
};
for (const [name, sw] of Object.entries(SWITCHES)) {
    sw.input = document.getElementById(`${name}-switch`);
    sw.reboot = document.getElementById(`${name}-reboot`);
}
const optionsStatus = document.getElementById('options-status');

function parseSwitchState(text) {
    const state = {};
    for (const line of lines(text)) {
        const [key, value] = line.split(' ');
        state[key] = value;
    }
    return state;
}

async function loadSwitch(name) {
    const sw = SWITCHES[name];
    const result = await exec(`${OPTIONS_HELPER} ${name}`);
    if (result.errno !== 0) {
        optionsStatus.textContent = `Could not read the options: ${result.stderr.trim() || `exit ${result.errno}`}`;
        return;
    }
    const state = parseSwitchState(result.stdout);
    sw.input.checked = state.configured === 'on';
    sw.reboot.hidden = state.configured === state.running;
    sw.input.disabled = false;
    updateRebootButton();
}

// The device preset works like a switch with more than two positions: the
// helper reports the configured and the running preset, and lists the presets
// for this Android version.
const deviceSelect = document.getElementById('device-select');
const deviceReboot = document.getElementById('device-reboot');

async function loadDevice() {
    const result = await exec(`${OPTIONS_HELPER} device`);
    if (result.errno !== 0) {
        optionsStatus.textContent = `Could not read the device: ${result.stderr.trim() || `exit ${result.errno}`}`;
        return;
    }
    let configured = '';
    let running = '';
    deviceSelect.replaceChildren();
    for (const line of lines(result.stdout)) {
        const [key, codename, ...model] = line.split(' ');
        if (key === 'configured') configured = codename;
        else if (key === 'running') running = codename;
        else if (key === 'preset') deviceSelect.add(new Option(model.join(' '), codename));
    }
    deviceSelect.value = configured;
    deviceReboot.hidden = configured === running;
    deviceSelect.disabled = false;
    updateRebootButton();
}

deviceSelect.addEventListener('change', async () => {
    const wanted = deviceSelect.value;
    deviceSelect.disabled = true;
    const result = await exec(`${OPTIONS_HELPER} device ${wanted}`);
    if (result.errno !== 0) {
        const reason = result.stderr.trim() || `exit ${result.errno}`;
        optionsStatus.textContent = `Could not change it: ${reason}`;
        toast(reason);
    } else {
        const model = deviceSelect.selectedOptions[0].textContent;
        optionsStatus.textContent = `Saved. This device claims to be a ${model} after the next reboot.`;
    }
    await loadDevice();
});

// --- reboot ------------------------------------------------------------------

// Shown while any switch says "Reboot to apply". Like Adopt, it arms on the first
// tap and acts on the second: a reboot from a stray tap loses whatever the user
// had open.
const rebootButton = document.getElementById('reboot-button');
const rebootLabel = document.getElementById('reboot-label');
let rebootArmed = false;

function updateRebootButton() {
    rebootButton.hidden = deviceReboot.hidden &&
        Object.values(SWITCHES).every((sw) => sw.reboot.hidden);
    if (rebootButton.hidden) disarmReboot();
}

function disarmReboot() {
    rebootArmed = false;
    rebootButton.dataset.armed = 'no';
    rebootLabel.textContent = 'Reboot now';
}

rebootButton.addEventListener('click', async () => {
    if (!rebootArmed) {
        rebootArmed = true;
        rebootButton.dataset.armed = 'yes';
        rebootLabel.textContent = 'Tap again to reboot';
        return;
    }
    rebootLabel.textContent = 'Rebooting...';
    const result = await exec(`${OPTIONS_HELPER} reboot`);
    if (result.errno !== 0) {
        const reason = result.stderr.trim() || `exit ${result.errno}`;
        optionsStatus.textContent = `Could not reboot: ${reason}`;
        disarmReboot();
    }
});

async function loadOptions() {
    await loadDevice();
    for (const name of Object.keys(SWITCHES)) await loadSwitch(name);
}

for (const [name, sw] of Object.entries(SWITCHES)) {
    sw.input.addEventListener('change', async () => {
        const wanted = sw.input.checked ? 'on' : 'off';
        sw.input.disabled = true;
        const result = await exec(`${OPTIONS_HELPER} ${name} ${wanted}`);
        if (result.errno !== 0) {
            const reason = result.stderr.trim() || `exit ${result.errno}`;
            optionsStatus.textContent = `Could not change it: ${reason}`;
            toast(reason);
            sw.input.checked = !sw.input.checked;
            sw.input.disabled = false;
            return;
        }
        optionsStatus.textContent = sw.saved[wanted];
        await loadSwitch(name);
    });
}

// --- log ---------------------------------------------------------------------

const logStatus = document.getElementById('log-status');

async function loadLog() {
    const text = document.getElementById('log-text');
    const result = await exec(`${OPTIONS_HELPER} log`);
    if (result.errno !== 0) {
        text.textContent = `Could not read apply.log: ${result.stderr.trim() || `exit ${result.errno}`}`;
        return;
    }
    text.replaceChildren(...result.stdout.split('\n').filter(Boolean).map((line) => {
        const row = document.createElement('span');
        row.className = line.startsWith('failed: ') ? 'failed' : '';
        row.textContent = `${line}\n`;
        return row;
    }));
    if (!text.childElementCount) text.textContent = 'apply.log is empty.';
}

document.getElementById('export-logs').addEventListener('click', async () => {
    logStatus.textContent = 'Collecting...';
    const result = await exec(`${OPTIONS_HELPER} export`);
    if (result.errno !== 0) {
        logStatus.textContent = `Could not export: ${result.stderr.trim() || `exit ${result.errno}`}`;
        return;
    }
    const path = result.stdout.trim();
    logStatus.textContent = `Saved ${path}. Read it, then attach it to an issue.`;
    toast(`Saved ${path.split('/').pop()}`);
});

// --- about -------------------------------------------------------------------

// The channel the manager's update button reads (module.prop updateJson). It is
// fetched by the page rather than the helper because the device has no curl.
const UPDATE_JSON = 'https://raw.githubusercontent.com/ymuuuu/NoEmulator/main/update.json';

async function loadAbout() {
    const group = document.getElementById('about-version');
    const result = await exec(`${OPTIONS_HELPER} status`);
    const installed = result.errno === 0 ? parseStatus(result.stdout).version || 'unknown' : 'unknown';
    group.replaceChildren(infoRow('Installed', installed), infoRow('Latest', 'Checking...'));

    let latest;
    try {
        const response = await fetch(UPDATE_JSON, { cache: 'no-store' });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        latest = (await response.json()).version;
    } catch (error) {
        group.replaceChildren(infoRow('Installed', installed), infoRow('Latest', 'Could not check', true));
        return;
    }
    const outdated = latest !== installed;
    group.replaceChildren(
        infoRow('Installed', installed),
        infoRow('Latest', outdated ? `${latest}, update from the Modules list` : `${latest}, up to date`, outdated),
    );
}

// Links open in the device's browser through an intent: the manager's WebView
// is not a browser and gives a tapped link nowhere to go. The URL goes into a
// root shell command, so only plain URL characters are let through, and every
// URL comes from this page's own markup.
const SAFE_URL = /^https:\/\/[A-Za-z0-9./_#?=&-]+$/;

for (const link of document.querySelectorAll('[data-url]')) {
    link.addEventListener('click', async (event) => {
        event.preventDefault();
        const url = link.dataset.url;
        if (!SAFE_URL.test(url)) return;
        const result = await exec(`am start -a android.intent.action.VIEW -d '${url}'`);
        if (result.errno !== 0) toast(`Could not open ${url}`);
    });
}

// --- navigation --------------------------------------------------------------

// Each page loads the first time it is shown, so opening the WebUI runs only
// the Home status and never lists packages the user did not ask to see. The Log
// page reloads every time, since it is opened to see what just happened.
const loaders = {
    'view-home': loadHome,
    'view-angle': reload,
    'view-options': loadOptions,
    'view-about': loadAbout,
    'view-log': loadLog,
};
const reloadEachTime = new Set(['view-log']);
const loaded = new Set();

function show(viewId) {
    for (const view of document.querySelectorAll('.view')) view.classList.toggle('active', view.id === viewId);
    for (const item of document.querySelectorAll('.nav-item')) item.classList.toggle('active', item.dataset.view === viewId);
    window.scrollTo(0, 0);
    if (reloadEachTime.has(viewId) || !loaded.has(viewId)) {
        loaded.add(viewId);
        loaders[viewId]();
    }
}

for (const item of document.querySelectorAll('.nav-item')) {
    item.addEventListener('click', () => show(item.dataset.view));
}
for (const opener of document.querySelectorAll('[data-open-view]')) {
    opener.addEventListener('click', () => show(opener.dataset.openView));
}

renderIcons(document);
show('view-home');
