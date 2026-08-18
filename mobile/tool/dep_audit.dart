// tool/dep_audit.dart
//
// Fails when a package this app resolves to carries a published security
// advisory. It reports; it never edits pubspec.yaml or pubspec.lock.
//
//   dart run tool/dep_audit.dart        # from mobile/, after `flutter pub get`
//
// Exit codes, because CI reads them and "nothing happened" must never look the
// same as "nothing is wrong":
//   0   every resolved pub.dev package was checked, none has an advisory
//   1   at least one has an advisory, or the lock could not be read at all
//   75  the audit did not complete — see the soft-pass note below
//
// WHY THIS EXISTS
// `flutter pub get` pulls 275 packages into this app, and Dart ships no `npm
// audit` equivalent — so nothing here had ever asked whether any of them is
// known to be vulnerable. The pre-market audit named that as a missing
// process. This closes it against OSV (osv.dev), the aggregator that carries
// the GitHub Advisory Database's `Pub` ecosystem, over plain HTTP with no new
// dependency: dart:io and dart:convert only, because a dependency auditor that
// adds dependencies is an odd thing to trust.
//
// WHY IT REPORTS AND NEVER BUMPS
// A transitive package has already hard-crashed this app once. An automatic
// upgrade would trade a hypothetical vulnerability for a real outage on a
// sideloaded fleet with no update channel, so a human reads the finding and
// decides which single package moves.
//
// WHY A NETWORK FAILURE PASSES AND A MISSING LOCK DOES NOT
// osv.dev is a third party on the far side of a runner's network. If it is
// down, this tree is not broken, and reddening every push over somebody else's
// outage is how a gate stops being obeyed and starts being deleted — so an
// unreachable or unrecognisable API exits 75 and says loudly that it proved
// nothing. A missing or unparseable pubspec.lock is the opposite kind of
// failure: local, deterministic, entirely about this repo. That one is red,
// because an audit that checked nothing must never read as green.

import 'dart:convert';
import 'dart:io';

/// OSV's batch endpoint accepts up to 1000 queries. 100 keeps each request
/// small, so one malformed response costs one batch of context rather than the
/// whole run, and a partial answer stays recognisable as partial.
const _batchSize = 100;

const _osvHost = 'api.osv.dev';
const _netTimeout = Duration(seconds: 30);

/// sysexits' EX_TEMPFAIL: the operation failed, but not because of the caller.
const _exitInconclusive = 75;

/// One resolved package, exactly as pubspec.lock records it.
class _Pkg {
  const _Pkg(this.name, this.version);

  final String name;
  final String version;
}

/// What the lock file yielded: what can be audited, and what cannot.
class _Lock {
  const _Lock(this.audited, this.skipped);

  final List<_Pkg> audited;

  /// Packages OSV's `Pub` ecosystem cannot answer for — SDK, git and path
  /// dependencies, and any private pub host. Listed, never dropped quietly:
  /// the difference between "clean" and "never looked at" is the whole point
  /// of running this.
  final List<String> skipped;
}

/// Stands in for "OSV paginated this package's advisories". Not an id: it is
/// never fetched and never linked, because there is no vulnerability page for
/// it — but it counts as a finding, so a truncated page can never read as a
/// clean one.
const _truncationMarker = 'osv:truncated';

/// An advisory, filled in as far as OSV would answer.
class _Advisory {
  const _Advisory(this.id, {this.summary, this.severity, this.aliases});

  final String id;
  final String? summary;
  final String? severity;
  final List<String>? aliases;

  /// One line a person can act on. `querybatch` answers bare ids, and
  /// "GHSA-9v85-q87q-g4vg" on its own tells a reader nothing at all.
  String get line {
    final parts = <String>[id];
    final s = severity;
    final t = summary;
    final a = aliases;
    if (s != null) parts.add(s);
    if (t != null) parts.add(t);
    if (a != null && a.isNotEmpty) parts.add('(${a.join(', ')})');
    return parts.join('  ');
  }
}

/// One package and everything OSV holds against it.
class _Finding {
  const _Finding(this.pkg, this.advisories);

  final _Pkg pkg;
  final List<_Advisory> advisories;
}

/// Thrown when OSV answers in a shape this decoder will not guess at. It
/// differs from a transport failure only in the message; both are
/// inconclusive, and both are loud.
class _OsvShapeException implements Exception {
  const _OsvShapeException(this.message);

  final String message;

  @override
  String toString() => 'OSV response shape: $message';
}

