// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.10

library dump_info;

import 'dart:convert'
    show ChunkedConversionSink, JsonEncoder, StringConversionSink;

import 'package:dart2js_info/info.dart';
import 'package:dart2js_info/json_info_codec.dart';
import 'package:dart2js_info/binary_serialization.dart' as dump_info;
import 'package:kernel/ast.dart' as ir;

import '../compiler.dart';
import 'common.dart';
import 'common/elements.dart' show JElementEnvironment;
import 'common/names.dart';
import 'common/tasks.dart' show CompilerTask;
import 'compiler.dart' show Compiler;
import 'constants/values.dart' show ConstantValue, InterceptorConstantValue;
import 'deferred_load/output_unit.dart' show OutputUnit, deferredPartFileName;
import 'elements/entities.dart';
import 'inferrer/abstract_value_domain.dart';
import 'inferrer/types.dart'
    show GlobalTypeInferenceMemberResult, GlobalTypeInferenceResults;
import 'js/js.dart' as jsAst;
import 'js_model/js_strategy.dart';
import 'js_backend/field_analysis.dart';
import 'universe/world_impact.dart' show WorldImpact;
import 'util/sink_adapter.dart';
import 'world.dart' show JClosedWorld;

class ElementInfoCollector {
  final Compiler compiler;
  final JClosedWorld closedWorld;
  final GlobalTypeInferenceResults _globalInferenceResults;
  final DumpInfoTask dumpInfoTask;

  JElementEnvironment get environment => closedWorld.elementEnvironment;

  final AllInfo result = AllInfo();
  final Map<Entity, Info> _entityToInfo = <Entity, Info>{};
  final Map<ConstantValue, Info> _constantToInfo = <ConstantValue, Info>{};
  final Map<OutputUnit, OutputUnitInfo> _outputToInfo = {};

  ElementInfoCollector(this.compiler, this.dumpInfoTask, this.closedWorld,
      this._globalInferenceResults);

  void run() {
    dumpInfoTask._constantToNode.forEach((constant, node) {
      // TODO(sigmund): add dependencies on other constants
      var span = dumpInfoTask._nodeData[node];
      var info = ConstantInfo(
          size: span.end - span.start,
          code: [span],
          outputUnit: _unitInfoForConstant(constant));
      _constantToInfo[constant] = info;
      result.constants.add(info);
    });
    environment.libraries.forEach(visitLibrary);
  }

  /// Whether to emit information about [entity].
  ///
  /// By default we emit information for any entity that contributes to the
  /// output size. Either because it is a function being emitted or inlined,
  /// or because it is an entity that holds dependencies to other entities.
  bool shouldKeep(Entity entity) {
    return dumpInfoTask.impacts.containsKey(entity) ||
        dumpInfoTask.inlineCount.containsKey(entity);
  }

  LibraryInfo visitLibrary(LibraryEntity lib) {
    String libname = environment.getLibraryName(lib);
    if (libname.isEmpty) {
      libname = '<unnamed>';
    }
    int size = dumpInfoTask.sizeOf(lib);
    LibraryInfo info = LibraryInfo(libname, lib.canonicalUri, null, size);
    _entityToInfo[lib] = info;

    environment.forEachLibraryMember(lib, (MemberEntity member) {
      if (member.isFunction || member.isGetter || member.isSetter) {
        FunctionInfo functionInfo = visitFunction(member);
        if (functionInfo != null) {
          info.topLevelFunctions.add(functionInfo);
          functionInfo.parent = info;
        }
      } else if (member.isField) {
        FieldInfo fieldInfo = visitField(member);
        if (fieldInfo != null) {
          info.topLevelVariables.add(fieldInfo);
          fieldInfo.parent = info;
        }
      }
    });

    environment.forEachClass(lib, (ClassEntity clazz) {
      ClassTypeInfo classTypeInfo = visitClassType(clazz);
      if (classTypeInfo != null) {
        info.classTypes.add(classTypeInfo);
        classTypeInfo.parent = info;
      }

      ClassInfo classInfo = visitClass(clazz);
      if (classInfo != null) {
        info.classes.add(classInfo);
        classInfo.parent = info;
      }
    });

    if (info.isEmpty && !shouldKeep(lib)) return null;
    result.libraries.add(info);
    return info;
  }

  GlobalTypeInferenceMemberResult _resultOfMember(MemberEntity e) =>
      _globalInferenceResults.resultOfMember(e);

  AbstractValue _resultOfParameter(Local e) =>
      _globalInferenceResults.resultOfParameter(e);

  FieldInfo visitField(FieldEntity field) {
    AbstractValue inferredType = _resultOfMember(field).type;
    // If a field has an empty inferred type it is never used.
    if (inferredType == null ||
        closedWorld.abstractValueDomain
            .isEmpty(inferredType)
            .isDefinitelyTrue) {
      return null;
    }

    int size = dumpInfoTask.sizeOf(field);
    List<CodeSpan> code = dumpInfoTask.codeOf(field);

    // TODO(het): Why doesn't `size` account for the code size already?
    if (code != null) size += code.length;

    FieldInfo info = FieldInfo(
        name: field.name,
        type: '${environment.getFieldType(field)}',
        inferredType: '$inferredType',
        code: code,
        outputUnit: _unitInfoForMember(field),
        isConst: field.isConst);
    _entityToInfo[field] = info;
    FieldAnalysisData fieldData = closedWorld.fieldAnalysis.getFieldData(field);
    if (fieldData.initialValue != null) {
      info.initializer = _constantToInfo[fieldData.initialValue];
    }

    if (compiler.options.experimentCallInstrumentation) {
      // We use field.hashCode because it is globally unique and it is
      // available while we are doing codegen.
      info.coverageId = '${field.hashCode}';
    }

    int closureSize = _addClosureInfo(info, field);
    info.size = size + closureSize;

    result.fields.add(info);
    return info;
  }

  ClassTypeInfo visitClassType(ClassEntity clazz) {
    // Omit class type if it is not needed.
    ClassTypeInfo classTypeInfo = ClassTypeInfo(
        name: clazz.name, outputUnit: _unitInfoForClassType(clazz));

    // TODO(joshualitt): Get accurate size information for class types.
    classTypeInfo.size = 0;

    bool isNeeded =
        compiler.backendStrategy.emitterTask.neededClassTypes.contains(clazz);
    if (!isNeeded) {
      return null;
    }

    result.classTypes.add(classTypeInfo);
    return classTypeInfo;
  }

