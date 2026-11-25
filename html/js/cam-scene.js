// ========================================
// THE CAMERA CREATOR'S SCENE — what the camera looks at (tools/camera.lua "The scene", shared/cam_scene.lua)
//
// Three parts, drawn into the Camera Creator's own panels (html/js/cam-editor.js hands its helpers over):
//   the Scene tab (the card)   add an actor, a vehicle, a prop or a light where the camera looks; the cast,
//                              the tracks (focus, time & weather, effects, markers), each picked with a press
//   the inspector (right)      the picked thing: what it is, where it is, and keys at the playhead (an emote from
//                              WHIP's emote menu, walk here, drive here, lights, a fade ...) and its keys so far
//   the lanes (the timeline)   one row per thing and track under the camera's keys: its keys as dots, dragged
//                              to move them, pressed to go there
//
// IT DRAWS; LUA DECIDES, as the rest of the editor: every press is a callback, and the state comes back whole.
// Ported from whip_cine (an unofficial WHIP fork of atiysu's aty_cinematic, MIT).
//
// 2022-SAFE (CEF is Chromium 103): no :has(), no CSS nesting, no color-mix().
// ========================================

const LANES = [
    { key: 'actors', label: 'Actor', many: 'Actors', glyph: '👤' },
    { key: 'vehicles', label: 'Vehicle', many: 'Vehicles', glyph: '🚗' },
    { key: 'props', label: 'Prop', many: 'Props', glyph: '📦' },
    { key: 'lights', label: 'Light', many: 'Lights', glyph: '💡' },
];
const TRACKS = [
    { key: 'dof', label: 'Focus' },
    { key: 'env', label: 'Time & weather' },
    { key: 'fx', label: 'Effects' },
    { key: 'markers', label: 'Markers' },
];

const PEDS = [
    ['a_m_y_business_01', 'Businessman'], ['a_f_y_business_01', 'Businesswoman'], ['a_m_y_hipster_01', 'Hipster'],
    ['a_f_y_hipster_01', 'Hipster (f)'], ['a_m_y_stbla_02', 'Street guy'], ['a_f_y_tourist_01', 'Tourist'],
    ['a_m_m_beach_01', 'Beach'], ['g_m_y_ballaorig_01', 'Gang'], ['s_m_y_cop_01', 'Police'],
    ['s_m_y_swat_01', 'SWAT'], ['s_m_m_security_01', 'Security'], ['s_m_m_paramedic_01', 'Paramedic'],
].map(([key, label]) => ({ key, label }));
const CARS = [
    ['elegy', 'Elegy'], ['sultan', 'Sultan'], ['zentorno', 'Zentorno'], ['comet2', 'Comet'], ['dominator', 'Dominator'],
    ['buffalo', 'Buffalo'], ['police3', 'Police cruiser'], ['ambulance', 'Ambulance'], ['stretch', 'Limo'],
    ['burrito3', 'Van'], ['bati', 'Bati (bike)'], ['faggio', 'Faggio (scooter)'],
].map(([key, label]) => ({ key, label }));
const PROPS = [
    ['prop_box_wood02a', 'Crate'], ['prop_mp_cone_02', 'Cone'], ['prop_barrier_work05', 'Barrier'],
    ['prop_bench_01a', 'Bench'], ['prop_table_03', 'Table'], ['prop_chair_01a', 'Chair'],
    ['prop_dumpster_01a', 'Dumpster'], ['prop_tv_flat_01', 'TV'],
].map(([key, label]) => ({ key, label }));
const DRIVERS = [{ key: '', label: 'Nobody (parked)' }].concat(PEDS);
const WEATHERS = ['EXTRASUNNY', 'CLEAR', 'CLOUDS', 'OVERCAST', 'SMOG', 'FOGGY', 'RAIN', 'THUNDER', 'CLEARING',
    'SNOW', 'BLIZZARD', 'SNOWLIGHT', 'XMAS', 'HALLOWEEN'].map((w) => ({ key: w, label: w.charAt(0) + w.slice(1).toLowerCase() }));
