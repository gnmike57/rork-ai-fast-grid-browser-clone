import Foundation

struct JavaScriptInjectionService {
    static func fillHelperScript() -> String {
        return """
        window.__ffb_isVisible = function(el) {
            if (!el) return false;
            if (el.disabled || el.readOnly) return false;
            if (el.getAttribute && el.getAttribute('aria-hidden') === 'true') return false;
            var style = window.getComputedStyle ? window.getComputedStyle(el) : null;
            if (style) {
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                if (style.pointerEvents === 'none') return false;
            }
            // offsetParent is null for fixed/sticky elements in some browsers,
            // so also accept anything with a non-zero client box.
            if (el.offsetParent !== null) return true;
            var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
            return !!(rect && rect.width > 0 && rect.height > 0);
        };

        window.__ffb_setNativeValue = function(element, value) {
            try {
                var proto = window.HTMLInputElement && window.HTMLInputElement.prototype;
                var desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
                if (desc && desc.set) {
                    desc.set.call(element, value);
                } else {
                    element.value = value;
                }
            } catch (e) {
                element.value = value;
            }
            try { element.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' })); } catch (e) {}
        };

        // Light by default: a plain document query is used whenever it finds
        // anything, so the common page costs exactly what it did before. The
        // open-shadow-root walk only runs when the document query comes back
        // empty, which is precisely the web-component login that used to be
        // invisible to every finder below.
        window.__ffb_deepAll = function(selector) {
            var direct = [];
            try { direct = Array.prototype.slice.call(document.querySelectorAll(selector)); } catch (e) { direct = []; }
            if (direct.length > 0) return direct;
            var out = [];
            var roots = [document];
            var guard = 0;
            while (roots.length > 0 && guard < 200) {
                guard++;
                var root = roots.shift();
                try {
                    var hosts = root.querySelectorAll('*');
                    for (var j = 0; j < hosts.length; j++) {
                        var sr = hosts[j].shadowRoot;
                        if (!sr) continue;
                        roots.push(sr);
                        try {
                            var found = sr.querySelectorAll(selector);
                            for (var k = 0; k < found.length && out.length < 200; k++) out.push(found[k]);
                        } catch (e) {}
                    }
                } catch (e) {}
                if (out.length >= 200) break;
            }
            return out;
        };

        window.__ffb_hasAny = function(hay, needles) {
            if (!hay) return false;
            for (var i = 0; i < needles.length; i++) {
                if (hay.indexOf(needles[i]) !== -1) return true;
            }
            return false;
        };

        /// Every identifying string attached to a control, lowercased and
        /// joined — name, id, placeholder, aria-label, autocomplete, class,
        /// and its associated or wrapping label.
        window.__ffb_attrText = function(el) {
            var parts = [];
            try {
                parts.push(el.getAttribute('name') || '');
                parts.push(el.id || '');
                parts.push(el.getAttribute('placeholder') || '');
                parts.push(el.getAttribute('aria-label') || '');
                parts.push(el.getAttribute('autocomplete') || '');
                var cls = el.className;
                if (typeof cls === 'string') parts.push(cls);
                if (el.id) {
                    var scope = (el.getRootNode ? el.getRootNode() : document) || document;
                    if (scope.querySelector) {
                        var lbl = scope.querySelector('label[for="' + el.id + '"]');
                        if (lbl) parts.push(lbl.textContent || '');
                    }
                }
                if (el.closest) {
                    var wrap = el.closest('label');
                    if (wrap) parts.push(wrap.textContent || '');
                }
            } catch (e) {}
            return parts.join(' ').toLowerCase();
        };

        // Ranked matching replaces first-match-wins. A page with a search box
        // above the form, a newsletter signup below it, or a register form on
        // the same route used to hand back whichever matched the earliest
        // selector; now every candidate is scored and the best one wins.
        window.__ffb_scoreUsername = function(el) {
            if (!el) return -1000;
            var type = (el.getAttribute('type') || 'text').toLowerCase();
            if (type === 'password' || type === 'hidden' || type === 'checkbox' ||
                type === 'radio' || type === 'file' || type === 'submit' ||
                type === 'button' || type === 'search' || type === 'range') return -1000;
            var meta = window.__ffb_attrText(el);
            var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            var score = 0;
            if (ac === 'username') score += 140;
            else if (ac === 'email') score += 130;
            if (type === 'email') score += 110;
            else if (type === 'tel') score += 40;
            else score += 10;
            if (window.__ffb_hasAny(meta, ['username', 'user_name', 'userid', 'user-id'])) score += 90;
            if (window.__ffb_hasAny(meta, ['email', 'e-mail'])) score += 80;
            if (window.__ffb_hasAny(meta, ['login', 'signin', 'sign-in', 'account', 'member'])) score += 60;
            else if (window.__ffb_hasAny(meta, ['user'])) score += 45;
            if (window.__ffb_hasAny(meta, ['phone', 'mobile', 'msisdn'])) score += 25;
            if (window.__ffb_hasAny(meta, ['search', 'query', 'keyword', 'filter'])) score -= 400;
            if ((el.getAttribute('name') || '').toLowerCase() === 'q') score -= 400;
            var role = (el.getAttribute('role') || '').toLowerCase();
            if (role === 'searchbox' || role === 'search') score -= 400;
            if (window.__ffb_hasAny(meta, ['captcha', 'otp', 'one-time', 'verification', 'coupon',
                                           'promo', 'voucher', 'newsletter', 'subscribe', 'zip',
                                           'postal', 'firstname', 'lastname', 'address', 'city', 'card'])) score -= 300;
            if (window.__ffb_hasAny(meta, ['confirm', 'repeat', 'retype'])) score -= 200;
            if (window.__ffb_isVisible(el)) score += 60; else score -= 250;
            try {
                var f = el.closest ? el.closest('form') : null;
                if (f && f.querySelector('input[type="password"]')) score += 120;
            } catch (e) {}
            return score;
        };

        window.__ffb_scorePassword = function(el) {
            if (!el) return -1000;
            var type = (el.getAttribute('type') || '').toLowerCase();
            var meta = window.__ffb_attrText(el);
            var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            var score = 0;
            if (ac === 'current-password') score += 150;
            if (type === 'password') score += 120;
            if (ac === 'new-password') score -= 90;
            if (window.__ffb_hasAny(meta, ['password', 'passwd', 'pwd', 'passphrase'])) score += 70;
            // 'passport' used to match the bare input[name*="pass"] selector.
            if (window.__ffb_hasAny(meta, ['passport'])) score -= 300;
            if (window.__ffb_hasAny(meta, ['confirm', 'repeat', 'retype', 'again', 'verify',
                                           'newpass', 'new-pass', 'new_pass'])) score -= 250;
            if (window.__ffb_hasAny(meta, ['otp', 'captcha'])) score -= 150;
            if (window.__ffb_isVisible(el)) score += 60; else score -= 250;
            return score;
        };

        window.__ffb_bestPassword = function() {
            var cands = window.__ffb_deepAll('input[type="password"], input[autocomplete="current-password"], input[autocomplete="new-password"], input[name*="pass" i], input[id*="pass" i], input[placeholder*="pass" i]');
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < cands.length; i++) {
                var s = window.__ffb_scorePassword(cands[i]);
                if (s > bestScore) { bestScore = s; best = cands[i]; }
            }
            return best;
        };

        window.__ffb_findPassword = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            return window.__ffb_bestPassword();
        };

        window.__ffb_findUsername = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            var pass = null;
            try { pass = window.__ffb_bestPassword(); } catch (e) {}
            var passTop = null;
            if (pass) {
                try { passTop = pass.getBoundingClientRect().top; } catch (e) {}
            }
            var cands = window.__ffb_deepAll('input, textarea');
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < cands.length; i++) {
                var c = cands[i];
                var s = window.__ffb_scoreUsername(c);
                if (s <= 0) continue;
                // The identifier for a login sits just above its password box.
                if (passTop !== null) {
                    try {
                        var t = c.getBoundingClientRect().top;
                        var d = Math.abs(passTop - t);
                        if (t <= passTop && d < 400) s += 70;
                        else if (d < 400) s += 20;
                        else s -= 40;
                    } catch (e) {}
                }
                if (s > bestScore) { bestScore = s; best = c; }
            }
            return best;
        };

        window.__ffb_scoreSubmit = function(el, passEl) {
            if (!el) return -1000;
            if (!window.__ffb_isVisible(el)) return -1000;
            var text = ((el.textContent || el.value || el.getAttribute('aria-label') || '') + '').trim().toLowerCase();
            var meta = window.__ffb_attrText(el);
            var type = (el.getAttribute('type') || '').toLowerCase();
            var score = 0;
            if (type === 'submit') score += 90;
            if (text === 'log in' || text === 'login' || text === 'sign in' ||
                text === 'signin' || text === 'submit' || text === 'continue' || text === 'next') score += 120;
            else if (window.__ffb_hasAny(text, ['log in', 'login', 'sign in', 'signin', 'submit'])) score += 80;
            else if (window.__ffb_hasAny(text, ['continue', 'next', 'proceed'])) score += 35;
            // Checked against identifiers only — button text like 'Center' or
            // a 'google' class must not read as a login verb.
            if (window.__ffb_hasAny(meta, ['login', 'signin', 'sign-in', 'submit'])) score += 45;
            if (window.__ffb_hasAny(text, ['forgot', 'reset', 'register', 'sign up', 'signup',
                                           'create account', 'cancel', 'back', 'help', 'privacy',
                                           'cookie', 'terms', 'show password', 'remember'])) score -= 400;
            if (window.__ffb_hasAny(meta, ['forgot', 'register', 'signup', 'sign-up'])) score -= 400;
            try {
                if (passEl && el.closest && passEl.closest) {
                    var ef = el.closest('form');
                    if (ef && ef === passEl.closest('form')) score += 90;
                }
            } catch (e) {}
            var tag = (el.tagName || '').toLowerCase();
            if (tag === 'button' || tag === 'input') score += 20;
            return score;
        };

        window.__ffb_findSubmit = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            var pass = null;
            try { pass = window.__ffb_bestPassword(); } catch (e) {}
            var cands = window.__ffb_deepAll('button, input[type="submit"], input[type="button"], input[type="image"], a[role="button"], [role="button"]');
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < cands.length; i++) {
                var s = window.__ffb_scoreSubmit(cands[i], pass);
                if (s > bestScore) { bestScore = s; best = cands[i]; }
            }
            if (best) return best;
            var form = null;
            try { form = (pass && pass.closest) ? pass.closest('form') : null; } catch (e) {}
            if (!form) form = document.querySelector('form');
            if (form) {
                var btn = form.querySelector('button[type="submit"], input[type="submit"], button');
                if (btn && window.__ffb_isVisible(btn)) return btn;
            }
            return null;
        };

        /// Single source of truth for "what does this page say happened".
        /// The RCR observer and the one-shot snapshot both read through this,
        /// so the two can no longer drift apart.
        window.__ffb_readPageState = function() {
            var passField = null;
            try { passField = window.__ffb_bestPassword(); } catch (e) {}
            var hasPassword = false;
            try { hasPassword = !!(passField && window.__ffb_isVisible(passField)); } catch (e) {}
            var bodyText = '';
            try { bodyText = (document.body && document.body.innerText) ? document.body.innerText : ''; } catch (e) {}
            var lower = bodyText.toLowerCase();
            // Case-sensitive: only the exact 'Welcome!' marker counts.
            // All-caps 'WELCOME' / 'WELCOME BACK!' must NOT trigger success.
            var hasWelcome = bodyText.indexOf('Welcome!') !== -1;
            var hasDisabled = lower.indexOf('been disabled') !== -1;
            var hasTempDisabled = (!hasDisabled) && (lower.indexOf('temporarily') !== -1);
            // A success marker only counts when it is actually on screen and
            // carries text. Sites ship hidden success templates on the login
            // page itself, and a bare [class*="success"] match read those as a
            // logged-in account.
            var hasSuccess = false;
            try {
                var marks = document.querySelectorAll('[class*="success"], [data-status="success"], [role="status"]');
                for (var i = 0; i < marks.length && i < 40; i++) {
                    var m = marks[i];
                    if (!window.__ffb_isVisible(m)) continue;
                    if (((m.textContent || '') + '').trim().length === 0) continue;
                    hasSuccess = true;
                    break;
                }
            } catch (e) {}
            var hasError = window.__ffb_hasAny(lower, [
                'invalid username', 'invalid password', 'invalid login', 'invalid credentials',
                'incorrect password', 'incorrect username', 'wrong password',
                'login failed', 'sign in failed', 'authentication failed',
                'credentials do not match', 'user not found', 'no account found'
            ]);
            var hasCaptcha = false;
            try {
                hasCaptcha = window.__ffb_hasAny(lower, ['are you a robot', 'verify you are human',
                                                         "verify you're human", 'not a robot',
                                                         'complete the captcha'])
                    || document.querySelector('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], .g-recaptcha, .h-captcha, #cf-challenge-running') != null;
            } catch (e) {}
            var hasTwoFactor = window.__ffb_hasAny(lower, [
                'two-factor', 'two factor', '2-step', 'two-step',
                'verification code', 'authentication code', 'one-time code', 'one time passcode'
            ]);
            var path = '/';
            var url = '';
            try { path = window.location.pathname || '/'; url = window.location.href; } catch (e) {}
            return {
                hasPassword: hasPassword,
                hasWelcome: hasWelcome,
                hasDisabled: hasDisabled,
                hasTempDisabled: hasTempDisabled,
                hasSuccess: hasSuccess,
                hasError: hasError,
                hasCaptcha: hasCaptcha,
                hasTwoFactor: hasTwoFactor,
                isHomepage: (path === '' || path === '/'),
                url: url
            };
        };
        """
    }