  ClassInfo visitClass(ClassEntity clazz) {
    // Omit class if it is not needed.
    ClassInfo classInfo = ClassInfo(
        name: clazz.name,
        isAbstract: clazz.isAbstract,
        outputUnit: _unitInfoForClass(clazz));
    _entityToInfo[clazz] = classInfo;

    int size = dumpInfoTask.sizeOf(clazz);
    environment.forEachLocalClassMember(clazz, (member) {
      if (member.isFunction || member.isGetter || member.isSetter) {
        FunctionInfo functionInfo = visitFunction(member);
        if (functionInfo != null) {
          classInfo.functions.add(functionInfo);
          functionInfo.parent = classInfo;
          for (var closureInfo in functionInfo.closures) {
            size += closureInfo.size;
          }
        }
      } else if (member.isField) {
        FieldInfo fieldInfo = visitField(member);
        if (fieldInfo != null) {
          classInfo.fields.add(fieldInfo);
          fieldInfo.parent = classInfo;
          for (var closureInfo in fieldInfo.closures) {
            size += closureInfo.size;
          }
        }
      } else {
        throw StateError('Class member not a function or field');
      }
    });
    environment.forEachConstructor(clazz, (constructor) {
      FunctionInfo functionInfo = visitFunction(constructor);
      if (functionInfo != null) {
        classInfo.functions.add(functionInfo);
        functionInfo.parent = classInfo;
        for (var closureInfo in functionInfo.closures) {
          size += closureInfo.size;
        }
      }
    });

    classInfo.size = size;

    if (!compiler.backendStrategy.emitterTask.neededClasses.contains(clazz) &&
        classInfo.fields.isEmpty &&
        classInfo.functions.isEmpty) {
      return null;
    }

    result.classes.add(classInfo);
    return classInfo;
  }

  ClosureInfo visitClosureClass(ClassEntity element) {
    ClosureInfo closureInfo = ClosureInfo(
        name: element.name,
        outputUnit: _unitInfoForClass(element),
        size: dumpInfoTask.sizeOf(element));
    _entityToInfo[element] = closureInfo;

    FunctionEntity callMethod = closedWorld.elementEnvironment
        .lookupClassMember(element, Identifiers.call);

    FunctionInfo functionInfo = visitFunction(callMethod);
    if (functionInfo == null) return null;
    closureInfo.function = functionInfo;
    functionInfo.parent = closureInfo;

    result.closures.add(closureInfo);
    return closureInfo;
  }

  FunctionInfo visitFunction(FunctionEntity function) {
    int size = dumpInfoTask.sizeOf(function);
    // TODO(sigmund): consider adding a small info to represent unreachable
    // code here.
    if (size == 0 && !shouldKeep(function)) return null;

    // TODO(het): use 'toString' instead of 'text'? It will add '=' for setters
    String name = function.memberName.text;
    int kind;
    if (function.isStatic || function.isTopLevel) {
      kind = FunctionInfo.TOP_LEVEL_FUNCTION_KIND;
    } else if (function.enclosingClass != null) {
      kind = FunctionInfo.METHOD_FUNCTION_KIND;
    }

    if (function.isConstructor) {
      name = name == ""
          ? "${function.enclosingClass.name}"
          : "${function.enclosingClass.name}.${function.name}";
      kind = FunctionInfo.CONSTRUCTOR_FUNCTION_KIND;
    }

    assert(kind != null);

    FunctionModifiers modifiers = FunctionModifiers(
      isStatic: function.isStatic,
      isConst: function.isConst,
      isFactory: function.isConstructor
          ? (function as ConstructorEntity).isFactoryConstructor
          : false,
      isExternal: function.isExternal,
    );
    List<CodeSpan> code = dumpInfoTask.codeOf(function);

    List<ParameterInfo> parameters = <ParameterInfo>[];
    List<String> inferredParameterTypes = <String>[];

    closedWorld.elementEnvironment.forEachParameterAsLocal(
        _globalInferenceResults.globalLocalsMap, function, (parameter) {
      inferredParameterTypes.add('${_resultOfParameter(parameter)}');
    });
    int parameterIndex = 0;
    closedWorld.elementEnvironment.forEachParameter(function, (type, name, _) {
      // Synthesized parameters have no name. This can happen on parameters of
      // setters derived from lowering late fields.
      parameters.add(ParameterInfo(name ?? '#t${parameterIndex}',
          inferredParameterTypes[parameterIndex++], '$type'));
    });

    final functionType = environment.getFunctionType(function);
    String returnType = '${functionType.returnType}';

    String inferredReturnType = '${_resultOfMember(function).returnType}';
    String sideEffects =
        '${_globalInferenceResults.inferredData.getSideEffectsOfElement(function)}';

    int inlinedCount = dumpInfoTask.inlineCount[function];
    if (inlinedCount == null) inlinedCount = 0;

    FunctionInfo info = FunctionInfo(
        name: name,
        functionKind: kind,
        modifiers: modifiers,
        returnType: returnType,
        inferredReturnType: inferredReturnType,
        parameters: parameters,
        sideEffects: sideEffects,
        inlinedCount: inlinedCount,
        code: code,
        type: functionType.toString(),
        outputUnit: _unitInfoForMember(function));
    _entityToInfo[function] = info;

    int closureSize = _addClosureInfo(info, function);
    size += closureSize;

    if (compiler.options.experimentCallInstrumentation) {
      // We use function.hashCode because it is globally unique and it is
      // available while we are doing codegen.
      info.coverageId = '${function.hashCode}';
    }

    info.size = size;

    result.functions.add(info);
    return info;
  }

  /// Adds closure information to [info], using all nested closures in [member].
  ///
  /// Returns the total size of the nested closures, to add to the info size.
  int _addClosureInfo(Info info, MemberEntity member) {
    assert(info is FunctionInfo || info is FieldInfo);
    int size = 0;
    List<ClosureInfo> nestedClosures = <ClosureInfo>[];
    environment.forEachNestedClosure(member, (closure) {
      ClosureInfo closureInfo = visitClosureClass(closure.enclosingClass);
      if (closureInfo != null) {
        closureInfo.parent = info;
        nestedClosures.add(closureInfo);
        size += closureInfo.size;
      }
    });
    if (info is FunctionInfo) info.closures = nestedClosures;
    if (info is FieldInfo) info.closures = nestedClosures;

    return size;
  }

  OutputUnitInfo _infoFromOutputUnit(OutputUnit outputUnit) {
    return _outputToInfo.putIfAbsent(outputUnit, () {
      // Dump-info currently only works with the full emitter. If another
      // emitter is used it will fail here.
      JsBackendStrategy backendStrategy = compiler.backendStrategy;
      assert(outputUnit.name != null || outputUnit.isMainOutput);
      var filename = outputUnit.isMainOutput
          ? compiler.options.outputUri.pathSegments.last
          : deferredPartFileName(compiler.options, outputUnit.name);
      OutputUnitInfo info = OutputUnitInfo(filename, outputUnit.name,
          backendStrategy.emitterTask.emitter.generatedSize(outputUnit));
      info.imports
          .addAll(closedWorld.outputUnitData.getImportNames(outputUnit));
      result.outputUnits.add(info);
      return info;
    });
  }