const COLORS = [
    ['Warm', [255, 214, 170]], ['Daylight', [255, 255, 255]], ['Cool', [170, 200, 255]], ['Amber', [255, 150, 40]],
    ['Red', [255, 60, 60]], ['Blue', [60, 120, 255]], ['Green', [80, 255, 120]], ['Purple', [190, 90, 255]],
];
const FX = [
    { label: 'Sparks', key: { particle: { asset: 'core', name: 'ent_brk_sparking_wires', pos: 'here', scale: 1.0 } } },
    { label: 'Smoke', key: { particle: { asset: 'core', name: 'exp_grd_bzgas_smoke', pos: 'here', scale: 1.0, dur: 8000 } } },
    { label: 'Fire', key: { particle: { asset: 'core', name: 'ent_ray_heli_aprtmnt_l_fire', pos: 'here', scale: 1.0, dur: 8000 } } },
    { label: 'Flare', key: { particle: { asset: 'core', name: 'exp_grd_flare', pos: 'here', scale: 1.0, dur: 6000 } } },
    { label: 'Explosion', key: { explosion: { pos: 'here', kind: 2, scale: 1.0 } } },
    { label: 'Car blast', key: { explosion: { pos: 'here', kind: 7, scale: 1.0 } } },
    { label: 'Flash', key: { screen: { name: 'MinigameEndNeutral', dur: 1200 } } },
    { label: 'Blur', key: { screen: { name: 'DrugsMichaelAliensFight', dur: 4000 } } },
];

// The form values a track's next key takes, kept on this page between redraws.
const form = {
    dof: { near: 0, far: 6, strength: 1, focus: '' },
    env: { hour: 18, minute: 30, weather: '', wind: null, rain: null },
    light: { intensity: 8 },
    marker: 'Beat',
};

function sceneOf(st) { return (st && st.seq && st.seq.scene) || {}; }
function listOf(st, lane) { const l = sceneOf(st)[lane]; return Array.isArray(l) ? l : []; }
function keysOf(st, lane, id) {
    const sc = sceneOf(st);
    if (lane === 'dof' || lane === 'env') return (sc[lane] && Array.isArray(sc[lane].keys)) ? sc[lane].keys : [];
    if (lane === 'fx' || lane === 'markers') return Array.isArray(sc[lane]) ? sc[lane] : [];
    const e = listOf(st, lane).find((x) => x.id === id);
    return e && Array.isArray(e.keys) ? e.keys : [];
}

/** Every id a camera key can frame: actors, vehicles, props. */
export function sceneSubjects(st) {
    const out = [];
    for (const lane of ['actors', 'vehicles', 'props']) {
        for (const e of listOf(st, lane)) out.push({ key: e.id, label: e.id });
    }
    return out;
}

