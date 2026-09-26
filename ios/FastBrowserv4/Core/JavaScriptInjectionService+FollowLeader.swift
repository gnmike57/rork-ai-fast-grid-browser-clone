import Foundation

/// JavaScript for Follow the Leader mode (record actions in the leader
/// window, robustly replay + verify them in followers) and for session
/// save/load (capture and restore localStorage / sessionStorage). Cookies are
/// handled natively via `WKHTTPCookieStore`; these scripts cover only the
/// in-page pieces.
extension JavaScriptInjectionService {

    // MARK: - Follow the Leader — recorder (leader window only)

    /// The recorder installer, injected into **every** frame of every window
    /// at `.atDocumentStart`.
    ///
    /// Listeners are armed before the page's own scripts run, so an action
    /// taken in the first moments after a page appears is never lost. Until
    /// native arms the window (`followLeaderArmScript`), events are held in a
    /// small, time-bounded buffer rather than posted — which is what makes
    /// early actions recoverable instead of dropped. Descriptors are computed
    /// lazily at post/flush time so an unarmed window (i.e. every follower)
    /// pays almost nothing.
    ///
    /// Idempotent: re-running is a no-op, so it is safe as both a user script
    /// and a manual `evaluateJavaScript` fallback.
    ///
    /// Two fidelities live in here. Relaxed is unchanged: debounced typing,
    /// sampled scrolling, Enter only. Unbreakable (`__ffb_flStrict`) records
    /// every keystroke, every key with its modifiers, focus and blur, the
    /// exact point inside an element that was tapped, each change of hovered
    /// element, and every scroll position — and holds the leader's own
    /// irreversible taps until native says the followers have caught up.
    static func followLeaderRecorderSource() -> String {
        return """
        (function() {
            if (window.__ffb_flRecorder) { return; }
            window.__ffb_flRecorder = true;

            var BUFFER_MS = 6000;
            var BUFFER_MAX = 60;
            var t0 = Date.now();
            var buffer = [];
            // How long a held commit waits for native before releasing itself.
            // A gate that never opens would eat the user's tap, which is worse
            // than a follower being briefly behind.
            var GATE_SELF_RELEASE_MS = 25000;

            var esc = function(s){ try { return (window.CSS && CSS.escape) ? CSS.escape(s) : ('' + s); } catch(e){ return '' + s; } };
            var cssPath = function(el){
                if (!el || el.nodeType !== 1) return '';
                var doc = el.ownerDocument || document;
                if (el === doc.body) return 'body';
                var parts = [];
                var node = el;
                while (node && node.nodeType === 1 && parts.length < 25) {
                    var sel = node.nodeName.toLowerCase();
                    if (node.id) { parts.unshift(sel + '#' + esc(node.id)); break; }
                    var parent = node.parentNode;
                    if (!parent || parent.nodeType !== 1) { parts.unshift(sel); break; }
                    var kids = parent.children;
                    var sameTag = 0, idx = 0;
                    for (var i = 0; i < kids.length; i++) {
                        if (kids[i].nodeName === node.nodeName) { sameTag++; if (kids[i] === node) idx = sameTag; }
                    }
                    if (sameTag > 1) { sel += ':nth-of-type(' + idx + ')'; }
                    parts.unshift(sel);
                    node = parent;
                }
                return parts.join(' > ');
            };
            var labelFor = function(el){
                try {
                    var doc = el.ownerDocument || document;
                    if (el.id) { var l = doc.querySelector('label[for="' + esc(el.id) + '"]'); if (l) return (l.textContent || '').trim().slice(0, 60); }
                    if (el.closest) { var w = el.closest('label'); if (w) return (w.textContent || '').trim().slice(0, 60); }
                } catch(e){}
                return '';
            };
            var hintFor = function(el){
                if (!el || el.nodeType !== 1) return {};
                var g = function(n){ try { return el.getAttribute(n) || ''; } catch(e){ return ''; } };
                var text = '';
                try { text = ((el.innerText || el.value || g('value') || '') + '').trim().slice(0, 60); } catch(e){}
                return {
                    tag: (el.nodeName || '').toLowerCase(),
                    type: (g('type') || '').toLowerCase(),
                    name: g('name'),
                    id: el.id || '',
                    placeholder: g('placeholder'),
                    aria: g('aria-label'),
                    autocomplete: g('autocomplete'),
                    label: labelFor(el),
                    text: text
                };
            };
            var build = function(kind, el, extra){
                var d = { kind: kind, selector: '', hint: {}, frame: '', topFrame: (window.top === window) };
                try { d.frame = location.href; } catch(e){}
                if (el && el.nodeType === 1) { d.selector = cssPath(el); d.hint = hintFor(el); }
                if (extra) { for (var k in extra) d[k] = extra[k]; }
                return d;
            };
            var post = function(obj){
                try {
                    if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.followLeader) {
                        webkit.messageHandlers.followLeader.postMessage(obj);
                    }
                } catch(e){}
            };
            // Synthetic events raised by our own replay engine must never be
            // recorded — that would echo a follower's activity back out.
            var isReplaying = function(){
                try { return Date.now() < (window.__ffb_flReplayUntil || 0); } catch(e){ return false; }
            };
            // A click on a submit button (or Enter in a field) makes the
            // browser raise `submit` as a consequence. Replaying both would
            // submit a follower's form twice, so the consequence is dropped.
            var lastActivationAt = 0;
            var lastValues = new WeakMap();

            // Am I allowed to post? The top window is armed natively, but a
            // sub-frame that mounted *after* that (a panel, a widget, a
            // late-injected checkout box) can never be reached by the
            // parent's one-shot walk. So each frame asks up the chain the
            // first time it sees an action and arms itself — which is also
            // what removes the old twelve-frame ceiling. Cross-origin parents
            // throw and are skipped; they were unreachable either way.
            var isArmed = function(){
                if (window.__ffb_flActive === true) return true;
                try {
                    var p = window.parent;
                    if (p && p !== window) {
                        var up = (p.__ffb_flActive === true)
                            || (typeof p.__ffb_flIsArmed === 'function' && p.__ffb_flIsArmed());
                        if (up) { window.__ffb_flActive = true; return true; }
                    }
                } catch(e){}
                return false;
            };
            window.__ffb_flIsArmed = isArmed;

            // Strictness is asked up the frame chain the same way arming is,
            // so a late-mounted checkout iframe records at the same fidelity
            // as the document that owns it.
            var isStrict = function(){
                if (window.__ffb_flStrict === true) return true;
                try {
                    var p = window.parent;
                    if (p && p !== window) {
                        var up = (p.__ffb_flStrict === true)
                            || (typeof p.__ffb_flIsStrict === 'function' && p.__ffb_flIsStrict());
                        if (up) { window.__ffb_flStrict = true; return true; }
                    }
                } catch(e){}
                return false;
            };
            window.__ffb_flIsStrict = isStrict;

            // Fields whose contents must never travel a character at a time.
            //
            // This is the one place keystroke-exact recording would leak: a
            // per-key action on a card number carries the leader's digits in
            // the key name itself, and a rotating follower would then receive
            // them even though its value is substituted. So a sensitive field
            // is recorded the settled way in both modes — one committed
            // value, which is the only thing substitution can rewrite.
            var SENSITIVE_HINT = /(card|cc-|cardnumber|cardnum|creditcard|\\bpan\\b|cvc|cvv|csc|security.?code|expir|exp.?date|mm.?yy|password|passcode|\\bpin\\b)/;
            var isSensitiveField = function(el){
                try {
                    if (!el || el.nodeType !== 1) return false;
                    var tp = '';
                    try { tp = (el.getAttribute('type') || '').toLowerCase(); } catch(x){}
                    if (tp === 'password') return true;
                    var probe = '';
                    try {
                        probe = [
                            el.getAttribute('autocomplete') || '',
                            el.getAttribute('name') || '',
                            el.id || '',
                            el.getAttribute('placeholder') || '',
                            el.getAttribute('aria-label') || ''
                        ].join(' ').toLowerCase();
                    } catch(x){}
                    if (probe && SENSITIVE_HINT.test(probe)) return true;
                } catch(e){}
                return false;
            };

            var modsOf = function(e){
                var m = [];
                try {
                    if (e.altKey) m.push('alt');
                    if (e.ctrlKey) m.push('ctrl');
                    if (e.metaKey) m.push('meta');
                    if (e.shiftKey) m.push('shift');
                } catch(x){}
                return m.join('+');
            };

            // Where inside the element the tap landed, as a 0…1 fraction of
            // its own box. A follower's copy of that element can sit
            // somewhere else entirely, so an absolute coordinate would be
            // meaningless — but "70% across a slider" travels perfectly.
            var pointOf = function(e, el){
                try {
                    var r = el.getBoundingClientRect();
                    if (!r || r.width <= 0 || r.height <= 0) return null;
                    var cx = (e.clientX == null ? 0 : e.clientX);
                    var cy = (e.clientY == null ? 0 : e.clientY);
                    // A keyboard-activated or scripted click reports 0,0 —
                    // treat that as "no point" so the follower keeps hitting
                    // the centre rather than the top-left corner.
                    if (!cx && !cy) return null;
                    return {
                        px: Math.min(1, Math.max(0, (cx - r.left) / r.width)),
                        py: Math.min(1, Math.max(0, (cy - r.top) / r.height))
                    };
                } catch(x){ return null; }
            };

            // The vocabulary of a point of no return. Deliberately limited to
            // things that submit, pay or navigate: gating every button would
            // make the mode feel broken rather than careful.
            var COMMIT_TEXT = /(sign in|signin|log in|login|submit|continue|next|place order|\\bpay\\b|checkout|check out|\\bbuy\\b|confirm|\\border\\b|purchase|subscribe|register|sign up|signup|create account|\\bsend\\b|\\bapply\\b|\\bbook\\b)/;
            var isCommitEl = function(el){
                try {
                    if (!el || el.nodeType !== 1) return false;
                    var node = el;
                    if (node.closest) {
                        var b = node.closest('button,input[type="submit"],input[type="button"],a,[role="button"]');
                        if (b) { node = b; }
                    }
                    var tag = (node.nodeName || '').toLowerCase();
                    var tp = '';
                    try { tp = (node.getAttribute('type') || '').toLowerCase(); } catch(x){}
                    if (tp === 'submit' || tp === 'image') return true;
                    var form = node.form || (node.closest ? node.closest('form') : null);
                    if (tag === 'button' && tp !== 'button' && tp !== 'reset' && form) return true;
                    var txt = '';
                    try { txt = ((node.innerText || node.value || '') + '').trim().toLowerCase().slice(0, 48); } catch(x){}
                    if (txt && COMMIT_TEXT.test(txt)) return true;
                } catch(e){}
                return false;
            };

            // Commit gate. In Unbreakable the leader's own irreversible tap is
            // cancelled here, reported to native, and re-dispatched only once
            // every window has confirmed everything before it — so the
            // submit happens from an identical starting state everywhere.
            //
            // Our listeners are installed at document start, ahead of the
            // page's own capture handlers, which is what makes cancelling the
            // event here actually stop it.
            var held = null;
            var gateOpen = false;
            var swallow = function(e){
                try { e.preventDefault(); } catch(x){}
                try { e.stopImmediatePropagation(); } catch(x){}
                try { e.stopPropagation(); } catch(x){}
            };
            var gateHold = function(e, el, kind){
                if (!isStrict() || gateOpen || !isArmed() || isReplaying()) return false;
                // Already holding one: swallow the second so an impatient
                // double tap can never stack two commits.
                if (held) { swallow(e); return true; }
                swallow(e);
                held = { el: el, kind: kind };
                post({ kind: 'gate', gateKind: kind, frame: (function(){ try { return location.href; } catch(x){ return ''; } })(), topFrame: (window.top === window) });
                try {
                    setTimeout(function(){
                        if (held) { window.__ffb_flReleaseGate(); }
                    }, GATE_SELF_RELEASE_MS);
                } catch(x){}
                return true;
            };

            var fireEnter = function(el){
                var handled = false;
                var sawSubmit = false;
                var f = el.form || (el.closest ? el.closest('form') : null);
                var witness = function(){ sawSubmit = true; };
                if (f) { try { f.addEventListener('submit', witness, true); } catch(x){} }
                try { el.focus(); } catch(x){}
                ['keydown', 'keypress', 'keyup'].forEach(function(tp){
                    try {
                        var ev = new KeyboardEvent(tp, { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 });
                        var notCancelled = el.dispatchEvent(ev);
                        if (tp === 'keydown' && !notCancelled) { handled = true; }
                    } catch(x){}
                });
                // Only fall back to submitting the form when the page gave no
                // sign of taking the keystroke. Escalating on top of a page
                // that handled it would be a second submission.
                setTimeout(function(){
                    if (handled || sawSubmit || !f) {
                        if (f) { try { f.removeEventListener('submit', witness, true); } catch(x){} }
                        return;
                    }
                    try { if (f.requestSubmit) { f.requestSubmit(); } else { f.submit(); } } catch(x){}
                    try { f.removeEventListener('submit', witness, true); } catch(x){}
                }, 240);
            };

            // Called by native once every window has caught up. Performs the
            // action the user originally took, which then flows through the
            // normal recorder path out to the followers.
            window.__ffb_flReleaseGate = function(){
                if (!held) { return 0; }
                var target = held.el;
                var kind = held.kind;
                held = null;
                gateOpen = true;
                try {
                    if (kind === 'submit') {
                        if (target.requestSubmit) { target.requestSubmit(); }
                        else if (target.submit) { target.submit(); }
                    } else if (kind === 'key') {
                        fireEnter(target);
                    } else if (typeof target.click === 'function') {
                        target.click();
                    }
                } catch(e){}
                try { setTimeout(function(){ gateOpen = false; }, 1500); } catch(x){ gateOpen = false; }
                return 1;
            };
            window.__ffb_flHasHeldGate = function(){ return !!held; };

            var emit = function(kind, el, extra){
                if (isReplaying()) return;
                var now = Date.now();
                if (kind === 'submit' && now - lastActivationAt < 700) { return; }
                if (kind === 'click' || kind === 'key') { lastActivationAt = now; }
                // A field raises both an `input` and a `change` carrying the
                // same settled value; mirroring one value twice is busywork in
                // either mode. Distinct values always pass, so keystroke-exact
                // recording is unaffected.
                if ((kind === 'input' || kind === 'select') && el) {
                    var v = (extra && extra.value != null) ? String(extra.value) : '';
                    try {
                        if (lastValues.get(el) === v) { return; }
                        lastValues.set(el, v);
                    } catch(x){}
                }
                if (isArmed()) { post(build(kind, el, extra)); return; }
                if (now - t0 > BUFFER_MS) return;
                if (buffer.length >= BUFFER_MAX) { buffer.shift(); }
                buffer.push({ kind: kind, el: el, extra: extra });
            };

            // Called by the arm script: replays anything captured before this
            // window was armed, in the order it happened.
            window.__ffb_flFlush = function(){
                var pending = buffer;
                buffer = [];
                for (var i = 0; i < pending.length; i++) {
                    try { post(build(pending[i].kind, pending[i].el, pending[i].extra)); } catch(e){}
                }
                return pending.length;
            };
            window.__ffb_flReset = function(){ buffer = []; };

            document.addEventListener('click', function(e){
                var el = e.target; if (!el || el.nodeType !== 1) return;
                var commit = isCommitEl(el);
                if (commit && gateHold(e, el, 'click')) return;
                var extra = { commit: commit };
                if (isStrict()) {
                    var p = pointOf(e, el);
                    if (p) { extra.px = p.px; extra.py = p.py; }
                }
                emit('click', el, extra);
            }, true);

            // Relaxed debounces so we mirror a settled value rather than every
            // keystroke, and the native queue then collapses consecutive edits
            // of the same field into the final value. Unbreakable emits every
            // input event as it happens, so an input mask or a per-key
            // validator sees the same sequence of states it saw here.
            var readValue = function(el){
                try {
                    if (el.value != null) return String(el.value);
                    if (el.textContent != null) return String(el.textContent);
                } catch(x){}
                return '';
            };
            var inputTimers = new WeakMap();
            document.addEventListener('input', function(e){
                var el = e.target; if (!el) return;
                if (isStrict() && !isSensitiveField(el)) { emit('input', el, { value: readValue(el) }); return; }
                try { var prev = inputTimers.get(el); if (prev) clearTimeout(prev); } catch(x){}
                var id = setTimeout(function(){
                    emit('input', el, { value: readValue(el) });
                }, 90);
                try { inputTimers.set(el, id); } catch(x){}
            }, true);

            // Focus and blur exist only in Unbreakable. Plenty of checkouts
            // only validate a card number when you leave the field, and Tab
            // cannot be replayed as a keystroke (a synthetic Tab moves nothing)
            // — so the focus change it caused is mirrored instead.
            document.addEventListener('focusin', function(e){
                if (!isStrict()) return;
                var el = e.target; if (!el || el.nodeType !== 1) return;
                emit('focus', el, null);
            }, true);

            document.addEventListener('focusout', function(e){
                if (!isStrict()) return;
                var el = e.target; if (!el || el.nodeType !== 1) return;
                emit('blur', el, null);
            }, true);

            // Hover, recorded when the hovered *element* changes rather than
            // as pointer movement: raw movement is thousands of events a
            // minute and would swamp every follower's queue. `pointerover`
            // already fires only on entering a new element.
            var lastHover = null;
            document.addEventListener('pointerover', function(e){
                if (!isStrict()) return;
                var el = e.target; if (!el || el.nodeType !== 1) return;
                if (el === lastHover) return;
                lastHover = el;
                emit('hover', el, null);
            }, true);

            document.addEventListener('change', function(e){
                var el = e.target; if (!el) return;
                var tp = (el.type || '').toLowerCase();
                if (tp === 'checkbox' || tp === 'radio') {
                    emit('check', el, { checked: !!el.checked });
                } else if (el.nodeName === 'SELECT') {
                    var text = '';
                    try { text = (el.selectedIndex >= 0 ? (el.options[el.selectedIndex].text || '') : ''); } catch(x){}
                    emit('select', el, { value: (el.value != null ? String(el.value) : ''), optionText: text });
                } else {
                    emit('input', el, { value: (el.value != null ? String(el.value) : '') });
                }
            }, true);

            document.addEventListener('submit', function(e){
                var el = e.target; if (!el) return;
                if (gateHold(e, el, 'submit')) return;
                emit('submit', el, { commit: true });
            }, true);

            // Enter is how most login forms are actually submitted, so it is
            // recorded in both modes and gated in Unbreakable. Every other key
            // is Unbreakable only.
            document.addEventListener('keydown', function(e){
                if (!e) return;
                var el = e.target; if (!el || el.nodeType !== 1) return;
                if (e.key === 'Enter') {
                    if (gateHold(e, el, 'key')) return;
                    emit('key', el, { key: 'Enter', mods: modsOf(e), commit: true });
                    return;
                }
                if (!isStrict()) return;
                // A modifier pressed on its own carries nothing to replay; it
                // travels as part of the key it modifies.
                if (e.key === 'Shift' || e.key === 'Control' || e.key === 'Alt' || e.key === 'Meta') return;
                // Never send the individual keys of a card number, security
                // code or password. Those fields commit as one settled value,
                // which is what keeps a rotating window on its own card.
                if (isSensitiveField(el)) return;
                emit('key', el, { key: e.key, mods: modsOf(e) });
            }, true);

            if (window.top === window) {
                var lastScroll = 0;
                var scrollQueued = false;
                var flushScroll = function(){
                    scrollQueued = false;
                    emit('scroll', null, { x: Math.round(window.scrollX || 0), y: Math.round(window.scrollY || 0) });
                };
                window.addEventListener('scroll', function(){
                    if (isStrict()) {
                        // Every distinct position, coalesced to one per frame:
                        // the recorder can't post faster than the display
                        // updates, so nothing is skipped and nothing is
                        // duplicated.
                        if (scrollQueued) return;
                        scrollQueued = true;
                        try {
                            if (window.requestAnimationFrame) { window.requestAnimationFrame(flushScroll); }
                            else { setTimeout(flushScroll, 16); }
                        } catch(x){ flushScroll(); }
                        return;
                    }
                    var now = Date.now();
                    if (now - lastScroll < 140) return;
                    lastScroll = now;
                    emit('scroll', null, { x: Math.round(window.scrollX || 0), y: Math.round(window.scrollY || 0) });
                }, true);
            }
        })();
        """
    }