Future<void> main() async {
  final lock = File('pubspec.lock');
  if (!lock.existsSync()) {
    stderr.writeln(
      'dep_audit: no pubspec.lock in ${Directory.current.path}\n'
      '  Run this from mobile/, after `flutter pub get`. The lock is\n'
      '  gitignored in this repo, so a fresh checkout has to resolve before\n'
      '  the file exists at all.',
    );
    exit(1);
  }

  final parsed = _parseLock(lock.readAsStringSync());

  // The blindness check, and it is the same idea as release.sh asserting that
  // `flutter analyze` actually printed a summary: a parser that silently
  // matched nothing reports a spotless dependency tree, which is the most
  // convincing wrong answer this tool can give.
  if (parsed.audited.isEmpty) {
    stderr.writeln(
      'dep_audit: parsed 0 pub.dev packages out of ${lock.lengthSync()} bytes '
      'of pubspec.lock.\n'
      '  Either the lock format moved or the file is truncated. This audit is '
      'blind, not green.',
    );
    exit(1);
  }

  stdout.writeln(
    'dep_audit: ${parsed.audited.length} pub.dev packages resolved in '
    'pubspec.lock',
  );
  if (parsed.skipped.isNotEmpty) {
    stdout.writeln(
      '  no OSV coverage, not audited: ${parsed.skipped.join(', ')}',
    );
  }

  final client = HttpClient()..connectionTimeout = _netTimeout;

  final List<List<String>> ids;
  try {
    ids = await _queryOsv(client, parsed.audited);
  } catch (e) {
    client.close();
    stderr.writeln(
      '\n'
      '  ──────────────────────────────────────────────────────────────\n'
      '  DEPENDENCY AUDIT DID NOT RUN. THIS IS NOT A PASS.\n'
      '  ${e.runtimeType}: $e\n'
      '  ${parsed.audited.length} packages went unchecked. osv.dev is a\n'
      '  third party, so this exits $_exitInconclusive rather than 1 and\n'
      '  leaves the tree green — but nothing above was verified.\n'
      '  ──────────────────────────────────────────────────────────────',
    );
    exit(_exitInconclusive);
  }

  final findings = <_Finding>[];
  for (var i = 0; i < parsed.audited.length; i++) {
    if (ids[i].isEmpty) continue;
    final detailed = <_Advisory>[];
    for (final id in ids[i]) {
      // The marker is a note to the reader, not an advisory id: fetching it
      // would 404 and print a link to a vulnerability page that cannot
      // exist. It still travels in the list so the count and the exit code
      // treat a truncated page as a finding.
      if (id == _truncationMarker) {
        detailed.add(const _Advisory(_truncationMarker,
            summary: 'more advisories than one OSV page returns — open the '
                'package on osv.dev and read the full list by hand',),);
        continue;
      }
      detailed.add(await _detail(client, id));
    }
    findings.add(_Finding(parsed.audited[i], detailed));
  }
  client.close();

  if (findings.isEmpty) {
    stdout.writeln(
      'dep_audit: checked ${parsed.audited.length} packages against osv.dev — '
      'no advisories.',
    );
    return;
  }

  final report = StringBuffer()
    ..writeln()
    ..writeln(
      'dep_audit: ${findings.length} package(s) carry a published security '
      'advisory.',
    )
    ..writeln();
  for (final f in findings) {
    report.writeln('  ${f.pkg.name} ${f.pkg.version}');
    for (final a in f.advisories) {
      report.writeln('    ${a.line}');
      if (a.id != _truncationMarker) {
        report.writeln('    https://osv.dev/vulnerability/${a.id}');
      }
    }
    report.writeln();
  }
  report
    ..writeln('Read each one before touching pubspec.yaml. Move ONE package at')
    ..writeln('a time and re-run the gates: in this repo a blanket upgrade has')
    ..writeln('a worse record than the advisories it was meant to close.');
  stderr.write(report);
  exit(1);
}

/// Reads pubspec.lock without a YAML parser, because pub writes this file and
/// pub writes it the same way every time.
///
/// The anchors are load-bearing and were checked against the real file rather
/// than assumed. A package block opens at EXACTLY two spaces with nothing after
/// the colon, which excludes both the `name:` nested six spaces deep inside
/// every `description:` and the trailing `sdks:` block, whose `dart:` and
/// `flutter:` keys carry their value on the same line.
_Lock _parseLock(String text) {
  final blockStart = RegExp(r'^  "?([A-Za-z_][A-Za-z0-9_]*)"?:\s*$');
  final field = RegExp(r'^\s+(source|version|url):\s*"?([^"\s]+)"?\s*$');

  final audited = <_Pkg>[];
  final skipped = <String>[];

  String? name;
  String? source;
  String? version;
  String? url;

  void close() {
    final n = name;
    final v = version;
    if (n == null) return;
    // OSV's `Pub` ecosystem IS pub.dev. A package from a private pub host is
    // one OSV has never seen, and answering "clean" for it would be a guess
    // wearing a result's clothes.
    if (source == 'hosted' && url == 'https://pub.dev' && v != null) {
      audited.add(_Pkg(n, v));
    } else {
      skipped.add('$n [${url ?? source ?? 'unknown source'}]');
    }
  }

  for (final line in const LineSplitter().convert(text)) {
    final start = blockStart.firstMatch(line);
    if (start != null) {
      close();
      name = start[1];
      source = null;
      version = null;
      url = null;
      continue;
    }
    if (name == null) continue;
    final f = field.firstMatch(line);
    if (f == null) continue;
    final key = f[1];
    final value = f[2];
    if (key == 'source') {
      source = value;
    } else if (key == 'version') {
      version = value;
    } else if (key == 'url') {
      url = value;
    }
  }
  close();

  return _Lock(audited, skipped);
}

