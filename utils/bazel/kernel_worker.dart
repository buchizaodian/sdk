// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A tool that invokes the CFE to compute kernel summary files.
///
/// This script can be used as a command-line command or a persistent server.
/// The server is implemented using the bazel worker protocol, so it can be used
/// within bazel as is. Other tools (like pub-build and package-build) also
/// use this persistent worker via the same protocol.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:build_integration/file_system/multi_root.dart';
import 'package:dev_compiler/src/kernel/target.dart';
import 'package:front_end/src/api_unstable/bazel_worker.dart' as fe;
import 'package:kernel/ast.dart' show Component, Library;
import 'package:kernel/target/targets.dart';
import 'package:vm/target/vm.dart';
import 'package:compiler/src/kernel/dart2js_target.dart';

main(List<String> args) async {
  args = preprocessArgs(args);

  if (args.contains('--persistent_worker')) {
    if (args.length != 1) {
      throw new StateError(
          "unexpected args, expected only --persistent-worker but got: $args");
    }
    await new KernelWorker().run();
  } else {
    var result = await computeKernel(args);
    if (!result.succeeded) {
      exitCode = 15;
    }
  }
}

/// A bazel worker loop that can compute full or summary kernel files.
class KernelWorker extends AsyncWorkerLoop {
  fe.InitializedCompilerState previousState;

  Future<WorkResponse> performRequest(WorkRequest request) async {
    var outputBuffer = new StringBuffer();
    var response = new WorkResponse()..exitCode = 0;
    try {
      fe.InitializedCompilerState previousStateToPass;
      if (request.arguments.contains("--reuse-compiler-result")) {
        previousStateToPass = previousState;
      } else {
        previousState = null;
      }
      var result = await computeKernel(request.arguments,
          isWorker: true,
          outputBuffer: outputBuffer,
          inputs: request.inputs,
          previousState: previousStateToPass);
      previousState = result.previousState;
      if (!result.succeeded) {
        response.exitCode = 15;
      }
    } catch (e, s) {
      outputBuffer.writeln(e);
      outputBuffer.writeln(s);
      response.exitCode = 15;
    }
    response.output = outputBuffer.toString();
    return response;
  }
}

/// If the last arg starts with `@`, this reads the file it points to and treats
/// each line as an additional arg.
///
/// This is how individual work request args are differentiated from startup
/// args in bazel (inidividual work request args go in that file).
List<String> preprocessArgs(List<String> args) {
  args = new List.from(args);
  if (args.isEmpty) {
    return args;
  }
  String lastArg = args.last;
  if (lastArg.startsWith('@')) {
    File argsFile = new File(lastArg.substring(1));
    try {
      args.removeLast();
      args.addAll(argsFile.readAsLinesSync());
    } on FileSystemException catch (e) {
      throw new Exception('Failed to read file specified by $lastArg : $e');
    }
  }
  return args;
}

/// An [ArgParser] for generating kernel summaries.
final summaryArgsParser = new ArgParser()
  ..addFlag('help', negatable: false, abbr: 'h')
  ..addFlag('exclude-non-sources',
      negatable: false,
      help: 'Whether source files loaded implicitly should be included as '
          'part of the summary.')
  ..addFlag('summary-only',
      defaultsTo: true,
      negatable: true,
      help: 'Whether to only build summary files.')
  ..addOption('target',
      allowed: const ['vm', 'dart2js', 'devcompiler'],
      help: 'Build kernel for the vm, dart2js, or devcompiler')
  ..addOption('dart-sdk-summary')
  ..addMultiOption('input-summary')
  ..addMultiOption('input-linked')
  ..addMultiOption('multi-root')
  ..addOption('multi-root-scheme', defaultsTo: 'org-dartlang-multi-root')
  ..addOption('libraries-file')
  ..addOption('packages-file')
  ..addMultiOption('source')
  ..addOption('output')
  ..addFlag('reuse-compiler-result', defaultsTo: false)
  ..addFlag('use-incremental-compiler', defaultsTo: false);

class ComputeKernelResult {
  final bool succeeded;
  final fe.InitializedCompilerState previousState;

  ComputeKernelResult(this.succeeded, this.previousState);
}