    /// Arms the leader window (and its same-origin sub-frames) and flushes
    /// anything the recorder buffered before arming. Includes the installer
    /// so it still works if the user script never ran for this document.
    ///
    /// - Parameter strict: whether this window records at Unbreakable
    ///   fidelity. Set on every frame in the walk so a sub-frame's own
    ///   listeners agree with the top document.
    static func followLeaderArmScript(strict: Bool) -> String {
        return followLeaderRecorderSource() + """

        (function() {
            var strict = \(strict ? "true" : "false");
            // Same-origin sub-frames record too, so an action inside an
            // embedded panel is mirrored like any other. This walk exists to
            // flush what already-mounted frames buffered; frames that appear
            // later arm themselves on their first action, so there is no
            // frame ceiling any more.
            var walk = function(w, depth){
                if (!w || depth > 4) return 0;
                var n = 0;
                try {
                    w.__ffb_flActive = true;
                    w.__ffb_flStrict = strict;
                    if (typeof w.__ffb_flFlush === 'function') { n += w.__ffb_flFlush(); }
                    var frames = w.document.querySelectorAll('iframe,frame');
                    for (var i = 0; i < frames.length && i < 40; i++) {
                        try { n += walk(frames[i].contentWindow, depth + 1); } catch(e){}
                    }
                } catch(e){}
                return n;
            };
            var flushed = walk(window, 0);
            return JSON.stringify({ armed: true, strict: strict, flushed: flushed });
        })();
        """
    }

