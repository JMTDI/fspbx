<?php

namespace Tests\Unit;

use App\Services\FreeswitchEslService;
use App\Services\SwitchVariableService;
use Illuminate\Validation\ValidationException;
use Mockery;
use Tests\TestCase;

class SwitchVariableReloadTest extends TestCase
{
    public function test_successful_xml_write_triggers_reload(): void
    {
        $variables = Mockery::mock(SwitchVariableService::class)->makePartial();
        $variables->shouldReceive('syncVarsXml')->once()->ordered()->andReturn(true);
        $esl = Mockery::mock(FreeswitchEslService::class);
        $esl->shouldReceive('isConnected')->once()->andReturn(true);
        $esl->shouldReceive('executeCommand')->once()->with('reloadxml')->andReturn('+OK [Success]');
        $this->app->instance(FreeswitchEslService::class, $esl);

        $variables->syncAndReloadXml();
    }

    public function test_failed_xml_write_does_not_reload(): void
    {
        $variables = Mockery::mock(SwitchVariableService::class)->makePartial();
        $variables->shouldReceive('syncVarsXml')->once()->andReturn(false);
        $esl = Mockery::mock(FreeswitchEslService::class);
        $esl->shouldNotReceive('executeCommand');
        $this->app->instance(FreeswitchEslService::class, $esl);

        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage('Variables remain saved in the database');
        $variables->syncAndReloadXml();
    }

    /** @dataProvider failedReloadResponses */
    public function test_failed_reload_is_reported(mixed $response): void
    {
        $variables = Mockery::mock(SwitchVariableService::class)->makePartial();
        $variables->shouldReceive('syncVarsXml')->once()->andReturn(true);
        $esl = Mockery::mock(FreeswitchEslService::class);
        $esl->shouldReceive('isConnected')->once()->andReturn(true);
        $esl->shouldReceive('executeCommand')->once()->with('reloadxml')->andReturn($response);
        $this->app->instance(FreeswitchEslService::class, $esl);

        $this->expectException(ValidationException::class);
        $variables->syncAndReloadXml();
    }

    public static function failedReloadResponses(): array
    {
        return [['-ERR reload failed'], [null], ['']];
    }

    public function test_disconnected_event_socket_is_reported(): void
    {
        $variables = Mockery::mock(SwitchVariableService::class)->makePartial();
        $variables->shouldReceive('syncVarsXml')->once()->andReturn(true);
        $esl = Mockery::mock(FreeswitchEslService::class);
        $esl->shouldReceive('isConnected')->once()->andReturn(false);
        $esl->shouldNotReceive('executeCommand');
        $this->app->instance(FreeswitchEslService::class, $esl);

        $this->expectException(ValidationException::class);
        $variables->syncAndReloadXml();
    }
}
