<?php
/**
 * qa-receiver.php — Stocked QA report receiver for cPanel shared hosting.
 * Build 73 / v4.17.
 *
 * WHAT IT IS FOR
 * The Stocked app can post a finished QA ticket — its Markdown report, the two
 * AI hand-off documents, the screenshot and any mockup — straight to your own
 * domain, so the evidence lands on hosting you control rather than only in the
 * Cloudflare Worker's KV. It writes one folder per ticket, grouped by build.
 *
 * WHY PHP AND NOT SOMETHING NICER
 * Because cPanel hosting runs PHP and nothing else without setup. This file has
 * no dependencies, no composer, no database and no framework: upload it, set a
 * token, and it works. Everything clever was deliberately left out, because the
 * person maintaining it is not a PHP developer and the failure mode of a clever
 * script on shared hosting is a blank 500 page with the detail in a log you
 * cannot reach.
 *
 * ── INSTALL ──────────────────────────────────────────────────────────────────
 * 1. Edit QA_TOKEN below. Make it long and random. Anyone who has it can write
 *    files into the folder this script owns, so treat it like a password.
 * 2. Upload this file to  public_html/qa/qa-receiver.php
 * 3. Open the Stocked app → Settings → App Health → QA → "Reports, logs and
 *    where they go" → cPanel, and enter:
 *       URL    https://yourdomain.com/qa/qa-receiver.php
 *       Token  the same string you set in step 1
 * 4. Tap "Send everything that hasn't gone yet". Reports appear under
 *    public_html/qa/reports/Build 73/STK-73-0001 — title/
 *
 * ── A NOTE ON PRIVACY ────────────────────────────────────────────────────────
 * Everything written below public_html is reachable from the open internet by
 * anyone who guesses the path. QA reports contain screenshots of your app with
 * whatever data was on screen. The script drops a .htaccess into the storage
 * folder that denies direct access on Apache — which cPanel uses — but do not
 * rely on that alone if the reports are sensitive: put the storage folder
 * outside public_html by setting QA_STORAGE_DIR to an absolute path such as
 * '/home/youruser/qa-reports'.
 * ─────────────────────────────────────────────────────────────────────────────
 */

// ── Configuration ────────────────────────────────────────────────────────────

/** Shared secret. MUST match the token entered in the app. Change this. */
const QA_TOKEN = 'change-me-to-something-long-and-random';

/**
 * Where reports are written. Relative paths resolve next to this script.
 * An absolute path outside public_html is safer — see the privacy note above.
 */
const QA_STORAGE_DIR = 'reports';

/** Largest single upload accepted, in bytes. Mockups are the big ones. */
const QA_MAX_FILE_BYTES = 8 * 1024 * 1024;

/** Directory and file permissions. 0755/0644 suits nearly every cPanel host. */
const QA_DIR_MODE  = 0755;
const QA_FILE_MODE = 0644;

// ── Plumbing ─────────────────────────────────────────────────────────────────

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

/** Reply and stop. Every exit from this script goes through here. */
function qa_reply($status, $payload)
{
    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

/**
 * Make a path segment safe.
 *
 * The app already sanitises folder names, but this script must not trust the
 * app: anyone with the token can post anything. Strip every directory
 * separator and every dot-run, so no input can climb out of the storage folder
 * no matter what it contains.
 */
function qa_safe_segment($raw, $fallback)
{
    $s = (string) $raw;
    $s = str_replace(["\0", '/', '\\'], ' ', $s);
    $s = preg_replace('/\.{2,}/', '.', $s);
    $s = preg_replace('/[\x00-\x1F\x7F]/u', '', $s);
    $s = preg_replace('/[<>:"|?*]/u', '', $s);
    $s = trim($s, " .\t\n\r");
    if ($s === '' || $s === '.' || $s === '..') {
        return $fallback;
    }
    // 120 bytes keeps the full path under the 255-byte limit ext4 and most
    // shared hosts impose, even nested three folders deep.
    if (strlen($s) > 120) {
        $s = rtrim(substr($s, 0, 120));
    }
    return $s;
}

/** Create a directory, recursively, and report whether it now exists. */
function qa_ensure_dir($path)
{
    if (is_dir($path)) {
        return true;
    }
    // The @ is intentional: a race with a concurrent request makes mkdir emit a
    // warning and return false even though the directory is now there, and the
    // is_dir re-check below is the answer we actually want.
    @mkdir($path, QA_DIR_MODE, true);
    return is_dir($path);
}

/** Write a text file, returning true on success. */
function qa_write_text($path, $text)
{
    $ok = @file_put_contents($path, $text) !== false;
    if ($ok) {
        @chmod($path, QA_FILE_MODE);
    }
    return $ok;
}

// ── Guards ───────────────────────────────────────────────────────────────────

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') {
    // A plain GET is how you check the file uploaded correctly and PHP is
    // running. It deliberately reveals nothing but liveness.
    qa_reply(200, ['ok' => true, 'service' => 'stocked-qa-receiver', 'version' => '4.17']);
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    qa_reply(405, ['ok' => false, 'error' => 'POST only']);
}