/// Computes a kernel file based on [args].
///
/// If [isWorker] is true then exit codes will not be set on failure.
///
/// If [outputBuffer] is provided then messages will be written to that buffer
/// instead of printed to the console.
///
/// Returns whether or not the summary was successfully output.
Future<ComputeKernelResult> computeKernel(List<String> args,
    {bool isWorker: false,
    StringBuffer outputBuffer,
    Iterable<Input> inputs,
    fe.InitializedCompilerState previousState}) async {
  dynamic out = outputBuffer ?? stderr;
  bool succeeded = true;
  var parsedArgs = summaryArgsParser.parse(args);

  if (parsedArgs['help']) {
    out.writeln(summaryArgsParser.usage);
    if (!isWorker) exit(0);
    return new ComputeKernelResult(false, previousState);
  }

  // Bazel creates an overlay file system where some files may be located in the
  // source tree, some in a gendir, and some in a bindir. The multi-root file
  // system hides this from the front end.
  var multiRoots = parsedArgs['multi-root'].map(Uri.base.resolve).toList();
  if (multiRoots.isEmpty) multiRoots.add(Uri.base);
  var fileSystem = new MultiRootFileSystem(parsedArgs['multi-root-scheme'],
      multiRoots, fe.StandardFileSystem.instance);
  var sources =
      (parsedArgs['source'] as List<String>).map(Uri.base.resolve).toList();
  var excludeNonSources = parsedArgs['exclude-non-sources'] as bool;

  var summaryOnly = parsedArgs['summary-only'] as bool;
  // TODO(sigmund,jakemac): make target mandatory. We allow null to be backwards
  // compatible while we migrate existing clients of this tool.
  var targetName =
      (parsedArgs['target'] as String) ?? (summaryOnly ? 'devcompiler' : 'vm');
  var targetFlags = new TargetFlags();
  Target target;
  switch (targetName) {
    case 'vm':
      target = new VmTarget(targetFlags);
      if (summaryOnly) {
        out.writeln('error: --summary-only not supported for the vm target');
      }
      break;
    case 'dart2js':
      target = new Dart2jsTarget('dart2js', targetFlags);
      if (summaryOnly) {
        out.writeln(
            'error: --summary-only not supported for the dart2js target');
      }
      break;
    case 'devcompiler':
      // TODO(jakemac):If `generateKernel` changes to return a summary
      // component, process the component instead.
      target = new DevCompilerSummaryTarget(sources, excludeNonSources);
      if (!summaryOnly) {
        out.writeln('error: --no-summary-only not supported for the '
            'devcompiler target');
      }
      break;
    default:
      out.writeln('error: unsupported target: $targetName');
  }

  // TODO(sigmund,jakemac): make it mandatory. We allow null while we migrate
  // existing clients of this tool.
  var librariesSpec = parsedArgs['libraries-file'] == null
      ? null
      : Uri.base.resolve(parsedArgs['libraries-file']);

  List<Uri> linkedInputs = (parsedArgs['input-linked'] as List<String>)
      .map(Uri.base.resolve)
      .toList();

  List<Uri> summaryInputs = (parsedArgs['input-summary'] as List<String>)
      .map(Uri.base.resolve)
      .toList();

  fe.InitializedCompilerState state;
  bool usingIncrementalCompiler = false;
  if (parsedArgs['use-incremental-compiler'] && linkedInputs.isEmpty) {
    usingIncrementalCompiler = true;

    /// Build a map of uris to digests.
    final inputDigests = <Uri, List<int>>{};
    for (var input in inputs) {
      var uri = Uri.parse(input.path);
      if (uri.scheme.isEmpty) {
        uri = Uri.parse('file://${input.path}');
      }
      inputDigests[uri] = input.digest;
    }

    state = await fe.initializeIncrementalCompiler(
        previousState,
        Uri.base.resolve(parsedArgs['dart-sdk-summary']),
        Uri.base.resolve(parsedArgs['packages-file']),
        librariesSpec,
        summaryInputs,
        inputDigests,
        target,
        fileSystem,
        summaryOnly);
  } else {
    state = await fe.initializeCompiler(
        // TODO(sigmund): pass an old state once we can make use of it.
        null,
        Uri.base.resolve(parsedArgs['dart-sdk-summary']),
        librariesSpec,
        Uri.base.resolve(parsedArgs['packages-file']),
        summaryInputs,
        linkedInputs,
        target,
        fileSystem);
  }

  void onDiagnostic(fe.DiagnosticMessage message) {
    fe.printDiagnosticMessage(message, out.writeln);
    succeeded = false;
  }

  List<int> kernel;
  if (usingIncrementalCompiler) {
    state.options.onDiagnostic = onDiagnostic;
    Component incrementalComponent = await state.incrementalCompiler
        .computeDelta(entryPoints: sources, fullComponent: true);
    if (summaryOnly) {
      incrementalComponent.uriToSource.clear();
      incrementalComponent.problemsAsJson = null;
      incrementalComponent.mainMethod = null;
      target.performOutlineTransformations(incrementalComponent);
    }

    kernel = fe.serializeComponent(incrementalComponent);
  } else {
    kernel = await fe.compile(state, sources, onDiagnostic,
        summaryOnly: summaryOnly);
  }

  if (kernel != null) {
    var outputFile = new File(parsedArgs['output']);
    outputFile.createSync(recursive: true);
    outputFile.writeAsBytesSync(kernel);
  } else {
    assert(!succeeded);
  }

  return new ComputeKernelResult(succeeded, state);
}

/// Extends the DevCompilerTarget to transform outlines to meet the requirements
/// of summaries in bazel and package-build.
///
/// Build systems like package-build may provide the same input file twice to
/// the summary worker, but only intends to have it in one output summary.  The
/// convention is that if it is listed as a source, it is intended to be part of
/// the output, if the source file was loaded as a dependency, then it was
/// already included in a different summary.  The transformation below ensures
/// that the output summary doesn't include those implicit inputs.
///
/// Note: this transformation is destructive and is only intended to be used
/// when generating summaries.
class DevCompilerSummaryTarget extends DevCompilerTarget {
  final List<Uri> sources;
  final bool excludeNonSources;

  DevCompilerSummaryTarget(this.sources, this.excludeNonSources);

  @override
  void performOutlineTransformations(Component component) {
    super.performOutlineTransformations(component);
    if (!excludeNonSources) return;

    List<Library> libraries = new List.from(component.libraries);
    component.libraries.clear();
    Set<Uri> include = sources.toSet();
    for (var lib in libraries) {
      if (include.contains(lib.importUri)) {
        component.libraries.add(lib);
      } else {
        // Excluding the library also means that their canonical names will not
        // be computed as part of serialization, so we need to do that
        // preemtively here to avoid errors when serializing references to
        // elements of these libraries.
        component.root.getChildFromUri(lib.importUri).bindTo(lib.reference);
        lib.computeCanonicalNames();
      }
    }
  }
}
