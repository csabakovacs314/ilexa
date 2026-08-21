/**
 * Companion to markasjunk: force its "Not junk" toolbar button to stay
 * visible in every folder, not just the configured spam folder. Registered
 * at parse time (not inside an 'init' listener) so it's guaranteed to be
 * attached before markasjunk_toggle_button() ever fires.
 */
if (window.rcmail) {
    rcmail.addEventListener('markasjunk-update', function(p) {
        p.disp.ham = true;
        return p;
    });
}