if (QA_TOKEN === 'change-me-to-something-long-and-random') {
    qa_reply(500, [
        'ok'    => false,
        'error' => 'QA_TOKEN has not been changed from its default. Edit qa-receiver.php.',
    ]);
}

$token = isset($_POST['token']) ? (string) $_POST['token'] : '';
// hash_equals compares in constant time, so the response time cannot be used to
// guess the token one character at a time. Available since PHP 5.6.
if ($token === '' || !hash_equals(QA_TOKEN, $token)) {
    qa_reply(401, ['ok' => false, 'error' => 'bad token']);
}

// ── Where this ticket goes ───────────────────────────────────────────────────

$root = QA_STORAGE_DIR;
if ($root === '' || $root[0] !== '/') {
    $root = __DIR__ . '/' . $root;
}

if (!qa_ensure_dir($root)) {
    qa_reply(500, ['ok' => false, 'error' => 'cannot create storage folder: ' . $root]);
}

// Deny direct web access to the stored reports on Apache. Harmless elsewhere.
// Written once; if you have deliberately made the folder public, delete it.
$htaccess = $root . '/.htaccess';
if (!file_exists($htaccess)) {
    qa_write_text(
        $htaccess,
        "# Stocked QA reports — not for public reading.\n" .
        "<IfModule mod_authz_core.c>\n  Require all denied\n</IfModule>\n" .
        "<IfModule !mod_authz_core.c>\n  Order deny,allow\n  Deny from all\n</IfModule>\n"
    );
}

$build  = qa_safe_segment(isset($_POST['build']) ? $_POST['build'] : '', '0');
$folder = qa_safe_segment(isset($_POST['folder']) ? $_POST['folder'] : '', 'untitled');
$ticket = qa_safe_segment(isset($_POST['ticket']) ? $_POST['ticket'] : '', 'no-number');

$buildDir = $root . '/Build ' . $build;
$dir      = $buildDir . '/' . $folder;

if (!qa_ensure_dir($dir)) {
    qa_reply(500, ['ok' => false, 'error' => 'cannot create ticket folder']);
}

// ── Text documents ───────────────────────────────────────────────────────────
//
// The field names ARE the file names — 'report.md', 'chatgpt-mockup-prompt.md',
// 'claude-handback.md' — which is why the app sends them that way. Anything
// else posted as a field is ignored, so a future app version can add a document
// without this script needing to know about it in advance... but only if the
// name matches the pattern below, which exists so the field list cannot be used
// to write a .php file into a web-served folder.

$written = [];
$skipped = [];

foreach ($_POST as $name => $value) {
    if ($name === 'token' || !is_string($value)) {
        continue;
    }
    // Only .md and .txt, and only plain names. This is the one place where
    // attacker-controlled input becomes a filename with an extension, so it is
    // an allow-list rather than a deny-list on purpose.
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,60}\.(md|txt)$/', $name)) {
        continue;
    }
    $safe = qa_safe_segment($name, '');
    if ($safe === '') {
        continue;
    }
    if (qa_write_text($dir . '/' . $safe, $value)) {
        $written[] = $safe;
    } else {
        $skipped[] = $safe . ' (write failed)';
    }
}

