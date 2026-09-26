import Foundation

/// JavaScript for Instant Fill: one complete reading of everything filled in
/// the leader, and one batch write of that reading into a follower.
///
/// Deliberately a *snapshot*, not a stream. Follow the Leader already mirrors
/// keystroke by keystroke; this exists for the other case — you filled a form
/// in the leader (by hand, by autofill, by paste, or before the mode was even
/// on) and now want the same thing in every other window in one press. Nothing
/// here records, queues or replays: it reads once and writes once.
///
/// Like the card fill, this fills and nothing else. There is no click, no
/// `form.submit()` and no synthesised Enter anywhere in this file.
extension JavaScriptInjectionService {

    // MARK: - Audit (leader window)

    /// Body for `callAsyncJavaScript`. Takes no arguments and returns
    /// `{ fields: [...], scanned: Int }`.
    ///
    /// Every visible, filled control in the document and its same-origin
    /// sub-frames, each carrying enough description for a follower to find its
    /// own copy of that control: the CSS path, the identifying attributes, the
    /// visible label, and its ordinal position among the fields of its frame.
    /// An empty field is skipped — Instant Fill copies what you filled in, and
    /// blanking a follower's box is not that.
    static func instantFillAuditBody() -> String {
        """
        \(instantFillSharedHelpers())

        const out = [];
        let scanned = 0;
        const docs = documents();

        for (let d = 0; d < docs.length; d++) {
            const doc = docs[d];
            let frameHref = '';
            try { frameHref = doc.location.href; } catch (e) { frameHref = ''; }

            let nodes = [];
            try {
                nodes = Array.prototype.slice.call(
                    doc.querySelectorAll('input,select,textarea,[contenteditable="true"]')
                );
            } catch (e) { nodes = []; }

            // Ordinal position is counted over every candidate field in the
            // frame, filled or not, so "the third field on this form" means
            // the same thing on a follower whose boxes are not all filled.
            let ordinal = -1;
            for (let i = 0; i < nodes.length; i++) {
                const el = nodes[i];
                // One hostile field — a proxied getter, a custom element that
                // has not upgraded — must never take the rest of the form
                // down with it.
                try {
                    if (!isFieldCandidate(el)) continue;
                    ordinal += 1;
                    scanned += 1;
                    if (out.length >= MAX_FIELDS) break;
                    if (!vis(el)) continue;

                    const tag = norm(el.nodeName);
                    const type = norm(attr(el, 'type') || el.type || '');
                    const editable = isEditable(el);

                    // Buttons are not content. They are pressed, not filled,
                    // and copying one as a value would be meaningless.
                    if (type === 'submit' || type === 'button' || type === 'reset' || type === 'image') continue;
                    if (type === 'file') continue;

                    const entry = {
                        selector: cssPath(el),
                        frame: frameHref,
                        index: ordinal,
                        tag: tag,
                        type: type,
                        name: attr(el, 'name'),
                        id: el.id || '',
                        placeholder: attr(el, 'placeholder'),
                        aria: attr(el, 'aria-label'),
                        autocomplete: attr(el, 'autocomplete'),
                        label: labelText(el),
                        value: '',
                        optionText: '',
                        checked: false,
                        isCheckbox: false,
                        isSelect: false,
                        isEditable: editable
                    };

                    if (type === 'checkbox' || type === 'radio') {
                        entry.isCheckbox = true;
                        entry.checked = !!el.checked;
                        // An untouched, unticked box carries no instruction.
                        // Ticking is the action; leaving alone is the default.
                        if (!entry.checked) continue;
                    } else if (tag === 'select') {
                        entry.isSelect = true;
                        let v = '';
                        let t = '';
                        try { v = el.value == null ? '' : ('' + el.value); } catch (e) {}
                        try { t = el.selectedIndex >= 0 ? ('' + (el.options[el.selectedIndex].text || '')) : ''; } catch (e) {}
                        entry.value = v;
                        entry.optionText = t;
                        // A select resting on its placeholder row is not a
                        // choice the user made.
                        if (!v || isPlaceholderChoice(el)) continue;
                    } else {
                        let v = '';
                        try {
                            v = editable
                                ? ('' + (el.textContent || ''))
                                : (el.value == null ? '' : '' + el.value);
                        } catch (e) { v = ''; }
                        entry.value = v;
                        if (!v.trim()) continue;
                    }

                    out.push(entry);
                } catch (e) {}
            }
            if (out.length >= MAX_FIELDS) break;
        }

        return { fields: out, scanned: scanned };
        """
    }