  OutputUnitInfo _unitInfoForMember(MemberEntity entity) {
    return _infoFromOutputUnit(
        closedWorld.outputUnitData.outputUnitForMember(entity));
  }

  OutputUnitInfo _unitInfoForClass(ClassEntity entity) {
    return _infoFromOutputUnit(
        closedWorld.outputUnitData.outputUnitForClass(entity, allowNull: true));
  }

  OutputUnitInfo _unitInfoForClassType(ClassEntity entity) {
    return _infoFromOutputUnit(closedWorld.outputUnitData
        .outputUnitForClassType(entity, allowNull: true));
  }

  OutputUnitInfo _unitInfoForConstant(ConstantValue constant) {
    OutputUnit outputUnit =
        closedWorld.outputUnitData.outputUnitForConstant(constant);
    if (outputUnit == null) {
      assert(constant is InterceptorConstantValue);
      return null;
    }
    return _infoFromOutputUnit(outputUnit);
  }
}

class KernelInfoCollector {
  final ir.Component component;
  final Compiler compiler;
  final JClosedWorld closedWorld;
  final GlobalTypeInferenceResults _globalInferenceResults;
  final DumpInfoTask dumpInfoTask;

  JElementEnvironment get environment => closedWorld.elementEnvironment;

  final AllInfo result = AllInfo();
  final Map<Entity, Info> _entityToInfo = <Entity, Info>{};
  final Map<ConstantValue, Info> _constantToInfo = <ConstantValue, Info>{};
  final Map<OutputUnit, OutputUnitInfo> _outputToInfo = {};

  KernelInfoCollector(this.component, this.compiler, this.dumpInfoTask,
      this.closedWorld, this._globalInferenceResults);

  void run() {
    // TODO(markzipan): Add CFE constants to `result.constants`.
    component.libraries.forEach(visitLibrary);
  }

  LibraryInfo visitLibrary(ir.Library lib) {
    final libEntity = environment.lookupLibrary(lib.importUri);
    if (libEntity == null) return null;

    String libname = lib.name;
    if (libname == null || libname.isEmpty) {
      libname = '<unnamed>';
    }

    LibraryInfo info = LibraryInfo(libname, lib.importUri, null, null);
    _entityToInfo[libEntity] = info;

    lib.members.forEach((ir.Member member) {
      final memberEntity =
          environment.lookupLibraryMember(libEntity, member.name.text);
      if (memberEntity == null) return;
      if (member.function != null) {
        FunctionInfo functionInfo =
            visitFunction(member.function, functionEntity: memberEntity);
        if (functionInfo != null) {
          info.topLevelFunctions.add(functionInfo);
          functionInfo.parent = info;
        }
      } else {
        FieldInfo fieldInfo = visitField(member, fieldEntity: memberEntity);
        if (fieldInfo != null) {
          info.topLevelVariables.add(fieldInfo);
          fieldInfo.parent = info;
        }
      }
    });

    lib.classes.forEach((ir.Class clazz) {
      final classEntity = environment.lookupClass(libEntity, clazz.name);
      if (classEntity == null) return;

      ClassTypeInfo classTypeInfo = visitClassType(clazz);
      if (classTypeInfo != null) {
        info.classTypes.add(classTypeInfo);
        classTypeInfo.parent = info;
      }

      ClassInfo classInfo = visitClass(clazz, classEntity: classEntity);
      if (classInfo != null) {
        info.classes.add(classInfo);
        classInfo.parent = info;
      }
    });

    result.libraries.add(info);
    return info;
  }

  AbstractValue _resultOfParameter(Local e) =>
      _globalInferenceResults.resultOfParameter(e);

  FieldInfo visitField(ir.Field field, {FieldEntity fieldEntity}) {
    FieldInfo info = FieldInfo(
        name: field.name.text,
        type: field.type.toStringInternal(),
        inferredType: null,
        code: null,
        outputUnit: null,
        isConst: field.isConst,
        size: null);
    _entityToInfo[fieldEntity] = info;

    if (compiler.options.experimentCallInstrumentation) {
      // We use field.hashCode because it is globally unique and it is
      // available while we are doing codegen.
      info.coverageId = '${field.hashCode}';
    }

    result.fields.add(info);
    return info;
  }

  ClassTypeInfo visitClassType(ir.Class clazz) {
    ClassTypeInfo classTypeInfo = ClassTypeInfo(name: clazz.name);
    result.classTypes.add(classTypeInfo);
    return classTypeInfo;
  }

  ClassInfo visitClass(ir.Class clazz, {ClassEntity classEntity}) {
    // Omit class if it is not needed.
    ClassInfo classInfo = ClassInfo(
        name: clazz.name, isAbstract: clazz.isAbstract, outputUnit: null);
    _entityToInfo[classEntity] = classInfo;

    clazz.members.forEach((ir.Member member) {
      // clazz.members includes constructors
      MemberEntity memberEntity =
          environment.lookupLocalClassMember(classEntity, member.name.text) ??
              environment.lookupConstructor(classEntity, member.name.text);
      if (memberEntity == null) return;
      // Multiple kernel members can map to single JWorld member
      // (e.g., when one of a getter/field pair are tree-shaken),
      // so avoid duplicating the downstream info object.
      if (_entityToInfo.containsKey(memberEntity)) {
        return;
      }

      if (member.function != null) {
        FunctionInfo functionInfo =
            visitFunction(member.function, functionEntity: memberEntity);
        if (functionInfo != null) {
          classInfo.functions.add(functionInfo);
          functionInfo.parent = classInfo;
        }
      } else {
        FieldInfo fieldInfo = visitField(member, fieldEntity: memberEntity);
        if (fieldInfo != null) {
          classInfo.fields.add(fieldInfo);
          fieldInfo.parent = classInfo;
        }
      }
    });

    result.classes.add(classInfo);
    return classInfo;
  }

