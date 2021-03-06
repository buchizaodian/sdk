// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NonConstantIfElementConditionFromDeferredLibraryTest);
  });
}

@reflectiveTest
class NonConstantIfElementConditionFromDeferredLibraryTest
    extends DriverResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..enabledExperiments = [
      EnableString.control_flow_collections,
      EnableString.spread_collections
    ];

  test_inList_deferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return const [if(a.c) 0];
}''', [
      CompileTimeErrorCode
          .NON_CONSTANT_IF_ELEMENT_CONDITION_FROM_DEFERRED_LIBRARY
    ]);
  }

  test_inList_nonConst() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return [if(a.c) 0];
}''');
  }

  test_inList_notDeferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' as a;
f() {
  return const [if(a.c) 0];
}''');
  }

  test_inMap_deferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return const {if(a.c) 0 : 0};
}''', [
      CompileTimeErrorCode
          .NON_CONSTANT_IF_ELEMENT_CONDITION_FROM_DEFERRED_LIBRARY
    ]);
  }

  test_inMap_notConst() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return {if(a.c) 0 : 0};
}''');
  }

  test_inMap_notDeferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' as a;
f() {
  return const {if(a.c) 0 : 0};
}''');
  }

  test_inSet_deferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return const {if(a.c) 0};
}''', [
      CompileTimeErrorCode
          .NON_CONSTANT_IF_ELEMENT_CONDITION_FROM_DEFERRED_LIBRARY
    ]);
  }

  test_inSet_notConst() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' deferred as a;
f() {
  return {if(a.c) 0};
}''');
  }

  test_inSet_notDeferred() async {
    newFile(convertPath('/test/lib/lib1.dart'), content: r'''
const bool c = true;''');
    await assertNoErrorsInCode(r'''
import 'lib1.dart' as a;
f() {
  return const {if(a.c) 0};
}''');
  }
}
