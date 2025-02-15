// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io' show Directory, File, Platform;

import 'package:_fe_analyzer_shared/src/testing/features.dart';
import 'package:_fe_analyzer_shared/src/testing/id.dart' show ActualData, Id;
import 'package:_fe_analyzer_shared/src/testing/id_testing.dart';
import 'package:front_end/src/api_prototype/compiler_options.dart';
import 'package:front_end/src/api_prototype/language_version.dart' as lv;
import 'package:front_end/src/builder/library_builder.dart';
import 'package:front_end/src/fasta/messages.dart' show FormattedMessage;
import 'package:front_end/src/source/source_library_builder.dart';
import 'package:front_end/src/testing/id_testing_helper.dart'
    show
        CfeDataExtractor,
        CfeDataComputer,
        CfeTestConfig,
        CfeTestResultData,
        InternalCompilerResult,
        createUriForFileName,
        onFailure,
        runTestFor;
import 'package:front_end/src/testing/id_testing_utils.dart';
import 'package:kernel/ast.dart' show Component, Library, Version;

import '../utils/symbolic_language_versions.dart';

Future<void> main(List<String> args) async {
  // Fix default/max major and minor version so we can test it.
  // This config sets it to 2.8.
  TestConfigWithLanguageVersion cfeConfig =
      new TestConfigWithLanguageVersion(cfeMarker, "cfe");

  Directory dataDir = new Directory.fromUri(Platform.script.resolve('data'));
  await runTests<Features>(dataDir,
      args: args,
      createUriForFileName: createUriForFileName,
      onFailure: onFailure,
      runTest: runTestFor(const LanguageVersioningDataComputer(), [cfeConfig]),
      skipList: [
        // Two language versions specified, the last one is ok and is used here.
        "package_default_version_is_wrong_2",
      ],
      preProcessFile: replaceMarkersWithVersions,
      postProcessFile: replaceVersionsWithMarkers);
}

class TestConfigWithLanguageVersion extends CfeTestConfig {
  TestConfigWithLanguageVersion(String marker, String name)
      : super(marker, name);

  @override
  CompilerOptions customizeCompilerOptions(
      CompilerOptions options, TestData testData) {
    options.currentSdkVersion =
        SymbolicLanguageVersion.currentVersion.version.toText();

    File f = new File.fromUri(testData.testFileUri.resolve("test.options"));
    if (f.existsSync()) {
      List<String> lines = f.readAsStringSync().split("\n");
      for (String line in lines) {
        const String packages = "--packages=";
        if (line == "" || line.startsWith("#")) continue;
        if (line.startsWith(packages)) {
          String value = line.substring(packages.length);
          options.packagesFileUri = testData.entryPoint.resolve(value);
          print("Setting package file uri to ${options.packagesFileUri}");
        } else {
          throw "Unsupported: $line";
        }
      }
    }
    return options;
  }
}

class Tags {
  static const String languageVersion = 'languageVersion';
  static const String packageUri = 'packageUri';
  static const String errors = 'errors';
}

class LanguageVersioningDataComputer extends CfeDataComputer<Features> {
  const LanguageVersioningDataComputer();

  @override
  Future<void> inspectTestResultData(CfeTestResultData testResultData) async {
    CompilerOptions options = testResultData.customData;
    Component component = testResultData.compilerResult.component!;
    for (Library library in component.libraries) {
      if (library.importUri.isScheme("dart")) continue;
      Version lvFile =
          (await lv.languageVersionForUri(library.fileUri, options)).version;
      Version lvImportUri =
          (await lv.languageVersionForUri(library.importUri, options)).version;
      if ((lvFile != lvImportUri || lvFile != library.languageVersion)) {
        throw """
Language version disagreement:
Library: ${library.languageVersion}
Language version API (file URI): ${lvFile}
Language version API (import URI): ${lvImportUri}
""";
      }
    }
  }

  @override
  void computeLibraryData(CfeTestResultData testResultData, Library library,
      Map<Id, ActualData<Features>> actualMap,
      {bool? verbose}) {
    new LanguageVersioningDataExtractor(
            testResultData.compilerResult, actualMap)
        .computeForLibrary(library);
  }

  @override
  bool get supportsErrors => true;

  @override
  Features computeErrorData(
      CfeTestResultData testResultData, Id id, List<FormattedMessage> errors) {
    Features features = new Features();
    features[Tags.errors] = errors.map((m) => m.code.name).join(',');
    return features;
  }

  @override
  DataInterpreter<Features> get dataValidator =>
      const FeaturesDataInterpreter();
}

class LanguageVersioningDataExtractor extends CfeDataExtractor<Features> {
  LanguageVersioningDataExtractor(InternalCompilerResult compilerResult,
      Map<Id, ActualData<Features>> actualMap)
      : super(compilerResult, actualMap);

  @override
  Features computeLibraryValue(Id id, Library library) {
    Features features = new Features();
    features[Tags.languageVersion] =
        "${library.languageVersion.major}.${library.languageVersion.minor}";
    LibraryBuilder? libraryBuilder =
        lookupLibraryBuilder(compilerResult, library);
    if (libraryBuilder is SourceLibraryBuilder &&
        libraryBuilder.packageUriForTesting != null) {
      features[Tags.packageUri] =
          libraryBuilder.packageUriForTesting.toString();
    }
    return features;
  }
}