/** A key in words, for its row in the list and its dot's tip. */
function describe(k, lm) {
    const bits = [];
    if (k.emote) bits.push('Emote: ' + k.emote);
    if (k.anim) bits.push('Anim: ' + k.anim.name);
    if (k.scenario) bits.push('Scenario');
    if (k.walk) bits.push(k.walk.speed > 1.5 ? 'Run there' : 'Walk there');
    if (k.drive) bits.push('Drive there');
    if (k.face) bits.push('Mood: ' + ((lm && lm[k.face]) || k.face));
    if (k.ragdoll) bits.push('Ragdoll');
    if (k.clear) bits.push('Stop');
    if (k.hide === true) bits.push('Hide');
    if (k.hide === false) bits.push('Show');
    if (k.lights !== undefined) bits.push(k.lights ? 'Lights on' : 'Lights off');
    if (k.siren !== undefined) bits.push(k.siren ? 'Siren on' : 'Siren off');
    if (k.engine !== undefined) bits.push(k.engine ? 'Engine on' : 'Engine off');
    if (k.horn) bits.push('Horn');
    if (k.door) bits.push((k.door[1] ? 'Open' : 'Shut') + ' doors');
    if (k.move) bits.push('Move there');
    if (k.turn) bits.push('Turn');
    if (k.intensity !== undefined) bits.push('Brightness ' + k.intensity);
    if (k.on !== undefined) bits.push(k.on ? 'On' : 'Off');
    if (k.flicker !== undefined) bits.push('Flicker ' + k.flicker);
    if (k.hour !== undefined) bits.push(String(k.hour).padStart(2, '0') + ':' + String(k.minute || 0).padStart(2, '0'));
    if (k.weather) bits.push(k.weather.charAt(0) + k.weather.slice(1).toLowerCase());
    if (k.off) bits.push('Focus off');
    else if (k.near !== undefined) bits.push('Focus ' + (typeof k.focus === 'string' ? 'on ' + k.focus : k.focus ? 'on a point' : k.near + '–' + k.far + ' m'));
    if (k.particle) bits.push('Effect');
    if (k.explosion) bits.push('Explosion');
    if (k.screen) bits.push('Screen: ' + k.screen.name);
    if (k.label) bits.push(k.label);
    return bits.join(' · ') || 'Key';
}

// ---- the Scene tab (the card) ----

export function renderSceneTab(c, x) {
    const { h, btn, section, cbk, st } = x;
    const add = section(c, 'Add where the camera looks');
    const row = h('div', 'ce-btns ce-btns-4');
    for (const l of LANES) {
        row.appendChild(btn(l.label, () => cbk('ceSceneAdd', { lane: l.key }), '', l.key === 'lights'
            ? 'A light where the camera is, pointing where it looks'
            : 'A new ' + l.label.toLowerCase() + ' in the middle of the screen'));
    }
    add.appendChild(row);

    const sel = st.sceneSel || {};
    const cast = section(c, 'In the scene');
    let any = false;
    const chips = h('div', 'ce-chips');
    for (const l of LANES) {
        for (const e of listOf(st, l.key)) {
            any = true;
            const b = h('button', 'ce-chipbtn ce-lane-' + l.key + (sel.lane === l.key && sel.id === e.id ? ' on' : ''));
            b.type = 'button';
            b.appendChild(h('span', 'ce-chip-dot'));
            b.appendChild(h('span', null, e.id));
            b.title = l.label + (e.model ? ': ' + e.model : '');
            b.addEventListener('click', () => cbk('ceSceneSelect', { lane: l.key, id: e.id }));
            chips.appendChild(b);
        }
    }
    if (any) cast.appendChild(chips);
    else cast.appendChild(h('div', 'ce-note', 'Nothing yet. Fly to a spot, look at it and add an actor or a vehicle: its name is a subject your camera keys can orbit and chase.'));

    const tracks = section(c, 'Tracks');
    const tr = h('div', 'ce-btns ce-btns-2');
    for (const t of TRACKS) {
        const n = keysOf(st, t.key).length;
        tr.appendChild(btn(t.label + (n ? ' · ' + n : ''), () => cbk('ceSceneSelect', { lane: t.key }), sel.lane === t.key ? 'on' : '', 'Its keys, and a new one at the playhead'));
    }
    tracks.appendChild(tr);
    c.appendChild(h('div', 'ce-note', st.sceneUp ? 'The scene is up in the world at the playhead.' : (any ? 'Loading the scene…' : '')));
}

// ---- the inspector: the picked thing or track ----

