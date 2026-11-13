<?php

namespace Tests\Unit;

use App\Mail\ResetPasswordMail;
use App\Models\User;
use Illuminate\Auth\Notifications\ResetPassword;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Notifications\Channels\MailChannel;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Illuminate\View\Compilers\Compiler;
use ReflectionProperty;
use Tests\TestCase;

class ResetPasswordMailTest extends TestCase
{
    private string $originalConnection;

    protected function setUp(): void
    {
        parent::setUp();

        $compiledPath = '/tmp/fspbx-reset-password-mail-tests';
        File::ensureDirectoryExists($compiledPath);
        config(['view.compiled' => $compiledPath, 'mail.default' => 'array', 'mail.from.address' => 'noreply@example.test']);
        (new ReflectionProperty(Compiler::class, 'cachePath'))->setValue(app('blade.compiler'), $compiledPath);

        $this->originalConnection = config('database.default');
        config()->set('database.connections.reset_password_mail_test', [
            'driver' => 'sqlite',
            'database' => ':memory:',
            'prefix' => '',
            'foreign_key_constraints' => true,
        ]);
        config()->set('database.default', 'reset_password_mail_test');
        DB::purge('reset_password_mail_test');

        // Minimal schema for BaseMailable::mergeDefaultSettings(); no email_templates
        // table, so the mail renders from the shipped file-based template source
        // (App\Services\EmailTemplateSourceService), exercising the real template
        // file on disk.
        Schema::create('v_default_settings', function (Blueprint $table) {
            $table->uuid('default_setting_uuid')->primary();
            $table->string('default_setting_category');
            $table->string('default_setting_subcategory');
            $table->string('default_setting_value')->nullable();
            $table->string('default_setting_enabled')->default('true');
        });
        Schema::create('v_domain_settings', function (Blueprint $table) {
            $table->uuid('domain_uuid');
            $table->string('domain_setting_subcategory');
            $table->string('domain_setting_value')->nullable();
            $table->string('domain_setting_enabled')->default('true');
        });
    }

    protected function tearDown(): void
    {
        DB::disconnect('reset_password_mail_test');
        config()->set('database.default', $this->originalConnection);

        parent::tearDown();
    }

    public function test_the_reset_password_notification_is_routed_through_the_branded_mailable(): void
    {
        $notifiable = new class
        {
            public string $name_formatted = 'Jordan';
            public ?string $domain_uuid = null;

            public function getEmailForPasswordReset(): string
            {
                return 'jordan@example.test';
            }
        };

        $mail = (new ResetPassword('test-token'))->toMail($notifiable);

        $this->assertInstanceOf(ResetPasswordMail::class, $mail);
        $this->assertSame('jordan@example.test', $mail->attributes['email']);
        $this->assertSame('Jordan', $mail->attributes['name']);
        $this->assertTrue($mail->hasTo('jordan@example.test'));
        $this->assertStringContainsString('/test-token', $mail->attributes['url']);
        $this->assertStringContainsString('email=jordan%40example.test', $mail->attributes['url']);
    }

    public function test_content_renders_the_reset_link_and_expiry(): void
    {
        $mail = new ResetPasswordMail([
            'email' => 'jordan@example.test',
            'name' => 'Jordan',
            'url' => 'https://pbx.example.test/reset-password/test-token?email=jordan%40example.test',
            'expire_minutes' => 60,
        ]);

        $rendered = $mail->render();

        $this->assertStringContainsString(
            'https://pbx.example.test/reset-password/test-token',
            $rendered
        );
        $this->assertStringContainsString('60 minutes', $rendered);
        $this->assertStringContainsString('Jordan', $rendered);
    }

    public function test_subject_falls_back_to_the_shipped_template_subject(): void
    {
        $mail = new ResetPasswordMail([
            'email' => 'jordan@example.test',
            'name' => 'Jordan',
            'url' => 'https://pbx.example.test/reset-password/test-token',
            'expire_minutes' => 60,
        ]);

        $this->assertSame('Reset Password Notification', $mail->attributes['email_subject']);
    }

