import Foundation

/// Result of one card fill inside one window.
nonisolated struct CardFillOutcome: Equatable, Sendable {
    /// Card fields the page exposed.
    var found: Int
    /// Fields actually written. Lower than `found` when a box already held
    /// the right value, which is a success, not a miss.
    var filled: Int
    var reason: String

    var didFindFields: Bool { found > 0 }

    init(found: Int = 0, filled: Int = 0, reason: String = "") {
        self.found = found
        self.filled = filled
        self.reason = reason
    }

    init(jsResult: Any?) {
        guard let dict = jsResult as? [String: Any] else {
            self.init(reason: "unreadable-result")
            return
        }
        func int(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d) }
            if let n = any as? NSNumber { return n.intValue }
            return 0
        }
        self.init(
            found: int(dict["found"]),
            filled: int(dict["filled"]),
            reason: dict["reason"] as? String ?? ""
        )
    }

    static func + (lhs: CardFillOutcome, rhs: CardFillOutcome) -> CardFillOutcome {
        CardFillOutcome(
            found: lhs.found + rhs.found,
            filled: lhs.filled + rhs.filled,
            reason: lhs.reason.isEmpty ? rhs.reason : lhs.reason
        )
    }
}

extension JavaScriptInjectionService {

    /// Body for `callAsyncJavaScript`, called with a single `card` argument
    /// built from `CardFillPayload.jsArguments`.
    ///
    /// Deliberately fills and nothing else. There is no click, no
    /// `form.submit()`, no synthesised Enter anywhere in here: putting a card
    /// number into a box and authorising a payment are two different
    /// decisions, and only one of them belongs to an autofill button.
    static func cardFillBody() -> String {
        """
        const c = card || {};

        const norm = (s) => ((s == null ? '' : '' + s)).trim().toLowerCase();
        const digits = (s) => ((s == null ? '' : '' + s)).replace(/[^0-9]/g, '');

        const vis = (el) => {
            try {
                if (!el) return false;
                if (el.disabled || el.readOnly) return false;
                if (window.__ffb_isVisible) return !!window.__ffb_isVisible(el);
                const r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                if (r && (r.width > 0 || r.height > 0)) return true;
                return el.offsetParent !== null;
            } catch (e) { return false; }
        };

        // Real checkout forms nearly always live in an embedded payment
        // frame, so the top document alone is not enough. Cross-origin
        // frames throw on access and are skipped — unreachable by design.
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

        function labelText(el) {
            try {
                const doc = el.ownerDocument || document;
                if (el.id) {
                    const l = doc.querySelector('label[for="' + (window.CSS && CSS.escape ? CSS.escape(el.id) : el.id) + '"]');
                    if (l) return norm(l.textContent).slice(0, 80);
                }
                if (el.closest) {
                    const w = el.closest('label');
                    if (w) return norm(w.textContent).slice(0, 80);
                }
                // Some checkouts put the label in a sibling span rather than
                // a real <label>.
                const prev = el.previousElementSibling;
                if (prev && prev.textContent) return norm(prev.textContent).slice(0, 80);
            } catch (e) {}
            return '';
        }

        // Strips punctuation so card_number / card-number / cardNumber all
        // collapse to one haystack, matching the Swift classifier exactly.
        const flatten = (s) => norm(s).replace(/[^a-z0-9]/g, '');

        function autoToken(el) {
            let raw = '';
            try { raw = norm(el.getAttribute('autocomplete') || el.autocomplete || ''); } catch (e) { raw = ''; }
            if (!raw) return null;
            const tokens = raw.split(/\\s+/);
            for (const t of tokens) {
                if (t === 'cc-number') return 'number';
                if (t === 'cc-exp') return 'exp';
                if (t === 'cc-exp-month') return 'month';
                if (t === 'cc-exp-year') return 'year';
                if (t === 'cc-csc') return 'cvv';
                if (t === 'cc-name' || t === 'cc-given-name' || t === 'cc-family-name') return 'name';
            }
            return null;
        }

        function classify(el) {
            const token = autoToken(el);
            if (token) return token;

            let type = '';
            try { type = norm(el.getAttribute('type') || el.type || ''); } catch (e) {}
            if (type === 'password' || type === 'search' || type === 'hidden' ||
                type === 'checkbox' || type === 'radio' || type === 'file') return null;

            const tag = norm(el.tagName);
            const parts = [];
            try { parts.push(el.getAttribute('name') || ''); } catch (e) {}
            try { parts.push(el.getAttribute('id') || ''); } catch (e) {}
            try { parts.push(el.getAttribute('aria-label') || ''); } catch (e) {}
            try { parts.push(el.getAttribute('data-testid') || ''); } catch (e) {}
            if (tag !== 'select') {
                try { parts.push(el.getAttribute('placeholder') || ''); } catch (e) {}
            }
            parts.push(labelText(el));
            const text = flatten(parts.join(' '));
            if (!text) return null;

            const has = (list) => list.some((n) => text.indexOf(n) >= 0);
            const is = (list) => list.indexOf(text) >= 0;

            // Security code first: the phrase usually also contains "card",
            // which would otherwise drag it into the number branch.
            if (has(['cvc', 'cvv', 'csc', 'securitycode', 'cardcode', 'cardverification', 'verificationcode'])) return 'cvv';

            const isExp = has(['exp', 'validthru', 'validuntil', 'goodthru']);
            const cardContext = has(['card', 'credit', 'payment']);
            const isMonth = has(['month', 'mm', 'mon']);
            const isYear = has(['year', 'yy', 'yr']);

            // "mm" and "mon" hide inside innocent words like "summary" and
            // "money". Writing an expiry month into one of those would be a
            // genuinely bad failure, so a bare month/year hint only counts
            // with expiry or card context, or as the whole field description.
            if (isExp) {
                if (isMonth && isYear) return 'exp';
                if (isMonth) return 'month';
                if (isYear) return 'year';
                return 'exp';
            }
            if (is(['mmyy', 'mmyyyy', 'monthyear'])) return 'exp';
            if (cardContext && isMonth && isYear) return 'exp';
            if (is(['mm', 'month']) || (cardContext && isMonth)) return 'month';
            if (is(['yy', 'yyyy', 'year']) || (cardContext && isYear)) return 'year';

            if (has(['cardholder', 'nameoncard', 'cardname', 'ccname', 'holdername', 'accountholder'])) return 'name';
            if (tag === 'select') return null;
            if (has(['cardnumber', 'ccnumber', 'creditcard', 'cardnum', 'ccnum', 'acctnum'])) return 'number';
            if (has(['card']) && has(['number', 'num'])) return 'number';
            return null;
        }

        function setNative(el, value) {
            try {
                const proto = el instanceof HTMLTextAreaElement
                    ? HTMLTextAreaElement.prototype
                    : (el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
                const desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
            } catch (e) {
                try { el.value = value; } catch (e2) { return false; }
            }
            return true;
        }

        // Sites that mask or reformat as you type only react to a realistic
        // event burst. A bare `Event('input')` carries no `inputType` or
        // `data` — exactly what an input-masking library keys its reformat
        // off. Expiry and CVV boxes run one almost universally; a raw card
        // number box usually doesn't, which is why that field alone looked
        // fine while the other three silently discarded a value the native
        // setter had already written in. The trailing InputEvent supplies
        // both properties.
        function fire(el, value) {
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

        function writeInput(el, value) {
            if (!value) return 'skip';
            let current = '';
            try { current = '' + (el.value || ''); } catch (e) {}
            // Already correct — leave it alone. Rewriting a good value would
            // restart the site's own formatting and validation for nothing.
            if (norm(current) === norm(value)) return 'already';
            if (digits(value) && digits(current) === digits(value) && digits(current).length > 0) return 'already';
            if (!setNative(el, value)) return 'fail';
            fire(el, value);
            return 'filled';
        }

        function writeSelect(el, candidates) {
            let options = [];
            try { options = Array.prototype.slice.call(el.options || []); } catch (e) { return 'fail'; }
            if (!options.length) return 'fail';
            for (const cand of candidates) {
                if (!cand) continue;
                const wanted = norm(cand);
                const wantedNum = parseInt(digits(cand), 10);
                for (let i = 0; i < options.length; i++) {
                    const opt = options[i];
                    const v = norm(opt.value);
                    const t = norm(opt.textContent);
                    const numericMatch = !isNaN(wantedNum) &&
                        (parseInt(digits(v), 10) === wantedNum || parseInt(digits(t), 10) === wantedNum);
                    if (v === wanted || t === wanted || numericMatch) {
                        if (el.selectedIndex === i) return 'already';
                        try { el.selectedIndex = i; } catch (e) { return 'fail'; }
                        fire(el);
                        return 'filled';
                    }
                }
            }
            return 'fail';
        }

        function maxLen(el) {
            try {
                const n = parseInt(el.getAttribute('maxlength') || el.maxLength, 10);
                return (isNaN(n) || n <= 0) ? 0 : n;
            } catch (e) { return 0; }
        }

        // Value for a combined expiry box, matched to how much room it has:
        // a 4-character box wants MMYY, a 7-character one wants MM/YYYY.
        function expiryFor(el) {
            const m = maxLen(el);
            if (m === 4) return c.month + c.shortYear;
            if (m >= 7) return c.month + '/' + c.fullYear;
            return c.month + '/' + c.shortYear;
        }

        function yearFor(el) {
            const m = maxLen(el);
            if (m === 2) return c.shortYear;
            if (m >= 4) return c.fullYear;
            // No maxlength to go on: prefer what is already there, else short.
            let current = '';
            try { current = digits('' + (el.value || '')); } catch (e) {}
            return current.length > 2 ? c.fullYear : c.shortYear;
        }

        let found = 0;
        let filled = 0;
        const docs = documents();

        for (const doc of docs) {
            let nodes = [];
            try { nodes = Array.prototype.slice.call(doc.querySelectorAll('input,select')); } catch (e) { nodes = []; }
            const fields = [];
            for (const el of nodes) {
                // One field throwing — a proxied getter, a custom element
                // that hasn't upgraded yet — must never take the whole
                // document's fields down with it.
                try {
                    if (!vis(el)) continue;
                    const kind = classify(el);
                    if (!kind) continue;
                    fields.push({ el: el, kind: kind });
                } catch (e) {}
            }
            if (!fields.length) continue;

            // Some checkouts split the number across four short boxes. Only
            // treat them that way when there really are several, each too
            // short to hold a full number on its own.
            const numberFields = fields.filter((f) => f.kind === 'number' && norm(f.el.tagName) !== 'select');
            const segmented = numberFields.length >= 3 &&
                numberFields.every((f) => { const m = maxLen(f.el); return m > 0 && m <= 6; });

            if (segmented) {
                const all = digits(c.number);
                let cursor = 0;
                for (const f of numberFields) {
                    const size = maxLen(f.el) || 4;
                    const chunk = all.slice(cursor, cursor + size);
                    cursor += size;
                    found += 1;
                    if (!chunk) continue;
                    const r = writeInput(f.el, chunk);
                    if (r === 'filled') filled += 1;
                }
            }

            for (const f of fields) {
                // Same isolation as the collection pass above: one field's
                // exception must never silently blackout the rest of the
                // form. Without this, a throw while writing whichever field
                // happens to be walked first — commonly the number box,
                // since it usually sits first in the markup — would look
                // exactly like "fills the number, skips everything else".
                try {
                    const el = f.el;
                    const isSelect = norm(el.tagName) === 'select';
                    if (segmented && f.kind === 'number' && !isSelect) continue;
                    found += 1;
                    let result = 'skip';
                    if (isSelect) {
                        if (f.kind === 'month') {
                            result = writeSelect(el, [c.month, String(parseInt(c.month, 10))]);
                        } else if (f.kind === 'year') {
                            result = writeSelect(el, [c.fullYear, c.shortYear]);
                        } else if (f.kind === 'exp') {
                            result = writeSelect(el, [c.month + '/' + c.shortYear, c.month + '/' + c.fullYear, c.month + c.shortYear]);
                        } else if (f.kind === 'name') {
                            result = writeSelect(el, [c.name]);
                        }
                    } else if (f.kind === 'number') {
                        result = writeInput(el, digits(c.number));
                    } else if (f.kind === 'cvv') {
                        result = writeInput(el, c.cvv);
                    } else if (f.kind === 'name') {
                        result = writeInput(el, c.name);
                    } else if (f.kind === 'month') {
                        result = writeInput(el, c.month);
                    } else if (f.kind === 'year') {
                        result = writeInput(el, yearFor(el));
                    } else if (f.kind === 'exp') {
                        result = writeInput(el, expiryFor(el));
                    }
                    if (result === 'filled') filled += 1;
                } catch (e) {}
            }
        }

        // A card number's own input event is commonly what triggers a
        // site's brand-detection pass, which can re-render or briefly
        // disable its siblings — exactly the moment a framework swaps in
        // fresh expiry/CVV/name nodes and orphans the ones just written to,
        // or the moment a field that started disabled becomes fillable. A
        // short settle and one fresh, re-queried look (never the stale
        // `fields` array) rescues anything the first pass missed for either
        // reason. Cheap when nothing needs it: `writeInput`/`writeSelect`
        // both no-op in one comparison when a field already holds the right
        // value.
        if (found > 0) {
            await new Promise((resolve) => setTimeout(resolve, 90));
            for (const doc of docs) {
                let liveNodes = [];
                try { liveNodes = Array.prototype.slice.call(doc.querySelectorAll('input,select')); } catch (e) { liveNodes = []; }
                for (const el of liveNodes) {
                    try {
                        if (!vis(el)) continue;
                        const kind = classify(el);
                        if (!kind) continue;
                        const isSelect = norm(el.tagName) === 'select';
                        let result = 'skip';
                        if (isSelect) {
                            if (kind === 'month') result = writeSelect(el, [c.month, String(parseInt(c.month, 10))]);
                            else if (kind === 'year') result = writeSelect(el, [c.fullYear, c.shortYear]);
                            else if (kind === 'exp') result = writeSelect(el, [c.month + '/' + c.shortYear, c.month + '/' + c.fullYear, c.month + c.shortYear]);
                            else if (kind === 'name') result = writeSelect(el, [c.name]);
                        } else if (kind === 'number') {
                            result = writeInput(el, digits(c.number));
                        } else if (kind === 'cvv') {
                            result = writeInput(el, c.cvv);
                        } else if (kind === 'name') {
                            result = writeInput(el, c.name);
                        } else if (kind === 'month') {
                            result = writeInput(el, c.month);
                        } else if (kind === 'year') {
                            result = writeInput(el, yearFor(el));
                        } else if (kind === 'exp') {
                            result = writeInput(el, expiryFor(el));
                        }
                        // 'already' here means the first pass's write survived
                        // the settle — nothing new to count. Only a fresh
                        // 'filled' means the retry actually rescued a field.
                        if (result === 'filled') filled += 1;
                    } catch (e) {}
                }
            }
        }

        // Focus is deliberately dropped at the end: leaving the caret parked
        // in a card box invites a stray keystroke into it.
        try { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); } catch (e) {}

        return { ok: true, found: found, filled: filled, reason: found === 0 ? 'no-card-fields' : '' };
        """
    }
}
