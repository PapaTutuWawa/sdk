// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/cider/rename.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/micro/resolve_file.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../utilities/mock_packages.dart';
import 'cider_service.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CiderRenameComputerTest);
  });
}

@reflectiveTest
class CiderRenameComputerTest extends CiderServiceTest {
  late _CorrectionContext _correctionContext;

  @override
  void setUp() {
    super.setUp();
    BazelMockPackages.instance.addFlutter(resourceProvider);
  }

  void test_canRename_class() async {
    var refactor = await _compute(r'''
class ^Old {}
}
''');

    expect(refactor!.refactoringElement.element.name, 'Old');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_field() async {
    var refactor = await _compute(r'''
class A {
 int ^bar;
 void foo() {
   bar = 5;
 }
}
''');

    expect(refactor!.refactoringElement.element.name, 'bar');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_field_static_private() async {
    var refactor = await _compute(r'''
class A{
  static const ^_val = 1234;
}
''');

    expect(refactor, isNotNull);
    expect(refactor!.refactoringElement.element.name, '_val');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_function() async {
    var refactor = await _compute(r'''
void ^foo() {
}
''');

    expect(refactor!.refactoringElement.element.name, 'foo');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_label() async {
    var refactor = await _compute(r'''
main() {
  myLabel:
  while (true) {
    continue ^myLabel;
    break myLabel;
  }
}
''');

    expect(refactor, isNotNull);
    expect(refactor!.refactoringElement.element.name, 'myLabel');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_local() async {
    var refactor = await _compute(r'''
void foo() {
  var ^a = 0; var b = a + 1;
}
''');

    expect(refactor!.refactoringElement.element.name, 'a');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_method() async {
    var refactor = await _compute(r'''
extension E on int {
  void ^foo() {}
}
''');

    expect(refactor!.refactoringElement.element.name, 'foo');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_canRename_operator() async {
    var refactor = await _compute(r'''
class A{
  A operator ^+(A other) => this;
}
''');

    expect(refactor, isNull);
  }

  void test_canRename_parameter() async {
    var refactor = await _compute(r'''
void foo(int ^bar) {
  var a = bar + 1;
}
''');

    expect(refactor, isNotNull);
    expect(refactor!.refactoringElement.element.name, 'bar');
    expect(refactor.refactoringElement.offset, _correctionContext.offset);
  }

  void test_checkName_class() async {
    var result = await _checkName(r'''
class ^Old {}
''', 'New');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'Old');
  }

  void test_checkName_function() async {
    var result = await _checkName(r'''
int ^foo() => 2;
''', 'bar');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'foo');
  }

  void test_checkName_local() async {
    var result = await _checkName(r'''
void foo() {
  var ^a = 0; var b = a + 1;
}
''', 'bar');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'a');
  }

  void test_checkName_local_invalid() async {
    var result = await _checkName(r'''
void foo() {
  var ^a = 0; var b = a + 1;
}
''', 'Aa');

    expect(result!.status.problems.length, 1);
    expect(result.oldName, 'a');
  }

  void test_checkName_parameter() async {
    var result = await _checkName(r'''
void foo(String ^a) {
  var b = a + 1;
}
''', 'bar');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'a');
  }

  void test_checkName_topLevelVariable() async {
    var result = await _checkName(r'''
var ^foo;
''', 'bar');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'foo');
  }

  void test_checkName_TypeAlias() async {
    var result = await _checkName(r'''
typedef ^Foo = void Function();
''', 'Bar');

    expect(result!.status.problems.length, 0);
    expect(result.oldName, 'Foo');
  }

  void test_rename_class() async {
    var result = await _rename(r'''
class ^Old implements Other {
  Old() {}
  Old.named() {}
}
class Other {
  factory Other.a() = Old;
  factory Other.b() = Old.named;
}
void f() {
  Old t1 = new Old();
  Old t2 = new Old.named();
}
''', 'New');

    expect(result!.matches.length, 1);
    expect(result.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'), [
        CharacterLocation(1, 7),
        CharacterLocation(2, 3),
        CharacterLocation(3, 3),
        CharacterLocation(6, 23),
        CharacterLocation(7, 23),
        CharacterLocation(10, 3),
        CharacterLocation(10, 16),
        CharacterLocation(11, 3),
        CharacterLocation(11, 16)
      ])
    ]);
  }

  void test_rename_class_flutterWidget() async {
    var result = await _rename(r'''
import 'package:flutter/material.dart';

class ^TestPage extends StatefulWidget {
  const TestPage();

  @override
  State<TestPage> createState() => TestPageState();
}

class TestPageState extends State<TestPage> {
  @override
  Widget build(BuildContext context) => throw 0;
}
''', 'NewPage');

    expect(result!.matches.length, 1);
    expect(result.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'), [
        CharacterLocation(3, 7),
        CharacterLocation(4, 9),
        CharacterLocation(7, 9),
        CharacterLocation(10, 35)
      ])
    ]);
    expect(result.flutterWidgetRename != null, isTrue);
    expect(result.flutterWidgetRename!.name, 'NewPageState');
    expect(result.flutterWidgetRename!.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(7, 36), CharacterLocation(10, 7)])
    ]);
  }

  void test_rename_field() async {
    var result = await _rename(r'''
class A{
  int get ^x => 5;
}

void foo() {
  var m = A().x;
}
''', 'y');

    expect(result, isNotNull);
    expect(result!.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(2, 11), CharacterLocation(6, 15)]),
    ]);
  }

  void test_rename_field_static_private() async {
    var result = await _rename(r'''
class A{
  static const ^_val = 1234;
}

void foo() {
  print(A._val);
}
''', '_newVal');

    expect(result, isNotNull);
    expect(result!.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(2, 16), CharacterLocation(6, 11)]),
    ]);
  }

  void test_rename_function() async {
    var result = await _rename(r'''
test() {}
^foo() {}
void f() {
  print(test);
  print(test());
  foo();
}
''', 'bar');

    expect(result!.matches.length, 1);
    expect(result.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'), [
        CharacterLocation(2, 1),
        CharacterLocation(6, 3),
      ])
    ]);
  }

  void test_rename_function_imported() async {
    var a = newFile2('/workspace/dart/test/lib/a.dart', r'''
foo() {}
''');
    await fileResolver.resolve2(path: a.path);
    var result = await _rename(r'''
import 'a.dart';
void f() {
  ^foo();
}
''', 'bar');
    expect(result!.matches.length, 2);
    expect(result.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/a.dart'), [
        CharacterLocation(1, 1),
      ]),
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(3, 3)])
    ]);
  }

  void test_rename_local() async {
    var result = await _rename(r'''
void foo() {
  var ^a = 0; var b = a + 1;
}
''', 'bar');

    expect(result!.matches.length, 1);
    expect(
        result.matches[0],
        CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
            [CharacterLocation(2, 7), CharacterLocation(2, 22)]));
  }

  void test_rename_method_imported() async {
    var a = newFile2('/workspace/dart/test/lib/a.dart', r'''
class A {
  foo() {}
}
''');
    await fileResolver.resolve2(path: a.path);
    var result = await _rename(r'''
import 'a.dart';
void f() {
  var a = A().^foo();
}
''', 'bar');
    expect(result!.matches.length, 2);
    expect(result.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/a.dart'), [
        CharacterLocation(2, 3),
      ]),
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(3, 15)])
    ]);
  }

  void test_rename_parameter() async {
    var result = await _rename(r'''
void foo(String ^a) {
  var b = a + 1;
}
''', 'bar');
    expect(result!.matches.length, 1);
    expect(result.checkName.oldName, 'a');
  }

  void test_rename_propertyAccessor() async {
    var result = await _rename(r'''
get foo {}
set foo(x) {}
void f() {
  print(foo);
  ^foo = 1;
  foo += 2;
''', 'bar');
    expect(result!.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(1, 5), CharacterLocation(4, 9)]),
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'), [
        CharacterLocation(2, 5),
        CharacterLocation(5, 3),
        CharacterLocation(6, 3)
      ])
    ]);
  }

  void test_rename_typeAlias_functionType() async {
    var result = await _rename(r'''
typedef ^F = void Function();
void f(F a) {}
''', 'bar');

    expect(result!.matches, [
      CiderSearchMatch(convertPath('/workspace/dart/test/lib/test.dart'),
          [CharacterLocation(1, 9), CharacterLocation(2, 8)])
    ]);
  }

  Future<CheckNameResponse?> _checkName(String content, String newName) async {
    _updateFile(content);

    var canRename = await CiderRenameComputer(
      fileResolver,
    ).canRename2(
      convertPath(testPath),
      _correctionContext.line,
      _correctionContext.character,
    );
    return canRename?.checkNewName(newName);
  }

  Future<CanRenameResponse?> _compute(String content) async {
    _updateFile(content);

    return CiderRenameComputer(
      fileResolver,
    ).canRename2(
      convertPath(testPath),
      _correctionContext.line,
      _correctionContext.character,
    );
  }

  Future<RenameResponse?> _rename(String content, String newName) async {
    _updateFile(content);

    var canRename = await CiderRenameComputer(
      fileResolver,
    ).canRename2(
      convertPath(testPath),
      _correctionContext.line,
      _correctionContext.character,
    );
    return canRename?.checkNewName(newName)?.computeRenameRanges2();
  }

  void _updateFile(String content) {
    var offset = content.indexOf('^');
    expect(offset, isPositive, reason: 'Expected to find ^');
    expect(content.indexOf('^', offset + 1), -1, reason: 'Expected only one ^');

    var lineInfo = LineInfo.fromContent(content);
    var location = lineInfo.getLocation(offset);

    content = content.substring(0, offset) + content.substring(offset + 1);
    newFile2(testPath, content);

    _correctionContext = _CorrectionContext(
      content,
      offset,
      location.lineNumber - 1,
      location.columnNumber - 1,
    );
  }
}

class _CorrectionContext {
  final String content;
  final int offset;
  final int line;
  final int character;

  _CorrectionContext(this.content, this.offset, this.line, this.character);
}
