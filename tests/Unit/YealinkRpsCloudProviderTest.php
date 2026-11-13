<?php

namespace Tests\Unit;

use App\Models\DomainSettings;
use App\Models\DeviceCloudProvisioning;
use App\Http\Controllers\DeviceCloudProvisioningController;
use App\Jobs\RegisterDeviceWithCloudProvider;
use App\Services\DeviceCloudProvisioningService;
use App\Services\YealinkRpsCloudProvider;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Redis;
use Tests\TestCase;

class YealinkRpsCloudProviderTest extends TestCase
{
    private string $databasePath;

    protected function setUp(): void
    {
        parent::setUp();

        $this->databasePath = sys_get_temp_dir() . '/fspbx-yealink-rps-' . bin2hex(random_bytes(8)) . '.sqlite';
        touch($this->databasePath);

        config([
            'database.default' => 'sqlite',
            'database.connections.sqlite.database' => $this->databasePath,
            'services.ztp.yealink.api_url' => 'https://yealink-rps.test',
            'logging.default' => 'null',
        ]);

        DB::purge('sqlite');
        DB::reconnect('sqlite');

        Schema::create('v_default_settings', function (Blueprint $table) {
            $table->string('default_setting_uuid')->primary();
            $table->string('default_setting_category')->nullable();
            $table->string('default_setting_subcategory')->nullable();
            $table->string('default_setting_name')->nullable();
            $table->text('default_setting_value')->nullable();
            $table->string('default_setting_enabled')->nullable();
        });

        Schema::create('v_domain_settings', function (Blueprint $table) {
            $table->string('domain_setting_uuid')->primary();
            $table->string('domain_uuid')->nullable();
            $table->string('domain_setting_category')->nullable();
            $table->string('domain_setting_subcategory')->nullable();
            $table->string('domain_setting_name')->nullable();
            $table->text('domain_setting_value')->nullable();
            $table->string('domain_setting_enabled')->nullable();
        });

        Schema::create('v_devices', function (Blueprint $table) {
            $table->string('device_uuid')->primary();
            $table->string('domain_uuid');
            $table->string('device_vendor');
            $table->string('device_address');
            $table->string('serial_number')->nullable();
        });
        Schema::create('device_cloud_provisioning', function (Blueprint $table) {
            $table->string('uuid')->primary();
            $table->string('device_uuid');
            $table->string('domain_uuid');
            $table->string('provider');
            $table->string('status');
            $table->string('last_action');
            $table->text('error')->nullable();
        });

        $this->provider()->setCredentials([
            'access_key_id' => 'access-key-id',
            'access_key_secret' => 'access-key-secret',
        ]);
    }

    protected function tearDown(): void
    {
        DB::purge('sqlite');

        if (isset($this->databasePath) && is_file($this->databasePath)) {
            unlink($this->databasePath);
        }

        parent::tearDown();
    }

    public function test_it_authenticates_with_ymcs_and_registers_a_device_by_mac(): void
    {
        $this->pairServer();

        Http::fake([
            'https://yealink-rps.test/v2/token' => Http::response([
                'access_token' => 'access-token',
                'token_type' => 'bearer',
                'expires_in' => 86400,
            ]),
            'https://yealink-rps.test/v2/rps/addDevicesByMac' => Http::response([
                'total' => 1,
                'successCount' => 1,
                'failureCount' => 0,
                'errors' => [],
            ]),
        ]);

        $result = $this->provider()->createDevice([
            'domain_uuid' => 'domain-uuid',
            'device_address' => '00:15:65:12:31:23',
            'serial_number' => '00123456789',
        ]);

        $this->assertTrue($result['success']);

        Http::assertSent(fn ($request) => $request->url() === 'https://yealink-rps.test/v2/token'
            && $request->hasHeader('Authorization', 'Basic ' . base64_encode('access-key-id:access-key-secret'))
            && $request->hasHeader('timestamp')
            && $request->hasHeader('nonce')
            && $request['grant_type'] === 'client_credentials');

        Http::assertSent(fn ($request) => $request->url() === 'https://yealink-rps.test/v2/rps/addDevicesByMac'
            && $request->hasHeader('Authorization', 'Bearer access-token')
            && $request->hasHeader('timestamp')
            && $request->hasHeader('nonce')
            && $request[0]['mac'] === '001565123123'
            && $request[0]['serverId'] === 'server-id'
            && $request->data() === [['mac' => '001565123123', 'serverId' => 'server-id']]
            && ! $request->hasHeader('X-Ca-Signature'));
    }

    public function test_it_normalizes_ymcs_device_paging_for_the_shared_sync_flow(): void
    {
        Http::fake([
            'https://yealink-rps.test/v2/token' => Http::response(['access_token' => 'access-token']),
            'https://yealink-rps.test/v2/rps/listDevices' => Http::response([
                'skip' => 0,
                'limit' => 1,
                'total' => 2,
                'data' => [['id' => 'device-id', 'mac' => '001565123123']],
            ]),
        ]);

        $result = $this->provider()->getDevices(1, null);

        $this->assertTrue($result['success']);
        $this->assertSame('001565123123', $result['data']['results'][0]['mac']);
        $this->assertSame('1', $result['data']['next']);
    }