    /// Releases a commit the leader is holding, in whichever same-origin frame
    /// is holding it. Walks every frame because a checkout's pay button often
    /// lives inside the provider's iframe rather than the top document.
    static func followLeaderReleaseGateScript() -> String {
        return """
        (function() {
            var released = 0;
            var walk = function(w, depth){
                if (!w || depth > 4) return;
                try {
                    if (typeof w.__ffb_flReleaseGate === 'function') { released += w.__ffb_flReleaseGate(); }
                    var frames = w.document.querySelectorAll('iframe,frame');
                    for (var i = 0; i < frames.length && i < 40; i++) {
                        try { walk(frames[i].contentWindow, depth + 1); } catch(e){}
                    }
                } catch(e){}
            };
            walk(window, 0);
            return JSON.stringify({ released: released });
        })();
        """
    }

    /// Stops the leader recorder from posting further actions and drops
    /// anything still buffered.
    static func followLeaderDisableScript() -> String {
        return """
        (function() {
            var walk = function(w, depth){
                if (!w || depth > 4) return;
                try {
                    w.__ffb_flActive = false;
                    w.__ffb_flStrict = false;
                    // Anything the gate was holding is performed rather than
                    // swallowed: turning the mode off must not eat the tap
                    // the user already made.
                    if (typeof w.__ffb_flReleaseGate === 'function') { w.__ffb_flReleaseGate(); }
                    if (typeof w.__ffb_flReset === 'function') { w.__ffb_flReset(); }
                    var frames = w.document.querySelectorAll('iframe,frame');
                    for (var i = 0; i < frames.length && i < 40; i++) {
                        try { walk(frames[i].contentWindow, depth + 1); } catch(e){}
                    }
                } catch(e){}
            };
            walk(window, 0);
        })();
        """
    }

