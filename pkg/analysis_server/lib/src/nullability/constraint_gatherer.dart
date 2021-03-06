// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/nullability/conditional_discard.dart';
import 'package:analysis_server/src/nullability/constraint_variable_gatherer.dart';
import 'package:analysis_server/src/nullability/decorated_type.dart';
import 'package:analysis_server/src/nullability/expression_checks.dart';
import 'package:analysis_server/src/nullability/nullability_node.dart';
import 'package:analysis_server/src/nullability/transitional_api.dart';
import 'package:analysis_server/src/nullability/unit_propagation.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:meta/meta.dart';

/// Visitor that gathers nullability migration constraints from code to be
/// migrated.
///
/// The return type of each `visit...` method is a [DecoratedType] indicating
/// the static type of the visited expression, along with the constraint
/// variables that will determine its nullability.  For `visit...` methods that
/// don't visit expressions, `null` will be returned.
class ConstraintGatherer extends GeneralizingAstVisitor<DecoratedType> {
  /// The repository of constraint variables and decorated types (from a
  /// previous pass over the source code).
  final VariableRepository _variables;

  final bool _permissive;

  final NullabilityMigrationAssumptions assumptions;

  /// Constraints gathered by the visitor are stored here.
  final Constraints _constraints;

  /// The file being analyzed.
  final Source _source;

  /// For convenience, a [DecoratedType] representing non-nullable `Object`.
  final DecoratedType _notNullType;

  /// For convenience, a [DecoratedType] representing non-nullable `bool`.
  final DecoratedType _nonNullableBoolType;

  /// For convenience, a [DecoratedType] representing non-nullable `Type`.
  final DecoratedType _nonNullableTypeType;

  /// For convenience, a [DecoratedType] representing `Null`.
  final DecoratedType _nullType;

  /// The [DecoratedType] of the innermost function or method being visited, or
  /// `null` if the visitor is not inside any function or method.
  ///
  /// This is needed to construct the appropriate nullability constraints for
  /// return statements.
  DecoratedType _currentFunctionType;

  /// Information about the most recently visited binary expression whose
  /// boolean value could possibly affect nullability analysis.
  _ConditionInfo _conditionInfo;

  /// The set of constraint variables that would have to be assigned the value
  /// of `true` for the code currently being visited to be reachable.
  ///
  /// Guard variables are attached to the left hand side of any generated
  /// constraints, so that constraints do not take effect if they come from
  /// code that can be proven unreachable by the migration tool.
  final _guards = <ConstraintVariable>[];

  /// Indicates whether the statement or expression being visited is within
  /// conditional control flow.  If `true`, this means that the enclosing
  /// function might complete normally without executing the current statement
  /// or expression.
  bool _inConditionalControlFlow = false;

  ConstraintGatherer(TypeProvider typeProvider, this._variables,
      this._constraints, this._source, this._permissive, this.assumptions)
      : _notNullType =
            DecoratedType(typeProvider.objectType, _variables.neverNullable),
        _nonNullableBoolType =
            DecoratedType(typeProvider.boolType, _variables.neverNullable),
        _nonNullableTypeType =
            DecoratedType(typeProvider.typeType, _variables.neverNullable),
        _nullType = DecoratedType(
            typeProvider.nullType, NullabilityNode(ConstraintVariable.always));

  /// Gets the decorated type of [element] from [_variables], performing any
  /// necessary substitutions.
  DecoratedType getOrComputeElementType(Element element,
      {DecoratedType targetType}) {
    Map<TypeParameterElement, DecoratedType> substitution;
    Element baseElement;
    if (element is Member) {
      assert(targetType != null);
      baseElement = element.baseElement;
      var targetTypeType = targetType.type;
      if (targetTypeType is InterfaceType &&
          baseElement is ClassMemberElement) {
        var enclosingClass = baseElement.enclosingElement;
        assert(targetTypeType.element == enclosingClass); // TODO(paulberry)
        substitution = <TypeParameterElement, DecoratedType>{};
        assert(enclosingClass.typeParameters.length ==
            targetTypeType.typeArguments.length); // TODO(paulberry)
        for (int i = 0; i < enclosingClass.typeParameters.length; i++) {
          substitution[enclosingClass.typeParameters[i]] =
              targetType.typeArguments[i];
        }
      }
    } else {
      baseElement = element;
    }
    var decoratedBaseType =
        _variables.decoratedElementType(baseElement, create: true);
    if (substitution != null) {
      DartType elementType;
      if (element is MethodElement) {
        elementType = element.type;
      } else {
        throw element.runtimeType; // TODO(paulberry)
      }
      return decoratedBaseType.substitute(
          _constraints, substitution, elementType);
    } else {
      return decoratedBaseType;
    }
  }

