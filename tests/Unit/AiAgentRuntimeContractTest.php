<?php

namespace Tests\Unit;

use PHPUnit\Framework\TestCase;

class AiAgentRuntimeContractTest extends TestCase
{
    public function test_outbound_runtime_uses_external_tcp_without_a_gateway_or_credentials(): void
    {
        $script = file_get_contents(dirname(__DIR__, 2) . '/resources/freeswitch_scripts/ai_agent.lua');

        $this->assertStringContainsString('sofia/external/', $script);
        $this->assertStringContainsString('@sip.retellai.com;transport=tcp', $script);
        $this->assertStringContainsString('sip_h_X-FSPBX-Agent-UUID', $script);
        $this->assertStringContainsString('sip_h_X-FSPBX-SIP-Host', $script);
        $this->assertStringContainsString('i.public_sip_host', $script);
        $this->assertStringContainsString("s.sip_profile_setting_name = 'sip-port'", $script);
        $this->assertStringContainsString('value:match("^%$%${([%w_.%-]+)}$")', $script);
        $this->assertStringContainsString('api:execute("global_getvar", variable_name)', $script);
        $this->assertStringContainsString('resolve_global_value(agent.external_sip_port)', $script);
        $this->assertStringContainsString('public_sip_host .. ":" .. external_sip_port', $script);
        $this->assertStringContainsString('log("Final dial string: " .. dial_string)', $script);
        $this->assertStringContainsString('session:execute("bridge", dial_string)', $script);
        $this->assertStringNotContainsString('recording_disabled', $script);
        $this->assertStringNotContainsString('sofia/gateway/', $script);
        $this->assertStringNotContainsString('password', strtolower($script));
    }

    public function test_return_runtime_requires_the_strict_uuid_transfer_shape_and_tenant_destination(): void
    {
        $script = file_get_contents(dirname(__DIR__, 2) . '/resources/freeswitch_scripts/ai_agent_return.lua');

        $this->assertStringContainsString('^xfer%.', $script);
        $this->assertStringContainsString('e.domain_uuid = a.domain_uuid', $script);
        $this->assertStringContainsString('a.provisioning_status = \'synced\'', $script);
        $this->assertStringContainsString('log("Received SIP Request-URI user: " .. request_user)', $script);
        $this->assertStringContainsString('"Parsed transfer target: AI Agent UUID="', $script);
        $this->assertStringContainsString('"Matched transfer target: AI Agent UUID="', $script);
        $this->assertStringContainsString('log("Final transfer command: " .. transfer_destination)', $script);
        $this->assertStringContainsString('session:execute("transfer", transfer_destination)', $script);
    }

    /** @dataProvider transferTargetProvider */
    public function test_transfer_lookup_only_accepts_enabled_destinations_in_the_agents_account(
        string $extension,
        bool $allowed,
        ?string $mutation = null
    ): void {
        $database = new \PDO('sqlite::memory:');
        $database->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $database->exec(<<<'SQL'
            CREATE TABLE ai_agents (ai_agent_uuid TEXT, domain_uuid TEXT, enabled BOOLEAN, provisioning_status TEXT);
            CREATE TABLE v_domains (domain_uuid TEXT, domain_name TEXT, domain_enabled TEXT);
            CREATE TABLE v_extensions (domain_uuid TEXT, extension TEXT, enabled TEXT);
            CREATE TABLE v_ring_groups (domain_uuid TEXT, ring_group_extension TEXT, ring_group_enabled TEXT);
            INSERT INTO ai_agents VALUES ('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa', 'account-a', true, 'synced');
            INSERT INTO v_domains VALUES ('account-a', 'a.example.test', 'true'), ('account-b', 'b.example.test', 'true');
            INSERT INTO v_extensions VALUES
                ('account-a', '100', 'true'),
                ('account-b', '100', 'true'),
                ('account-b', '101', 'true'),
                ('account-a', '102', 'false'),
                ('account-b', '102', 'true');
            INSERT INTO v_ring_groups VALUES
                ('account-a', '8000', 'true'),
                ('account-b', '8000', 'true'),
                ('account-b', '8001', 'true'),
                ('account-a', '8002', 'false'),
                ('account-b', '8002', 'true'),
                ('account-a', '8003', NULL);
            SQL);

        if ($mutation !== null) {
            $database->exec($mutation);
        }

        // Execute the runtime's SQL itself so account and enabled checks are exercised.
        $script = file_get_contents(dirname(__DIR__, 2) . '/resources/freeswitch_scripts/ai_agent_return.lua');
        $this->assertSame(1, preg_match('/dbh:first_row\(\[\[(.*?)\]\]/s', $script, $matches));
        $statement = $database->prepare($matches[1]);
        $statement->execute([
            'agent_uuid' => 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa',
            'extension' => $extension,
        ]);

        $this->assertSame($allowed ? [
            'domain_uuid' => 'account-a',
            'domain_name' => 'a.example.test',
            'extension' => $extension,
        ] : false, $statement->fetch(\PDO::FETCH_ASSOC));
    }

    public static function transferTargetProvider(): iterable
    {
        yield 'own extension with the same number in another account' => ['100', true];
        yield 'own ring group without an extension row' => ['8000', true];
        yield 'foreign extension' => ['101', false];
        yield 'foreign ring group' => ['8001', false];
        yield 'disabled extension with an enabled foreign match' => ['102', false];
        yield 'disabled ring group with an enabled foreign match' => ['8002', false];
        yield 'ring group without an enabled value' => ['8003', false];
        yield 'unknown destination' => ['9999', false];

        foreach (['extension' => '100', 'ring group' => '8000'] as $type => $extension) {
            yield "$type with a disabled account" => [$extension, false, "UPDATE v_domains SET domain_enabled = 'false' WHERE domain_uuid = 'account-a'"];
            yield "$type with a disabled agent" => [$extension, false, 'UPDATE ai_agents SET enabled = false'];
            yield "$type with an unsynchronized agent" => [$extension, false, "UPDATE ai_agents SET provisioning_status = 'failed'"];
            yield "$type with an unknown agent" => [$extension, false, 'DELETE FROM ai_agents'];
        }
    }

    public function test_phone_number_routing_builder_transfers_to_the_ai_agent_extension(): void
    {
        require_once dirname(__DIR__, 2) . '/app/helpers.php';

        $this->assertSame([
            'destination_app' => 'transfer',
            'destination_data' => '9450 XML account.example.com',
        ], buildDestinationAction([
            'type' => 'ai_agents',
            'extension' => '9450',
        ], 'account.example.com'));
    }
}
