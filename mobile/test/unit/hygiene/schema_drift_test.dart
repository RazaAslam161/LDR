import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every column name the client writes or filters on, checked against the
/// database's actual shape.
///
/// This test exists because the same fault has shipped five times:
///
///   vault_items.storage_path / media_mime_type   — PGRST204 on every upload
///   memory_threads' four delete columns          — delete threw
///   rituals' six                                 — the LIST QUERY threw
///   afterglow_entries' six                       — the write threw AND the
///                                                  read failed silently, so
///                                                  `if (row['deleted'] == true)`
///                                                  never filtered anything
///
/// All four compiled perfectly. All four passed `flutter test`. They can only
/// fail against a real database, which is exactly the thing CI does not have —
/// so the database's shape is checked in at supabase/schema_snapshot.json and
/// diffed here instead.
///
/// The second half matters as much as the first. `authenticated` holds no
/// table-level UPDATE on memory_threads any more, only a grant on eight
/// columns, so writing `state` is a 403 rather than a missing column. To this
/// test they are the same defect and get the same failure.
void main() {
  final snapshotFile = File('../supabase/schema_snapshot.json');

  late Map<String, Set<String>> tables;
  late Set<String> functions;
  late Map<String, Set<String>> updatableColumns;

  setUpAll(() {
    expect(snapshotFile.existsSync(), isTrue,
        reason: 'supabase/schema_snapshot.json is the reference; without it '
            'this test is blind rather than passing',);
    final json = jsonDecode(snapshotFile.readAsStringSync()) as Map<String, dynamic>;
    tables = (json['tables'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, (v as List).cast<String>().toSet()),);
    functions = (json['functions'] as List).cast<String>().toSet();
    updatableColumns = (json['authenticated_update_columns'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as List).cast<String>().toSet()));
  });

  List<File> dartSources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('every column the client writes exists in the database', () {
    final drift = <String>[];
    for (final file in dartSources()) {
      final src = _Source(file.readAsStringSync());
      for (final use in src.tableUses()) {
        final known = tables[use.table];
        if (known == null) {
          drift.add('${file.path}:${src.lineAt(use.offset)}  '
              'no such table: ${use.table}');
          continue;
        }
        for (final column in {...use.writes, ...use.reads}) {
          if (!known.contains(column)) {
            drift.add('${file.path}:${src.lineAt(use.offset)}  '
                '${use.table}.$column (${use.verb}) does not exist');
          }
        }
      }
    }
    expect(drift, isEmpty,
        reason: 'client code writes columns the database does not have. This '
            'compiles and only fails on a real request:\n  ${drift.join('\n  ')}',);
  });

  test('no update writes a column authenticated is not granted', () {
    final denied = <String>[];
    for (final file in dartSources()) {
      final src = _Source(file.readAsStringSync());
      for (final use in src.tableUses()) {
        if (use.verb != 'update') continue;
        final granted = updatableColumns[use.table];
        if (granted == null) continue; // table-level UPDATE still held
        // Only the map's keys are written. A column in .eq() is a filter and
        // needs SELECT, which is a different grant entirely.
        for (final column in use.writes) {
          if (!granted.contains(column)) {
            denied.add('${file.path}:${src.lineAt(use.offset)}  '
                '${use.table}.$column is not in the column grant — this is a '
                '403, and for lifecycle columns it is deliberate: go through '
                'the RPC',);
          }
        }
      }
    }
    expect(denied, isEmpty, reason: denied.join('\n  '));
  });

  test('every rpc the client calls exists', () {
    final missing = <String>[];
    var seen = 0;
    for (final file in dartSources()) {
      final src = _Source(file.readAsStringSync());
      for (final call in src.rpcCalls()) {
        seen++;
        if (!functions.contains(call.name)) {
          missing.add('${file.path}:${src.lineAt(call.offset)}  '
              'rpc(${call.name}) does not exist');
        }
      }
    }
    // Without this the check passes by matching nothing, which is exactly how
    // it passed while looking for a bare `.rpc(` this codebase never writes.
    expect(seen, greaterThan(10), reason: 'found almost no rpc calls to check');
    expect(missing, isEmpty,
        reason: 'PGRST202 at runtime:\n  ${missing.join('\n  ')}',);
  });

  test('the snapshot is not empty', () {
    // A truncated or unparsed snapshot would let every check above pass by
    // knowing nothing — the same way a bad `git ls-files` would in
    // repo_hygiene_test.
    expect(tables.length, greaterThan(30));
    expect(tables['memory_threads'], contains('cover_path'));
    expect(functions, contains('memory_confirm_delete'));
  });
}