    static func fillCredentialScript(
        username: String,
        password: String,
        usernameSelector: String?,
        passwordSelector: String?,
        suppressKeyboard: Bool = false
    ) -> String {
        let escapedUser = username.jsEscaped
        let escapedPass = password.jsEscaped
        let userSel = (usernameSelector?.isEmpty == false) ? usernameSelector!.jsEscaped : ""
        let passSel = (passwordSelector?.isEmpty == false) ? passwordSelector!.jsEscaped : ""
        let focusCall = suppressKeyboard ? "" : "try { el.focus({ preventScroll: true }); } catch (e) { try { el.focus(); } catch (e2) {} }"
        let blurAfter = suppressKeyboard ? "try { if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); } } catch (e) {}" : ""

        return """
        (function() {
            var userField = window.__ffb_findUsername ? window.__ffb_findUsername('\(userSel)') : null;
            var passField = window.__ffb_findPassword ? window.__ffb_findPassword('\(passSel)') : null;
            var setVal = window.__ffb_setNativeValue || function(el, v) {
                el.value = v;
                try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
                try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
            };
            var fillField = function(el, v) {
                if (!el) return;
                \(focusCall)
                setVal(el, v);
                try { el.setAttribute('value', v); } catch (e) {}
            };
            var filled = 0;
            if (userField) { fillField(userField, '\(escapedUser)'); filled++; }
            if (passField) { fillField(passField, '\(escapedPass)'); filled++; }
            \(blurAfter)
            return JSON.stringify({ filled: filled, userFound: !!userField, passFound: !!passField });
        })();
        """
    }