  @override
  DecoratedType visitAssertStatement(AssertStatement node) {
    _handleAssignment(_notNullType, node.condition);
    if (identical(_conditionInfo?.condition, node.condition)) {
      if (!_inConditionalControlFlow &&
          _conditionInfo.trueDemonstratesNonNullIntent != null) {
        _recordFact(_conditionInfo.trueDemonstratesNonNullIntent);
      }
    }
    node.message?.accept(this);
    return null;
  }

  @override
  DecoratedType visitBinaryExpression(BinaryExpression node) {
    switch (node.operator.type) {
      case TokenType.EQ_EQ:
      case TokenType.BANG_EQ:
        assert(node.leftOperand is! NullLiteral); // TODO(paulberry)
        var leftType = node.leftOperand.accept(this);
        node.rightOperand.accept(this);
        if (node.rightOperand is NullLiteral) {
          // TODO(paulberry): figure out what the rules for isPure should be.
          // TODO(paulberry): only set falseChecksNonNull in unconditional
          // control flow
          bool isPure = node.leftOperand is SimpleIdentifier;
          var conditionInfo = _ConditionInfo(node,
              isPure: isPure,
              trueGuard: leftType.node.nullable,
              falseDemonstratesNonNullIntent: leftType.node.nonNullIntent);
          _conditionInfo = node.operator.type == TokenType.EQ_EQ
              ? conditionInfo
              : conditionInfo.not(node);
        }
        return _nonNullableBoolType;
      case TokenType.PLUS:
        _handleAssignment(_notNullType, node.leftOperand);
        var callee = node.staticElement;
        assert(!(callee is ClassMemberElement &&
            callee.enclosingElement.typeParameters
                .isNotEmpty)); // TODO(paulberry)
        assert(callee != null); // TODO(paulberry)
        var calleeType = getOrComputeElementType(callee);
        // TODO(paulberry): substitute if necessary
        assert(calleeType.positionalParameters.length > 0); // TODO(paulberry)
        _handleAssignment(
            calleeType.positionalParameters[0], node.rightOperand);
        return calleeType.returnType;
      default:
        assert(false); // TODO(paulberry)
        return null;
    }
  }

  @override
  DecoratedType visitBooleanLiteral(BooleanLiteral node) {
    return DecoratedType(node.staticType, _variables.neverNullable);
  }

  @override
  DecoratedType visitClassDeclaration(ClassDeclaration node) {
    node.members.accept(this);
    return null;
  }

  @override
  DecoratedType visitConditionalExpression(ConditionalExpression node) {
    _handleAssignment(_notNullType, node.condition);
    // TODO(paulberry): guard anything inside the true and false branches
    var thenType = node.thenExpression.accept(this);
    assert(_isSimple(thenType)); // TODO(paulberry)
    var elseType = node.elseExpression.accept(this);
    assert(_isSimple(elseType)); // TODO(paulberry)
    var overallType = DecoratedType(
        node.staticType,
        NullabilityNode(_joinNullabilities(
            node, thenType.node.nullable, elseType.node.nullable)));
    _variables.recordDecoratedExpressionType(node, overallType);
    return overallType;
  }

  @override
  DecoratedType visitDefaultFormalParameter(DefaultFormalParameter node) {
    var defaultValue = node.defaultValue;
    if (defaultValue == null) {
      if (node.declaredElement.hasRequired) {
        // Nothing to do; the implicit default value of `null` will never be
        // reached.
      } else if (node.declaredElement.isOptionalPositional ||
          assumptions.namedNoDefaultParameterHeuristic ==
              NamedNoDefaultParameterHeuristic.assumeNullable) {
        _recordFact(
            getOrComputeElementType(node.declaredElement).node.nullable);
      } else {
        assert(assumptions.namedNoDefaultParameterHeuristic ==
            NamedNoDefaultParameterHeuristic.assumeRequired);
      }
    } else {
      _handleAssignment(
          getOrComputeElementType(node.declaredElement), defaultValue,
          canInsertChecks: false);
    }
    return null;
  }