    public function test_it_treats_a_ymcs_batch_error_as_a_failed_request(): void
    {
        $this->pairServer();

        Http::fake([
            'https://yealink-rps.test/v2/token' => Http::response(['access_token' => 'access-token']),
            'https://yealink-rps.test/v2/rps/addDevicesByMac' => Http::response([
                'total' => 1,
                'successCount' => 0,
                'failureCount' => 1,
                'errors' => [[
                    'mac' => '001565123123',
                    'errorInfo' => 'Device already exists.',
                ]],
            ]),
        ]);

        $result = $this->provider()->createDevice([
            'domain_uuid' => 'domain-uuid',
            'device_address' => '001565123123',
        ]);

        $this->assertFalse($result['success']);
        $this->assertSame('Device already exists.', $result['error']);
    }

    public function test_it_removes_bound_devices_before_deleting_an_rps_server(): void
    {
        Http::fake([
            'https://yealink-rps.test/v2/token' => Http::response(['access_token' => 'access-token']),
            'https://yealink-rps.test/v2/rps/listDevices' => Http::response([
                'skip' => 0,
                'limit' => 100,
                'total' => 2,
                'data' => [
                    ['id' => 'bound-device', 'serverId' => 'server-id'],
                    ['id' => 'other-device', 'serverId' => 'other-server'],
                ],
            ]),
            'https://yealink-rps.test/v2/rps/delDevices' => Http::response([
                'total' => 1,
                'successCount' => 1,
                'failureCount' => 0,
                'errors' => [],
            ]),
            'https://yealink-rps.test/v2/rps/delServers' => Http::response([
                'total' => 1,
                'successCount' => 1,
                'failureCount' => 0,
                'errors' => [],
            ]),
        ]);

        $this->assertTrue($this->provider()->deleteOrganization('server-id'));

        Http::assertSent(fn ($request) => $request->url() === 'https://yealink-rps.test/v2/rps/delDevices'
            && $request['deviceIdType'] === 'id'
            && $request['deviceIds'] === ['bound-device']);
        Http::assertSent(fn ($request) => $request->url() === 'https://yealink-rps.test/v2/rps/delServers'
            && $request['serverIds'] === ['server-id']);
    }

    public function test_serial_number_mode_defaults_off_and_survives_omitted_updates(): void
    {
        $this->assertFalse($this->provider()->getCredentials()['require_serial_number']);
        $this->setSerialMode(true);
        $this->provider()->setCredentials(['access_key_id' => 'new-key', 'access_key_secret' => 'new-secret']);
        $this->assertTrue($this->provider()->getCredentials()['require_serial_number']);
        $this->setSerialMode(false);
        $this->assertFalse($this->provider()->getCredentials()['require_serial_number']);
    }

    public function test_standard_mode_sends_serial_number_with_leading_zeros(): void
    {
        $this->setSerialMode(true);
        $this->pairServer();
        Http::fake([
            '*/v2/token' => Http::response(['access_token' => 'access-token']),
            '*/v2/rps/addDevices' => Http::response(['successCount' => 1, 'failureCount' => 0]),
        ]);
        $this->assertTrue($this->provider()->createDevice([
            'domain_uuid' => 'domain-uuid',
            'device_address' => '00:15:65:12:31:23',
            'serial_number' => '001106312113402006',
        ])['success']);
        Http::assertSent(fn ($request) => $request->url() === 'https://yealink-rps.test/v2/rps/addDevices'
            && $request->data() === [['mac' => '001565123123', 'serverId' => 'server-id', 'sn' => '001106312113402006']]);
        Http::assertSentCount(2);
    }

    public function test_standard_mode_rejects_missing_serial_before_any_http_request(): void
    {
        $this->setSerialMode(true);
        Http::fake();
        foreach ([[], ['serial_number' => null], ['serial_number' => '  ']] as $serial) {
            try {
                $this->provider()->createDevice($serial + ['domain_uuid' => 'domain-uuid', 'device_address' => '001565123123']);
                $this->fail('Missing serial must be rejected.');
            } catch (\RuntimeException $exception) {
                $this->assertSame('Save a serial number on this device before adding it to Yealink RPS.', $exception->getMessage());
            }
        }
        Http::assertNothingSent();
    }

    public function test_mac_only_403_preserves_provider_error_and_does_not_fall_back(): void
    {
        $this->pairServer();
        Http::fake([
            '*/v2/token' => Http::response(['access_token' => 'access-token']),
            '*/v2/rps/addDevicesByMac' => Http::response(['message' => 'Permission denied by Yealink.'], 403),
        ]);
        try {
            $this->provider()->createDevice(['domain_uuid' => 'domain-uuid', 'device_address' => '001565123123']);
            $this->fail('403 must fail.');
        } catch (\RuntimeException $exception) {
            $this->assertStringStartsWith('Permission denied by Yealink.', $exception->getMessage());
            $this->assertStringContainsString('enable Require serial number', $exception->getMessage());
        }
        Http::assertSentCount(2);
        $this->assertFalse($this->provider()->requiresSerialNumber());
    }