  FunctionInfo visitFunction(ir.FunctionNode function,
      {FunctionEntity functionEntity}) {
    var parent = function.parent;
    String name = parent.toStringInternal();
    bool isConstructor = parent is ir.Constructor;
    bool isFactory = parent is ir.Procedure && parent.isFactory;
    // Kernel `isStatic` refers to static members, constructors, and top-level
    // members.
    bool isTopLevel = ((parent is ir.Field && parent.isStatic) ||
            (parent is ir.Procedure && parent.isStatic)) &&
        (parent is ir.Member && parent.enclosingClass == null);
    bool isStaticMember = ((parent is ir.Field && parent.isStatic) ||
            (parent is ir.Procedure && parent.isStatic)) &&
        (parent is ir.Member && parent.enclosingClass != null) &&
        !isConstructor &&
        !isFactory;
    bool isConst = parent is ir.Member && parent.isConst;
    bool isExternal = parent is ir.Member && parent.isExternal;
    bool isMethod = parent is ir.Member && parent.enclosingClass != null;
    bool isGetter = parent is ir.Procedure && parent.isGetter;
    bool isSetter = parent is ir.Procedure && parent.isSetter;
    int kind;
    if (isTopLevel) {
      kind = FunctionInfo.TOP_LEVEL_FUNCTION_KIND;
    } else if (isMethod) {
      kind = FunctionInfo.METHOD_FUNCTION_KIND;
    }
    if (isConstructor || isFactory) {
      kind = FunctionInfo.CONSTRUCTOR_FUNCTION_KIND;
      String functionName = function.toStringInternal();
      name = functionName.isEmpty ? '$name' : '$name$functionName';
    } else {
      if (parent.parent is ir.Class && name.contains('.')) {
        name = name.split('.')[1];
      }
    }
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);

    FunctionModifiers modifiers = FunctionModifiers(
      isStatic: isStaticMember,
      isConst: isConst,
      isFactory: isFactory,
      isExternal: isExternal,
      isGetter: isGetter,
      isSetter: isSetter,
    );

    List<ParameterInfo> parameters = <ParameterInfo>[];
    List<String> inferredParameterTypes = <String>[];

    closedWorld.elementEnvironment.forEachParameterAsLocal(
        _globalInferenceResults.globalLocalsMap, functionEntity, (parameter) {
      inferredParameterTypes.add('${_resultOfParameter(parameter)}');
    });

    int parameterIndex = 0;
    closedWorld.elementEnvironment.forEachParameter(functionEntity,
        (type, name, _) {
      // Synthesized parameters have no name. This can happen on parameters of
      // setters derived from lowering late fields.
      parameters.add(ParameterInfo(name ?? '#t${parameterIndex}',
          inferredParameterTypes[parameterIndex++], '$type'));
    });

    // TODO(markzipan): Determine if it's safe to default to nonNullable here.
    final nullability = parent is ir.Member
        ? parent.enclosingLibrary.nonNullable
        : ir.Nullability.nonNullable;
    final functionType = function.computeFunctionType(nullability);

    FunctionInfo info = FunctionInfo(
        name: name,
        functionKind: kind,
        modifiers: modifiers,
        returnType: function.returnType.toStringInternal(),
        inferredReturnType: null,
        parameters: parameters,
        sideEffects: null,
        inlinedCount: null,
        code: null,
        type: functionType.toStringInternal(),
        outputUnit: null);
    _entityToInfo[functionEntity] = info;

    if (compiler.options.experimentCallInstrumentation) {
      // We use function.hashCode because it is globally unique and it is
      // available while we are doing codegen.
      info.coverageId = '${function.hashCode}';
    }

    result.functions.add(info);
    return info;
  }
}

/// Annotates [KernelInfoCollector] with info extracted from closed-world
/// analysis.
class DumpInfoAnnotator {
  final KernelInfoCollector kernelInfo;
  final Compiler compiler;
  final JClosedWorld closedWorld;
  final GlobalTypeInferenceResults _globalInferenceResults;
  final DumpInfoTask dumpInfoTask;

  JElementEnvironment get environment => closedWorld.elementEnvironment;

  DumpInfoAnnotator(this.kernelInfo, this.compiler, this.dumpInfoTask,
      this.closedWorld, this._globalInferenceResults);

  void run() {
    dumpInfoTask._constantToNode.forEach((constant, node) {
      // TODO(sigmund): add dependencies on other constants
      var span = dumpInfoTask._nodeData[node];
      var info = ConstantInfo(
          size: span.end - span.start,
          code: [span],
          outputUnit: _unitInfoForConstant(constant));
      kernelInfo._constantToInfo[constant] = info;
      info.treeShakenStatus = TreeShakenStatus.Live;
      kernelInfo.result.constants.add(info);
    });
    environment.libraries.forEach(visitLibrary);
  }

  /// Whether to emit information about [entity].
  ///
  /// By default we emit information for any entity that contributes to the
  /// output size. Either because it is a function being emitted or inlined,
  /// or because it is an entity that holds dependencies to other entities.
  bool shouldKeep(Entity entity) {
    return dumpInfoTask.impacts.containsKey(entity) ||
        dumpInfoTask.inlineCount.containsKey(entity);
  }

  LibraryInfo visitLibrary(LibraryEntity lib) {
    var kLibraryInfos = kernelInfo.result.libraries
        .where((i) => '${i.uri}' == '${lib.canonicalUri}');
    assert(
        kLibraryInfos.length == 1,
        'Ambiguous library resolution. '
        'Expected singleton, found $kLibraryInfos');
    var kLibraryInfo = kLibraryInfos.first;

    String libname = environment.getLibraryName(lib);
    if (libname.isEmpty) {
      libname = '<unnamed>';
    }
    assert(kLibraryInfo.name == libname);
    kLibraryInfo.size = dumpInfoTask.sizeOf(lib);

    environment.forEachLibraryMember(lib, (MemberEntity member) {
      if (member.isFunction || member.isGetter || member.isSetter) {
        visitFunction(member, libname);
      } else if (member.isField) {
        visitField(member, libname);
      } else {
        throw StateError('Class member not a function or field');
      }
    });

    environment.forEachClass(lib, (ClassEntity clazz) {
      visitClassType(clazz, libname);
      visitClass(clazz, libname);
    });

    bool hasLiveFields = [
      ...kLibraryInfo.topLevelFunctions,
      ...kLibraryInfo.topLevelVariables,
      ...kLibraryInfo.classes,
      ...kLibraryInfo.classTypes
    ].any((i) => i.treeShakenStatus == TreeShakenStatus.Live);
    if (!hasLiveFields && !shouldKeep(lib)) return null;
    kLibraryInfo.treeShakenStatus = TreeShakenStatus.Live;
    return kLibraryInfo;
  }

  GlobalTypeInferenceMemberResult _resultOfMember(MemberEntity e) =>
      _globalInferenceResults.resultOfMember(e);

  AbstractValue _resultOfParameter(Local e) =>
      _globalInferenceResults.resultOfParameter(e);

