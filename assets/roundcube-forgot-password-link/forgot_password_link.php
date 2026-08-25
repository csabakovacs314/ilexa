<?php

/**
 * Adds a "forgot password?" link to Roundcube's login page.
 *
 * Roundcube's own recovery mechanism lives entirely in PostfixAdmin:
 * public/users/password-recover.php sends a reset link to a mailbox's
 * email_other column once it is set (see the secondary_email plugin, which
 * is the only thing that populates that column). This plugin adds no
 * recovery logic of its own -- it only makes the existing flow reachable
 * from the login screen users actually land on, via the login skin's own
 * <roundcube:container name="loginfooter"> insertion point.
 *
 * forgot_password_link_url is deployment-specific (PostfixAdmin's alias
 * path is not guaranteed to be the same on every install -- see
 * config.inc.php.dist); an empty URL disables the link rather than
 * rendering one that goes nowhere.
 */
class forgot_password_link extends rcube_plugin
{
    public $noframe = true;

    function init()
    {
        $this->load_config();
        $this->add_texts('localization/', true);
        $this->add_hook('template_container', [$this, 'container']);

        // Styles the link as a button and lifts it above the footer's product
        // name, so it lands directly under the submit button. Login page only
        // -- this is the only task that renders the container below, and the
        // rules deliberately reach #login-footer, which exists nowhere else.
        if (rcmail::get_instance()->task === 'login') {
            $this->include_stylesheet('forgot_password_link.css');
        }
    }

    function container($args)
    {
        if (($args['name'] ?? '') !== 'loginfooter') {
            return $args;
        }

        $url = rcmail::get_instance()->config->get('forgot_password_link_url', '');
        if ($url === '') {
            return $args;
        }

        // A root-relative href ('/postfixadmin2/...') would otherwise be
        // caught by rcmail_output_html::fix_paths(), which rewrites ANY
        // href/src starting with '/' as a skin-relative asset path (its
        // cache-busting mechanism for skin images/CSS/JS) -- that mangled
        // this exact link into "skins/elastic/postfixadmin2/...", a 404.
        // resolve_url() turns it into a scheme://host/... URL first, which
        // fix_paths() does not touch.
        $url = rcube_utils::resolve_url($url);

        $link = html::a(
            ['href' => $url, 'class' => 'forgot-password-link'],
            rcube::Q($this->gettext('forgotpassword'))
        );

        $args['content'] .= ($args['content'] !== '' ? ' &nbsp;&bull;&nbsp; ' : '') . $link;

        return $args;
    }
}
