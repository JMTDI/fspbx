<?php

namespace App\Mail;

use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Attachment;

class FaxReceived extends BaseMailable
{
    public function __construct(array $attributes = [])
    {
        $sender = $attributes['caller_id_number']
            ?? $attributes['caller_id_name']
            ?? '';
        $pages = $attributes['fax_pages'] ?? '';

        $attributes['email_subject'] = $attributes['email_subject']
            ?? 'Fax received from ' . $sender
                . ($pages !== '' ? ' (' . $pages . ' page' . ((string) $pages === '1' ? '' : 's') . ')' : '');

        parent::__construct($attributes);
    }

    public function content(): Content
    {
        return new Content(
            view: 'emails.fax.received',
            text: 'emails.fax.received-text',
        );
    }

    public function attachments(): array
    {
        $path = $this->attributes['attachment_path'] ?? null;

        if (!$path || !is_file($path)) {
            return [];
        }

        return [
            Attachment::fromPath($path)
                ->as($this->attributes['attachment_name'] ?? basename($path))
                ->withMime($this->attributes['attachment_mime'] ?? 'application/octet-stream'),
        ];
    }
}