  // TODO(markzipan): [parentName] is used for disambiguation, but this might
  // not always be valid. Check and validate later.
  FieldInfo visitField(FieldEntity field, String parentName) {
    AbstractValue inferredType = _resultOfMember(field).type;
    // If a field has an empty inferred type it is never used.
    if (inferredType == null ||
        closedWorld.abstractValueDomain
            .isEmpty(inferredType)
            .isDefinitelyTrue) {
      return null;
    }

    final kFieldInfos = kernelInfo.result.fields
        .where((f) => f.name == field.name && f.parent.name == parentName)
        .toList();
    assert(
        kFieldInfos.length == 1,
        'Ambiguous field resolution. '
        'Expected singleton, found $kFieldInfos');
    final kFieldInfo = kFieldInfos.first;

    int size = dumpInfoTask.sizeOf(field);
    List<CodeSpan> code = dumpInfoTask.codeOf(field);

    // TODO(het): Why doesn't `size` account for the code size already?
    if (code != null) size += code.length;

    kFieldInfo.outputUnit = _unitInfoForMember(field);
    kFieldInfo.inferredType = '$inferredType';
    kFieldInfo.code = code;
    kFieldInfo.treeShakenStatus = TreeShakenStatus.Live;

    FieldAnalysisData fieldData = closedWorld.fieldAnalysis.getFieldData(field);
    if (fieldData.initialValue != null) {
      kFieldInfo.initializer =
          kernelInfo._constantToInfo[fieldData.initialValue];
    }

    int closureSize = _addClosureInfo(kFieldInfo, field);
    kFieldInfo.size = size + closureSize;
    return kFieldInfo;
  }

  // TODO(markzipan): [parentName] is used for disambiguation, but this might
  // not always be valid. Check and validate later.
  ClassTypeInfo visitClassType(ClassEntity clazz, String parentName) {
    var kClassTypeInfos = kernelInfo.result.classTypes
        .where((i) => i.name == clazz.name && i.parent.name == parentName);
    assert(
        kClassTypeInfos.length == 1,
        'Ambiguous class type resolution. '
        'Expected singleton, found $kClassTypeInfos');
    var kClassTypeInfo = kClassTypeInfos.first;

    // TODO(joshualitt): Get accurate size information for class types.
    kClassTypeInfo.size = 0;

    // Omit class type if it is not needed.
    bool isNeeded =
        compiler.backendStrategy.emitterTask.neededClassTypes.contains(clazz);
    if (!isNeeded) return null;

    assert(kClassTypeInfo.name == clazz.name);
    kClassTypeInfo.outputUnit = _unitInfoForClassType(clazz);
    kClassTypeInfo.treeShakenStatus = TreeShakenStatus.Live;
    return kClassTypeInfo;
  }

  // TODO(markzipan): [parentName] is used for disambiguation, but this might
  // not always be valid. Check and validate later.
  ClassInfo visitClass(ClassEntity clazz, String parentName) {
    final kClassInfos = kernelInfo.result.classes
        .where((i) => i.name == clazz.name && i.parent.name == parentName)
        .toList();
    assert(
        kClassInfos.length == 1,
        'Ambiguous class resolution. '
        'Expected singleton, found $kClassInfos');
    final kClassInfo = kClassInfos.first;

    int size = dumpInfoTask.sizeOf(clazz);
    environment.forEachLocalClassMember(clazz, (member) {
      if (member.isFunction || member.isGetter || member.isSetter) {
        FunctionInfo functionInfo = visitFunction(member, clazz.name);
        if (functionInfo != null) {
          for (var closureInfo in functionInfo.closures) {
            size += closureInfo.size;
          }
        }
      } else if (member.isField) {
        FieldInfo fieldInfo = visitField(member, clazz.name);
        if (fieldInfo != null) {
          for (var closureInfo in fieldInfo.closures) {
            size += closureInfo.size;
          }
        }
      } else {
        throw StateError('Class member not a function or field');
      }
    });
    environment.forEachConstructor(clazz, (constructor) {
      FunctionInfo functionInfo = visitFunction(constructor, clazz.name);
      if (functionInfo != null) {
        for (var closureInfo in functionInfo.closures) {
          size += closureInfo.size;
        }
      }
    });
    kClassInfo.size = size;

    bool hasLiveFields = [...kClassInfo.fields, ...kClassInfo.functions]
        .any((i) => i.treeShakenStatus == TreeShakenStatus.Live);
    if (!compiler.backendStrategy.emitterTask.neededClasses.contains(clazz) &&
        !hasLiveFields) {
      return null;
    }

    kClassInfo.outputUnit = _unitInfoForClass(clazz);
    kClassInfo.treeShakenStatus = TreeShakenStatus.Live;
    return kClassInfo;
  }

  ClosureInfo visitClosureClass(ClassEntity element) {
    ClosureInfo closureInfo = ClosureInfo(
        name: element.name,
        outputUnit: _unitInfoForClass(element),
        size: dumpInfoTask.sizeOf(element));
    kernelInfo._entityToInfo[element] = closureInfo;

    FunctionEntity callMethod = closedWorld.elementEnvironment
        .lookupClassMember(element, Identifiers.call);

    FunctionInfo functionInfo = visitFunction(callMethod, element.name);
    if (functionInfo == null) return null;

    closureInfo.function = functionInfo;
    functionInfo.parent = closureInfo;
    closureInfo.treeShakenStatus = TreeShakenStatus.Live;

    kernelInfo.result.closures.add(closureInfo);
    return closureInfo;
  }

  // TODO(markzipan): [parentName] is used for disambiguation, but this might
  // not always be valid. Check and validate later.
  FunctionInfo visitFunction(FunctionEntity function, String parentName) {
    int size = dumpInfoTask.sizeOf(function);
    // TODO(sigmund): consider adding a small info to represent unreachable
    // code here.
    if (size == 0 && !shouldKeep(function)) return null;

    var compareName = function.name;
    if (function.isConstructor) {
      compareName = compareName == ""
          ? "${function.enclosingClass.name}"
          : "${function.enclosingClass.name}.${function.name}";
    }

    // Multiple kernel members members can sometimes map to a single JElement.
    // [isSetter] and [isGetter] are required for disambiguating these cases.
    final kFunctionInfos = kernelInfo.result.functions
        .where((i) =>
            i.name == compareName &&
            i.parent.name == parentName &&
            !(function.isGetter ^ i.modifiers.isGetter) &&
            !(function.isSetter ^ i.modifiers.isSetter))
        .toList();
    assert(
        kFunctionInfos.length == 1,
        'Ambiguous function resolution. '
        'Expected singleton, found $kFunctionInfos');
    final kFunctionInfo = kFunctionInfos.first;

    List<CodeSpan> code = dumpInfoTask.codeOf(function);
    List<ParameterInfo> parameters = <ParameterInfo>[];
    List<String> inferredParameterTypes = <String>[];

    closedWorld.elementEnvironment.forEachParameterAsLocal(
        _globalInferenceResults.globalLocalsMap, function, (parameter) {
      inferredParameterTypes.add('${_resultOfParameter(parameter)}');
    });
    int parameterIndex = 0;
    closedWorld.elementEnvironment.forEachParameter(function, (type, name, _) {
      // Synthesized parameters have no name. This can happen on parameters of
      // setters derived from lowering late fields.
      parameters.add(ParameterInfo(name ?? '#t${parameterIndex}',
          inferredParameterTypes[parameterIndex++], '$type'));
    });

    String inferredReturnType = '${_resultOfMember(function).returnType}';
    String sideEffects =
        '${_globalInferenceResults.inferredData.getSideEffectsOfElement(function)}';
    int inlinedCount = dumpInfoTask.inlineCount[function] ?? 0;

    kFunctionInfo.inferredReturnType = inferredReturnType;
    kFunctionInfo.sideEffects = sideEffects;
    kFunctionInfo.inlinedCount = inlinedCount;
    kFunctionInfo.code = code;
    kFunctionInfo.outputUnit = _unitInfoForMember(function);

    int closureSize = _addClosureInfo(kFunctionInfo, function);
    kFunctionInfo.size = size + closureSize;

    kFunctionInfo.treeShakenStatus = TreeShakenStatus.Live;
    return kFunctionInfo;
  }

