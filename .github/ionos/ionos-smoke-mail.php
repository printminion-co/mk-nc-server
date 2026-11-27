<?php

/**
 * Makes a sample system mail with the real mail template of an installed instance and prints it as JSON
 * ({"class": ..., "html": ..., "text": ...}). Used by ionos-smoke-brand.sh, run in the unpacked tree:
 *
 *   php ionos-smoke-mail.php <tree>
 *
 * It sends nothing: it only renders what IMailer::createEMailTemplate returns, the way every system mail is made.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli' || !isset($argv[1]) || !is_file($argv[1] . '/lib/base.php')) {
	fwrite(STDERR, "usage: php ionos-smoke-mail.php <tree of an installed instance>\n");
	exit(2);
}
$tree = $argv[1];
chdir($tree);
define('OC_CONSOLE', 1);
require_once $tree . '/lib/base.php';

$mailer = \OCP\Server::get(\OCP\Mail\IMailer::class);
$template = $mailer->createEMailTemplate('ionos.smoke', []);
$template->setSubject('Smoke test mail');
$template->addHeader();
$template->addHeading('Smoke test heading');
$template->addBodyText('Smoke test body text.');
$template->addBodyButton('Open the instance', 'https://example.invalid/');
$template->addFooter();

echo json_encode([
	'class' => get_class($template),
	'html' => $template->renderHtml(),
	'text' => $template->renderText(),
], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
