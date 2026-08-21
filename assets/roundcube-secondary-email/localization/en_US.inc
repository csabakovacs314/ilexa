<?php
$labels = [];

$labels['secondary_email']       = 'Recovery email';
$labels['secondary_email_title'] = 'Recovery email';

$labels['intro'] = 'Add a secondary email address so you can recover your account if you forget your password. It is only used for password recovery.';
$labels['currentset']   = 'Recovery email on file: %s';
$labels['currentunset'] = 'No recovery email is set yet.';

$labels['newemail']    = 'Secondary email address';
$labels['sendcode']    = 'Send verification code';
$labels['entercode']   = 'Enter the 6-digit code we sent';
$labels['verifycode']  = 'Verify';
$labels['resend']      = 'Send a new code';

$labels['codesent']         = 'A verification code was sent. It expires in 10 minutes.';
$labels['saved']            = 'Recovery email saved.';
$labels['invalidemail']     = 'Enter a valid email address.';
$labels['samemail']         = 'Use an address different from your login address.';
$labels['toosoon']          = 'Please wait a bit before requesting another code.';
$labels['expired']          = 'That code expired. Send a new one.';
$labels['toomanyattempts']  = 'Too many attempts. Send a new code.';
$labels['badcode']          = 'That code is not correct.';
$labels['savefailed']       = 'Could not save the address. Try again.';
$labels['sendfailed']       = 'Could not send the code. Try again.';
$labels['nocode']           = 'Enter the code first.';
$labels['noemail']          = 'You must be logged in.';

$labels['mailsubject'] = 'Your webmail verification code';
$labels['mailbody']    = "Your verification code is: %s\n\nEnter this code in Webmail to confirm this address as your account recovery email. The code expires in 10 minutes.\n\nIf you did not request this, you can ignore this message.";

$labels['noticetext']     = 'You have no recovery email set — if you forget your password, no one can help you get back in.';
$labels['noticelink']     = 'Add one now';
$labels['noticedismiss']  = 'Dismiss';