  /// Adds closure information to [info], using all nested closures in [member].
  ///
  /// Returns the total size of the nested closures, to add to the info size.
  int _addClosureInfo(BasicInfo info, MemberEntity member) {
    assert(info is FunctionInfo || info is FieldInfo);
    int size = 0;
    List<ClosureInfo> nestedClosures = <ClosureInfo>[];
    environment.forEachNestedClosure(member, (closure) {
      ClosureInfo closureInfo = visitClosureClass(closure.enclosingClass);
      if (closureInfo != null) {
        closureInfo.parent = info;
        closureInfo.treeShakenStatus = info.treeShakenStatus;
        nestedClosures.add(closureInfo);
        size += closureInfo.size;
      }
    });
    if (info is FunctionInfo) info.closures = nestedClosures;
    if (info is FieldInfo) info.closures = nestedClosures;

    return size;
  }

  OutputUnitInfo _infoFromOutputUnit(OutputUnit outputUnit) {
    return kernelInfo._outputToInfo.putIfAbsent(outputUnit, () {
      // Dump-info currently only works with the full emitter. If another
      // emitter is used it will fail here.
      JsBackendStrategy backendStrategy = compiler.backendStrategy;
      assert(outputUnit.name != null || outputUnit.isMainOutput);
      var filename = outputUnit.isMainOutput
          ? compiler.options.outputUri.pathSegments.last
          : deferredPartFileName(compiler.options, outputUnit.name);
      OutputUnitInfo info = OutputUnitInfo(filename, outputUnit.name,
          backendStrategy.emitterTask.emitter.generatedSize(outputUnit));
      info.treeShakenStatus = TreeShakenStatus.Live;
      info.imports
          .addAll(closedWorld.outputUnitData.getImportNames(outputUnit));
      kernelInfo.result.outputUnits.add(info);
      return info;
    });
  }

  OutputUnitInfo _unitInfoForMember(MemberEntity entity) {
    return _infoFromOutputUnit(
        closedWorld.outputUnitData.outputUnitForMember(entity));
  }

  OutputUnitInfo _unitInfoForClass(ClassEntity entity) {
    return _infoFromOutputUnit(
        closedWorld.outputUnitData.outputUnitForClass(entity, allowNull: true));
  }

  OutputUnitInfo _unitInfoForClassType(ClassEntity entity) {
    return _infoFromOutputUnit(closedWorld.outputUnitData
        .outputUnitForClassType(entity, allowNull: true));
  }

  OutputUnitInfo _unitInfoForConstant(ConstantValue constant) {
    OutputUnit outputUnit =
        closedWorld.outputUnitData.outputUnitForConstant(constant);
    if (outputUnit == null) {
      assert(constant is InterceptorConstantValue);
      return null;
    }
    return _infoFromOutputUnit(outputUnit);
  }
}

class Selection {
  final Entity selectedEntity;
  final Object receiverConstraint;
  Selection(this.selectedEntity, this.receiverConstraint);
}

/// Interface used to record information from different parts of the compiler so
/// we can emit them in the dump-info task.
// TODO(sigmund,het): move more features here. Ideally the dump-info task
// shouldn't reach into internals of other parts of the compiler. For example,
// we currently reach into the full emitter and as a result we don't support
// dump-info when using the startup-emitter (issue #24190).
abstract class InfoReporter {
  void reportInlined(FunctionEntity element, MemberEntity inlinedFrom);
}

class DumpInfoTask extends CompilerTask implements InfoReporter {
  final Compiler compiler;
  final bool useBinaryFormat;

  DumpInfoTask(this.compiler)
      : useBinaryFormat = compiler.options.useDumpInfoBinaryFormat,
        super(compiler.measurer);

  @override
  String get name => "Dump Info";

  /// The size of the generated output.
  int _programSize;

  /// Data associated with javascript AST nodes. The map only contains keys for
  /// nodes that we care about.  Keys are automatically added when
  /// [registerEntityAst] is called.
  final Map<jsAst.Node, CodeSpan> _nodeData = <jsAst.Node, CodeSpan>{};

  // A mapping from Dart Entities to Javascript AST Nodes.
  final Map<Entity, List<jsAst.Node>> _entityToNodes =
      <Entity, List<jsAst.Node>>{};
  final Map<ConstantValue, jsAst.Node> _constantToNode =
      <ConstantValue, jsAst.Node>{};

  final Map<Entity, int> inlineCount = <Entity, int>{};

  // A mapping from an entity to a list of entities that are
  // inlined inside of it.
  final Map<Entity, List<Entity>> inlineMap = <Entity, List<Entity>>{};

  final Map<MemberEntity, WorldImpact> impacts = <MemberEntity, WorldImpact>{};

  /// Register the size of the generated output.
  void reportSize(int programSize) {
    _programSize = programSize;
  }

  @override
  void reportInlined(FunctionEntity element, MemberEntity inlinedFrom) {
    inlineCount.putIfAbsent(element, () => 0);
    inlineCount[element] += 1;
    inlineMap.putIfAbsent(inlinedFrom, () => <Entity>[]);
    inlineMap[inlinedFrom].add(element);
  }

  void registerImpact(MemberEntity member, WorldImpact impact) {
    if (compiler.options.dumpInfo) {
      impacts[member] = impact;
    }
  }

  void unregisterImpact(var impactSource) {
    impacts.remove(impactSource);
  }