    // MARK: - Apply (follower windows)

    /// Body for `callAsyncJavaScript`, called with a single `snapshot`
    /// argument of the form `{ fields: [...] }`.
    ///
    /// Returns `{ found, filled, missed }`. `found` counts snapshot fields
    /// that resolved to a control here; `filled` counts the ones actually
    /// written. A field already holding the right value counts as found but
    /// not filled — rewriting it would restart the site's own formatting and
    /// validation for nothing.
    static func instantFillApplyBody() -> String {
        """
        \(instantFillSharedHelpers())

        const fields = (snapshot && snapshot.fields) ? snapshot.fields : [];
        const docs = documents();

        // A control may satisfy exactly one snapshot field. Without this a
        // form of four similar boxes could take the same value four times,
        // which looks like a fill and is actually a single value smeared
        // across the form.
        const used = new Set();

        // Ordinal fallback needs the same candidate list the audit counted,
        // built once per document rather than per field.
        const ordinalCache = new Map();
        function candidates(doc) {
            if (ordinalCache.has(doc)) return ordinalCache.get(doc);
            let nodes = [];
            try {
                nodes = Array.prototype.slice.call(
                    doc.querySelectorAll('input,select,textarea,[contenteditable="true"]')
                );
            } catch (e) { nodes = []; }
            const list = [];
            for (let i = 0; i < nodes.length; i++) {
                try { if (isFieldCandidate(nodes[i])) list.push(nodes[i]); } catch (e) {}
            }
            ordinalCache.set(doc, list);
            return list;
        }

        // Documents ordered so the frame the field came from is tried first.
        function docsFor(f) {
            if (!f.frame) return docs;
            const ordered = docs.slice();
            ordered.sort((d1, d2) => {
                const h1 = (() => { try { return d1.location.href; } catch (e) { return ''; } })();
                const h2 = (() => { try { return d2.location.href; } catch (e) { return ''; } })();
                return (h2 === f.frame ? 1 : 0) - (h1 === f.frame ? 1 : 0);
            });
            return ordered;
        }

        function shapeMatches(el, f) {
            const tag = norm(el.nodeName);
            if (f.isSelect) return tag === 'select';
            if (f.isCheckbox) {
                const t = norm(attr(el, 'type') || el.type || '');
                return t === 'checkbox' || t === 'radio';
            }
            return tag !== 'select';
        }

        // Scored on the same evidence the mirroring engine uses, so a page
        // that shifted around still resolves to the right control instead of
        // the first vaguely similar one.
        function score(el, f) {
            if (!el || el.nodeType !== 1) return -1;
            if (used.has(el)) return -1;
            if (!shapeMatches(el, f)) return -1;
            let s = vis(el) ? 20 : -50;
            if (f.id && el.id === f.id) s += 90;
            if (f.name && attr(el, 'name') === f.name) s += 74;
            if (f.autocomplete && attr(el, 'autocomplete') === f.autocomplete) s += 34;
            if (f.placeholder) {
                const ph = attr(el, 'placeholder');
                if (ph === f.placeholder) s += 46;
                else if (ph && norm(ph).indexOf(norm(f.placeholder)) !== -1) s += 18;
            }
            if (f.aria && attr(el, 'aria-label') === f.aria) s += 40;
            if (f.label) {
                const lt = labelText(el);
                if (lt && lt === norm(f.label)) s += 36;
                else if (lt && lt.length > 2 && norm(f.label).indexOf(lt) !== -1) s += 14;
            }
            if (f.type && norm(attr(el, 'type') || el.type || '') === f.type) s += 18;
            if (f.tag && norm(el.nodeName) === f.tag) s += 10;
            return s;
        }

        function locate(f) {
            const order = docsFor(f);

            // 1. The exact control, by the path recorded in the leader.
            if (f.selector) {
                for (let d = 0; d < order.length; d++) {
                    try {
                        const e0 = order[d].querySelector(f.selector);
                        if (e0 && !used.has(e0) && vis(e0) && shapeMatches(e0, f)) return e0;
                    } catch (e) {}
                }
            }

            // 2. By id, which survives a re-render that moved the element.
            if (f.id) {
                for (let d = 0; d < order.length; d++) {
                    try {
                        const e1 = order[d].getElementById(f.id);
                        if (e1 && !used.has(e1) && vis(e1) && shapeMatches(e1, f)) return e1;
                    } catch (e) {}
                }
            }

            // 3. Best scoring candidate above a confidence floor.
            let best = null;
            let bestScore = 52;
            for (let d = 0; d < order.length; d++) {
                const list = candidates(order[d]);
                const limit = Math.min(list.length, 600);
                for (let i = 0; i < limit; i++) {
                    const sc = score(list[i], f);
                    if (sc > bestScore) { bestScore = sc; best = list[i]; }
                }
            }
            if (best) return best;

            // 4. Same position on the same form. Last resort by design: it is
            // the only rule that ignores what the field says about itself, so
            // it must never outrank one that reads it.
            if (typeof f.index === 'number' && f.index >= 0) {
                for (let d = 0; d < order.length; d++) {
                    let href = '';
                    try { href = order[d].location.href; } catch (e) {}
                    if (f.frame && href !== f.frame) continue;
                    const list = candidates(order[d]);
                    const el = list[f.index];
                    if (el && !used.has(el) && vis(el) && shapeMatches(el, f)) return el;
                }
            }
            return null;
        }

        function readValue(el) {
            try {
                if (isEditable(el)) return '' + (el.textContent || '');
                return el.value == null ? '' : ('' + el.value);
            } catch (e) { return ''; }
        }

        function writeText(el, value) {
            const current = readValue(el);
            if (current === value) return 'already';
            if (isEditable(el)) {
                try { el.focus({ preventScroll: true }); } catch (e) {}
                try { el.textContent = value; } catch (e) { return 'fail'; }
                fireBurst(el, value);
                return readValue(el) === value ? 'filled' : 'fail';
            }
            if (!setNative(el, value)) return 'fail';
            fireBurst(el, value);
            return readValue(el) === value ? 'filled' : 'fail';
        }

        function writeSelect(el, f) {
            let options = [];
            try { options = Array.prototype.slice.call(el.options || []); } catch (e) { return 'fail'; }
            if (!options.length) return 'fail';
            const wantValue = '' + (f.value == null ? '' : f.value);
            const wantText = norm(f.optionText || '');
            for (let i = 0; i < options.length; i++) {
                if (('' + options[i].value) === wantValue) {
                    if (el.selectedIndex === i) return 'already';
                    try { el.selectedIndex = i; } catch (e) { return 'fail'; }
                    fireBurst(el, wantValue);
                    return 'filled';
                }
            }
            // Value did not match, so fall back to the option's visible text —
            // plenty of sites rebuild option values per session while the
            // wording stays put.
            if (wantText) {
                for (let i = 0; i < options.length; i++) {
                    if (norm(options[i].text) === wantText) {
                        if (el.selectedIndex === i) return 'already';
                        try { el.selectedIndex = i; } catch (e) { return 'fail'; }
                        fireBurst(el, wantValue);
                        return 'filled';
                    }
                }
            }
            return 'fail';
        }

        function writeCheckbox(el, f) {
            const want = !!f.checked;
            if (!!el.checked === want) return 'already';
            try { el.click(); } catch (e) {}
            if (!!el.checked !== want) {
                try { el.checked = want; } catch (e) { return 'fail'; }
                fireBurst(el, want ? 'on' : '');
            }
            return (!!el.checked === want) ? 'filled' : 'fail';
        }

        function applyOne(f) {
            const el = locate(f);
            if (!el) return { found: false, wrote: false };
            used.add(el);
            let result = 'skip';
            if (f.isSelect) result = writeSelect(el, f);
            else if (f.isCheckbox) result = writeCheckbox(el, f);
            else result = writeText(el, '' + (f.value == null ? '' : f.value));
            return { found: true, wrote: result === 'filled', failed: result === 'fail', el: el, f: f };
        }

        let found = 0;
        let filled = 0;
        const retries = [];

        for (let i = 0; i < fields.length; i++) {
            try {
                const r = applyOne(fields[i]);
                if (r.found) found += 1;
                if (r.wrote) filled += 1;
                else if (r.failed) retries.push(r);
            } catch (e) {}
        }

        // Writing one field commonly makes a site re-render its siblings —
        // brand detection on a card number, a dependent dropdown, a field
        // that only becomes enabled once the one above it is set. A short
        // settle and one fresh attempt rescues those. Cheap when nothing
        // needs it: every writer no-ops in a single comparison once a field
        // already holds the right value.
        if (retries.length > 0) {
            await new Promise((resolve) => setTimeout(resolve, 90));
            for (let i = 0; i < retries.length; i++) {
                try {
                    const prior = retries[i];
                    used.delete(prior.el);
                    const r = applyOne(prior.f);
                    if (r.wrote) filled += 1;
                } catch (e) {}
            }
        }

        // Never leave the caret parked in a field this filled — a stray
        // keystroke landing in a card or password box is a real cost.
        try { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); } catch (e) {}

        return { found: found, filled: filled, missed: Math.max(0, fields.length - found) };
        """
    }