    public function test_notification_delivers_html_and_text_with_the_reset_link(): void
    {
        // Keep delivery real, but isolate unrelated email-log persistence.
        \Illuminate\Support\Facades\Event::fake([
            \Illuminate\Mail\Events\MessageSending::class,
            \Illuminate\Mail\Events\MessageSent::class,
        ]);
        $user = $this->recipient();
        app(MailChannel::class)->send($user, new ResetPassword('test-token'));

        $messages = app('mailer')->getSymfonyTransport()->messages();
        $this->assertCount(1, $messages);
        $message = $messages->first()->getOriginalMessage();
        $this->assertSame('jordan@example.test', $message->getTo()[0]->getAddress());
        $this->assertSame('Reset Password Notification', $message->getSubject());
        $url = url(route('password.reset', ['token' => 'test-token', 'email' => $user->user_email], false));
        foreach ([$message->getHtmlBody(), $message->getTextBody()] as $body) {
            $this->assertStringContainsString($url, html_entity_decode($body));
            $this->assertStringContainsString(config('auth.passwords.users.expire').' minutes', $body);
        }
    }

    public function test_recipient_account_override_wins_and_other_accounts_are_excluded(): void
    {
        $this->createTemplateTable();
        $user = $this->recipient();
        session(['domain_uuid' => '22222222-2222-4222-8222-222222222222']);
        $this->template('default', null, 'Default');
        $this->template('custom', null, 'Global');
        $this->template('custom', session('domain_uuid'), 'Other account');
        $this->template('custom', $user->domain_uuid, 'Recipient account');

        $mail = (new ResetPassword('test-token'))->toMail($user);
        $this->assertSame($user->domain_uuid, $mail->attributes['domain_uuid']);
        $this->assertSame('Recipient account', $mail->attributes['email_subject']);
        $this->assertStringContainsString('Recipient account', $mail->render());

        DB::table('email_templates')->where('domain_uuid', $user->domain_uuid)->delete();
        $this->assertSame('Global', (new ResetPassword('test-token'))->toMail($user)->attributes['email_subject']);
        DB::table('email_templates')->whereNull('domain_uuid')->where('template_type', 'custom')->delete();
        $this->assertSame('Default', (new ResetPassword('test-token'))->toMail($user)->attributes['email_subject']);
    }

    public function test_recipient_language_is_normalized_and_missing_translation_falls_back_to_english(): void
    {
        $this->createTemplateTable();
        $user = $this->recipient();
        session(['domain_uuid' => '22222222-2222-4222-8222-222222222222', 'domain.language.code' => 'en-us']);
        DB::table('v_domain_settings')->insert([
            'domain_uuid' => $user->domain_uuid,
            'domain_setting_subcategory' => 'language',
            'domain_setting_value' => ' ES-ES ',
        ]);
        $this->template('custom', $user->domain_uuid, 'English');
        $this->template('custom', $user->domain_uuid, 'Spanish', 'es-es');
        $mail = (new ResetPassword('test-token'))->toMail($user);
        $this->assertSame('es-es', $mail->attributes['language']);
        $this->assertSame('Spanish', $mail->attributes['email_subject']);

        DB::table('email_templates')->where('template_language', 'es-es')->delete();
        $this->assertSame('English', (new ResetPassword('test-token'))->toMail($user)->attributes['email_subject']);
        DB::table('v_domain_settings')->update(['domain_setting_value' => 'unsupported']);
        $mail = (new ResetPassword('test-token'))->toMail($user);
        $this->assertSame('en-us', $mail->attributes['language']);
        $this->assertSame('English', $mail->attributes['email_subject']);
    }

    private function recipient(): User
    {
        $user = new User;
        $user->user_email = 'jordan@example.test';
        $user->domain_uuid = '11111111-1111-4111-8111-111111111111';

        return $user;
    }

    private function createTemplateTable(): void
    {
        Schema::create('email_templates', function (Blueprint $table) {
            $table->uuid('email_template_uuid')->primary();
            $table->uuid('domain_uuid')->nullable();
            $table->string('template_key');
            $table->string('template_type');
            $table->string('template_language');
            $table->string('template_layout');
            $table->string('template_subject');
            $table->text('template_html');
            $table->text('template_text');
            $table->boolean('template_enabled');
            $table->timestamps();
        });
    }

    private function template(string $type, ?string $domainUuid, string $subject, string $language = 'en-us'): void
    {
        DB::table('email_templates')->insert([
            'email_template_uuid' => (string) Str::uuid(),
            'domain_uuid' => $domainUuid,
            'template_key' => 'authentication.reset-password',
            'template_type' => $type,
            'template_language' => $language,
            'template_layout' => 'none',
            'template_subject' => $subject,
            'template_html' => '<p>'.$subject.'</p><a href="{{ $attributes[\'url\'] }}">Reset</a>',
            'template_text' => $subject.' {{ $attributes[\'url\'] }}',
            'template_enabled' => true,
        ]);
    }
}
