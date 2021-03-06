// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'element_test.dart' as element;
import 'function_type_test.dart' as function_type;
import 'inheritance_manager2_test.dart' as inheritance_manager2;
import 'type_algebra_test.dart' as type_algebra;

/// Utility for manually running all tests.
main() {
  defineReflectiveSuite(() {
    element.main();
    function_type.main();
    inheritance_manager2.main();
    type_algebra.main();
  }, name: 'element');
}