export function renderSceneInspector(p, x) {
    const { h, btn, section, head, select, toggle, numberField, segButtons, cbk, st, fmtTime, playhead } = x;
    const sel = st.sceneSel;
    const lane = sel.lane;
    const id = sel.id;
    const isThing = LANES.some((l) => l.key === lane);
    const def = isThing ? listOf(st, lane).find((e) => e.id === id) : null;
    if (isThing && !def) return false;
    const L = LANES.find((l) => l.key === lane) || TRACKS.find((t) => t.key === lane);
    const key = (k) => cbk('ceSceneKey', { lane, id, key: k });
    const setF = (field, value) => cbk('ceSceneSet', { lane, id, field, value });
    const moods = {};
    for (const m of (st.moods || [])) moods[m.key] = m.label;

    const top = head(p, 'camera', isThing ? id : L.label);
    top.now.appendChild(h('span', 'ce-chip-static', isThing ? L.label : 'Track'));
    top.now.appendChild(h('span', null, 'Keys at ' + fmtTime(playhead)));
    top.row.appendChild(btn('', () => cbk('ceSceneSelect', {}), 'ghost small icon', 'Put it down (Esc)', 'close'));

    // ---- what it is ----
    if (lane === 'actors' || lane === 'vehicles' || lane === 'props') {
        const what = section(p, 'What');
        const list = lane === 'actors' ? PEDS : lane === 'vehicles' ? CARS : PROPS;
        const items = list.some((m) => m.key === def.model) ? list : [{ key: def.model, label: def.model }].concat(list);
        const mw = h('label', 'ce-field ce-field-wide');
        mw.appendChild(h('span', 'ce-field-label', 'Model'));
        mw.appendChild(select(items, def.model, (v) => setF('model', v)));
        what.appendChild(mw);
        const own = h('input', 'ce-input ce-input-text');
        own.type = 'text';
        own.placeholder = 'or type a model name';
        own.addEventListener('keydown', (e) => { if (e.key === 'Enter' && own.value.trim()) setF('model', own.value.trim()); });
        own.addEventListener('change', () => { if (own.value.trim()) setF('model', own.value.trim()); });
        what.appendChild(own);
        if (lane === 'vehicles') {
            const dw = h('label', 'ce-field ce-field-wide');
            dw.appendChild(h('span', 'ce-field-label', 'Driver'));
            dw.appendChild(select(DRIVERS, def.driver || '', (v) => setF('driver', v)));
            what.appendChild(dw);
        }
        const g = h('div', 'ce-grid');
        const heading = lane === 'props' ? (def.rot || [0, 0, 0])[2] : (def.spawn || [0, 0, 0, 0])[3];
        g.appendChild(numberField('Heading', heading, 5, -180, 180, '°', (v) => setF('heading', v || 0)));
        what.appendChild(g);
        const acts = h('div', 'ce-btns ce-btns-2');
        acts.appendChild(btn('Move here', () => cbk('ceSceneHere', { lane, id }), 'primary', 'To where the camera looks'));
        acts.appendChild(btn('Delete', () => cbk('ceSceneDelete', { lane, id }), 'danger'));
        what.appendChild(acts);
        what.appendChild(h('div', 'ce-note', 'Camera keys frame it as "' + id + '": pick it under New keys or a key\'s Of.'));
    }
    if (lane === 'lights') {
        const what = section(p, 'Light');
        what.appendChild(segButtons([{ key: 'spot', label: 'Spot' }, { key: 'point', label: 'Point' }], def.kind, (v) => setF('kind', v)));
        const sw = h('div', 'ce-swatches');
        for (const [name, rgb] of COLORS) {
            const b = h('button', 'ce-swatch' + (def.color && def.color.join() === rgb.join() ? ' on' : ''));
            b.type = 'button';
            b.title = name;
            b.style.background = 'rgb(' + rgb.join(',') + ')';
            b.addEventListener('click', () => setF('color', rgb));
            sw.appendChild(b);
        }
        what.appendChild(sw);
        const g = h('div', 'ce-grid');
        g.appendChild(numberField('Brightness', def.intensity, 0.5, 0, 100, '', (v) => setF('intensity', v || 0)));
        g.appendChild(numberField('Reach', def.range, 0.5, 0.1, 100, 'm', (v) => setF('range', v || 1)));
        if (def.kind === 'spot') {
            g.appendChild(numberField('Beam', def.outer, 1, 1, 90, '°', (v) => setF('outer', v || 40)));
            g.appendChild(numberField('Core', def.inner, 1, 1, 89, '°', (v) => setF('inner', v || 20)));
        }
        g.appendChild(numberField('Falloff', def.falloff, 0.5, 0.1, 50, '', (v) => setF('falloff', v || 4)));
        what.appendChild(g);
        const fw = h('label', 'ce-field ce-field-wide');
        fw.appendChild(h('span', 'ce-field-label', 'Moves with'));
        fw.appendChild(select([{ key: '', label: 'Nothing (stays put)' }].concat(sceneSubjects(st)), def.follow || '', (v) => setF('follow', v)));
        what.appendChild(fw);
        what.appendChild(toggle('Casts shadows', !!def.shadow, (on) => setF('shadow', on)));
        const acts = h('div', 'ce-btns ce-btns-2');
        acts.appendChild(btn('Put at camera', () => cbk('ceSceneHere', { lane, id }), 'primary', 'Where the camera is, pointing where it looks'));
        acts.appendChild(btn('Delete', () => cbk('ceSceneDelete', { lane, id }), 'danger'));
        what.appendChild(acts);
    }

    // ---- keys at the playhead ----
    const ks = section(p, 'Key at the playhead');
    const grid = h('div', 'ce-btns ce-btns-2');
    const add = (label, k, tip, cls) => grid.appendChild(btn(label, () => key(k), cls || '', tip));
    if (lane === 'actors') {
        grid.appendChild(btn('Emote…', () => cbk('ceSceneEmote', { id }), 'primary', 'From the emote menu: its videos, its search'));
        add('Walk here', { walk: 'here' }, 'Walks to where the camera looks');
        add('Run here', { run: 'here' }, 'Runs to where the camera looks');
        add('Ragdoll', { ragdoll: 2500 }, 'Falls over');
        add('Stop', { clear: true }, 'Stops what it was doing');
        add('Hide', { hide: true });
        add('Show', { hide: false });
        ks.appendChild(grid);
        if ((st.moods || []).length) {
            const mw = h('label', 'ce-field ce-field-wide');
            mw.appendChild(h('span', 'ce-field-label', 'Mood from here'));
            mw.appendChild(select([{ key: '', label: 'Pick a mood…' }].concat(st.moods), '', (v) => { if (v) key({ face: v }); }));
            ks.appendChild(mw);
        }
    } else if (lane === 'vehicles') {
        if (def.driver) add('Drive here', { drive: 'here' }, 'Its driver drives to where the camera looks', 'primary');
        add('Lights on', { lights: true }); add('Lights off', { lights: false });
        add('Siren on', { siren: true }); add('Siren off', { siren: false });
        add('Engine on', { engine: true }); add('Engine off', { engine: false });
        add('Horn', { horn: 600 });
        add('Open doors', { door: [0, true] }); add('Shut doors', { door: [0, false] });
        add('Hide', { hide: true }); add('Show', { hide: false });
        ks.appendChild(grid);
        if (!def.driver) ks.appendChild(h('div', 'ce-note', 'Give it a driver to drive it on cue.'));
    } else if (lane === 'props') {
        add('Move here', { move: 'here' }, 'Slides there from its last place, arriving at this key', 'primary');
        add('Hide', { hide: true }); add('Show', { hide: false });
        ks.appendChild(grid);
    } else if (lane === 'lights') {
        const g = h('div', 'ce-grid');
        g.appendChild(numberField('Fade to', form.light.intensity, 0.5, 0, 100, '', (v) => { form.light.intensity = v || 0; }));
        ks.appendChild(g);
        grid.appendChild(btn('Fade to it', () => key({ intensity: form.light.intensity }), 'primary', 'Brightness eases from the key before to this'));
        add('Off', { on: false }); add('On', { on: true });
        add('Flicker', { flicker: 0.4 }); add('Steady', { flicker: 0 });
        ks.appendChild(grid);
    } else if (lane === 'dof') {
        const g = h('div', 'ce-grid');
        g.appendChild(numberField('Sharp from', form.dof.near, 0.1, 0, 1000, 'm', (v) => { form.dof.near = v || 0; }));
        g.appendChild(numberField('Sharp to', form.dof.far, 0.1, 0, 2000, 'm', (v) => { form.dof.far = v || 1; }));
        g.appendChild(numberField('Blur', form.dof.strength, 0.05, 0, 1, '', (v) => { form.dof.strength = v == null ? 1 : v; }));
        ks.appendChild(g);
        const fw = h('label', 'ce-field ce-field-wide');
        fw.appendChild(h('span', 'ce-field-label', 'Follows'));
        fw.appendChild(select([{ key: '', label: 'Nothing (the distances)' }, { key: 'here', label: 'Where the camera looks' }]
            .concat(sceneSubjects(st)), form.dof.focus, (v) => { form.dof.focus = v; }));
        ks.appendChild(fw);
        grid.appendChild(btn('Focus key', () => key({ near: form.dof.near, far: form.dof.far, strength: form.dof.strength,
            focus: form.dof.focus || undefined }), 'primary', 'From here to the next focus key the focus eases across: a focus pull'));
        add('Focus off', { off: true, near: 0, far: 0, strength: 0 });
        ks.appendChild(grid);
        ks.appendChild(h('div', 'ce-note', 'Seen when looking through and played: one subject\'s key, then another\'s, pulls focus between them.'));
    } else if (lane === 'env') {
        const g = h('div', 'ce-grid');
        g.appendChild(numberField('Hour', form.env.hour, 1, 0, 23, 'h', (v) => { form.env.hour = v == null ? 12 : v; }));
        g.appendChild(numberField('Minute', form.env.minute, 5, 0, 59, 'm', (v) => { form.env.minute = v || 0; }));
        g.appendChild(numberField('Wind', form.env.wind, 0.5, 0, 12, '', (v) => { form.env.wind = v; }));
        g.appendChild(numberField('Rain', form.env.rain, 0.05, 0, 1, '', (v) => { form.env.rain = v; }));
        ks.appendChild(g);
        const ww = h('label', 'ce-field ce-field-wide');
        ww.appendChild(h('span', 'ce-field-label', 'Weather'));
        ww.appendChild(select([{ key: '', label: 'As it is' }].concat(WEATHERS), form.env.weather, (v) => { form.env.weather = v; }));
        ks.appendChild(ww);
        const envKey = () => {
            const k = { hour: form.env.hour, minute: form.env.minute };
            if (form.env.weather) k.weather = form.env.weather;
            if (form.env.wind != null) k.wind = form.env.wind;
            if (form.env.rain != null) k.rain = form.env.rain;
            return k;
        };
        grid.appendChild(btn('Time & weather key', () => key(envKey()), 'primary', 'The clock runs smoothly from one time key to the next'));
        add('Blackout', { blackout: true }); add('Lights back', { blackout: false });
        ks.appendChild(grid);
        ks.appendChild(h('div', 'ce-note', 'Only your screen (and whoever plays it) changes: the server\'s weather is left alone.'));
    } else if (lane === 'fx') {
        for (const f of FX) add(f.label, f.key, 'Where the camera looks, at the playhead');
        ks.appendChild(grid);
        ks.appendChild(h('div', 'ce-note', 'Effects go off as it plays past them, never while you scrub.'));
    } else if (lane === 'markers') {
        const i = h('input', 'ce-input ce-input-text');
        i.type = 'text';
        i.maxLength = 32;
        i.value = form.marker;
        i.addEventListener('change', () => { form.marker = i.value.trim() || 'Beat'; });
        ks.appendChild(i);
        grid.appendChild(btn('Marker', () => key({ label: form.marker }), 'primary', 'A named moment on the timeline'));
        ks.appendChild(grid);
    }

    // ---- its keys so far ----
    const keys = keysOf(st, lane, id);
    const kl = section(p, keys.length ? 'Its keys' : null);
    if (!keys.length) kl.appendChild(h('div', 'ce-note', 'No keys yet: move the playhead and add one.'));
    keys.forEach((k, idx) => {
        const row = h('div', 'ce-keyrow');
        const go = h('button', 'ce-keyrow-go');
        go.type = 'button';
        go.appendChild(h('span', 'ce-chip-static', fmtTime(k.t)));
        go.appendChild(h('span', 'ce-keyrow-text', describe(k, moods)));
        go.title = 'The playhead to it';
        go.addEventListener('click', () => cbk('ceScrub', { t: k.t }));
        row.appendChild(go);
        row.appendChild(btn('', () => cbk('ceSceneKeyDelete', { lane, id, i: idx + 1 }), 'ghost small icon', 'Delete this key', 'close'));
        kl.appendChild(row);
    });
    return true;
}