    /// Structure-only page outline for the AI fill healer. Returns DOM
    /// metadata (types, names, ids, labels, visibility) — NEVER field values
    /// or any credential content. This is the only payload an AI ever sees.
    static func pageOutlineScript() -> String {
        return """
        (function() {
            try {
                var isVisible = window.__ffb_isVisible || function(el) { return !!el; };
                var inputs = [];
                var allInputs = document.querySelectorAll('input, textarea');
                for (var i = 0; i < allInputs.length && inputs.length < 12; i++) {
                    var el = allInputs[i];
                    var visible = false;
                    try { visible = !!isVisible(el); } catch (e) {}
                    var labelText = '';
                    try {
                        if (el.id) {
                            var lbl = document.querySelector('label[for="' + el.id + '"]');
                            if (lbl) labelText = (lbl.textContent || '').trim().slice(0, 60);
                        }
                        if (!labelText && el.closest) {
                            var wrap = el.closest('label');
                            if (wrap) labelText = (wrap.textContent || '').trim().slice(0, 60);
                        }
                    } catch (e) {}
                    inputs.push({
                        index: i,
                        tag: (el.tagName || '').toLowerCase(),
                        type: (el.getAttribute('type') || 'text').toLowerCase(),
                        name: el.getAttribute('name') || '',
                        id: el.id || '',
                        placeholder: el.getAttribute('placeholder') || '',
                        ariaLabel: el.getAttribute('aria-label') || '',
                        autocomplete: el.getAttribute('autocomplete') || '',
                        labelText: labelText,
                        visible: visible
                    });
                }
                var buttons = [];
                var allBtns = document.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]');
                for (var b = 0; b < allBtns.length && buttons.length < 10; b++) {
                    var btn = allBtns[b];
                    var bVisible = false;
                    try { bVisible = !!isVisible(btn); } catch (e) {}
                    var text = ((btn.textContent || btn.value || '') + '').trim().slice(0, 40);
                    buttons.push({
                        index: b,
                        tag: (btn.tagName || '').toLowerCase(),
                        type: (btn.getAttribute('type') || '').toLowerCase(),
                        id: btn.id || '',
                        text: text,
                        visible: bVisible
                    });
                }
                var bodyText = '';
                try { bodyText = (document.body && document.body.innerText ? document.body.innerText : '').toLowerCase().slice(0, 3000); } catch (e) {}
                var captcha = /captcha|are you a robot|verify you'?re human|verify you are human|not a robot/.test(bodyText);
                var lockout = /account (is )?(locked|disabled|suspended)|too many (failed )?attempts|temporarily blocked/.test(bodyText);
                return JSON.stringify({
                    url: location.href,
                    title: (document.title || '').slice(0, 80),
                    forms: (document.forms ? document.forms.length : 0),
                    inputs: inputs,
                    buttons: buttons,
                    hasCaptcha: captcha,
                    hasLockout: lockout
                });
            } catch (e) {
                return JSON.stringify({ url: '', title: '', forms: 0, inputs: [], buttons: [], hasCaptcha: false, hasLockout: false });
            }
        })();
        """
    }