  @override
  DecoratedType visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _handleAssignment(_currentFunctionType.returnType, node.expression);
    return null;
  }

  @override
  DecoratedType visitFunctionDeclaration(FunctionDeclaration node) {
    node.functionExpression.parameters.accept(this);
    assert(_currentFunctionType == null);
    _currentFunctionType =
        _variables.decoratedElementType(node.declaredElement);
    _inConditionalControlFlow = false;
    try {
      node.functionExpression.body.accept(this);
    } finally {
      _currentFunctionType = null;
    }
    return null;
  }

  @override
  DecoratedType visitIfStatement(IfStatement node) {
    // TODO(paulberry): should the use of a boolean in an if-statement be
    // treated like an implicit `assert(b != null)`?  Probably.
    _handleAssignment(_notNullType, node.condition);
    _inConditionalControlFlow = true;
    ConstraintVariable trueGuard;
    ConstraintVariable falseGuard;
    if (identical(_conditionInfo?.condition, node.condition)) {
      trueGuard = _conditionInfo.trueGuard;
      falseGuard = _conditionInfo.falseGuard;
      _variables.recordConditionalDiscard(
          _source,
          node,
          ConditionalDiscard(trueGuard ?? ConstraintVariable.always,
              falseGuard ?? ConstraintVariable.always, _conditionInfo.isPure));
    }
    if (trueGuard != null) {
      _guards.add(trueGuard);
    }
    try {
      node.thenStatement.accept(this);
    } finally {
      if (trueGuard != null) {
        _guards.removeLast();
      }
    }
    if (falseGuard != null) {
      _guards.add(falseGuard);
    }
    try {
      node.elseStatement?.accept(this);
    } finally {
      if (falseGuard != null) {
        _guards.removeLast();
      }
    }
    return null;
  }

  @override
  DecoratedType visitIntegerLiteral(IntegerLiteral node) {
    return DecoratedType(node.staticType, _variables.neverNullable);
  }

  @override
  DecoratedType visitMethodDeclaration(MethodDeclaration node) {
    node.parameters.accept(this);
    assert(_currentFunctionType == null);
    _currentFunctionType =
        _variables.decoratedElementType(node.declaredElement);
    _inConditionalControlFlow = false;
    try {
      node.body.accept(this);
    } finally {
      _currentFunctionType = null;
    }
    return null;
  }

  @override
  DecoratedType visitMethodInvocation(MethodInvocation node) {
    DecoratedType targetType;
    if (node.target != null) {
      assert(node.operator.type == TokenType.PERIOD);
      _checkNonObjectMember(node.methodName.name); // TODO(paulberry)
      targetType = _handleAssignment(_notNullType, node.target);
    }
    var callee = node.methodName.staticElement;
    assert(callee != null); // TODO(paulberry)
    var calleeType = getOrComputeElementType(callee, targetType: targetType);
    // TODO(paulberry): substitute if necessary
    var arguments = node.argumentList.arguments;
    int i = 0;
    var suppliedNamedParameters = Set<String>();
    for (var expression in arguments) {
      if (expression is NamedExpression) {
        var name = expression.name.label.name;
        var parameterType = calleeType.namedParameters[name];
        assert(parameterType != null); // TODO(paulberry)
        _handleAssignment(parameterType, expression.expression);
        suppliedNamedParameters.add(name);
      } else {
        assert(calleeType.positionalParameters.length > i); // TODO(paulberry)
        _handleAssignment(calleeType.positionalParameters[i++], expression);
      }
    }
    // Any parameters not supplied must be optional.
    for (var entry in calleeType.namedParameterOptionalVariables.entries) {
      assert(entry.value != null);
      if (suppliedNamedParameters.contains(entry.key)) continue;
      _recordFact(entry.value);
    }
    return calleeType.returnType;
  }

  @override
  DecoratedType visitNode(AstNode node) {
    if (_permissive) {
      try {
        return super.visitNode(node);
      } catch (_) {
        return null;
      }
    } else {
      return super.visitNode(node);
    }
  }

  @override
  DecoratedType visitNullLiteral(NullLiteral node) {
    return _nullType;
  }

  @override
  DecoratedType visitParenthesizedExpression(ParenthesizedExpression node) {
    return node.expression.accept(this);
  }

  @override
  DecoratedType visitReturnStatement(ReturnStatement node) {
    if (node.expression == null) {
      _checkAssignment(_currentFunctionType.returnType, _nullType, null);
    } else {
      _handleAssignment(_currentFunctionType.returnType, node.expression);
    }
    return null;
  }

  @override
  DecoratedType visitSimpleIdentifier(SimpleIdentifier node) {
    var staticElement = node.staticElement;
    if (staticElement is ParameterElement) {
      return getOrComputeElementType(staticElement);
    } else if (staticElement is ClassElement) {
      return _nonNullableTypeType;
    } else {
      // TODO(paulberry)
      throw new UnimplementedError('${staticElement.runtimeType}');
    }
  }

  @override
  DecoratedType visitStringLiteral(StringLiteral node) {
    return DecoratedType(node.staticType, _variables.neverNullable);
  }

  @override
  DecoratedType visitThisExpression(ThisExpression node) {
    return DecoratedType(node.staticType, _variables.neverNullable);
  }

  @override
  DecoratedType visitThrowExpression(ThrowExpression node) {
    node.expression.accept(this);
    // TODO(paulberry): do we need to check the expression type?  I think not.
    return DecoratedType(node.staticType, _variables.neverNullable);
  }

  @override
  DecoratedType visitTypeName(TypeName typeName) {
    return DecoratedType(typeName.type, _variables.neverNullable);
  }

  /// Creates the necessary constraint(s) for an assignment from [sourceType] to
  /// [destinationType].  [expression] is the expression whose type is
  /// [sourceType]; it is the expression we will have to null-check in the case
  /// where a nullable source is assigned to a non-nullable destination.
  void _checkAssignment(DecoratedType destinationType, DecoratedType sourceType,
      Expression expression) {
    if (sourceType.node.nullable != null) {
      _guards.add(sourceType.node.nullable);
      var destinationNonNullIntent = destinationType.node.nonNullIntent;
      try {
        CheckExpression checkNotNull;
        if (expression != null) {
          checkNotNull = CheckExpression(expression);
          _variables.recordExpressionChecks(
              _source, expression, ExpressionChecks(checkNotNull));
        }
        // nullable_src => nullable_dst | check_expr
        _recordFact(ConstraintVariable.or(
            _constraints, destinationType.node.nullable, checkNotNull));
        if (checkNotNull != null) {
          // nullable_src & nonNullIntent_dst => check_expr
          if (destinationNonNullIntent != null) {
            _recordConstraint(destinationNonNullIntent, checkNotNull);
          }
        }
      } finally {
        _guards.removeLast();
      }
      var sourceNonNullIntent = sourceType.node.nonNullIntent;
      if (!_inConditionalControlFlow && sourceNonNullIntent != null) {
        if (destinationType.node.nullable == null) {
          // The destination type can never be nullable so this demonstrates
          // non-null intent.
          _recordFact(sourceNonNullIntent);
        } else if (destinationNonNullIntent != null) {
          // Propagate non-null intent from the destination to the source.
          _recordConstraint(destinationNonNullIntent, sourceNonNullIntent);
        }
      }
    }
    // TODO(paulberry): it's a cheat to pass in expression=null for the
    // recursive checks.  Really we want to unify all the checks in a single
    // ExpressionChecks object.
    expression = null;
    // TODO(paulberry): generalize this.
    if ((_isSimple(sourceType) || destinationType.type.isObject) &&
        _isSimple(destinationType)) {
      // Ok; nothing further to do.
    } else if (sourceType.type is InterfaceType &&
        destinationType.type is InterfaceType &&
        sourceType.type.element == destinationType.type.element) {
      assert(sourceType.typeArguments.length ==
          destinationType.typeArguments.length);
      for (int i = 0; i < sourceType.typeArguments.length; i++) {
        _checkAssignment(destinationType.typeArguments[i],
            sourceType.typeArguments[i], expression);
      }
    } else if (destinationType.type.isDynamic || sourceType.type.isDynamic) {
      // ok; nothing further to do.
    } else {
      throw '$destinationType <= $sourceType'; // TODO(paulberry)
    }
  }

  /// Double checks that [name] is not the name of a method or getter declared
  /// on [Object].
  ///
  /// TODO(paulberry): get rid of this method and put the correct logic into the
  /// call sites.
  void _checkNonObjectMember(String name) {
    assert(name != 'toString');
    assert(name != 'hashCode');
    assert(name != 'noSuchMethod');
    assert(name != 'runtimeType');
  }

  /// Creates the necessary constraint(s) for an assignment of the given
  /// [expression] to a destination whose type is [destinationType].
  DecoratedType _handleAssignment(
      DecoratedType destinationType, Expression expression,
      {bool canInsertChecks = true}) {
    var sourceType = expression.accept(this);
    _checkAssignment(
        destinationType, sourceType, canInsertChecks ? expression : null);
    return sourceType;
  }

  /// Double checks that [type] is sufficiently simple for this naive prototype
  /// implementation.
  ///
  /// TODO(paulberry): get rid of this method and put the correct logic into the
  /// call sites.
  bool _isSimple(DecoratedType type) {
    if (type.type.isBottom) return true;
    if (type.type.isVoid) return true;
    if (type.type is! InterfaceType) return false;
    if ((type.type as InterfaceType).typeParameters.isNotEmpty) return false;
    return true;
  }

  /// Creates a constraint variable (if necessary) representing the nullability
  /// of [node], which is the disjunction of the nullabilities [a] and [b].
  ConstraintVariable _joinNullabilities(
      ConditionalExpression node, ConstraintVariable a, ConstraintVariable b) {
    if (a == null) return b;
    if (b == null) return a;
    if (identical(a, ConstraintVariable.always) ||
        identical(b, ConstraintVariable.always)) {
      return ConstraintVariable.always;
    }
    var result = TypeIsNullable(node.offset);
    _recordConstraint(a, result);
    _recordConstraint(b, result);
    _recordConstraint(result, ConstraintVariable.or(_constraints, a, b));
    return result;
  }

  /// Records a constraint having [condition] as its left hand side and
  /// [consequence] as its right hand side.  Any [_guards] are included in the
  /// left hand side.
  void _recordConstraint(
      ConstraintVariable condition, ConstraintVariable consequence) {
    _guards.add(condition);
    try {
      _recordFact(consequence);
    } finally {
      _guards.removeLast();
    }
  }

  /// Records a constraint having [consequence] as its right hand side.  Any
  /// [_guards] are used as the right hand side.
  void _recordFact(ConstraintVariable consequence) {
    assert(consequence != null);
    _constraints.record(_guards, consequence);
  }
}