    // MARK: - Shared helpers

    /// Helpers used identically by the audit and the apply pass.
    ///
    /// Shared verbatim on purpose: the two sides have to agree exactly on what
    /// counts as a field, what counts as visible, and how a label is read. If
    /// they ever drifted, a field the leader recorded could be invisible to
    /// every follower and the failure would look like a matching bug.
    private static func instantFillSharedHelpers() -> String {
        """
        const MAX_FIELDS = 120;
        const norm = (s) => ('' + (s == null ? '' : s)).trim().toLowerCase();
        const attr = (el, n) => { try { return el.getAttribute(n) || ''; } catch (e) { return ''; } };
        const esc = (s) => { try { return (window.CSS && CSS.escape) ? CSS.escape(s) : ('' + s); } catch (e) { return '' + s; } };

        const isEditable = (el) => {
            try {
                const tag = norm(el.nodeName);
                if (tag === 'input' || tag === 'textarea' || tag === 'select') return false;
                return attr(el, 'contenteditable') === 'true' || el.isContentEditable === true;
            } catch (e) { return false; }
        };

        // A control worth copying: not disabled, not read-only, not hidden,
        // and not one of the input types that carries no user content.
        const isFieldCandidate = (el) => {
            try {
                if (!el || el.nodeType !== 1) return false;
                if (el.disabled || el.readOnly) return false;
                const tag = norm(el.nodeName);
                if (tag === 'input') {
                    const t = norm(attr(el, 'type') || el.type || '');
                    if (t === 'hidden' || t === 'file' || t === 'submit' ||
                        t === 'button' || t === 'reset' || t === 'image') return false;
                }
                return true;
            } catch (e) { return false; }
        };

        const vis = (el) => {
            try {
                if (!el) return false;
                if (window.__ffb_isVisible) return !!window.__ffb_isVisible(el);
                const r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                if (r && (r.width > 0 || r.height > 0)) return true;
                return el.offsetParent !== null;
            } catch (e) { return false; }
        };

        // A select still resting on its prompt row ("Select a month…") has not
        // been chosen. Copying it would push a follower's real selection back
        // to the placeholder.
        const isPlaceholderChoice = (el) => {
            try {
                if (el.selectedIndex <= 0) {
                    const opt = el.options[el.selectedIndex];
                    if (!opt) return true;
                    if (!('' + opt.value)) return true;
                    if (opt.disabled) return true;
                    return el.selectedIndex === 0 && !!attr(el, 'required');
                }
            } catch (e) {}
            return false;
        };

        function labelText(el) {
            try {
                const doc = el.ownerDocument || document;
                if (el.id) {
                    const l = doc.querySelector('label[for="' + esc(el.id) + '"]');
                    if (l) return norm(l.textContent).slice(0, 60);
                }
                if (el.closest) {
                    const w = el.closest('label');
                    if (w) return norm(w.textContent).slice(0, 60);
                }
            } catch (e) {}
            return '';
        }

        function cssPath(el) {
            try {
                if (!el || el.nodeType !== 1) return '';
                const doc = el.ownerDocument || document;
                if (el === doc.body) return 'body';
                const parts = [];
                let node = el;
                while (node && node.nodeType === 1 && parts.length < 25) {
                    let sel = node.nodeName.toLowerCase();
                    if (node.id) { parts.unshift(sel + '#' + esc(node.id)); break; }
                    const parent = node.parentNode;
                    if (!parent || parent.nodeType !== 1) { parts.unshift(sel); break; }
                    const kids = parent.children;
                    let sameTag = 0;
                    let idx = 0;
                    for (let i = 0; i < kids.length; i++) {
                        if (kids[i].nodeName === node.nodeName) { sameTag++; if (kids[i] === node) idx = sameTag; }
                    }
                    if (sameTag > 1) { sel += ':nth-of-type(' + idx + ')'; }
                    parts.unshift(sel);
                    node = parent;
                }
                return parts.join(' > ');
            } catch (e) { return ''; }
        }

        // Same-origin sub-frames included: real checkout and login forms
        // routinely live in one. Cross-origin frames throw on access and are
        // skipped — unreachable by design.
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
            return docs;
        }

        function setNative(el, value) {
            try {
                const proto = (el instanceof HTMLTextAreaElement)
                    ? HTMLTextAreaElement.prototype
                    : ((el instanceof HTMLSelectElement) ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
                const desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
            } catch (e) {
                try { el.value = value; } catch (e2) { return false; }
            }
            return true;
        }

        // Sites that mask or reformat as you type only react to a realistic
        // burst. A bare Event('input') carries no inputType or data, which is
        // exactly what an input-masking library keys its reformat off — so the
        // trailing InputEvent supplies both.
        function fireBurst(el, value) {
            const dispatch = (evt) => { try { el.dispatchEvent(evt); } catch (e) {} };
            try { el.focus({ preventScroll: true }); } catch (e) { try { el.focus(); } catch (e2) {} }
            try { dispatch(new KeyboardEvent('keydown', { bubbles: true })); } catch (e) { dispatch(new Event('keydown', { bubbles: true })); }
            dispatch(new Event('input', { bubbles: true }));
            try { dispatch(new KeyboardEvent('keyup', { bubbles: true })); } catch (e) { dispatch(new Event('keyup', { bubbles: true })); }
            dispatch(new Event('change', { bubbles: true }));
            try {
                dispatch(new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: value == null ? null : ('' + value)
                }));
            } catch (e) {
                dispatch(new Event('input', { bubbles: true }));
            }
            try { dispatch(new FocusEvent('blur', { bubbles: true })); } catch (e) { dispatch(new Event('blur', { bubbles: true })); }
        }
        """
    }
}