    /// Probes suggested CSS selectors on the live page and reports what each
    /// resolves to (tag/type/name/visibility). Used to verify a healed
    /// selector BEFORE any secret is filled into it.
    static func selectorProbeScript(
        usernameSelector: String?,
        passwordSelector: String?,
        submitSelector: String?
    ) -> String {
        let user = (usernameSelector?.isEmpty == false) ? usernameSelector!.jsEscaped : ""
        let pass = (passwordSelector?.isEmpty == false) ? passwordSelector!.jsEscaped : ""
        let submit = (submitSelector?.isEmpty == false) ? submitSelector!.jsEscaped : ""
        return """
        (function() {
            var probe = function(sel) {
                if (!sel) return { found: false };
                try {
                    var el = document.querySelector(sel);
                    if (!el) return { found: false };
                    var visible = false;
                    try { visible = window.__ffb_isVisible ? !!window.__ffb_isVisible(el) : true; } catch (e) {}
                    return {
                        found: true,
                        tag: (el.tagName || '').toLowerCase(),
                        type: (el.getAttribute('type') || '').toLowerCase(),
                        name: el.getAttribute('name') || '',
                        id: el.id || '',
                        placeholder: el.getAttribute('placeholder') || '',
                        visible: visible
                    };
                } catch (e) { return { found: false }; }
            };
            return JSON.stringify({
                user: probe('\(user)'),
                pass: probe('\(pass)'),
                submit: probe('\(submit)')
            });
        })();
        """
    }

    /// Boolean verification that the current effective selectors found fields
    /// and that those fields contain values. Returns only booleans — never
    /// the values themselves.
    static func verifyFillScript(usernameSelector: String?, passwordSelector: String?) -> String {
        let user = (usernameSelector?.isEmpty == false) ? usernameSelector!.jsEscaped : ""
        let pass = (passwordSelector?.isEmpty == false) ? passwordSelector!.jsEscaped : ""
        return """
        (function() {
            var userField = window.__ffb_findUsername ? window.__ffb_findUsername('\(user)') : null;
            var passField = window.__ffb_findPassword ? window.__ffb_findPassword('\(pass)') : null;
            return JSON.stringify({
                userFound: !!userField,
                passFound: !!passField,
                userFilled: !!(userField && (userField.value || '').length > 0),
                passFilled: !!(passField && (passField.value || '').length > 0)
            });
        })();
        """
    }