// A small machine-readable sidecar, so anything you later build on top of this
// folder does not have to parse the Markdown to learn what the ticket is.
qa_write_text($dir . '/ticket.json', json_encode([
    'ticket'     => isset($_POST['ticket']) ? (string) $_POST['ticket'] : '',
    'title'      => isset($_POST['title']) ? (string) $_POST['title'] : '',
    'severity'   => isset($_POST['severity']) ? (string) $_POST['severity'] : '',
    'status'     => isset($_POST['status']) ? (string) $_POST['status'] : '',
    'build'      => isset($_POST['build']) ? (string) $_POST['build'] : '',
    'folder'     => isset($_POST['folder']) ? (string) $_POST['folder'] : '',
    'receivedAt' => gmdate('c'),
    'remoteIp'   => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '',
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));

// ── Images ───────────────────────────────────────────────────────────────────
//
// Exactly two are accepted, under fixed names, saved with a fixed extension.
// The uploaded filename is never used. That closes the usual PHP upload hole in
// the simplest possible way: there is no path by which a caller chooses what
// this script writes.

$imageFields = ['screenshot' => 'screenshot.jpg', 'mockup' => 'mockup.jpg'];

foreach ($imageFields as $field => $target) {
    if (!isset($_FILES[$field]) || !is_array($_FILES[$field])) {
        continue;
    }
    $f = $_FILES[$field];

    if (($f['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK) {
        if (($f['error'] ?? 0) !== UPLOAD_ERR_NO_FILE) {
            $skipped[] = $target . ' (upload error ' . $f['error'] . ')';
        }
        continue;
    }
    if (($f['size'] ?? 0) <= 0) {
        continue;
    }
    if ($f['size'] > QA_MAX_FILE_BYTES) {
        $skipped[] = $target . ' (too large: ' . $f['size'] . ' bytes)';
        continue;
    }
    if (!is_uploaded_file($f['tmp_name'])) {
        $skipped[] = $target . ' (not an uploaded file)';
        continue;
    }
    // Check the bytes, not the declared type: the Content-Type in a multipart
    // part is whatever the sender wrote there. getimagesize returns false for
    // anything that is not a real image, which is the whole test needed here.
    $info = @getimagesize($f['tmp_name']);
    if ($info === false || !in_array($info[2], [IMAGETYPE_JPEG, IMAGETYPE_PNG], true)) {
        $skipped[] = $target . ' (not a JPEG or PNG)';
        continue;
    }
    if ($info[2] === IMAGETYPE_PNG) {
        $target = str_replace('.jpg', '.png', $target);
    }

    if (@move_uploaded_file($f['tmp_name'], $dir . '/' . $target)) {
        @chmod($dir . '/' . $target, QA_FILE_MODE);
        $written[] = $target;
    } else {
        $skipped[] = $target . ' (move failed)';
    }
}

// ── Build index ──────────────────────────────────────────────────────────────
//
// Rebuilt from the folder listing on every post rather than appended to, so a
// re-sent ticket updates its line instead of adding a duplicate, and a folder
// deleted by hand disappears from the index by itself.

$rows = [];
foreach ((array) @scandir($buildDir) as $entry) {
    if ($entry === '.' || $entry === '..' || !is_dir($buildDir . '/' . $entry)) {
        continue;
    }
    $meta = @file_get_contents($buildDir . '/' . $entry . '/ticket.json');
    $m    = $meta ? json_decode($meta, true) : null;
    $rows[] = sprintf(
        "| %s | %s | %s | %s | %s |",
        $m['ticket']   ?? $entry,
        str_replace('|', '/', $m['title'] ?? ''),
        $m['severity'] ?? '',
        $m['status']   ?? '',
        $m['receivedAt'] ?? ''
    );
}
sort($rows);

qa_write_text(
    $buildDir . '/index.md',
    "# Stocked QA — Build " . $build . "\n\n" .
    count($rows) . " report" . (count($rows) === 1 ? '' : 's') .
    ", last updated " . gmdate('Y-m-d H:i') . " UTC.\n\n" .
    "| Number | Title | Severity | Status | Received |\n" .
    "| --- | --- | --- | --- | --- |\n" .
    implode("\n", $rows) . "\n"
);

qa_reply(201, [
    'ok'      => true,
    'ticket'  => $ticket,
    'folder'  => 'Build ' . $build . '/' . $folder,
    'written' => $written,
    'skipped' => $skipped,
]);
