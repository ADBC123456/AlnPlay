import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dream_player/services/update_service.dart';

void main() {
  test('compares numeric semver and v prefix', () {
    expect(UpdateService.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(UpdateService.compareVersions('v2.0', '2.0.0'), 0);
    expect(UpdateService.compareVersions('1.0+4', '1.0'), 0);
  });

  test('requires three stable version components', () async {
    SharedPreferences.setMockInitialValues({});
    final service = UpdateService(
      installedVersion: () async => '1.0.0',
      request: (u, h) async => const UpdateHttpResponse(
        200,
        '{"tag_name":"v1.2","draft":false,"prerelease":false,"html_url":"https://github.com/ADBC123456/AlnPlay/releases/tag/v1.2"}',
      ),
    );
    expect(
      (await service.check(force: true)).status,
      UpdateStatus.invalidResponse,
    );
  });

  test('returns update and stores etag', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = UpdateService(
      installedVersion: () async => '1.0.1',
      request: (uri, headers) async {
        calls++;
        expect(uri.toString(), contains('/releases/latest'));
        return const UpdateHttpResponse(
          200,
          '{"tag_name":"v1.2.0","body":"notes","draft":false,"prerelease":false,"html_url":"https://github.com/ADBC123456/AlnPlay/releases/tag/v1.2.0"}',
          etag: 'abc',
        );
      },
    );
    final result = await service.check(force: true);
    expect(result.status, UpdateStatus.updateAvailable);
    expect(result.release!.url, contains('/releases/tag/v1.2.0'));
    expect(calls, 1);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'dreamplayer.update.etag',
      ),
      'abc',
    );
  });

  test('maps not found and rate limited', () async {
    SharedPreferences.setMockInitialValues({});
    final notFound = UpdateService(
      request: (u, h) async => const UpdateHttpResponse(404, ''),
    );
    expect((await notFound.check(force: true)).status, UpdateStatus.notFound);
    final limited = UpdateService(
      request: (u, h) async => const UpdateHttpResponse(429, ''),
    );
    expect((await limited.check(force: true)).status, UpdateStatus.rateLimited);
  });

  test('rejects prerelease-shaped tags and a 304 without cache', () async {
    SharedPreferences.setMockInitialValues({});
    final invalid = UpdateService(
      installedVersion: () async => '1.0.0',
      request: (u, h) async => const UpdateHttpResponse(
        200,
        '{"tag_name":"v2.0.0-beta","draft":false,"prerelease":false,"html_url":"https://github.com/ADBC123456/AlnPlay/releases/tag/v2.0.0-beta"}',
      ),
    );
    expect(
      (await invalid.check(force: true)).status,
      UpdateStatus.invalidResponse,
    );
    final empty304 = UpdateService(
      request: (u, h) async => const UpdateHttpResponse(304, ''),
    );
    expect(
      (await empty304.check(force: true)).status,
      UpdateStatus.invalidResponse,
    );
  });

  test('throttles automatic checks for 24 hours', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = UpdateService(
      installedVersion: () async => '1.0.0',
      request: (u, h) async {
        calls++;
        return const UpdateHttpResponse(
          200,
          '{"tag_name":"v1.0.0","draft":false,"prerelease":false,"html_url":"https://github.com/ADBC123456/AlnPlay/releases/tag/v1.0.0"}',
        );
      },
    );
    await service.check(force: true);
    await service.check();
    expect(calls, 1);
  });

  test('maps a request timeout to network error', () async {
    SharedPreferences.setMockInitialValues({});
    final service = UpdateService(
      request: (u, h) async => throw TimeoutException('test'),
    );
    expect(
      (await service.check(force: true)).status,
      UpdateStatus.networkError,
    );
  });

  test('rate-limit cooldown applies to manual checks too', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = UpdateService(
      request: (u, h) async {
        calls++;
        return const UpdateHttpResponse(
          429,
          '',
          retryAfter: Duration(hours: 1),
        );
      },
    );
    expect((await service.check(force: true)).status, UpdateStatus.rateLimited);
    expect((await service.check(force: true)).status, UpdateStatus.rateLimited);
    expect(calls, 1);
  });

  test('network failure is throttled for automatic checks', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = UpdateService(
      request: (u, h) async {
        calls++;
        throw const SocketException('offline');
      },
    );
    expect(
      (await service.check(force: true)).status,
      UpdateStatus.networkError,
    );
    expect((await service.check()).status, UpdateStatus.networkError);
    expect(calls, 1);
  });

  test('notification is recorded once per release version', () async {
    SharedPreferences.setMockInitialValues({});
    final service = UpdateService();
    const release = UpdateInfo(
      version: 'v2.0.0',
      notes: '',
      url: alnPlayReleaseUrl,
    );
    expect(await service.shouldNotify(release), isTrue);
    await service.markNotified(release);
    expect(await service.shouldNotify(release), isFalse);
  });

  test('rejects invalid release URL and missing installed version', () async {
    SharedPreferences.setMockInitialValues({});
    final badUrl = UpdateService(
      installedVersion: () async => '1.0.0',
      request: (u, h) async => const UpdateHttpResponse(
        200,
        '{"tag_name":"v2.0.0","draft":false,"prerelease":false,"html_url":"https://example.com/release"}',
      ),
    );
    expect(
      (await badUrl.check(force: true)).status,
      UpdateStatus.invalidResponse,
    );
    SharedPreferences.setMockInitialValues({});
    final missingInstalled = UpdateService(
      installedVersion: () async => null,
      request: (u, h) async => const UpdateHttpResponse(
        200,
        '{"tag_name":"v2.0.0","draft":false,"prerelease":false,"html_url":"https://github.com/ADBC123456/AlnPlay/releases/tag/v2.0.0"}',
      ),
    );
    expect(
      (await missingInstalled.check(force: true)).status,
      UpdateStatus.invalidResponse,
    );
  });
}
