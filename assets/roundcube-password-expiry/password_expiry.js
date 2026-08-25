window.rcmail && rcmail.addEventListener('init', function () {

    // Dismissible per session, not permanent: re-appears next login during
    // the warning window rather than staying pinned across an entire work
    // session -- a banner nobody can dismiss for a week generates
    // disproportionate support tickets for the actual risk level this far
    // out. Once genuinely expired, password_expiry.php's hard redirect
    // (which cannot be dismissed) takes over instead of this banner.
    if (rcmail.env.password_expiry_show_banner && !sessionStorage.getItem('password_expiry_dismissed')) {
        var bar = $('<div>', {
            id: 'password-expiry-banner',
            css: {
                position: 'relative', zIndex: 9000, padding: '8px 36px 8px 14px',
                background: '#fff3cd', color: '#664d03', borderBottom: '1px solid #ffe69c',
                fontSize: '13px', textAlign: 'center'
            }
        });
        bar.append($('<span>').text(rcmail.gettext('noticetext', 'password_expiry') + ' '));
        bar.append($('<a>', { href: '?_task=settings&_action=plugin.password' })
            .text(rcmail.gettext('noticelink', 'password_expiry')));
        bar.append($('<a>', {
            href: '#', title: rcmail.gettext('noticedismiss', 'password_expiry'),
            css: { position: 'absolute', right: '12px', top: '6px', color: 'inherit', textDecoration: 'none' }
        }).text('×').on('click', function (e) {
            e.preventDefault();
            sessionStorage.setItem('password_expiry_dismissed', '1');
            bar.remove();
        }));
        $('body').prepend(bar);
    }
});