/// Information about a binary expression whose boolean value could possibly
/// affect nullability analysis.
class _ConditionInfo {
  /// The [expression] of interest.
  final Expression condition;

  /// Indicates whether [condition] is pure (free from side effects).
  ///
  /// For example, a condition like `x == null` is pure (assuming `x` is a local
  /// variable or static variable), because evaluating it has no user-visible
  /// effect other than returning a boolean value.
  final bool isPure;

  /// If not `null`, the [ConstraintVariable] whose value must be `true` in
  /// order for [condition] to evaluate to `true`.
  final ConstraintVariable trueGuard;

  /// If not `null`, the [ConstraintVariable] whose value must be `true` in
  /// order for [condition] to evaluate to `false`.
  final ConstraintVariable falseGuard;

  /// If not `null`, the [ConstraintVariable] whose value should be set to
  /// `true` if [condition] is asserted to be `true`.
  final ConstraintVariable trueDemonstratesNonNullIntent;

  /// If not `null`, the [ConstraintVariable] whose value should be set to
  /// `true` if [condition] is asserted to be `false`.
  final ConstraintVariable falseDemonstratesNonNullIntent;

  _ConditionInfo(this.condition,
      {@required this.isPure,
      this.trueGuard,
      this.falseGuard,
      this.trueDemonstratesNonNullIntent,
      this.falseDemonstratesNonNullIntent});

  /// Returns a new [_ConditionInfo] describing the boolean "not" of `this`.
  _ConditionInfo not(Expression condition) => _ConditionInfo(condition,
      isPure: isPure,
      trueGuard: falseGuard,
      falseGuard: trueGuard,
      trueDemonstratesNonNullIntent: falseDemonstratesNonNullIntent,
      falseDemonstratesNonNullIntent: trueDemonstratesNonNullIntent);
}