  /// Returns an iterable of [Selection]s that are used by [entity]. Each
  /// [Selection] contains an entity that is used and the selector that
  /// selected the entity.
  Iterable<Selection> getRetaining(Entity entity, JClosedWorld closedWorld) {
    WorldImpact impact = impacts[entity];
    if (impact == null) return const <Selection>[];

    var selections = <Selection>[];
    impact.forEachDynamicUse((_, dynamicUse) {
      AbstractValue mask = dynamicUse.receiverConstraint;
      selections.addAll(closedWorld
          // TODO(het): Handle `call` on `Closure` through
          // `world.includesClosureCall`.
          .locateMembers(dynamicUse.selector, mask)
          .map((MemberEntity e) => Selection(e, mask)));
    });
    impact.forEachStaticUse((_, staticUse) {
      selections.add(Selection(staticUse.element, null));
    });
    unregisterImpact(entity);
    return selections;
  }

  /// Registers that a javascript AST node [code] was produced by the dart
  /// Entity [entity].
  void registerEntityAst(Entity entity, jsAst.Node code,
      {LibraryEntity library}) {
    if (compiler.options.dumpInfo) {
      _entityToNodes.putIfAbsent(entity, () => <jsAst.Node>[]).add(code);
      _nodeData[code] ??= useBinaryFormat ? CodeSpan() : _CodeData();
    }
  }

  void registerConstantAst(ConstantValue constant, jsAst.Node code) {
    if (compiler.options.dumpInfo) {
      assert(_constantToNode[constant] == null ||
          _constantToNode[constant] == code);
      _constantToNode[constant] = code;
      _nodeData[code] ??= useBinaryFormat ? CodeSpan() : _CodeData();
    }
  }

  bool get shouldEmitText => !useBinaryFormat;
  // TODO(sigmund): delete the stack once we stop emitting the source text.
  final List<_CodeData> _stack = [];
  void enterNode(jsAst.Node node, int start) {
    var data = _nodeData[node];
    data?.start = start;

    if (shouldEmitText && data != null) {
      _stack.add(data);
    }
  }

  void emit(String string) {
    if (shouldEmitText) {
      // Note: historically we emitted the full body of classes and methods, so
      // instance methods ended up emitted twice.  Once we use a different
      // encoding of dump info, we also plan to remove this duplication.
      _stack.forEach((f) => f._text.write(string));
    }
  }

  void exitNode(jsAst.Node node, int start, int end, int closing) {
    var data = _nodeData[node];
    data?.end = end;
    if (shouldEmitText && data != null) {
      var last = _stack.removeLast();
      assert(data == last);
      assert(data.start == start);
    }
  }

  /// Returns the size of the source code that was generated for an entity.
  /// If no source code was produced, return 0.
  int sizeOf(Entity entity) {
    if (_entityToNodes.containsKey(entity)) {
      return _entityToNodes[entity].map(sizeOfNode).fold(0, (a, b) => a + b);
    } else {
      return 0;
    }
  }

  int sizeOfNode(jsAst.Node node) {
    CodeSpan span = _nodeData[node];
    if (span == null) return 0;
    return span.end - span.start;
  }

  List<CodeSpan> codeOf(MemberEntity entity) {
    List<jsAst.Node> code = _entityToNodes[entity];
    if (code == null) return const [];
    return code.map((ast) => _nodeData[ast]).toList();
  }

  void dumpInfo(JClosedWorld closedWorld,
      GlobalTypeInferenceResults globalInferenceResults) {
    measure(() {
      ElementInfoCollector elementInfoCollector = ElementInfoCollector(
          compiler, this, closedWorld, globalInferenceResults)
        ..run();

      var allInfo = buildDumpInfoData(closedWorld, elementInfoCollector);
      if (useBinaryFormat) {
        dumpInfoBinary(allInfo);
      } else {
        dumpInfoJson(allInfo);
      }
    });
  }

  void dumpInfoNew(ir.Component component, JClosedWorld closedWorld,
      GlobalTypeInferenceResults globalInferenceResults) {
    measure(() {
      KernelInfoCollector kernelInfoCollector = KernelInfoCollector(
          component, compiler, this, closedWorld, globalInferenceResults)
        ..run();

      DumpInfoAnnotator(kernelInfoCollector, compiler, this, closedWorld,
          globalInferenceResults)
        ..run();

      var allInfo = buildDumpInfoDataNew(closedWorld, kernelInfoCollector);
      // TODO(markzipan): Filter DumpInfo here instead of passing a filter
      // filter flag through the serializers.
      if (useBinaryFormat) {
        dumpInfoBinary(allInfo);
      } else {
        dumpInfoJson(allInfo, filterTreeshaken: true);
      }
    });
  }

  void dumpInfoJson(AllInfo data, {bool filterTreeshaken = false}) {
    StringBuffer jsonBuffer = StringBuffer();
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    ChunkedConversionSink<Object> sink = encoder.startChunkedConversion(
        StringConversionSink.fromStringSink(jsonBuffer));
    sink.add(AllInfoJsonCodec(
            isBackwardCompatible: true, filterTreeshaken: filterTreeshaken)
        .encode(data));
    compiler.outputProvider.createOutputSink(
        compiler.options.outputUri.pathSegments.last,
        'info.json',
        OutputType.dumpInfo)
      ..add(jsonBuffer.toString())
      ..close();
    compiler.reporter
        .reportInfoMessage(NO_LOCATION_SPANNABLE, MessageKind.GENERIC, {
      'text': "View the dumped .info.json file at "
          "https://dart-lang.github.io/dump-info-visualizer"
    });
  }

  void dumpInfoBinary(AllInfo data, {bool filterTreeshaken = false}) {
    var name = compiler.options.outputUri.pathSegments.last + ".info.data";
    // TODO(markzipan): Plumb [filterTreeshaken] through
    // [BinaryOutputSinkAdapter].
    Sink<List<int>> sink = BinaryOutputSinkAdapter(compiler.outputProvider
        .createBinarySink(compiler.options.outputUri.resolve(name)));
    dump_info.encode(data, sink);
    compiler.reporter
        .reportInfoMessage(NO_LOCATION_SPANNABLE, MessageKind.GENERIC, {
      'text': "Use `package:dart2js_info` to parse and process the dumped "
          ".info.data file."
    });
  }