    /// Installs a one-shot login-response observer that watches the page for
    /// ~6 seconds after a submit and posts a single classification
    /// (`success`, `failed`, `blocked`, or `timeout`) to the
    /// `loginResponse` script-message handler. Purely informational —
    /// never used by RCR (which has its own `rcrObserver`).
    static func loginResponseObserverScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_lrObserver) { try { window.__ffb_lrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_lrTimer) { try { clearTimeout(window.__ffb_lrTimer); } catch(e){} }
                if (window.__ffb_lrTimeout) { try { clearTimeout(window.__ffb_lrTimeout); } catch(e){} }
                window.__ffb_lrFired = false;
                var post = function(kind, hint) {
                    if (window.__ffb_lrFired) return;
                    window.__ffb_lrFired = true;
                    try { if (window.__ffb_lrObserver) window.__ffb_lrObserver.disconnect(); } catch(e){}
                    try { if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer); } catch(e){}
                    try { if (window.__ffb_lrTimeout) clearTimeout(window.__ffb_lrTimeout); } catch(e){}
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loginResponse) {
                            window.webkit.messageHandlers.loginResponse.postMessage({ kind: kind, hint: hint || '' });
                        }
                    } catch (e) {}
                };
                var classify = function() {
                    try {
                        var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                        var lower = bodyText.toLowerCase();
                        var passField = document.querySelector('input[type="password"]');
                        var hasPassword = !!(passField && passField.offsetParent !== null);
                        if (lower.indexOf('been disabled') !== -1 || lower.indexOf('account is locked') !== -1 || lower.indexOf('account locked') !== -1) {
                            post('blocked', 'disabled');
                            return;
                        }
                        if (lower.indexOf('invalid') !== -1 || lower.indexOf('incorrect') !== -1 || lower.indexOf('wrong password') !== -1 || lower.indexOf('try again') !== -1) {
                            post('failed', 'invalid');
                            return;
                        }
                        if (bodyText.indexOf('Welcome!') !== -1 || lower.indexOf('dashboard') !== -1 || lower.indexOf('sign out') !== -1 || lower.indexOf('log out') !== -1) {
                            post('success', 'welcome');
                            return;
                        }
                        var path = window.location.pathname || '/';
                        if ((path === '' || path === '/') && !hasPassword) { post('success', 'homepage'); return; }
                    } catch (e) {}
                };
                var debounced = function() {
                    if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer);
                    window.__ffb_lrTimer = setTimeout(classify, 350);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
                window.__ffb_lrObserver = obs;
                window.__ffb_lrTimeout = setTimeout(function() { post('timeout', ''); }, 6000);
                setTimeout(classify, 500);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func submitFormScript(submitSelector: String?) -> String {
        let sel = (submitSelector?.isEmpty == false) ? submitSelector!.jsEscaped : ""

        return """
        (function() {
            const btn = window.__ffb_findSubmit ? window.__ffb_findSubmit('\(sel)') : null;
            if (btn) { btn.click(); return JSON.stringify({ submitted: true }); }
            const form = document.querySelector('form');
            if (form) { form.submit(); return JSON.stringify({ submitted: true, method: 'form' }); }
            return JSON.stringify({ submitted: false });
        })();
        """
    }

    static func detectLoginFormScript() -> String {
        return """
        (function() {
            var isVisible = window.__ffb_isVisible || function(el) {
                if (!el) return false;
                if (el.offsetParent !== null) return true;
                var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                return !!(rect && rect.width > 0 && rect.height > 0);
            };
            var passFields = window.__ffb_deepAll
                ? window.__ffb_deepAll('input[type="password"], input[autocomplete="current-password"]')
                : document.querySelectorAll('input[type="password"], input[autocomplete="current-password"]');
            var visiblePass = 0;
            for (var i = 0; i < passFields.length; i++) {
                if (isVisible(passFields[i])) visiblePass++;
            }
            var forms = document.querySelectorAll('form');
            var formCount = 0;
            for (var j = 0; j < forms.length; j++) {
                if (forms[j].querySelector('input[type="password"], input[autocomplete="current-password"]')) formCount++;
            }
            return JSON.stringify({
                hasLoginForm: visiblePass > 0,
                passwordFieldCount: passFields.length,
                loginFormCount: formCount
            });
        })();
        """
    }

    /// Installs a MutationObserver that posts page state to native via the
    /// `rcrObserver` script-message handler. Idempotent — a previous observer
    /// is disconnected before a new one is attached. The script also fires an
    /// initial state ping so the runner sees the post-submit page even when
    /// no further DOM mutations occur.
    static func rcrInstallObserverScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_rcrObserver) { try { window.__ffb_rcrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} }
                // Both readers share window.__ffb_readPageState, so the
                // observer and the one-shot snapshot can never disagree
                // about what the same page says.
                var send = function() {
                    try {
                        if (!window.__ffb_readPageState) return;
                        var state = window.__ffb_readPageState();
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rcrObserver) {
                            window.webkit.messageHandlers.rcrObserver.postMessage(state);
                        }
                    } catch (e) {}
                };
                // A terminal page (disabled / success / an error banner) is
                // reported the moment it appears instead of after the full
                // debounce, so a decided attempt never pays the settle cost.
                var debounced = function() {
                    if (window.__ffb_rcrTimer) { clearTimeout(window.__ffb_rcrTimer); }
                    var quick = false;
                    try {
                        if (window.__ffb_readPageState) {
                            var s = window.__ffb_readPageState();
                            quick = !!(s.hasDisabled || s.hasTempDisabled || s.hasWelcome ||
                                       s.hasSuccess || s.hasError || s.hasCaptcha || s.hasTwoFactor);
                        }
                    } catch (e) {}
                    window.__ffb_rcrTimer = setTimeout(send, quick ? 60 : 450);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
                window.__ffb_rcrObserver = obs;
                setTimeout(send, 350);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func rcrUninstallObserverScript() -> String {
        return """
        (function() {
            try { if (window.__ffb_rcrObserver) { window.__ffb_rcrObserver.disconnect(); } } catch(e){}
            window.__ffb_rcrObserver = null;
            if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} window.__ffb_rcrTimer = null; }
            return JSON.stringify({ uninstalled: true });
        })();
        """
    }

    /// One-shot, synchronous-style page-state read (no observer, no debounce).
    /// Returns the same shape as the `rcrObserver` message so the extra-submit
    /// loop can check for a terminal result (disabled / temp-disabled /
    /// success) after every confirmation submit, without waiting on the
    /// MutationObserver debounce.
    static func pageStateSnapshotScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_readPageState) {
                    return JSON.stringify(window.__ffb_readPageState());
                }
                var passField = document.querySelector('input[type=\"password\"]');
                var hasPassword = !!(passField && passField.offsetParent !== null);
                var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                var lower = bodyText.toLowerCase();
                var hasWelcome = bodyText.indexOf('Welcome!') !== -1;
                var hasDisabled = lower.indexOf('been disabled') !== -1;
                var hasTempDisabled = (!hasDisabled) && (lower.indexOf('temporarily') !== -1);
                var path = window.location.pathname || '/';
                var isHomepage = (path === '' || path === '/');
                return JSON.stringify({
                    hasPassword: hasPassword,
                    hasWelcome: hasWelcome,
                    hasDisabled: hasDisabled,
                    hasTempDisabled: hasTempDisabled,
                    hasSuccess: false,
                    isHomepage: isHomepage,
                    url: window.location.href
                });
            } catch (e) {
                return JSON.stringify({ hasPassword: false, hasWelcome: false, hasDisabled: false, hasTempDisabled: false, hasSuccess: false, isHomepage: false, url: '' });
            }
        })();
        """
    }

    // MARK: - Multi-window viewport normalization

    /// Forces every page loaded inside a multi-window (Quad) tile to lay out
    /// against a full, "normal" single-window phone width instead of
    /// reflowing into the tile's own tiny physical width. WebKit's standard
    /// mobile viewport auto-fit then shrinks that normal layout down to
    /// whatever the tile's actual size is — giving every grid size (2×2,
    /// 2×3, 4×2, 3×3, 3×4, 4×4) an automatic, always-correct "zoomed out" view of the
    /// complete page instead of a squished/overlapping mobile layout.
    /// Re-asserts itself if the page's own scripts replace the viewport tag
    /// later (SPA-style sites), and again on DOMContentLoaded as a safety net
    /// since `document.head` may not exist yet at document-start.
    static func multiWindowViewportScript(referenceWidth: Int) -> String {
        return """
        (function() {
            if (window.__ffb_viewportLocked) return;
            window.__ffb_viewportLocked = true;
            var content = 'width=\(referenceWidth)';
            var apply = function() {
                try {
                    var metas = document.querySelectorAll('meta[name="viewport"]');
                    if (metas.length === 1 && metas[0].getAttribute('content') === content) return;
                    for (var i = 0; i < metas.length; i++) {
                        try { metas[i].remove(); } catch (e) {}
                    }
                    var meta = document.createElement('meta');
                    meta.setAttribute('name', 'viewport');
                    meta.setAttribute('content', content);
                    (document.head || document.documentElement).appendChild(meta);
                } catch (e) {}
            };
            apply();
            document.addEventListener('DOMContentLoaded', apply);
            var timer = null;
            try {
                var obs = new MutationObserver(function() {
                    if (timer) clearTimeout(timer);
                    timer = setTimeout(apply, 300);
                });
                obs.observe(document.documentElement, { childList: true, subtree: true });
                window.__ffb_viewportObserver = obs;
            } catch (e) {}
        })();
        """
    }

    // MARK: - Cookie banner removal

    /// Injected on every page load. Scans and removes cookie consent banners
    /// immediately, then installs a MutationObserver to catch dynamically-
    /// injected banners that appear after the initial load. Runs silently.
    static func cookieBannerRemovalScript() -> String {
        return """
        (function() {
            if (window.__ffb_cookieRemovalInstalled) return;
            window.__ffb_cookieRemovalInstalled = true;
            var selectors = [
                '.cookie-banner', '.cookieBanner', '.cookie-consent', '.cookieConsent',
                '.cookie-notice', '.cookieNotice', '.cookie-bar', '.cookieBar',
                '.cookie-popup', '.cookiePopup', '.cookie-modal', '.cookieModal',
                '#cookie-banner', '#cookieBanner', '#cookie-consent', '#cookieConsent',
                '#cookie-notice', '#cookieNotice', '#cookie-bar', '#cookieBar',
                '.gdpr-banner', '.gdprBanner', '.gdpr-modal', '.gdprModal',
                '.gdpr-consent', '.gdprConsent', '.gdpr-notice', '.gdprNotice',
                '#gdpr-banner', '#gdprBanner', '#gdpr-modal', '#gdprModal',
                '#gdpr-consent', '#gdprConsent', '#gdpr-notice', '#gdprNotice',
                '.cc-banner', '.ccBanner', '.cc-consent', '.ccConsent',
                '.consent-banner', '.consentBanner', '.consent-modal', '.consentModal',
                '#consent-banner', '#consentBanner', '#consent-modal', '#consentModal',
                '.eu-cookie', '.euCookie', '.privacy-banner', '.privacyBanner',
                '#privacy-banner', '#privacyBanner',
                '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.onetrust-pc-dark-filter',
                '#CybotCookiebotDialog', '#CybotCookiebotDialogBody',
                '.qc-cmp2-container', '.qc-cmp2-summary-buttons',
                '#didomi-host', '.didomi-popup-container',
                '#truste-consent-track', '.truste_overlay', '.truste_box_overlay',
                '.osano-cm-dialog', '#osano-cm-dom-info-dialog-open',
                '.sp_choice_type_11', '#sp_message_container_'
            ];
            // Attribute selectors for cookie/consent labelled elements.
            var attrSelectors = [
                '[aria-label*="cookie" i]',
                '[aria-label*="consent" i]',
                '[aria-label*="gdpr" i]',
                '[aria-label*="privacy" i]',
                '[data-cookie*="banner" i]',
                '[data-nosnippet*="cookie"]'
            ];
            var allSelectors = selectors.concat(attrSelectors);
            window.__ffb_cookieSelectors = allSelectors;
            var clickAccept = function() {
                var known = [
                    '#onetrust-accept-btn-handler',
                    '#onetrust-pc-btn-handler',
                    '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
                    '#CybotCookiebotDialogBodyButtonAccept',
                    '.qc-cmp2-summary-buttons button[mode="primary"]',
                    '#didomi-notice-agree-button',
                    '.osano-cm-accept-all',
                    'button[id*="accept-all" i]',
                    'button[class*="accept-all" i]',
                    'button[aria-label*="accept" i]'
                ];
                for (var n = 0; n < known.length; n++) {
                    try {
                        var hit = document.querySelector(known[n]);
                        if (hit) { hit.click(); return true; }
                    } catch(e) {}
                }
                var buttons = document.querySelectorAll('button, a, [role="button"], input[type="button"]');
                for (var b = 0; b < buttons.length; b++) {
                    try {
                        var t = ((buttons[b].innerText || buttons[b].value || '') + '').replace(/\\s+/g, ' ').trim();
                        if (/^(accept( all)?|agree|allow( all)?|i agree|got it|ok)$/i.test(t)) {
                            buttons[b].click();
                            return true;
                        }
                    } catch(e) {}
                }
                return false;
            };
            var removeMatches = function() {
                clickAccept();
                for (var i = 0; i < allSelectors.length; i++) {
                    try {
                        var els = document.querySelectorAll(allSelectors[i]);
                        for (var j = 0; j < els.length; j++) {
                            try { els[j].remove(); } catch(e) {}
                        }
                    } catch(e) {}
                }
                // Tight text-based fallback: only removes elements that are
                // BOTH short AND positioned as a banner (fixed or sticky),
                // since real cookie banners are always overlaid at the
                // viewport edge — never inline in the main content flow.
                try {
                    var candidates = document.querySelectorAll('div[style*="fixed"], div[style*="sticky"], section[style*="fixed"], section[style*="sticky"], aside[style*="fixed"], aside[style*="sticky"]');
                    for (var k = 0; k < candidates.length; k++) {
                        try {
                            var d = candidates[k];
                            var text = (d.textContent || '').toLowerCase();
                            var hasCookie = text.indexOf('cookie') !== -1 || text.indexOf('gdpr') !== -1;
                            var hasAction = text.indexOf('accept') !== -1 || text.indexOf('consent') !== -1 || text.indexOf('agree') !== -1 || text.indexOf('reject') !== -1;
                            if (text.length < 600 && hasCookie && hasAction) {
                                d.remove();
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
            };
            removeMatches();
            // Catch dynamically injected banners.
            try {
                var obs = new MutationObserver(function() {
                    if (window.__ffb_cookieTimer) clearTimeout(window.__ffb_cookieTimer);
                    window.__ffb_cookieTimer = setTimeout(removeMatches, 250);
                });
                obs.observe(document.documentElement, { childList: true, subtree: true });
                window.__ffb_cookieObs = obs;
            } catch(e) {}
        })();
        """
    }

    /// Waits for a cookie/consent banner to appear-and-be-dismissed after a
    /// fresh page load. The banner only ever shows up on a window's first
    /// load or right after a burn+reload, so this is only called at those two
    /// moments. Unlike the old version this does NOT bail immediately if no
    /// banner exists at call time — it gives the page a short grace window
    /// (~1.5s) for a dynamically-injected banner to appear, then polls via
    /// MutationObserver until dismissed or the full timeout elapses.
    static func waitForCookieNoticeScript(
        timeoutMs: Int = 10000,
        graceMs: Int = 1500
    ) -> String {
        return """
        (function() {
            return new Promise(function(resolve) {
                try {
                    var selectors = window.__ffb_cookieSelectors || [];
                    var matches = function() {
                        for (var i = 0; i < selectors.length; i++) {
                            try { if (document.querySelector(selectors[i])) return true; } catch(e) {}
                        }
                        return false;
                    };
                    var clickAccept = function() {
                        var known = [
                            '#onetrust-accept-btn-handler',
                            '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
                            '#CybotCookiebotDialogBodyButtonAccept',
                            '.qc-cmp2-summary-buttons button[mode="primary"]',
                            '#didomi-notice-agree-button',
                            '.osano-cm-accept-all',
                            'button[id*="accept-all" i]',
                            'button[aria-label*="accept" i]'
                        ];
                        for (var n = 0; n < known.length; n++) {
                            try {
                                var hit = document.querySelector(known[n]);
                                if (hit) { hit.click(); return true; }
                            } catch(e) {}
                        }
                        var buttons = document.querySelectorAll('button, a, [role="button"], input[type="button"]');
                        for (var b = 0; b < buttons.length; b++) {
                            try {
                                var t = ((buttons[b].innerText || buttons[b].value || '') + '').replace(/\\s+/g, ' ').trim();
                                if (/^(accept( all)?|agree|allow( all)?|i agree|got it|ok)$/i.test(t)) {
                                    buttons[b].click();
                                    return true;
                                }
                            } catch(e) {}
                        }
                        return false;
                    };
                    var done = false;
                    var obs = null;
                    var timer = null;
                    var pokeTimer = null;
                    var finish = function(reason) {
                        if (done) return;
                        done = true;
                        try { if (obs) obs.disconnect(); } catch(e) {}
                        try { if (timer) clearTimeout(timer); } catch(e) {}
                        try { if (pokeTimer) clearInterval(pokeTimer); } catch(e) {}
                        resolve(JSON.stringify({ waited: true, reason: reason }));
                    };
                    var startObserving = function() {
                        if (matches()) {
                            clickAccept();
                            pokeTimer = setInterval(function() {
                                if (!matches()) { finish('dismissed'); return; }
                                clickAccept();
                            }, 400);
                            obs = new MutationObserver(function() {
                                if (!matches()) finish('dismissed');
                            });
                            obs.observe(document.documentElement, { childList: true, subtree: true });
                        } else {
                            finish('none');
                        }
                    };
                    if (matches()) {
                        startObserving();
                    } else {
                        var graceTimer = setTimeout(function() {
                            startObserving();
                        }, \(graceMs));
                        obs = new MutationObserver(function() {
                            if (matches()) {
                                try { clearTimeout(graceTimer); } catch(e) {}
                                try { obs.disconnect(); } catch(e) {}
                                startObserving();
                            }
                        });
                        obs.observe(document.documentElement, { childList: true, subtree: true });
                    }
                    timer = setTimeout(function() { finish('timeout'); }, \(timeoutMs));
                } catch (e) {
                    resolve(JSON.stringify({ waited: false, reason: 'error' }));
                }
            });
        })();
        """
    }

    // MARK: - Fingerprint hardening

    /// Spoils font enumeration so sites can't fingerprint by installed fonts.
    /// Injected at document start so it takes effect before any page JS.
    static func fontSpoofingScript() -> String {
        return """
        (function() {
            if (window.__ffb_fontSpoofed) return;
            window.__ffb_fontSpoofed = true;
            var sparseFonts = ['Arial', 'Times New Roman', 'Courier New', 'Georgia', 'Verdana', 'Helvetica'];
            try {
                var origEnumerate = Object.getOwnPropertyDescriptor(CSSFontFaceRule.prototype, 'family');
                Object.defineProperty(document, 'fonts', {
                    get: function() {
                        return {
                            values: function() { return sparseFonts.values(); },
                            has: function() { return true; },
                            forEach: function(fn) { sparseFonts.forEach(fn); },
                            get: function() { return sparseFonts[0]; },
                            size: sparseFonts.length
                        };
                    },
                    configurable: true
                });
            } catch(e) {}
            // Override FontFaceSet check if present.
            try {
                if (typeof FontFaceSet !== 'undefined') {
                    FontFaceSet.prototype.check = function() { return true; };
                }
            } catch(e) {}
        })();
        """
    }

    /// Blocks device orientation and device motion event listeners so sites
    /// can't fingerprint sensor APIs. Injected at document start.
    static func sensorBlockingScript() -> String {
        return """
        (function() {
            if (window.__ffb_sensorsBlocked) return;
            window.__ffb_sensorsBlocked = true;
            var noop = function() {};
            try {
                Object.defineProperty(window, 'DeviceOrientationEvent', { value: null, writable: false, configurable: false });
            } catch(e) {}
            try {
                Object.defineProperty(window, 'DeviceMotionEvent', { value: null, writable: false, configurable: false });
            } catch(e) {}
            // Block addEventListener for these event types.
            var origAdd = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function(type, listener, options) {
                if (type === 'deviceorientation' || type === 'devicemotion' ||
                    type === 'orientationchange' || type === 'compassneedscalibration') {
                    return;
                }
                return origAdd.call(this, type, listener, options);
            };
            // Nullify the legacy on* properties.
            try { Object.defineProperty(window, 'ondeviceorientation', { get: function(){ return null; }, set: noop, configurable: false }); } catch(e) {}
            try { Object.defineProperty(window, 'ondevicemotion', { get: function(){ return null; }, set: noop, configurable: false }); } catch(e) {}
        })();
        """
    }

    /// Simulates human-like scrolling using randomised sine/cosine patterns.
    /// WKWebView doesn't expose mouse events, but scroll events are a common
    /// fingerprinting vector — this normalises them. Gated behind the
    /// `__ffb_rcrActive` flag so pages only scroll during automated RCR
    /// runs, never during ordinary browsing.
    static func humanScrollSimulationScript() -> String {
        return """
        (function() {
            if (window.__ffb_scrollSimInstalled) return;
            window.__ffb_scrollSimInstalled = true;
            var phase = Math.random() * Math.PI * 2;
            var interval = 2000 + Math.random() * 4000;
            setInterval(function() {
                if (window.__ffb_rcrActive !== true) return;
                phase += 0.3 + Math.random() * 0.7;
                var dy = Math.round(Math.sin(phase) * 30 + Math.cos(phase * 1.7) * 20 + Math.sin(phase * 3.1) * 15);
                var dx = Math.round(Math.cos(phase * 2.3) * 12 + Math.sin(phase * 0.7) * 8);
                try {
                    window.scrollBy(dx, dy);
                } catch(e) {}
            }, interval);
        })();
        """
    }

    /// Enables human-like scrolling — called when an RCR run starts.
    static func rcrScrollEnableScript() -> String {
        "window.__ffb_rcrActive = true;"
    }

    /// Disables human-like scrolling — called when an RCR run stops.
    static func rcrScrollDisableScript() -> String {
        "window.__ffb_rcrActive = false;"
    }

    /// DOM weight used to split the process memory footprint across windows.
    static func pageMemoryMetricsScript() -> String {
        return """
        (function() {
            try {
                var html = '';
                try { html = (document.documentElement && document.documentElement.outerHTML) ? document.documentElement.outerHTML : ''; } catch (e) {}
                return JSON.stringify({
                    htmlBytes: html.length,
                    nodes: document.querySelectorAll('*').length,
                    images: document.images ? document.images.length : 0,
                    iframes: document.querySelectorAll('iframe').length,
                    scripts: document.scripts ? document.scripts.length : 0
                });
            } catch (e) {
                return JSON.stringify({ htmlBytes: 0, nodes: 0, images: 0, iframes: 0, scripts: 0 });
            }
        })();
        """
    }

    static func extractFilledCredentialsScript() -> String {
        return """
        (function() {
            var passField = window.__ffb_findPassword ? window.__ffb_findPassword('') : document.querySelector('input[type="password"]');
            if (!passField || !passField.value) return JSON.stringify({ found: false });
            // Prefer the ranked username finder — it scores by proximity to the
            // password, label text and autocomplete hints, so it beats a naive
            // first-match against a form that also holds a search box or a
            // first/last-name pair. Only fall back to a raw query if the ranked
            // finder (or its helpers) is unavailable, and even then favour a
            // filled field sitting above the password.
            var userField = window.__ffb_findUsername ? window.__ffb_findUsername('') : null;
            if (!userField || !userField.value) {
                var form = passField.closest ? passField.closest('form') : null;
                var scope = form || document;
                var query = 'input[type="email"], input[autocomplete="username"], input[type="tel"], input[type="text"], input:not([type])';
                var candidates = window.__ffb_deepAll ? window.__ffb_deepAll(query) : Array.prototype.slice.call(scope.querySelectorAll(query));
                var picked = null;
                for (var i = 0; i < candidates.length; i++) {
                    var c = candidates[i];
                    if (!c || c === passField) continue;
                    if (c.type === 'password' || c.type === 'hidden') continue;
                    // A filled field is the strongest tell; otherwise keep the
                    // first plausible one as a backstop.
                    if (c.value) { picked = c; break; }
                    if (!picked) picked = c;
                }
                if (!userField || (picked && picked.value)) { userField = picked || userField; }
            }
            return JSON.stringify({
                found: true,
                username: userField ? (userField.value || '') : '',
                password: passField.value || ''
            });
        })();
        """
    }
}

extension JavaScriptInjectionService {
    /// Parses the JSON string returned by `pageStateSnapshotScript()` (or
    /// posted by the `rcrObserver` message handler) into a plain dictionary.
    static func parsePageState(_ raw: Any?) -> [String: Any]? {
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    /// True if the payload represents a result RCR should act on immediately
    /// (permanent disable, temporary disable, or success) rather than firing
    /// another confirmation submit.
    static func isTerminalRCRState(_ payload: [String: Any]) -> Bool {
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasError = payload["hasError"] as? Bool ?? false
        let hasCaptcha = payload["hasCaptcha"] as? Bool ?? false
        let hasTwoFactor = payload["hasTwoFactor"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false
        // The server has responded to our submit the moment any of these
        // appear — a decided outcome (disabled / success / 2FA) or a hard stop
        // (error banner / captcha). Re-submitting the same credentials past
        // this point only invites more captchas, so stop and let the judge run.
        return hasDisabled || hasTempDisabled || hasWelcome || hasSuccess
            || hasTwoFactor || hasCaptcha || hasError
            || (isHomepage && !hasPassword)
    }
}

extension String {
    /// Escapes a Swift string for interpolation into a single-quoted JS
    /// string literal. U+2028/U+2029 are legal in JSON but are line
    /// terminators in older ECMAScript string literals — a password
    /// containing either would silently break the whole injected script.
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