    // MARK: - Follow the Leader — scored replay + verification

    /// Async function body for `callAsyncJavaScript`. Reads a single
    /// `action` argument, re-locates the target element and applies it.
    ///
    /// Location is a *scored* search, not first-match: every candidate is
    /// graded against the recorded name / id / placeholder / aria / label /
    /// text / type, and the best one above a confidence floor wins — so a
    /// page that shifted around still resolves to the right control instead
    /// of the first vaguely similar one. Same-origin sub-frames are searched
    /// too. Every wait is a short poll rather than a fixed sleep, and the
    /// whole body is bounded so it always returns quickly.
    ///
    /// Returns `{ ok, kind, method, verified, reason }`.
    static func followLeaderApplyBody() -> String {
        return """
        const a = action || {};
        const H = a.hint || {};
        const kind = a.kind || '';
        const started = Date.now();
        const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
        const norm = (s) => ('' + (s == null ? '' : s)).trim().toLowerCase();
        const esc = (s) => { try { return (window.CSS && CSS.escape) ? CSS.escape(s) : ('' + s); } catch (e) { return '' + s; } };
        const attr = (el, n) => { try { return el.getAttribute(n) || ''; } catch (e) { return ''; } };
        const fire = (el, type) => { try { el.dispatchEvent(new Event(type, { bubbles: true })); } catch (e) {} };
        const mods = ('' + (a.mods || '')).split('+');
        const modInit = {
            altKey: mods.indexOf('alt') !== -1,
            ctrlKey: mods.indexOf('ctrl') !== -1,
            metaKey: mods.indexOf('meta') !== -1,
            shiftKey: mods.indexOf('shift') !== -1
        };
        // Legacy keyCode/which are still what a surprising number of form
        // scripts branch on, so single characters get their real code and
        // the named keys get the values those scripts expect.
        const legacyCode = (name) => {
            const table = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34, ' ': 32 };
            if (table[name] != null) return table[name];
            if (('' + name).length === 1) { try { return ('' + name).toUpperCase().charCodeAt(0); } catch (e) { return 0; } }
            return 0;
        };
        // The point inside the element to activate, as a fraction of its box.
        // Negative means "not recorded", which keeps the old centre-of-element
        // behaviour for every Relaxed action.
        const hasPoint = (typeof a.px === 'number' && a.px >= 0 && typeof a.py === 'number' && a.py >= 0);
        const pointIn = (rect) => hasPoint
            ? { x: rect.left + rect.width * a.px, y: rect.top + rect.height * a.py }
            : { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };

        // Suppress our own synthetic events from being re-recorded.
        const holdReplayFlag = () => { try { window.__ffb_flReplayUntil = Date.now() + 1500; } catch (e) {} };
        holdReplayFlag();

        const vis = (el) => {
            try {
                if (!el) return false;
                if (window.__ffb_isVisible) return !!window.__ffb_isVisible(el);
                const r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                if (r && (r.width > 0 || r.height > 0)) return true;
                return el.offsetParent !== null;
            } catch (e) { return false; }
        };

        // This document plus every same-origin sub-frame, nested ones
        // included — a control the leader used inside a late-mounted panel
        // has to be findable here too, or the mirroring is one-sided.
        // Cross-origin frames throw and are skipped: unreachable by design.
        function collectDocs(doc, out, depth) {
            if (!doc || depth > 4 || out.length >= 40) return;
            let frames = [];
            try { frames = doc.querySelectorAll('iframe,frame'); } catch (e) { frames = []; }
            for (let i = 0; i < frames.length && out.length < 40; i++) {
                let child = null;
                try { child = frames[i].contentDocument; } catch (e) { child = null; }
                if (child && child.querySelector) {
                    out.push(child);
                    collectDocs(child, out, depth + 1);
                }
            }
        }

        function documents() {
            const docs = [document];
            collectDocs(document, docs, 0);
            if (!a.topFrame && a.frame) {
                docs.sort((d1, d2) => {
                    const h1 = (() => { try { return d1.location.href; } catch (e) { return ''; } })();
                    const h2 = (() => { try { return d2.location.href; } catch (e) { return ''; } })();
                    return (h2 === a.frame ? 1 : 0) - (h1 === a.frame ? 1 : 0);
                });
            }
            return docs;
        }

        function labelText(el) {
            try {
                const doc = el.ownerDocument || document;
                if (el.id) { const l = doc.querySelector('label[for="' + esc(el.id) + '"]'); if (l) return norm(l.textContent).slice(0, 60); }
                if (el.closest) { const w = el.closest('label'); if (w) return norm(w.textContent).slice(0, 60); }
            } catch (e) {}
            return '';
        }

        function score(el) {
            if (!el || el.nodeType !== 1) return -1;
            let s = vis(el) ? 22 : -45;
            if (H.id && el.id === H.id) s += 90;
            if (H.name && attr(el, 'name') === H.name) s += 70;
            if (H.placeholder) {
                const ph = attr(el, 'placeholder');
                if (ph === H.placeholder) s += 46;
                else if (ph && norm(ph).indexOf(norm(H.placeholder)) !== -1) s += 20;
            }
            if (H.aria && attr(el, 'aria-label') === H.aria) s += 40;
            if (H.autocomplete && attr(el, 'autocomplete') === H.autocomplete) s += 26;
            if (H.label) {
                const lt = labelText(el);
                if (lt && lt === norm(H.label)) s += 34;
                else if (lt && lt.length > 2 && norm(H.label).indexOf(lt) !== -1) s += 14;
            }
            if (H.tag && norm(el.nodeName) === H.tag) s += 12;
            if (H.type && norm(attr(el, 'type')) === H.type) s += 16;
            if (H.text) {
                const want = norm(H.text);
                let et = '';
                try { et = norm(el.innerText || el.value || attr(el, 'value')); } catch (e) {}
                if (et && et === want) s += 44;
                else if (et && want.length > 2 && et.indexOf(want) !== -1) s += 18;
                else if (et && et.length > 2 && want.indexOf(et) !== -1) s += 12;
            }
            return s;
        }

        const VALUE_KINDS = (kind === 'input' || kind === 'select' || kind === 'check');
        // Focus, blur and keystrokes land on fields; hover can land on
        // anything at all, which is exactly why hover menus work.
        const FIELD_KINDS = (kind === 'focus' || kind === 'blur' || kind === 'key');
        function pool(doc) {
            let sel = 'button,input,a,select,textarea,summary,label,[role="button"],[role="link"],[type="submit"],[onclick]';
            if (VALUE_KINDS) {
                sel = 'input,textarea,select,[contenteditable="true"]';
            } else if (FIELD_KINDS) {
                sel = 'input,textarea,select,button,a,[contenteditable="true"],[tabindex],[role="button"]';
            } else if (kind === 'hover') {
                sel = 'a,button,li,summary,label,[role="button"],[role="menuitem"],[role="link"],[role="tab"],[aria-haspopup],[onmouseover],[onmouseenter]';
            }
            try { return doc.querySelectorAll(sel); } catch (e) { return []; }
        }

        function locate() {
            const docs = documents();
            if (a.selector) {
                for (let d = 0; d < docs.length; d++) {
                    try { const e0 = docs[d].querySelector(a.selector); if (e0 && vis(e0)) return e0; } catch (e) {}
                }
            }
            if (H.id) {
                for (let d = 0; d < docs.length; d++) {
                    try { const e1 = docs[d].getElementById(H.id); if (e1 && vis(e1)) return e1; } catch (e) {}
                }
            }
            let best = null;
            let bestScore = 54;
            for (let d = 0; d < docs.length; d++) {

                const nodes = pool(docs[d]);
                const limit = Math.min(nodes.length, 900);
                for (let i = 0; i < limit; i++) {
                    const sc = score(nodes[i]);
                    if (sc > bestScore) { bestScore = sc; best = nodes[i]; }
                }
            }
            if (best) return best;
            if (kind === 'input') {
                if (H.type === 'password' && window.__ffb_findPassword) { const p = window.__ffb_findPassword(''); if (p) return p; }
                if (window.__ffb_findUsername && (H.type === 'email' || H.type === 'text' || H.autocomplete === 'username' || H.autocomplete === 'email')) {
                    const u = window.__ffb_findUsername(''); if (u) return u;
                }
            } else if (kind === 'click' || kind === 'submit' || kind === 'key') {
                if (window.__ffb_findSubmit) { const sb = window.__ffb_findSubmit(''); if (sb) return sb; }
            }
            return null;
        }

        // Page fingerprint. The last three terms are what let a *content
        // swap* register: a tab that only replaces its own panel leaves the
        // URL, the title and the top-level child count completely untouched,
        // so the old fingerprint called it "nothing happened" and the click
        // got escalated — i.e. pressed again.
        const sig = () => {
            try {
                const body = document.body;
                return location.href + '|' + document.title + '|' + (body ? body.childElementCount : 0)
                    + '|' + document.forms.length + '|' + (document.activeElement ? document.activeElement.tagName : '')
                    + '|' + document.readyState
                    + '|' + (body ? body.getElementsByTagName('*').length : 0)
                    + '|' + (body ? Math.round(body.scrollHeight / 8) : 0)
                    + '|' + document.querySelectorAll('[aria-expanded="true"],[aria-selected="true"],[aria-checked="true"],[open]').length;
            } catch (e) { return 'sig-error'; }
        };

        // A live DOM watcher catches everything the fingerprint cannot — an
        // in-place re-render, a row appended to a cart, a class toggled on a
        // panel. Erring towards "something happened" is the safe direction:
        // it stops an escalation, and an escalation is a second press.
        function watchDOM(doc) {
            const state = { hits: 0, stop: function () {} };
            try {
                const root = (doc || document).documentElement || (doc || document).body;
                if (root && window.MutationObserver) {
                    const obs = new MutationObserver(function (records) { state.hits += records.length; });
                    obs.observe(root, { childList: true, subtree: true, attributes: true });
                    state.stop = function () { try { obs.disconnect(); } catch (e) {} };
                }
            } catch (e) {}
            return state;
        }

        // Poll instead of sleeping a fixed slice: a tap that worked is
        // detected in ~16ms rather than after a flat wait.
        async function changedWithin(before, watch, ms) {
            const end = Date.now() + ms;
            const baseline = watch ? watch.hits : 0;
            while (Date.now() < end) {
                await sleep(16);
                if (watch && watch.hits > baseline) return true;
                if (sig() !== before) return true;
            }
            return false;
        }

        if (kind === 'scroll') {
            try { window.scrollTo(a.x || 0, a.y || 0); } catch (e) {}
            return { ok: true, kind: 'scroll', method: 'scrollTo', verified: true };
        }

        // Hold the action until the document is usable rather than firing it
        // into a half-built page.
        const readyDeadline = started + 1200;
        while (Date.now() < readyDeadline) {
            let state = 'complete';
            try { state = document.readyState; } catch (e) {}
            if (state === 'interactive' || state === 'complete') break;
            await sleep(25);
        }

        let el = null;
        const findDeadline = started + 1600;
        for (;;) {
            el = locate();
            if (el || Date.now() > findDeadline) break;
            await sleep(60);
        }
        if (!el) return { ok: false, kind: kind, reason: 'not-found', verified: false };
        holdReplayFlag();

        const tag = norm(el.nodeName);

        if (kind === 'select' || (kind === 'input' && tag === 'select')) {
            const target = (a.value == null ? '' : '' + a.value);
            const wantText = norm(a.optionText || '');
            let matched = false;
            try {
                for (let i = 0; i < el.options.length; i++) {
                    if (('' + el.options[i].value) === target) { el.selectedIndex = i; matched = true; break; }
                }
                if (!matched && wantText) {
                    for (let i = 0; i < el.options.length; i++) {
                        if (norm(el.options[i].text) === wantText) { el.selectedIndex = i; matched = true; break; }
                    }
                }
            } catch (e) {}
            fire(el, 'input'); fire(el, 'change');
            return { ok: matched, kind: 'select', method: 'selectedIndex', verified: matched, reason: matched ? '' : 'no-matching-option' };
        }

        if (kind === 'input') {
            const target = (a.value == null ? '' : '' + a.value);
            const editable = (tag !== 'input' && tag !== 'textarea');
            const read = () => {
                try { return editable ? ('' + (el.textContent || '')) : (el.value == null ? '' : '' + el.value); } catch (e) { return ''; }
            };
            const setNative = (v) => {
                if (!editable && window.__ffb_setNativeValue) { window.__ffb_setNativeValue(el, v); return; }
                try { if (editable) { el.textContent = v; } else { el.value = v; } } catch (e) {}
                fire(el, 'input'); fire(el, 'change');
            };
            const techniques = [
                function nativeSetter() { setNative(target); },
                function focusType() { try { el.focus(); } catch (e) {} setNative(target); },
                function charByChar() {
                    try { el.focus(); } catch (e) {}
                    setNative('');
                    for (let i = 0; i < target.length; i++) {
                        try { if (editable) { el.textContent = target.slice(0, i + 1); } else { el.value = target.slice(0, i + 1); } } catch (e) {}
                        fire(el, 'keydown'); fire(el, 'input'); fire(el, 'keyup');
                    }
                    fire(el, 'change');
                },
                function attrSet() { try { el.setAttribute('value', target); } catch (e) {} setNative(target); }
            ];
            for (let i = 0; i < techniques.length; i++) {
                try { techniques[i](); } catch (e) {}
                // Settle poll — returns as soon as the field holds the value.
                const end = Date.now() + 120;
                let ok = (read() === target);
                while (!ok && Date.now() < end) { await sleep(12); ok = (read() === target); }
                if (ok) {
                    try { if (el.blur) el.blur(); } catch (e) {}
                    return { ok: true, kind: 'input', method: techniques[i].name, verified: true };
                }
            }
            return { ok: false, kind: 'input', reason: 'value-mismatch', verified: false };
        }

        if (kind === 'check') {
            const want = !!a.checked;
            if (!!el.checked !== want) {
                try { el.click(); } catch (e) {}
                await sleep(30);
            }
            if (!!el.checked !== want) {
                try { el.checked = want; } catch (e) {}
                fire(el, 'input'); fire(el, 'change');
                await sleep(20);
            }
            const ok = (!!el.checked === want);
            return { ok: ok, kind: 'check', method: 'toggle', verified: ok, reason: ok ? '' : 'state-mismatch' };
        }

        // Hover: enter the element the way a pointer would, so a menu that
        // only opens on hover opens here too. Never escalates and never
        // clicks — a hover that finds its element has done its job.
        if (kind === 'hover') {
            try {
                const r = el.getBoundingClientRect();
                const p = pointIn(r);
                ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove'].forEach(function (tp) {
                    try {
                        el.dispatchEvent(new MouseEvent(tp, { bubbles: (tp !== 'pointerenter' && tp !== 'mouseenter'), cancelable: true, clientX: p.x, clientY: p.y }));
                    } catch (e) {}
                });
            } catch (e) {}
            return { ok: true, kind: 'hover', method: 'pointerover', verified: true };
        }

        // Focus and blur are mirrored because a great many checkouts only
        // validate a field when you leave it, and because a replayed Tab
        // cannot move focus by itself.
        if (kind === 'focus') {
            let focused = false;
            try { el.focus({ preventScroll: false }); focused = (document.activeElement === el); } catch (e) {}
            if (!focused) { try { el.focus(); focused = (document.activeElement === el); } catch (e) {} }
            fire(el, 'focus');
            return { ok: true, kind: 'focus', method: focused ? 'focus' : 'delivered', verified: focused };
        }

        if (kind === 'blur') {
            let blurred = false;
            try { el.blur(); blurred = (document.activeElement !== el); } catch (e) {}
            fire(el, 'blur');
            fire(el, 'change');
            return { ok: true, kind: 'blur', method: blurred ? 'blur' : 'delivered', verified: blurred };
        }

        if (kind === 'key') {
            const keyName = a.key || 'Enter';
            const before = sig();
            const watch = watchDOM(el.ownerDocument || document);
            const f = el.form || (el.closest ? el.closest('form') : null);
            // Two independent proofs that the page took the keystroke: it
            // cancelled our keydown (every SPA login form does), or the form
            // actually raised `submit`. Either one means escalating to a
            // manual submit would be a *second* submission.
            let sawSubmit = false;
            const submitWitness = function () { sawSubmit = true; };
            if (f) { try { f.addEventListener('submit', submitWitness, true); } catch (e) {} }
            const cleanup = function () {
                watch.stop();
                if (f) { try { f.removeEventListener('submit', submitWitness, true); } catch (e) {} }
            };

            let handled = false;
            try { el.focus(); } catch (e) {}
            const code = legacyCode(keyName);
            // `keypress` is only meaningful for keys that produce a character,
            // so a replayed Backspace or Escape does not raise a phantom one.
            const isPrintable = ('' + keyName).length === 1;
            const sequence = isPrintable ? ['keydown', 'keypress', 'keyup'] : ['keydown', 'keyup'];
            sequence.forEach(function (tp) {
                try {
                    const init = { bubbles: true, cancelable: true, key: keyName, code: keyName, keyCode: code, which: code };
                    for (const m in modInit) { init[m] = modInit[m]; }
                    const ev = new KeyboardEvent(tp, init);
                    const notCancelled = el.dispatchEvent(ev);
                    if (tp === 'keydown' && !notCancelled) { handled = true; }
                } catch (e) {}
            });
            // Only a commit needs proof it went somewhere. An ordinary
            // keystroke is accompanied by its own input action carrying the
            // resulting value, so waiting on a page change here would add a
            // third of a second to every character typed.
            if (keyName !== 'Enter') {
                cleanup();
                return { ok: true, kind: 'key', method: handled ? 'keyboard' : 'delivered', verified: handled };
            }
            let changed = await changedWithin(before, watch, 320);
            if (changed || handled || sawSubmit) {
                cleanup();
                return { ok: true, kind: 'key', method: changed ? 'keyboard' : 'delivered', verified: changed };
            }
            if (keyName === 'Enter' && f) {
                try { if (f.requestSubmit) { f.requestSubmit(); } else { f.submit(); } } catch (e) {}
                changed = await changedWithin(before, watch, 260);
                cleanup();
                return { ok: true, kind: 'key', method: changed ? 'formSubmit' : 'delivered', verified: changed };
            }
            cleanup();
            return { ok: true, kind: 'key', method: 'attempted', verified: false };
        }

        if (kind === 'click' || kind === 'submit') {
            const before = sig();
            const doc = el.ownerDocument || document;
            const form = (tag === 'form') ? el : (el.form || (el.closest ? el.closest('form') : null));
            const watch = watchDOM(doc);

            // Independent witness that the activation actually reached the
            // control. A capture-phase listener on the document sees the
            // click before any page handler can swallow it, so a button that
            // does something invisible (add to cart, a counter, a tab that
            // swaps its own panel) is still provably pressed — and is never
            // pressed a second time by an escalation.
            let reached = false;
            const witness = function (ev) {
                try {
                    if (ev.target === el) { reached = true; return; }
                    if (el.contains && el.contains(ev.target)) { reached = true; return; }
                    if (ev.composedPath && ev.composedPath().indexOf(el) !== -1) { reached = true; }
                } catch (e) {}
            };
            try { doc.addEventListener('click', witness, true); } catch (e) {}
            let sawSubmit = false;
            const submitWitness = function () { sawSubmit = true; };
            if (form) { try { form.addEventListener('submit', submitWitness, true); } catch (e) {} }
            const cleanup = function () {
                watch.stop();
                try { doc.removeEventListener('click', witness, true); } catch (e) {}
                if (form) { try { form.removeEventListener('submit', submitWitness, true); } catch (e) {} }
            };

            // Each technique reports whether it definitely delivered the
            // activation, so escalation is driven by evidence rather than by
            // "the screen looks the same".
            const submitForm = function formSubmit() {
                if (!form) return false;
                if (form.requestSubmit) { try { form.requestSubmit(); return true; } catch (e) {} }
                try { form.submit(); return true; } catch (e) {}
                return false;
            };
            const mouseSeq = function mouse() {
                let sent = false;
                try {
                    const r = el.getBoundingClientRect();
                    const p = pointIn(r);
                    ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (tp) {
                        try {
                            el.dispatchEvent(new MouseEvent(tp, { bubbles: true, cancelable: true, clientX: p.x, clientY: p.y }));
                            if (tp === 'click') { sent = true; }
                        } catch (e) {}
                    });
                } catch (e) {}
                return sent;
            };
            const nativeClick = function nativeClick() {
                try { if (el.scrollIntoView) el.scrollIntoView({ block: 'center' }); } catch (e) {}
                try { if (typeof el.click === 'function') { el.click(); return true; } } catch (e) {}
                return false;
            };
            // A recorded form submit goes straight to the form; a tap tries
            // the element itself first — unless the leader's tap point was
            // recorded, in which case the positioned mouse sequence goes
            // first, because `element.click()` throws away the one piece of
            // information a map, slider or canvas actually needs.
            const techniques = (tag === 'form')
                ? [submitForm, nativeClick]
                : (hasPoint ? [mouseSeq, nativeClick, submitForm] : [nativeClick, mouseSeq, submitForm]);
            let acted = false;
            let delivered = false;
            let usedMethod = 'attempted';
            for (let i = 0; i < techniques.length; i++) {
                let sent = false;
                try { sent = !!techniques[i](); } catch (e) {}
                if (sent) { acted = true; usedMethod = techniques[i].name; }
                if (await changedWithin(before, watch, 240)) {
                    cleanup();
                    return { ok: true, kind: kind, method: sent ? techniques[i].name : 'observed', verified: true };
                }
                // Proof of delivery stops the loop here. Trying the next
                // technique would fire the same control again.
                if (sent || reached || sawSubmit) { delivered = true; break; }
            }
            cleanup();
            if (delivered) {
                // The control was provably activated; the page simply did
                // something this document cannot observe. Counting it as done
                // is what keeps a quiet button from being pressed twice.
                return { ok: true, kind: kind, method: 'delivered', verified: false, reason: usedMethod };
            }
            // Nothing landed — covered by an overlay, disabled, detached. This
            // is a real miss and is allowed to retry.
            return { ok: acted, kind: kind, method: 'attempted', verified: false };
        }

        return { ok: false, kind: kind || 'unknown', reason: 'unhandled', verified: false };
        """
    }

