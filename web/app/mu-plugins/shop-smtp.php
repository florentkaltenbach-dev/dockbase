<?php
/**
 * Plugin Name: Shop SMTP Relay
 * Description: Routes wp_mail through Mailcow's submission port using env-supplied credentials.
 * Version: 1.0.0
 */

defined('ABSPATH') || exit;

add_action('phpmailer_init', function ($phpmailer) {
    $host = getenv('WP_SMTP_HOST');
    $user = getenv('WP_SMTP_USER');
    $pass = getenv('WP_SMTP_PASS');

    if (!$host || !$user || !$pass) {
        return;
    }

    $phpmailer->isSMTP();
    $phpmailer->Host       = $host;
    $phpmailer->Port       = (int) (getenv('WP_SMTP_PORT') ?: 587);
    $phpmailer->SMTPAuth   = true;
    $phpmailer->Username   = $user;
    $phpmailer->Password   = $pass;
    $phpmailer->SMTPSecure = getenv('WP_SMTP_ENCRYPTION') ?: 'tls';
});

add_filter('wp_mail_from', function ($from) {
    $env = getenv('WP_SMTP_FROM_EMAIL');
    return $env ?: $from;
});

add_filter('wp_mail_from_name', function ($name) {
    $env = getenv('WP_SMTP_FROM_NAME');
    return $env ?: $name;
});
