window.rcmail && rcmail.addEventListener('init', function () {

    // --- settings page: the send-code / verify-code form -----------------
    if (rcmail.env.task == 'settings' && rcmail.env.action == 'plugin.secondary_email') {

        rcmail.addEventListener('plugin.secondary_email_sent', function () {
            $('#se-step-code').show();
            $('#se-code').val('').focus();
        });

        rcmail.addEventListener('plugin.secondary_email_verified', function (email) {
            $('#se-current').text(rcmail.gettext('currentset', 'secondary_email').replace('%s', email));
            $('#se-step-code').hide();
            $('#se-email').val(email);
        });

        var send_code = function () {
            var email = $.trim($('#se-email').val());
            if (!email) {
                rcmail.display_message(rcmail.gettext('invalidemail', 'secondary_email'), 'error');
                return;
            }
            var lock = rcmail.set_busy(true, 'loading');
            rcmail.http_post('plugin.secondary_email.send', { _email: email }, lock);
        };

        $('#se-send').on('click', send_code);
        $('#se-resend').on('click', send_code);

        $('#se-verify').on('click', function () {
            var code = $.trim($('#se-code').val());
            if (!code) {
                rcmail.display_message(rcmail.gettext('nocode', 'secondary_email'), 'error');
                return;
            }
            var lock = rcmail.set_busy(true, 'loading');
            rcmail.http_post('plugin.secondary_email.verify', { _code: code }, lock);
        });
    }

    // --- non-intrusive banner, any other page ------------------------
    if (rcmail.env.secondary_email_show_banner && !sessionStorage.getItem('secondary_email_dismissed')) {
        var bar = $('<div>', {
            id: 'secondary-email-banner',
            css: {
                position: 'relative', zIndex: 9000, padding: '8px 36px 8px 14px',
                background: '#fff3cd', color: '#664d03', borderBottom: '1px solid #ffe69c',
                fontSize: '13px', textAlign: 'center'
            }
        });
        bar.append($('<span>').text(rcmail.gettext('noticetext', 'secondary_email') + ' '));
        bar.append($('<a>', { href: '?_task=settings&_action=plugin.secondary_email' })
            .text(rcmail.gettext('noticelink', 'secondary_email')));
        bar.append($('<a>', {
            href: '#', title: rcmail.gettext('noticedismiss', 'secondary_email'),
            css: { position: 'absolute', right: '12px', top: '6px', color: 'inherit', textDecoration: 'none' }
        }).text('×').on('click', function (e) {
            e.preventDefault();
            sessionStorage.setItem('secondary_email_dismissed', '1');
            bar.remove();
        }));
        $('body').prepend(bar);
    }
});
