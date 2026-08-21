<?php

/**
 * Keeps markasjunk's "Not junk" button visible in every folder, not just
 * the configured spam folder, so a message rspamd only tagged (add-header,
 * never moved) but left in Inbox can be taught as ham directly -- without
 * first moving it to Spam and back. Hooks markasjunk's own 'markasjunk-update'
 * JS event (see markasjunk.js), so the vendor plugin is never touched.
 */
class markasjunk_ham_everywhere extends rcube_plugin
{
    function init()
    {
        $rc = rcmail::get_instance();
        if ($rc->task === 'mail') {
            $this->include_script('markasjunk_ham_everywhere.js');
        }
    }
}