    // MARK: - Session save / load — local + session storage

    /// Reads the current page's localStorage and sessionStorage (origin
    /// scoped, per the same-origin policy) plus its origin/href.
    static func sessionStorageCaptureScript() -> String {
        return """
        (function() {
            var ls = {}, ss = {};
            try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); ls[k] = localStorage.getItem(k); } } catch (e) {}
            try { for (var j = 0; j < sessionStorage.length; j++) { var k2 = sessionStorage.key(j); ss[k2] = sessionStorage.getItem(k2); } } catch (e) {}
            return JSON.stringify({ origin: location.origin, href: location.href, localStorage: ls, sessionStorage: ss });
        })();
        """
    }

    /// Restores previously captured storage into the current page. The two
    /// arguments must be valid JSON object literals (`{"k":"v",...}`).
    static func sessionStorageRestoreScript(localStorageJSON: String, sessionStorageJSON: String) -> String {
        return """
        (function() {
            try {
                var ls = \(localStorageJSON);
                for (var k in ls) { try { localStorage.setItem(k, ls[k]); } catch (e) {} }
            } catch (e) {}
            try {
                var ss = \(sessionStorageJSON);
                for (var k2 in ss) { try { sessionStorage.setItem(k2, ss[k2]); } catch (e) {} }
            } catch (e) {}
            return JSON.stringify({ restored: true });
        })();
        """
    }
}
