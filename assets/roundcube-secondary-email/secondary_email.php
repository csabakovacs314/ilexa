<?php

/**
 * Secondary (recovery) email plugin for Roundcube.
 *
 * Lets a user optionally record a verified secondary email address in
 * PostfixAdmin's own mailbox.email_other column. PostfixAdmin's stock
 * password-recover.php already sends the reset code there once it is
 * non-empty -- this plugin's only job is getting a verified address into
 * that column. It does not implement any part of the recovery flow itself.
 */
class secondary_email extends rcube_plugin
{
    public $noframe = true;

    private $rc;
    private $db;

    function init()
    {
        $this->rc = rcmail::get_instance();
        $this->load_config();
        $this->add_texts('localization/', true);

        if ($this->rc->task == 'settings') {
            $this->add_hook('settings_actions', [$this, 'settings_actions']);
            $this->register_action('plugin.secondary_email', [$this, 'settings_page']);
            $this->register_action('plugin.secondary_email.send', [$this, 'action_send']);
            $this->register_action('plugin.secondary_email.verify', [$this, 'action_verify']);
        }

        $this->add_hook('login_after', [$this, 'login_after']);

        // Notification banner: eligible on every task except login/logout,
        // for a logged-in user who has not yet set a recovery address.
        if ($this->rc->task != 'login' && $this->rc->task != 'logout' && $this->rc->user && $this->rc->user->ID) {
            if (!isset($_SESSION['secondary_email_needed'])) {
                // Session predates this plugin (login_after never ran for it) --
                // compute once and cache, same as the normal login path.
                $_SESSION['secondary_email_needed'] = ($this->_get_email_other() === '');
            }
            if ($_SESSION['secondary_email_needed']) {
                $this->include_script('secondary_email.js');
                $this->rc->output->set_env('secondary_email_show_banner', true);
                $this->rc->output->add_label(
                    'secondary_email.noticetext',
                    'secondary_email.noticelink',
                    'secondary_email.noticedismiss'
                );
            }
        }
    }

    // ---- settings tab ------------------------------------------------

    function settings_actions($args)
    {
        $args['actions'][] = [
            'action' => 'plugin.secondary_email',
            'class'  => 'secondary_email',
            'label'  => 'secondary_email',
            'title'  => 'secondary_email_title',
            'domain' => 'secondary_email',
        ];
        return $args;
    }

    function settings_page()
    {
        $this->include_script('secondary_email.js');
        $this->register_handler('plugin.body', [$this, 'html_form']);
        $this->rc->output->set_pagetitle($this->gettext('secondary_email'));
        $this->rc->output->set_env('secondary_email_current', $this->_get_email_other());
        $this->rc->output->add_label(
            'secondary_email.codesent',
            'secondary_email.invalidemail',
            'secondary_email.samemail',
            'secondary_email.toosoon',
            'secondary_email.expired',
            'secondary_email.toomanyattempts',
            'secondary_email.badcode',
            'secondary_email.savefailed',
            'secondary_email.sendfailed',
            'secondary_email.saved',
            'secondary_email.nocode',
            'secondary_email.noemail'
        );
        $this->rc->output->send('plugin');
    }

    function html_form($attrib)
    {
        $current = $this->_get_email_other();

        $out  = '<div id="secondary-email-plugin">';
        $out .= '<p>' . rcube::Q($this->gettext('intro')) . '</p>';
        $out .= '<p id="se-current">' . rcube::Q($current
            ? sprintf($this->gettext('currentset'), $current)
            : $this->gettext('currentunset')) . '</p>';

        $out .= '<div id="se-step-email">';
        $out .= '<label for="se-email">' . rcube::Q($this->gettext('newemail')) . '</label><br>';
        $out .= '<input type="email" id="se-email" size="40" value="' . rcube::Q($current) . '">';
        $out .= ' <button type="button" id="se-send" class="btn btn-secondary">' . rcube::Q($this->gettext('sendcode')) . '</button>';
        $out .= '</div>';

        $out .= '<div id="se-step-code" style="display:none">';
        $out .= '<label for="se-code">' . rcube::Q($this->gettext('entercode')) . '</label><br>';
        $out .= '<input type="text" id="se-code" size="8" maxlength="6" autocomplete="one-time-code" inputmode="numeric">';
        $out .= ' <button type="button" id="se-verify" class="btn btn-secondary">' . rcube::Q($this->gettext('verifycode')) . '</button>';
        $out .= ' <button type="button" id="se-resend" class="btn btn-link">' . rcube::Q($this->gettext('resend')) . '</button>';
        $out .= '</div>';

        $out .= '</div>';
        return $out;
    }