// ---- the lanes (under the camera's keys on the timeline) ----

const ROW = 18;

/** The scene's rows: things first, then the tracks that have keys (or are picked). How many were drawn. */
export function renderSceneLanes(box, x) {
    const { h, cbk, st, xAt, timeAt, snap, fmtTime } = x;
    box.innerHTML = '';
    const sel = st.sceneSel || {};
    const rows = [];
    for (const l of LANES) for (const e of listOf(st, l.key)) rows.push({ lane: l.key, id: e.id, label: e.id });
    for (const t of TRACKS) if (keysOf(st, t.key).length || sel.lane === t.key) rows.push({ lane: t.key, label: t.label });
    rows.forEach((r, n) => {
        const row = h('div', 'ce-srow ce-lane-' + r.lane + (sel.lane === r.lane && (sel.id || null) === (r.id || null) ? ' on' : ''));
        row.style.top = (n * ROW) + 'px';
        const label = h('button', 'ce-srow-label', r.label);
        label.type = 'button';
        label.title = 'Pick it';
        label.addEventListener('pointerdown', (e) => e.stopPropagation());
        label.addEventListener('click', () => cbk('ceSceneSelect', { lane: r.lane, id: r.id }));
        row.appendChild(label);
        keysOf(st, r.lane, r.id).forEach((k, idx) => {
            const dot = h('div', 'ce-skey');
            dot.style.left = xAt(k.t) + '%';
            dot.title = fmtTime(k.t) + ' · ' + describe(k);
            dot.addEventListener('pointerdown', (e) => dotDrag(e, dot, k, r, idx + 1, x));
            row.appendChild(dot);
        });
        box.appendChild(row);
    });
    return rows.length;
}

