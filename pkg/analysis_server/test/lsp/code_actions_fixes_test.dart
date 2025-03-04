// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol_generated.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;
import 'package:linter/src/rules.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'code_actions_abstract.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(FixesCodeActionsTest);
  });
}

@reflectiveTest
class FixesCodeActionsTest extends AbstractCodeActionsTest {
  Future<void> test_appliesCorrectEdits_withDocumentChangesSupport() async {
    // This code should get a fix to remove the unused import.
    const content = '''
    import 'dart:async';
    [[import]] 'dart:convert';

    Future foo;
    ''';

    const expectedContent = '''
    import 'dart:async';

    Future foo;
    ''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
      workspaceCapabilities:
          withDocumentChangesSupport(emptyWorkspaceClientCapabilities),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions,
        CodeActionKind('quickfix.remove.unusedImport'),
        'Remove unused import')!;

    // Ensure the edit came back, and using documentChanges.
    final edit = fixAction.edit!;
    expect(edit.documentChanges, isNotNull);
    expect(edit.changes, isNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyDocumentChanges(contents, edit.documentChanges!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_appliesCorrectEdits_withoutDocumentChangesSupport() async {
    // This code should get a fix to remove the unused import.
    const content = '''
    import 'dart:async';
    [[import]] 'dart:convert';

    Future foo;
    ''';

    const expectedContent = '''
    import 'dart:async';

    Future foo;
    ''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions,
        CodeActionKind('quickfix.remove.unusedImport'),
        'Remove unused import')!;

    // Ensure the edit came back, and using changes.
    final edit = fixAction.edit!;
    expect(edit.changes, isNotNull);
    expect(edit.documentChanges, isNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, edit.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_createFile() async {
    const content = '''
    import '[[newfile.dart]]';
    ''';

    final expectedCreatedFile =
        path.join(path.dirname(mainFilePath), 'newfile.dart');

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
      workspaceCapabilities: withResourceOperationKinds(
          emptyWorkspaceClientCapabilities, [ResourceOperationKind.Create]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(codeActions,
        CodeActionKind('quickfix.create.file'), "Create file 'newfile.dart'")!;

    final edit = fixAction.edit!;
    expect(edit.documentChanges, isNotNull);

    // Ensure applying the changes creates the file and with the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyDocumentChanges(contents, edit.documentChanges!);
    expect(contents[expectedCreatedFile], isNotEmpty);
  }

  Future<void> test_filtersCorrectly() async {
    const content = '''
    import 'dart:async';
    [[import]] 'dart:convert';

    Future foo;
    ''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize();

    ofKind(CodeActionKind kind) => getCodeActions(
          mainFileUri.toString(),
          range: rangeFromMarkers(content),
          kinds: [kind],
        );

    // The code above will return a quickfix.remove.unusedImport
    expect(await ofKind(CodeActionKind.QuickFix), isNotEmpty);
    expect(await ofKind(CodeActionKind('quickfix.remove')), isNotEmpty);
    expect(await ofKind(CodeActionKind('quickfix.other')), isEmpty);
    expect(await ofKind(CodeActionKind.Refactor), isEmpty);
  }

  Future<void> test_fixAll_notWhenNoBatchFix() async {
    // Some fixes (for example 'create function foo') are not available in the
    // batch processor, so should not generate fix-all-in-file fixes even if there
    // are multiple instances.
    const content = '''
var a = [[foo]]();
var b = bar();
    ''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final allFixes = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));

    // Expect only the single-fix, there should be no apply-all.
    expect(allFixes, hasLength(1));
    final fixTitle = allFixes.first.map((f) => f.title, (f) => f.title);
    expect(fixTitle, equals("Create function 'foo'"));
  }