    public function test_bulk_preflight_rejects_entire_selection_without_pending_records_or_jobs(): void
    {
        $this->setSerialMode(true);
        Bus::fake();
        Http::fake();
        $this->insertDevice('valid', '001565123121', '001234');
        $this->insertDevice('missing', '001565123122');
        $this->insertDevice('blank', '001565123123', '  ');
        $this->insertDevice('poly', '001565123124', null, 'domain-uuid', 'polycom');
        $this->insertDevice('foreign', '001565123125', null, 'other-domain');

        $response = $this->registerItems(['valid', 'missing', 'blank', 'poly', 'foreign']);
        $this->assertSame(422, $response->getStatusCode());
        $errors = $response->getData(true)['errors'];
        $this->assertEqualsCanonicalizing(['missing', 'blank'], array_keys($errors));
        $this->assertStringContainsString('001565123122', $errors['missing'][0]);
        $this->assertStringContainsString('001565123123', $errors['blank'][0]);
        $this->assertSame(0, DeviceCloudProvisioning::count());
        Bus::assertNothingDispatched();
        Http::assertNothingSent();
    }

    public function test_registration_queues_saved_serial_and_excludes_foreign_tenant(): void
    {
        $this->setSerialMode(true);
        Bus::fake();
        $this->insertDevice('valid', '001565123121', '001234');
        $this->insertDevice('foreign', '001565123125', null, 'other-domain');
        $this->assertSame(201, $this->registerItems(['valid', 'foreign'])->getStatusCode());
        Bus::assertDispatched(RegisterDeviceWithCloudProvider::class, function ($job) {
            $params = (new \ReflectionProperty($job, 'params'))->getValue($job);
            return $params['serial_number'] === '001234' && $params['device_uuid'] === 'valid';
        });
        Bus::assertDispatchedTimes(RegisterDeviceWithCloudProvider::class, 1);
        $this->assertSame(1, DeviceCloudProvisioning::count());
        $this->assertSame('pending', DeviceCloudProvisioning::first()->status);
    }

    public function test_mac_only_mode_allows_registration_without_serial(): void
    {
        Bus::fake();
        $this->insertDevice('valid', '001565123121');
        $this->assertSame(201, $this->registerItems(['valid'])->getStatusCode());
        Bus::assertDispatchedTimes(RegisterDeviceWithCloudProvider::class, 1);
    }

    public function test_old_job_without_serial_records_visible_error_after_mode_changes(): void
    {
        Http::fake();
        $job = (new DeviceCloudProvisioningService())->register([
            'device_uuid' => 'old-device', 'domain_uuid' => 'domain-uuid',
            'device_vendor' => 'yealink', 'device_address' => '001565123121',
        ]);
        $this->setSerialMode(true);
        $limiter = \Mockery::mock();
        Redis::shouldReceive('throttle')->once()->with('cloud-provider-jobs')->andReturn($limiter);
        $limiter->shouldReceive('allow')->with(1)->andReturnSelf();
        $limiter->shouldReceive('every')->with(2)->andReturnSelf();
        $limiter->shouldReceive('then')->once()->andReturnUsing(fn ($callback, $failure) => $callback());
        $job->handle();
        $record = DeviceCloudProvisioning::first();
        $this->assertSame('error', $record->status);
        $this->assertSame('Save a serial number on this device before adding it to Yealink RPS.', $record->error);
        Http::assertNothingSent();
    }

    private function insertDevice(string $uuid, string $mac, ?string $serial = null, string $domain = 'domain-uuid', string $vendor = 'yealink'): void
    {
        DB::table('v_devices')->insert([
            'device_uuid' => $uuid, 'domain_uuid' => $domain, 'device_vendor' => $vendor,
            'device_address' => $mac, 'serial_number' => $serial,
        ]);
    }

    private function registerItems(array $items): \Illuminate\Http\JsonResponse
    {
        session(['domain_uuid' => 'domain-uuid']);
        request()->merge(['items' => $items]);
        return (new DeviceCloudProvisioningController())->register();
    }

    private function setSerialMode(bool $enabled): void
    {
        $this->provider()->setCredentials([
            'access_key_id' => 'access-key-id', 'access_key_secret' => 'access-key-secret',
            'require_serial_number' => $enabled,
        ]);
    }

    private function provider(): YealinkRpsCloudProvider
    {
        return new YealinkRpsCloudProvider();
    }

    private function pairServer(): void
    {
        DomainSettings::create([
            'domain_uuid' => 'domain-uuid',
            'domain_setting_category' => 'cloud provision',
            'domain_setting_subcategory' => 'yealink_rps_server_id',
            'domain_setting_name' => 'text',
            'domain_setting_value' => 'server-id',
            'domain_setting_enabled' => 'true',
        ]);
    }
}