  AllInfo buildDumpInfoData(
      JClosedWorld closedWorld, ElementInfoCollector infoCollector) {
    Stopwatch stopwatch = Stopwatch();
    stopwatch.start();

    AllInfo result = infoCollector.result;

    // Recursively build links to function uses
    Iterable<Entity> functionEntities =
        infoCollector._entityToInfo.keys.where((k) => k is FunctionEntity);
    for (FunctionEntity entity in functionEntities) {
      FunctionInfo info = infoCollector._entityToInfo[entity];
      Iterable<Selection> uses = getRetaining(entity, closedWorld);
      // Don't bother recording an empty list of dependencies.
      for (Selection selection in uses) {
        // Don't register dart2js builtin functions that are not recorded.
        Info useInfo = infoCollector._entityToInfo[selection.selectedEntity];
        if (useInfo == null) continue;
        info.uses.add(
            DependencyInfo(useInfo, selection.receiverConstraint?.toString()));
      }
    }

    // Recursively build links to field uses
    Iterable<Entity> fieldEntity =
        infoCollector._entityToInfo.keys.where((k) => k is FieldEntity);
    for (FieldEntity entity in fieldEntity) {
      FieldInfo info = infoCollector._entityToInfo[entity];
      Iterable<Selection> uses = getRetaining(entity, closedWorld);
      // Don't bother recording an empty list of dependencies.
      for (Selection selection in uses) {
        Info useInfo = infoCollector._entityToInfo[selection.selectedEntity];
        if (useInfo == null) continue;
        info.uses.add(
            DependencyInfo(useInfo, selection.receiverConstraint?.toString()));
      }
    }

    // Track dependencies that come from inlining.
    for (Entity entity in inlineMap.keys) {
      CodeInfo outerInfo = infoCollector._entityToInfo[entity];
      if (outerInfo == null) continue;
      for (Entity inlined in inlineMap[entity]) {
        Info inlinedInfo = infoCollector._entityToInfo[inlined];
        if (inlinedInfo == null) continue;
        outerInfo.uses.add(DependencyInfo(inlinedInfo, 'inlined'));
      }
    }

    var fragmentsToLoad =
        compiler.backendStrategy.emitterTask.emitter.finalizedFragmentsToLoad;
    var fragmentMerger =
        compiler.backendStrategy.emitterTask.emitter.fragmentMerger;
    result.deferredFiles = fragmentMerger.computeDeferredMap(fragmentsToLoad);
    stopwatch.stop();

    result.program = ProgramInfo(
        entrypoint: infoCollector
            ._entityToInfo[closedWorld.elementEnvironment.mainFunction],
        size: _programSize,
        dart2jsVersion:
            compiler.options.hasBuildId ? compiler.options.buildId : null,
        compilationMoment: DateTime.now(),
        compilationDuration: compiler.measurer.elapsedWallClock,
        toJsonDuration: Duration(milliseconds: stopwatch.elapsedMilliseconds),
        dumpInfoDuration: Duration(milliseconds: this.timing),
        noSuchMethodEnabled: closedWorld.backendUsage.isNoSuchMethodUsed,
        isRuntimeTypeUsed: closedWorld.backendUsage.isRuntimeTypeUsed,
        isIsolateInUse: false,
        isFunctionApplyUsed: closedWorld.backendUsage.isFunctionApplyUsed,
        isMirrorsUsed: closedWorld.backendUsage.isMirrorsUsed,
        minified: compiler.options.enableMinification);

    return result;
  }

  AllInfo buildDumpInfoDataNew(
      JClosedWorld closedWorld, KernelInfoCollector infoCollector) {
    Stopwatch stopwatch = Stopwatch();
    stopwatch.start();

    AllInfo result = infoCollector.result;

    // Recursively build links to function uses
    Iterable<Entity> functionEntities =
        infoCollector._entityToInfo.keys.where((k) => k is FunctionEntity);
    for (FunctionEntity entity in functionEntities) {
      FunctionInfo info = infoCollector._entityToInfo[entity];
      Iterable<Selection> uses = getRetaining(entity, closedWorld);
      // Don't bother recording an empty list of dependencies.
      for (Selection selection in uses) {
        // Don't register dart2js builtin functions that are not recorded.
        Info useInfo = infoCollector._entityToInfo[selection.selectedEntity];
        if (useInfo == null) continue;
        if (useInfo.treeShakenStatus != TreeShakenStatus.Live) continue;
        info.uses.add(
            DependencyInfo(useInfo, selection.receiverConstraint?.toString()));
      }
    }

    // Recursively build links to field uses
    Iterable<Entity> fieldEntity =
        infoCollector._entityToInfo.keys.where((k) => k is FieldEntity);
    for (FieldEntity entity in fieldEntity) {
      FieldInfo info = infoCollector._entityToInfo[entity];
      Iterable<Selection> uses = getRetaining(entity, closedWorld);
      // Don't bother recording an empty list of dependencies.
      for (Selection selection in uses) {
        Info useInfo = infoCollector._entityToInfo[selection.selectedEntity];
        if (useInfo == null) continue;
        if (useInfo.treeShakenStatus != TreeShakenStatus.Live) continue;
        info.uses.add(
            DependencyInfo(useInfo, selection.receiverConstraint?.toString()));
      }
    }

    // Track dependencies that come from inlining.
    for (Entity entity in inlineMap.keys) {
      CodeInfo outerInfo = infoCollector._entityToInfo[entity];
      if (outerInfo == null) continue;
      for (Entity inlined in inlineMap[entity]) {
        Info inlinedInfo = infoCollector._entityToInfo[inlined];
        if (inlinedInfo == null) continue;
        if (inlinedInfo.treeShakenStatus != TreeShakenStatus.Live) continue;
        outerInfo.uses.add(DependencyInfo(inlinedInfo, 'inlined'));
      }
    }

    var fragmentsToLoad =
        compiler.backendStrategy.emitterTask.emitter.finalizedFragmentsToLoad;
    var fragmentMerger =
        compiler.backendStrategy.emitterTask.emitter.fragmentMerger;
    result.deferredFiles = fragmentMerger.computeDeferredMap(fragmentsToLoad);
    stopwatch.stop();

    result.program = ProgramInfo(
        entrypoint: infoCollector
            ._entityToInfo[closedWorld.elementEnvironment.mainFunction],
        size: _programSize,
        dart2jsVersion:
            compiler.options.hasBuildId ? compiler.options.buildId : null,
        compilationMoment: DateTime.now(),
        compilationDuration: compiler.measurer.elapsedWallClock,
        toJsonDuration: Duration(milliseconds: stopwatch.elapsedMilliseconds),
        dumpInfoDuration: Duration(milliseconds: this.timing),
        noSuchMethodEnabled: closedWorld.backendUsage.isNoSuchMethodUsed,
        isRuntimeTypeUsed: closedWorld.backendUsage.isRuntimeTypeUsed,
        isIsolateInUse: false,
        isFunctionApplyUsed: closedWorld.backendUsage.isFunctionApplyUsed,
        isMirrorsUsed: closedWorld.backendUsage.isMirrorsUsed,
        minified: compiler.options.enableMinification);

    return result;
  }
}

/// Helper class to store what dump-info will show for a piece of code.
// TODO(sigmund): delete once we no longer emit text by default.
class _CodeData extends CodeSpan {
  final StringBuffer _text = StringBuffer();
  @override
  String get text => '$_text';
  int get length => end - start;
}