/// One advisory-id list per package, index-aligned with [pkgs].
///
/// Throws on any transport or shape failure; the caller turns that into the
/// soft pass. Nothing in here may return a short or reordered list, because a
/// misaligned answer would pin one package's advisory on another and clear the
/// package that actually has it.
Future<List<List<String>>> _queryOsv(HttpClient client, List<_Pkg> pkgs) async {
  final out = <List<String>>[];

  for (var i = 0; i < pkgs.length; i += _batchSize) {
    final end = i + _batchSize > pkgs.length ? pkgs.length : i + _batchSize;
    final chunk = pkgs.sublist(i, end);

    final body = await _send(
      client,
      'POST',
      '/v1/querybatch',
      payload: <String, dynamic>{
        'queries': <Map<String, dynamic>>[
          for (final p in chunk)
            <String, dynamic>{
              'package': <String, String>{'name': p.name, 'ecosystem': 'Pub'},
              'version': p.version,
            },
        ],
      },
    );

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const _OsvShapeException('querybatch did not answer an object');
    }
    final results = decoded['results'];
    if (results is! List<dynamic>) {
      throw const _OsvShapeException('querybatch answered no "results" array');
    }
    if (results.length != chunk.length) {
      throw _OsvShapeException(
        'sent ${chunk.length} queries, got ${results.length} results — the '
        'answers cannot be matched to the packages that asked for them',
      );
    }

    for (var j = 0; j < results.length; j++) {
      final entry = results[j];
      if (entry is! Map<String, dynamic>) {
        throw _OsvShapeException('result $j is not an object');
      }
      // A clean package comes back as `{}` — an EMPTY OBJECT, not an empty
      // `vulns` array. Verified against the live API on 2026-08-18, because
      // reading `vulns.length` on the clean shape is a null dereference that
      // would surface as an outage and soft-pass the entire audit.
      final vulns = entry['vulns'];
      if (vulns == null) {
        out.add(const <String>[]);
        continue;
      }
      if (vulns is! List<dynamic>) {
        throw _OsvShapeException('result $j has a non-array "vulns"');
      }
      final ids = <String>[];
      for (final v in vulns) {
        if (v is! Map<String, dynamic>) {
          throw _OsvShapeException('result $j holds a non-object vuln');
        }
        final id = v['id'];
        if (id is String) ids.add(id);
      }
      // Only reachable if one package ever accumulates more advisories than a
      // page holds. Surfaced rather than swallowed: a truncated list would
      // under-report, and under-reporting is this tool's worst failure mode.
      if (entry['next_page_token'] != null) {
        ids.add(_truncationMarker);
      }
      out.add(ids);
    }
  }

  return out;
}

/// Summary and severity for one advisory id.
///
/// Degrades instead of failing: a detail lookup that breaks must not lose the
/// finding that `querybatch` has already proved exists.
Future<_Advisory> _detail(HttpClient client, String id) async {
  try {
    final decoded = jsonDecode(await _send(client, 'GET', '/v1/vulns/$id'));
    if (decoded is! Map<String, dynamic>) return _Advisory(id);

    final summary = decoded['summary'];
    final aliases = decoded['aliases'];

    // GitHub-sourced entries carry a word here ('HIGH', 'MODERATE'); anything
    // else falls back to the CVSS vector, which is at least comparable.
    String? severity;
    final dbSpecific = decoded['database_specific'];
    if (dbSpecific is Map<String, dynamic>) {
      final named = dbSpecific['severity'];
      if (named is String) severity = named;
    }
    if (severity == null) {
      final scores = decoded['severity'];
      if (scores is List<dynamic> && scores.isNotEmpty) {
        final first = scores.first;
        if (first is Map<String, dynamic>) {
          final score = first['score'];
          if (score is String) severity = score;
        }
      }
    }

    return _Advisory(
      id,
      summary: summary is String ? summary : null,
      severity: severity,
      aliases: aliases is List<dynamic>
          ? <String>[
              for (final a in aliases)
                if (a is String) a,
            ]
          : null,
    );
  } catch (e) {
    stderr.writeln(
      'dep_audit: no details for $id (${e.runtimeType}: $e) — the advisory '
      'itself still stands.',
    );
    return _Advisory(id);
  }
}

Future<String> _send(
  HttpClient client,
  String method,
  String path, {
  Object? payload,
}) async {
  final uri = Uri.https(_osvHost, path);
  final req =
      method == 'POST' ? await client.postUrl(uri) : await client.getUrl(uri);
  if (payload != null) {
    req
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(payload));
  }
  final res = await req.close().timeout(_netTimeout);
  final text = await res.transform(utf8.decoder).join().timeout(_netTimeout);
  if (res.statusCode != 200) {
    final head = text.length > 200 ? text.substring(0, 200) : text;
    throw HttpException('HTTP ${res.statusCode} from $path: $head');
  }
  return text;
}