    // ---- ajax actions --------------------------------------------------

    function action_send()
    {
        if (!$this->rc->user || !$this->rc->user->ID) {
            $this->_ajax_error('noemail');
            return;
        }

        $email = trim(rcube_utils::get_input_string('_email', rcube_utils::INPUT_POST));

        if (!$email || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            $this->_ajax_error('invalidemail');
            return;
        }
        if (strcasecmp($email, $_SESSION['username']) === 0) {
            $this->_ajax_error('samemail');
            return;
        }

        $cooldown = (int) $this->rc->config->get('secondary_email_resend_seconds', 60);
        $last     = isset($_SESSION['secondary_email_sent_at']) ? $_SESSION['secondary_email_sent_at'] : 0;
        if (time() - $last < $cooldown) {
            $this->_ajax_error('toosoon');
            return;
        }

        $code = (string) random_int(100000, 999999);

        $_SESSION['secondary_email_pending'] = [
            'email'    => $email,
            'code'     => password_hash($code, PASSWORD_DEFAULT),
            'expires'  => time() + (int) $this->rc->config->get('secondary_email_code_ttl', 600),
            'attempts' => 0,
        ];
        $_SESSION['secondary_email_sent_at'] = time();

        if (!$this->_send_code($email, $code)) {
            $this->_ajax_error('sendfailed');
            return;
        }

        $this->rc->output->show_message($this->gettext('codesent'), 'confirmation');
        $this->rc->output->command('plugin.secondary_email_sent', true);
        $this->rc->output->send();
    }

    function action_verify()
    {
        if (!$this->rc->user || !$this->rc->user->ID) {
            $this->_ajax_error('noemail');
            return;
        }

        $code    = trim(rcube_utils::get_input_string('_code', rcube_utils::INPUT_POST));
        $pending = isset($_SESSION['secondary_email_pending']) ? $_SESSION['secondary_email_pending'] : null;

        if (!$pending || time() > $pending['expires']) {
            unset($_SESSION['secondary_email_pending']);
            $this->_ajax_error('expired');
            return;
        }
        if ($pending['attempts'] >= 5) {
            unset($_SESSION['secondary_email_pending']);
            $this->_ajax_error('toomanyattempts');
            return;
        }

        $_SESSION['secondary_email_pending']['attempts']++;

        if (!$code || !password_verify($code, $pending['code'])) {
            $this->_ajax_error('badcode');
            return;
        }

        if (!$this->_write_email_other($pending['email'])) {
            $this->_ajax_error('savefailed');
            return;
        }

        unset($_SESSION['secondary_email_pending']);
        $_SESSION['secondary_email_needed'] = false;

        $this->rc->output->show_message($this->gettext('saved'), 'confirmation');
        $this->rc->output->command('plugin.secondary_email_verified', $pending['email']);
        $this->rc->output->send();
    }

    function login_after($args)
    {
        $_SESSION['secondary_email_needed'] = ($this->_get_email_other() === '');
        return $args;
    }

    // ---- helpers ---------------------------------------------------------

    private function _ajax_error($key)
    {
        $this->rc->output->show_message($this->gettext($key), 'error');
        $this->rc->output->send();
    }

    private function _db()
    {
        if (!$this->db) {
            $dsn      = $this->rc->config->get('secondary_email_db_dsn');
            $this->db = rcube_db::factory($dsn, '', false);
        }
        return $this->db;
    }

    private function _get_email_other()
    {
        $db  = $this->_db();
        $res = $db->query('SELECT email_other FROM mailbox WHERE username = ?', $_SESSION['username']);
        $row = $db->fetch_assoc($res);
        return $row ? trim($row['email_other']) : '';
    }

    private function _write_email_other($email)
    {
        $db = $this->_db();
        $db->query('UPDATE mailbox SET email_other = ? WHERE username = ?', $email, $_SESSION['username']);
        return $db->affected_rows() === 1;
    }

    private function _send_code($to, $code)
    {
        $from = $this->rc->config->get('secondary_email_from');
        if (!$from) {
            $domain = strpos($_SESSION['username'], '@') !== false
                ? substr(strrchr($_SESSION['username'], '@'), 1)
                : ($_SERVER['SERVER_NAME'] ?? 'localhost');
            $from = 'postmaster@' . $domain;
        }

        $subject = $this->gettext('mailsubject');
        $body    = sprintf($this->gettext('mailbody'), $code);
        $headers = "From: $from\r\nContent-Type: text/plain; charset=UTF-8\r\n";

        return @mail($to, '=?UTF-8?B?' . base64_encode($subject) . '?=', $body, $headers);
    }
}