  Future<void> test_fixAll_notWhenSingle() async {
    const content = '''
void f(String a) {
  [[print(a!)]];
}
    ''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions, CodeActionKind('quickfix'), "Remove '!'s in file");

    // Should not appear if there was only a single error.
    expect(fixAction, isNull);
  }

  Future<void> test_fixAll_whenMultiple() async {
    const content = '''
void f(String a) {
  [[print(a!!)]];
  print(a!!);
}
    ''';

    const expectedContent = '''
void f(String a) {
  print(a);
  print(a);
}
    ''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions, CodeActionKind('quickfix'), "Remove '!'s in file")!;

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, fixAction.edit!.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_ignoreDiagnosticForFile() async {
    const content = '''
// Header comment
// Header comment
// Header comment

// This comment is attached to the below import
import 'dart:async';
[[import]] 'dart:convert';

Future foo;''';

    const expectedContent = '''
// Header comment
// Header comment
// Header comment

// ignore_for_file: unused_import

// This comment is attached to the below import
import 'dart:async';
import 'dart:convert';

Future foo;''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    // Find the ignore action.
    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions,
        CodeActionKind('quickfix.ignore.file'),
        "Ignore 'unused_import' for this file")!;

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, fixAction.edit!.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_ignoreDiagnosticForLine() async {
    const content = '''
import 'dart:async';
[[import]] 'dart:convert';

Future foo;''';

    const expectedContent = '''
import 'dart:async';
// ignore: unused_import
import 'dart:convert';

Future foo;''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    // Find the ignore action.
    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(
        codeActions,
        CodeActionKind('quickfix.ignore.line'),
        "Ignore 'unused_import' for this line")!;

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, fixAction.edit!.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_noDuplicates_differentFix() async {
    // For convenience, quick-fixes are usually returned for the entire line,
    // though this can lead to duplicate entries (by title) when multiple
    // diagnostics have their own fixes of the same type.
    //
    // Expect only the only one nearest to the start of the range to be returned.
    const content = '''
    main() {
      var a = [];
      print(a!!);^
    }
    ''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        position: positionFromMarker(content));
    final removeNnaAction = findEditActions(codeActions,
        CodeActionKind('quickfix.remove.nonNullAssertion'), "Remove the '!'");

    // Expect only one of the fixes.
    expect(removeNnaAction, hasLength(1));

    // Ensure the action is for the diagnostic on the second bang which was
    // closest to the range requested.
    final secondBangPos =
        positionFromOffset(withoutMarkers(content).indexOf('!);'), content);
    expect(removeNnaAction.first.diagnostics, hasLength(1));
    final diagStart = removeNnaAction.first.diagnostics!.first.range.start;
    expect(diagStart, equals(secondBangPos));
  }

  Future<void> test_noDuplicates_sameFix() async {
    const content = '''
    var a = [Test, Test, Te[[]]st];
    ''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final createClassActions = findEditActions(codeActions,
        CodeActionKind('quickfix.create.class'), "Create class 'Test'");

    expect(createClassActions, hasLength(1));
    expect(createClassActions.first.diagnostics, hasLength(3));
  }

  Future<void> test_noDuplicates_withDocumentChangesSupport() async {
    const content = '''
    var a = [Test, Test, Te[[]]st];
    ''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
        textDocumentCapabilities: withCodeActionKinds(
            emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
        workspaceCapabilities: withApplyEditSupport(
            withDocumentChangesSupport(emptyWorkspaceClientCapabilities)));

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final createClassActions = findEditActions(codeActions,
        CodeActionKind('quickfix.create.class'), "Create class 'Test'");

    expect(createClassActions, hasLength(1));
    expect(createClassActions.first.diagnostics, hasLength(3));
  }

  Future<void> test_nonDartFile() async {
    newFile2(pubspecFilePath, simplePubspecContent);
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions =
        await getCodeActions(pubspecFileUri.toString(), range: startOfDocRange);
    expect(codeActions, isEmpty);
  }

  Future<void> test_organizeImportsFix_namedOrganizeImports() async {
    registerLintRules();
    newFile2(analysisOptionsPath, '''
linter:
  rules:
    - directives_ordering
    ''');

    // This code should get a fix to sort the imports.
    const content = '''
import 'dart:io';
[[import 'dart:async']];

Completer a;
ProcessInfo b;
    ''';

    const expectedContent = '''
import 'dart:async';
import 'dart:io';

Completer a;
ProcessInfo b;
    ''';
    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final fixAction = findEditAction(codeActions,
        CodeActionKind('quickfix.organize.imports'), 'Organize Imports')!;

    // Ensure the edit came back, and using changes.
    final edit = fixAction.edit!;
    expect(edit.changes, isNotNull);
    expect(edit.documentChanges, isNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, edit.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_outsideRoot() async {
    final otherFilePath = convertPath('/home/otherProject/foo.dart');
    final otherFileUri = Uri.file(otherFilePath);
    newFile2(otherFilePath, 'bad code to create error');
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(otherFileUri.toString());
    expect(codeActions, isEmpty);
  }

  Future<void> test_plugin() async {
    // This code should get a fix to replace 'foo' with 'bar'.'
    const content = '[[foo]]';
    const expectedContent = 'bar';

    final pluginResult = plugin.EditGetFixesResult([
      plugin.AnalysisErrorFixes(
        plugin.AnalysisError(
          plugin.AnalysisErrorSeverity.ERROR,
          plugin.AnalysisErrorType.HINT,
          plugin.Location(mainFilePath, 0, 3, 0, 0),
          "Do not use 'foo'",
          'do_not_use_foo',
        ),
        fixes: [
          plugin.PrioritizedSourceChange(
            0,
            plugin.SourceChange(
              "Change 'foo' to 'bar'",
              edits: [
                plugin.SourceFileEdit(mainFilePath, 0,
                    edits: [plugin.SourceEdit(0, 3, 'bar')])
              ],
              id: 'fooToBar',
            ),
          )
        ],
      )
    ]);
    configureTestPlugin(
      handler: (request) =>
          request is plugin.EditGetFixesParams ? pluginResult : null,
    );

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final assist = findEditAction(codeActions,
        CodeActionKind('quickfix.fooToBar'), "Change 'foo' to 'bar'")!;

    final edit = assist.edit!;
    expect(edit.changes, isNotNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyChanges(contents, edit.changes!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void> test_plugin_sortsWithServer() async {
    // Produces a server fix for removing unused import with a default
    // priority of 50.
    const content = '''
[[import]] 'dart:convert';
''';

    // Provide two plugin results that should sort either side of the server fix.
    final pluginResult = plugin.EditGetFixesResult([
      plugin.AnalysisErrorFixes(
        plugin.AnalysisError(
          plugin.AnalysisErrorSeverity.ERROR,
          plugin.AnalysisErrorType.HINT,
          plugin.Location(mainFilePath, 0, 3, 0, 0),
          'Dummy error',
          'dummy',
        ),
        fixes: [
          plugin.PrioritizedSourceChange(10, plugin.SourceChange('Low')),
          plugin.PrioritizedSourceChange(100, plugin.SourceChange('High')),
        ],
      )
    ]);
    configureTestPlugin(
      handler: (request) =>
          request is plugin.EditGetFixesParams ? pluginResult : null,
    );

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        range: rangeFromMarkers(content));
    final codeActionTitles = codeActions.map((action) =>
        action.map((command) => command.title, (action) => action.title));

    expect(
      codeActionTitles,
      containsAllInOrder([
        'High',
        'Remove unused import',
        'Low',
      ]),
    );
  }

  Future<void> test_snippets_createMethod_functionTypeNestedParameters() async {
    const content = '''
class A {
  void a() => c^((cell) => cell.south);
  void b() => c((cell) => cell.west);
}
''';

    const expectedContent = r'''
class A {
  void a() => c((cell) => cell.south);
  void b() => c((cell) => cell.west);

  ${1:c}(${2:Function(dynamic cell)} ${3:param0}) {}
}
''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
      workspaceCapabilities:
          withDocumentChangesSupport(emptyWorkspaceClientCapabilities),
      experimentalCapabilities: {
        'snippetTextEdit': true,
      },
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        position: positionFromMarker(content));
    final fixAction = findEditAction(codeActions,
        CodeActionKind('quickfix.create.method'), "Create method 'c'")!;

    // Ensure the edit came back, and using documentChanges.
    final edit = fixAction.edit!;
    expect(edit.documentChanges, isNotNull);
    expect(edit.changes, isNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyDocumentChanges(contents, edit.documentChanges!);
    expect(contents[mainFilePath], equals(expectedContent));
  }

  Future<void>
      test_snippets_extractVariable_functionTypeNestedParameters() async {
    const content = '''
main() {
  useFunction(te^st);
}

useFunction(int g(a, b)) {}
''';

    const expectedContent = r'''
main() {
  ${1:int Function(dynamic a, dynamic b)} ${2:test};
  useFunction(test);
}

useFunction(int g(a, b)) {}
''';

    newFile2(mainFilePath, withoutMarkers(content));
    await initialize(
      textDocumentCapabilities: withCodeActionKinds(
          emptyTextDocumentClientCapabilities, [CodeActionKind.QuickFix]),
      workspaceCapabilities:
          withDocumentChangesSupport(emptyWorkspaceClientCapabilities),
      experimentalCapabilities: {
        'snippetTextEdit': true,
      },
    );

    final codeActions = await getCodeActions(mainFileUri.toString(),
        position: positionFromMarker(content));
    final fixAction = findEditAction(
        codeActions,
        CodeActionKind('quickfix.create.localVariable'),
        "Create local variable 'test'")!;

    // Ensure the edit came back, and using documentChanges.
    final edit = fixAction.edit!;
    expect(edit.documentChanges, isNotNull);
    expect(edit.changes, isNull);

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };
    applyDocumentChanges(contents, edit.documentChanges!);
    expect(contents[mainFilePath], equals(expectedContent));
  }
}