/** A dot pressed: the playhead to it and its thing picked on release, moved if dragged. */
function dotDrag(e, dot, k, r, i, x) {
    const { cbk, xAt, timeAt, snap } = x;
    if (e.button !== 0 || x.looking()) return;
    e.preventDefault();
    e.stopPropagation();
    dot.setPointerCapture(e.pointerId);
    const startX = e.clientX;
    let moved = false, t = k.t;
    const move = (ev) => {
        if (!moved && Math.abs(ev.clientX - startX) < 4) return;
        moved = true;
        t = snap(timeAt(ev.clientX), ev.shiftKey);
        dot.style.left = xAt(t) + '%';
    };
    const up = () => {
        dot.removeEventListener('pointermove', move);
        dot.removeEventListener('pointerup', up);
        dot.removeEventListener('pointercancel', up);
        if (moved && t !== k.t) cbk('ceSceneKeyMove', { lane: r.lane, id: r.id, i, t });
        else if (!moved) {
            cbk('ceSceneSelect', { lane: r.lane, id: r.id });
            cbk('ceScrub', { t: k.t });
        }
    };
    dot.addEventListener('pointermove', move);
    dot.addEventListener('pointerup', up);
    dot.addEventListener('pointercancel', up);
}

export const SCENE_ROW = ROW;
