<?php

/**
 * Password-expiry self-check for Roundcube.
 *
 * Reads mailbox.password_expiry directly (own DB connection, same pattern
 * as the secondary_email plugin) once per login, caches the result in
 * $_SESSION, and:
 *
 *  - already expired: hard-redirects to the change-password screen. Does
 *    NOT implement its own "your password expired" messaging -- instead it
 *    seeds $_SESSION['password_expires'], the exact session key the STOCK
 *    password plugin's own password_init() already reads to show a proper,
 *    already-translated (en/hu) notice. Deliberately not the
 *    _first=1 redirect password_force_new_user uses -- that shows a
 *    different "welcome, set your first password" message, wrong for this
 *    case.
 *  - within the warning window (password_expiry_warn_days, default 7): a
 *    dismissible banner (same shape as secondary_email's own), and ALSO
 *    seeds $_SESSION['password_expires'] with the expiry datetime, so
 *    navigating to Settings > Password directly (not via the banner link)
 *    still shows the stock "will expire soon" warning.
 *  - otherwise: does nothing.
 *
 * Roundcube has no general "check this user's expiry" mechanism of its own
 * -- $_SESSION['password_expires'] exists only for the brand-new-user flow
 * (password_force_new_user), gated on a $this->newuser flag this plugin
 * never sets. This plugin is what actually populates it for a returning
 * user's real expiry, every login.
 */
class password_expiry extends rcube_plugin
{
    public $noframe = true;

    private $rc;
    private $db;

    function init()
    {
        $this->rc = rcmail::get_instance();
        $this->load_config();
        $this->add_texts('localization/', true);

        $this->add_hook('login_after', [$this, 'login_after']);

        // Recomputed every login (login_after), but a session started before
        // this plugin was deployed never ran that hook -- compute once here
        // too so such a session is not silently exempt forever.
        if ($this->rc->task != 'login' && $this->rc->task != 'logout' && $this->rc->user && $this->rc->user->ID) {
            if (!isset($_SESSION['password_expiry_state'])) {
                $_SESSION['password_expiry_state'] = $this->_compute_state();
            }
            $this->_apply_state($_SESSION['password_expiry_state']);
        }
    }

    function login_after($args)
    {
        $_SESSION['password_expiry_state'] = $this->_compute_state();
        $this->_apply_state($_SESSION['password_expiry_state']);
        return $args;
    }

    // ---- core ----------------------------------------------------------

    // Master switch (ilexa console, Admin -> Jelszó-lejárati kényszerítés).
    // Checked first, before any DB query -- when off this plugin costs
    // nothing beyond one file read per login. Same file the console's own
    // qa_password_expiry_enabled() reads (src/rbac.php) and the notifier
    // cron script checks; if this path ever changes, update those two too.
    // Fails closed to disabled, matching the console's own fail-closed
    // default: a missing/unreadable file, or anything other than exactly
    // '1', means off.
    private const ENABLED_FILE = '/var/cache/quarantine-admin/password_expiry_enabled';

    private function _enabled(): bool
    {
        if (!is_file(self::ENABLED_FILE)) return false;
        return trim((string) @file_get_contents(self::ENABLED_FILE)) === '1';
    }

    private function _compute_state(): array
    {
        if (!$this->_enabled()) {
            return ['status' => 'ok'];
        }

        $expiry = $this->_get_password_expiry();
        if ($expiry === null) {
            return ['status' => 'ok'];
        }

        $warnDays = (int) $this->rc->config->get('password_expiry_warn_days', 7);
        $expiryTs = strtotime($expiry);
        if ($expiryTs === false) {
            return ['status' => 'ok'];
        }

        $now = time();
        if ($expiryTs <= $now) {
            return ['status' => 'expired'];
        }
        if ($expiryTs <= $now + $warnDays * 86400) {
            return ['status' => 'warning', 'expiry' => $expiry];
        }
        return ['status' => 'ok'];
    }

    private function _apply_state(array $state)
    {
        $status = $state['status'] ?? 'ok';

        if ($status === 'expired') {
            $_SESSION['password_expires'] = 1;
            // Don't re-redirect once already on the change-password screen --
            // that would trap the user in a redirect loop the moment they
            // land there.
            if (!($this->rc->task === 'settings' && strpos($this->rc->action ?? '', 'plugin.password') === 0)) {
                $this->rc->output->command('redirect', '?_task=settings&_action=plugin.password', false);
            }
            return;
        }

        if ($status === 'warning') {
            $_SESSION['password_expires'] = $state['expiry'];

            $this->include_script('password_expiry.js');
            $this->rc->output->set_env('password_expiry_show_banner', true);
            $this->rc->output->add_label(
                'password_expiry.noticetext',
                'password_expiry.noticelink',
                'password_expiry.noticedismiss'
            );
        }
    }

    private function _get_password_expiry(): ?string
    {
        $db  = $this->_db();
        $res = $db->query('SELECT password_expiry FROM mailbox WHERE username = ?', $_SESSION['username']);
        $row = $db->fetch_assoc($res);
        if (!$row || empty($row['password_expiry'])) {
            return null;
        }
        // The column's own schema default (and PostfixAdmin's pre-Phase-0
        // unset state) is 2000-01-01, a sentinel meaning "never computed",
        // not a real date. strtotime('2000-01-01') is a normal POSITIVE
        // timestamp (year 2000 is long after the epoch) -- a "<= 0" check
        // does NOT catch it, and would otherwise treat the sentinel as a
        // real date in the deep past, incorrectly hard-redirecting anyone
        // still carrying it as "expired". Compare against a fixed cutoff
        // well before this system's mail_expiry feature could have produced
        // any genuine value, rather than hardcoding the one exact sentinel
        // string (defends against any other old placeholder value too).
        $ts = strtotime($row['password_expiry']);
        if ($ts === false || $ts < strtotime('2020-01-01')) {
            return null;
        }
        return $row['password_expiry'];
    }

    private function _db()
    {
        if (!$this->db) {
            $dsn      = $this->rc->config->get('password_expiry_db_dsn');
            $this->db = rcube_db::factory($dsn, '', false);
        }
        return $this->db;
    }
}