/// One `.from('table')` and the columns the statement it belongs to touches.
///
/// [writes] are the keys of an insert/update/upsert map — the only ones a
/// column grant applies to. [reads] are selected or filtered on, which needs
/// SELECT rather than UPDATE. Both have to exist; only [writes] have to be
/// granted.
class _TableUse {
  _TableUse(this.table, this.verb, this.writes, this.reads, this.offset);
  final String table;
  final String verb;
  final Set<String> writes;
  final Set<String> reads;
  final int offset;
}

class _RpcCall {
  _RpcCall(this.name, this.offset);
  final String name;
  final int offset;
}

/// Dart source with strings and comments masked out, so brace-walking and
/// `;`-hunting cannot be derailed by punctuation inside a literal.
///
/// [masked] is the same length as the original, with comment bodies and string
/// CONTENTS replaced by spaces. [_literals] maps the offset of an opening quote
/// to the literal's value, which is how a masked source still yields the table
/// and column names.
class _Source {
  _Source(this.text) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';

      if (c == '/' && next == '/') {
        while (i < text.length && text[i] != '\n') {
          buffer.write(' ');
          i++;
        }
        continue;
      }
      if (c == '/' && next == '*') {
        final end = text.indexOf('*/', i + 2);
        final stop = end < 0 ? text.length : end + 2;
        for (var k = i; k < stop; k++) {
          buffer.write(text[k] == '\n' ? '\n' : ' ');
        }
        i = stop;
        continue;
      }
      if (c == "'" || c == '"') {
        final start = i;
        final value = StringBuffer();
        i++;
        buffer.write(c);
        while (i < text.length && text[i] != c) {
          if (text[i] == r'\' && i + 1 < text.length) {
            value.write(text[i + 1]);
            buffer.write('  ');
            i += 2;
            continue;
          }
          value.write(text[i]);
          buffer.write(text[i] == '\n' ? '\n' : ' ');
          i++;
        }
        if (i < text.length) {
          buffer.write(c);
          i++;
        }
        _literals[start] = value.toString();
        _literalEnds[start] = i;
        continue;
      }
      buffer.write(c);
      i++;
    }
    masked = buffer.toString();
  }

  final String text;
  late final String masked;
  final Map<int, String> _literals = {};
  final Map<int, int> _literalEnds = {};

  int lineAt(int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;

  /// The literal that starts at the first non-space character after [from],
  /// or null if what follows is an expression rather than a string.
  String? _literalAfter(int from) {
    var i = from;
    while (i < masked.length && masked[i].trim().isEmpty) {
      i++;
    }
    return _literals[i];
  }

  static const _filters = [
    '.eq(', '.neq(', '.order(', '.lt(', '.lte(', '.gt(', '.gte(',
    '.like(', '.ilike(', '.contains(', '.in_(', '.isFilter(', '.filter(',
  ];

  /// Every call site in this app is `.rpc<dynamic>(` or `.rpc<void>(` — none is
  /// a bare `.rpc(`, so matching the bare form found nothing and the check
  /// passed by knowing nothing.
  static final _rpcPattern = RegExp(r'\.rpc\s*(<[^>]*>)?\s*\(');

  Iterable<_RpcCall> rpcCalls() sync* {
    for (final m in _rpcPattern.allMatches(masked)) {
      final name = _literalAfter(m.end);
      if (name != null) yield _RpcCall(name, m.start);
    }
  }

  Iterable<_TableUse> tableUses() sync* {
    var i = masked.indexOf('.from(');
    while (i >= 0) {
      final table = _literalAfter(i + 6);
      if (table != null) {
        final end = _statementEnd(i);
        // A write's map is the authoritative list; a bare select/filter chain
        // still names columns worth checking.
        var verb = 'read';
        final writes = <String>{};
        final reads = <String>{};
        for (final write in const ['.insert(', '.update(', '.upsert(']) {
          final at = masked.indexOf(write, i);
          if (at < 0 || at > end) continue;
          verb = write.substring(1, write.length - 1);
          writes.addAll(_mapKeys(at + write.length, end));
        }
        final selectAt = masked.indexOf('.select(', i);
        if (selectAt >= 0 && selectAt < end) {
          final list = _literalAfter(selectAt + 8);
          if (list != null) {
            for (final part in list.split(',')) {
              final name = part.trim();
              // Skip embeds (`memory_photos(id)`) and modifiers.
              if (name.isEmpty || name.contains('(') || name == '*') continue;
              reads.add(name);
            }
          }
        }
        for (final filter in _filters) {
          var at = masked.indexOf(filter, i);
          while (at >= 0 && at < end) {
            final column = _literalAfter(at + filter.length);
            if (column != null && !column.contains('.')) reads.add(column);
            at = masked.indexOf(filter, at + 1);
          }
        }
        if (writes.isNotEmpty || reads.isNotEmpty) {
          yield _TableUse(table, verb, writes, reads, i);
        }
      }
      i = masked.indexOf('.from(', i + 1);
    }
  }

  /// End of the statement beginning at [start] — the first `;` outside any
  /// bracket. Chained builders put the whole query in one statement, and a
  /// trailing `.map((rows) { ... })` closure is bracketed, so its inner `;`
  /// does not truncate the scan.
  int _statementEnd(int start) {
    var depth = 0;
    for (var i = start; i < masked.length; i++) {
      switch (masked[i]) {
        case '(':
        case '[':
        case '{':
          depth++;
        case ')':
        case ']':
        case '}':
          depth--;
        case ';':
          if (depth <= 0) return i;
      }
    }
    return masked.length;
  }

  /// The `'key':` literals at the top level of the map literal that begins
  /// after [from]. Nested maps are a value, not a column list, so only depth 1
  /// counts.
  Set<String> _mapKeys(int from, int limit) {
    final open = masked.indexOf('{', from);
    if (open < 0 || open > limit) return {};
    final keys = <String>{};
    var depth = 0;
    for (var i = open; i < masked.length; i++) {
      final c = masked[i];
      if (c == '{' || c == '[' || c == '(') {
        depth++;
        continue;
      }
      if (c == '}' || c == ']' || c == ')') {
        depth--;
        if (depth == 0) break;
        continue;
      }
      if (depth != 1) continue;
      final literal = _literals[i];
      if (literal == null) continue;
      // A key is followed by `:` — but so is the true branch of a ternary, and
      // `'retention': x == ephemeral ? 'ephemeral' : 'keep'` would otherwise
      // report a column named `ephemeral`. What separates them is what comes
      // BEFORE: an entry starts after `{`, `,` or a collection-if's `)`, while
      // a ternary branch follows `?` or `:`.
      var j = _literalEnds[i]!;
      while (j < masked.length && masked[j].trim().isEmpty) {
        j++;
      }
      if (j >= masked.length || masked[j] != ':') continue;
      var k = i - 1;
      while (k >= 0 && masked[k].trim().isEmpty) {
        k--;
      }
      if (k >= 0 && (masked[k] == '?' || masked[k] == ':')) continue;
      keys.add(literal);
    }
    return keys;
  }
}
